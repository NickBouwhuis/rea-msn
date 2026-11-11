#!/bin/bash
# Runs the GTK apps for real and clicks through them, saving a screenshot at
# each step: the screenshots are the result (see .github/workflows/gtk-smoke.yml).
#
# SCENARIO=matrix (the default): Messenger for Matrix against devserver/matrix's
# Synapse, fresh (alice, bob and carol, password 123456), through its group
# conversation features; the other people are played over the Matrix API. With
# MSNCTL (the msnctl binary, built on matrix-rust-sdk), it is also verified
# by emoji against another session of the account, and a picture is pasted.
# With KEYRING=1 (a keyring runs in the session), the session must be in it.
# SCENARIO=escargot: Windows Live Messenger against devserver's Escargot
# server: signs in, has no Matrix items in its menu, and gets a message that
# MSNCTL (the msnctl binary) sends as Bob.
#
# Needs a display with a window manager's worth of room (xvfb-run), a session
# bus (dbus-run-session), and: openbox xdotool imagemagick at-spi2-core
# gir1.2-atspi-2.0 python3-gi curl jq (and xclip, libsecret-tools, gnome-keyring).
#
#   APP=path/to/MatrixMessengerGTK OUT=smoke \
#     dbus-run-session -- xvfb-run -a -s "-screen 0 1400x900x24" linux/scripts/smoke-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HS="${HS:-http://127.0.0.1:8008}"
SCENARIO="${SCENARIO:-matrix}"
APP="${APP:?path to the MatrixMessengerGTK (or, for SCENARIO=escargot, MessengerGTK) binary}"
OUT="${OUT:-smoke}"
mkdir -p "$OUT"
exec > >(tee "$OUT/smoke-$SCENARIO.log") 2>&1
FAILED=0

say() { echo; echo "== $*"; }
enc() { jq -rn --arg s "$1" '$s|@uri'; }
login() {
	curl -sS -X POST -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$1\"},\"password\":\"123456\"}" \
		"$HS/_matrix/client/v3/login" | jq -r .access_token
}
# api TOKEN METHOD PATH [JSON]
api() {
	curl -sS -X "$2" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' ${4:+-d "$4"} "$HS/_matrix/client/v3$3"
}

# --- Matrix: the accounts' side of things, before the app starts --------------

matrix_setup() {
# Another session of Alice's, there first: it sets up cross-signing, so the
# app's session starts unverified, and it accepts a verification and confirms
# the emoji. (msnctl has "verify-wait" only when built on matrix-rust-sdk.)
if [ -n "${MSNCTL:-}" ]; then
	stdbuf -oL "$MSNCTL" --matrix "$HS" verify-wait @alice:localhost 123456 900 >"$OUT/verify-responder.log" 2>&1 &
	RESPONDER=$!
	for _ in $(seq 1 60); do grep -q "Signed in as" "$OUT/verify-responder.log" && break; sleep 1; done
	sleep 5
fi
A=$(login alice) B=$(login bob) C=$(login carol)
for who in "$A Alice @alice:localhost" "$B Bob @bob:localhost" "$C Carol @carol:localhost"; do
	set -- $who
	api "$1" PUT "/profile/$(enc "$3")/displayname" "{\"displayname\":\"$2\"}" >/dev/null
done
# Bob and Carol are on Alice's contact list (direct chats).
dm_bob=$(api "$A" POST /createRoom '{"preset":"trusted_private_chat","is_direct":true,"invite":["@bob:localhost"]}' | jq -r .room_id)
dm_carol=$(api "$A" POST /createRoom '{"preset":"trusted_private_chat","is_direct":true,"invite":["@carol:localhost"]}' | jq -r .room_id)
api "$B" POST "/join/$(enc "$dm_bob")" '{}' >/dev/null
api "$C" POST "/join/$(enc "$dm_carol")" '{}' >/dev/null
api "$A" PUT "/user/$(enc @alice:localhost)/account_data/m.direct" \
	"{\"@bob:localhost\":[\"$dm_bob\"],\"@carol:localhost\":[\"$dm_carol\"]}" >/dev/null
# A group she is in, an invitation to another, and a public room to join by address.
group=$(api "$B" POST /createRoom '{"preset":"private_chat","name":"Weekend plans","topic":"Where shall we go?","invite":["@alice:localhost","@carol:localhost"]}' | jq -r .room_id)
api "$A" POST "/join/$(enc "$group")" '{}' >/dev/null
api "$C" POST "/join/$(enc "$group")" '{}' >/dev/null
# Said before she signs in: history, which the encrypting client shows greyed above the conversation.
api "$B" PUT "/rooms/$(enc "$group")/send/m.room.message/smoke0" '{"msgtype":"m.text","body":"Shall we plan the weekend?"}' >/dev/null
sleep 12  # history is what is older than her sign-in (less 10 s)
api "$C" POST /createRoom '{"preset":"private_chat","name":"Book club","invite":["@alice:localhost"]}' >/dev/null
api "$C" POST /createRoom '{"preset":"public_chat","name":"Open room","room_alias_name":"open-room"}' >/dev/null
# Bob and Carol stay online, so that Invite lists them.
(while true; do
	api "$B" PUT "/presence/$(enc @bob:localhost)/status" '{"presence":"online"}' >/dev/null
	api "$C" PUT "/presence/$(enc @carol:localhost)/status" '{"presence":"online"}' >/dev/null
	sleep 10
done) &
KEEPER=$!
}

# --- The app -----------------------------------------------------------------

KEEPER=
RESPONDER=
APP_PID=
APP_HOME=
ENCRYPTING=
trap 'kill $APP_PID $KEEPER $RESPONDER 2>/dev/null' EXIT
# launch NAME=VALUE...: the app, signed in through its development hooks.
launch() {
	openbox >/dev/null 2>&1 &
	sleep 1
	APP_HOME="$(mktemp -d)"
	env GSK_RENDERER=cairo GDK_BACKEND=x11 XDG_CONFIG_HOME="$APP_HOME/config" XDG_DATA_HOME="$APP_HOME/data" MESSENGER_DEBUG=1 "$@" \
		"$APP" >"$OUT/app-$SCENARIO.log" 2>&1 &
	APP_PID=$!
}

at() { python3 "$HERE/smoke-at.py" "$@"; }
# shot NAME [SECONDS to settle]
shot() {
	sleep "${2:-1.5}"
	import -window root "$OUT/$1.png" && echo "shot $1"
}
# wait_for TEXT [find options]: until a widget with TEXT shows.
wait_for() {
	for _ in $(seq 1 40); do
		at find "$@" >/dev/null 2>&1 && return 0
		sleep 1
	done
	echo "!! never showed: $*"
	FAILED=1
	return 1
}
# appears TEXT SECONDS [find options]: whether a widget with TEXT shows in time (not a failure if not).
appears() {
	local text=$1 seconds=$2
	shift 2
	for _ in $(seq 1 "$seconds"); do
		at find "$text" "$@" >/dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}
# click BUTTON TEXT [find options]: 1 left, 3 right.
click() {
	local button=$1 pos
	shift
	pos=$(at find "$@") || { echo "!! nothing to click: $*"; FAILED=1; return 1; }
	echo "click $button at $pos: $*"
	xdotool mousemove $pos
	sleep 0.3
	xdotool click "$button"
	sleep 1
	xdotool mousemove 1300 850  # away, so no tooltip covers the next widget
}
# press TEXT [find options]: a button or menu item, through its accessible action.
press() {
	if at press "$@"; then echo "press: $*"; else echo "!! nothing to press: $*"; FAILED=1; return 1; fi
	sleep 1
}
# type_in PROMPT-TITLE TEXT: fills in the prompt dialog that just opened (its
# box has the focus) and confirms. Nothing is typed if it didn't open: keys
# would land wherever the focus is.
type_in() {
	wait_for "$1" --exact || return 1
	xdotool key ctrl+a
	xdotool type --delay 40 "$2"
	shot "$3"
	xdotool key Return
	sleep 1
}
double_click() {
	local pos
	pos=$(at find "$@") || { echo "!! nothing to double-click: $*"; FAILED=1; return 1; }
	echo "double-click at $pos: $*"
	xdotool mousemove $pos
	sleep 0.3
	xdotool click --repeat 2 --delay 120 1
	sleep 1
	xdotool mousemove 1300 850
}
# place WINDOW-TITLE X Y: conversation windows go beside the contact list.
# Dialogs have the main window's title: of the windows called that, the
# tallest is meant.
place() {
	local best= height=0 id h
	for id in $(xdotool search --name "^$1\$"); do
		h=$(xdotool getwindowgeometry --shell "$id" | sed -n 's/^HEIGHT=//p')
		if [ "${h:-0}" -gt "$height" ]; then best=$id height=$h; fi
	done
	[ -n "$best" ] && xdotool windowmove "$best" "$2" "$3"
	sleep 0.5
}
MAIN="Windows Live Messenger"

# --- Windows Live Messenger (Escargot) ----------------------------------------

escargot_scenario() {
launch MESSENGER_SERVER=local MESSENGER_AUTOLOGIN=alice@example.com:123456

say "Signed in to the Escargot dev server"
wait_for "You don't have any contacts yet."
place "$MAIN" 20 20
shot e01-signed-in 2

say "Its Contacts menu has nothing of Matrix's"
press "Contacts menu" --exact
shot e02-contacts-menu
at find "Add a contact..." --exact >/dev/null 2>&1 || { echo "!! no Add a contact... in the menu"; FAILED=1; }
for item in "Start a group conversation..." "Verify this session..."; do
	if at find "$item" --exact >/dev/null 2>&1; then
		echo "!! the menu offers $item"
		FAILED=1
	fi
done
press "Contacts menu" --exact

say "A message from Bob opens a conversation"
"${MSNCTL:?path to the msnctl binary}" --local say bob@example.com 123456 alice@example.com "Hello from Bob" 8 >"$OUT/msnctl-escargot.log" 2>&1 &
wait_for "Bob" --in "Bob"
place "Bob" 420 20
shot e03-conversation 4
at dump >"$OUT/tree-escargot.txt"
}

# --- Messenger for Matrix ------------------------------------------------------

matrix_scenario() {
matrix_setup
launch MESSENGER_MATRIX_HOMESERVER="$HS" MESSENGER_AUTOLOGIN=@alice:localhost:123456

say "Signed in: the contact list, with the invitation to Book club on top"
wait_for "Group conversations"
wait_for "has invited you to the group conversation"
shot 01-signed-in-invitation 2
at dump >"$OUT/tree-01.txt"

say "Joining it"
press "OK" --exact
sleep 2
wait_for "Book club" --in "$MAIN"
place "$MAIN" 20 20
shot 02-contact-list

# With end-to-end encryption, a session that isn't the account's first asks to
# be verified. (Not the plain client, nor an account's first session, which
# sets up cross-signing itself.)
if appears "Verify this session" 40 --exact; then
	ENCRYPTING=1
	say "Verifying this session: the recovery key's page, then emoji with the other session"
	shot 02a-verify-this-session
	press "Use recovery key" --exact
	shot 02b-recovery-key
	press "Back" --exact
	press "Use another session" --exact
	if appears "Do these appear on your other session, in the same order?" 60; then
		shot 02c-emoji
		press "They match" --exact
		if appears "This session is verified" 60; then shot 02d-verified; else echo "!! the session wasn't verified"; FAILED=1; fi
		press "OK" --exact
	else
		echo "!! no emoji to compare"
		FAILED=1
		shot 02c-no-emoji
		press "Cancel" --exact || press "Close" --exact
	fi
	sleep 2
	press "Contacts menu" --exact
	shot 02e-contacts-menu-after
	if at find "Verify this session..." --exact >/dev/null 2>&1; then
		echo "!! the menu still offers to verify"
		FAILED=1
	fi
	press "Contacts menu" --exact
	place "$MAIN" 20 20
else
	echo "no verification prompt (the plain client, or the account's first session)"
fi

say "A message in a group opens its window"
api "$B" PUT "/rooms/$(enc "$group")/send/m.room.message/smoke1" '{"msgtype":"m.text","body":"Who is in for Saturday?"}' >/dev/null
wait_for "Weekend plans" --in "Weekend plans"
place "Weekend plans" 420 20
api "$C" PUT "/rooms/$(enc "$group")/send/m.room.message/smoke2" '{"msgtype":"m.text","body":"Me!"}' >/dev/null
shot 03-group-window 3

say "Right-click a group: Rename, Leave; leaving asks first"
click 3 "Weekend plans" --in "$MAIN"
shot 04-group-menu
press "Leave group conversation..." --exact && wait_for "Are you sure you want to leave the group conversation Weekend plans?" && {
	shot 05-leave-confirmation
	press "Cancel" --exact
}

say "The Contacts menu: start a group conversation"
press "Contacts menu" --exact
shot 06-contacts-menu
# Exactly: the menu button's own accessible name has its items' text in it.
press "Start a group conversation..." --exact && type_in "Start a group conversation" "Trip planning" 07-new-group-prompt && {
	wait_for "Trip planning" --in "Trip planning"
	place "Trip planning" 420 400
	shot 08-new-group 2
}

say "Rename it"
click 3 "Trip planning" --in "$MAIN" && press "Rename..." --exact && type_in "Rename group conversation" "Trip to Texel" 09-rename-prompt && {
	wait_for "Trip to Texel" --in "$MAIN"
	shot 10-renamed 2
}

say "Add a contact, with a room's address: joins it"
press "Contacts menu" --exact && press "Add a contact..." --exact && type_in "Add a Contact" "#open-room:localhost" 11-add-contact-prompt && {
	wait_for "Open room" --in "$MAIN"
	shot 12-joined-by-address 2
}

say "Invite in a one-to-one conversation: a group of its own opens"
double_click "Bob" --exact --in "$MAIN" && wait_for "Bob" --in "Bob" && {
	place "Bob" 420 20
	if [ -n "$ENCRYPTING" ]; then
		# Pasting a picture into the message box (the second text box; the
		# first is the transcript) asks, then sends it.
		convert -size 48x48 xc:tomato "$OUT/pasted.png"
		xclip -selection clipboard -t image/png -i "$OUT/pasted.png"
		click 1 "" --role text --in "Bob" --nth 1
		xdotool key ctrl+v
		if appears "Send the picture you pasted to Bob?" 15; then
			shot 12a-paste-confirmation
			press "Send" --exact --in "$MAIN"
			shot 12b-picture-sent 3
			if api "$B" GET "/rooms/$(enc "$dm_bob")/messages?dir=b&limit=10" | jq -e '[.chunk[] | select(.content.msgtype == "m.image")] | length > 0' >/dev/null; then
				echo "the picture reached Bob"
			else
				echo "!! no picture reached Bob"
				FAILED=1
			fi
		else
			echo "!! pasting a picture didn't ask to send it"
			FAILED=1
		fi
	fi
	press "Invite" --in "Bob"
	shot 13-invite-menu
	press "Carol" --exact --in "Bob" && wait_for "Alice, Bob, Carol" --in "Alice, Bob, Carol" && {
		place "Alice, Bob, Carol" 760 300
		shot 14-group-from-invite 3
	}
}

say "Leaving a group, after the confirmation"
click 3 "Weekend plans" --in "$MAIN" && press "Leave group conversation..." --exact && press "Leave" --exact
sleep 3
if at find "Weekend plans" --in "$MAIN" >/dev/null 2>&1; then
	echo "!! Weekend plans is still listed"
	FAILED=1
fi
shot 15-after-leaving
at dump >"$OUT/tree-final.txt"

if [ -n "${KEYRING:-}" ] && [ -n "$ENCRYPTING" ]; then
	say "The session is kept in the keyring, not in a file"
	if secret-tool lookup application messenger-wlm-matrix-session account @alice:localhost | jq -e '.accessToken | length > 0' >/dev/null 2>&1; then
		echo "it is in the keyring"
	else
		echo "!! no session in the keyring"
		FAILED=1
	fi
	if ls "$APP_HOME/data/messenger-wlm-matrix/Matrix/Sessions"/*.json >/dev/null 2>&1; then
		echo "!! there is a session file too"
		FAILED=1
	fi
fi
}

case "$SCENARIO" in
	matrix) matrix_scenario ;;
	escargot) escargot_scenario ;;
	*) echo "SCENARIO is matrix or escargot" >&2; exit 2 ;;
esac
say "Done: $([ $FAILED = 0 ] && echo 'every step found what it looked for' || echo 'some steps failed, see above')"
exit $FAILED
