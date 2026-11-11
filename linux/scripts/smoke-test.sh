#!/bin/bash
# Runs Messenger for Matrix (GTK) for real and clicks through its group
# conversation features, saving a screenshot at each step: the screenshots are
# the result (see .github/workflows/gtk-smoke.yml). The other people are played
# over the Matrix API.
#
# Needs a display with a window manager's worth of room (xvfb-run), a session
# bus (dbus-run-session), and: openbox xdotool imagemagick at-spi2-core
# gir1.2-atspi-2.0 python3-gi curl jq. The homeserver is devserver/matrix's
# Synapse, fresh: alice, bob and carol with password 123456.
#
#   APP=path/to/MatrixMessengerGTK OUT=smoke \
#     dbus-run-session -- xvfb-run -a -s "-screen 0 1400x900x24" linux/scripts/smoke-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HS="${HS:-http://127.0.0.1:8008}"
APP="${APP:?path to the MatrixMessengerGTK binary}"
OUT="${OUT:-smoke}"
mkdir -p "$OUT"
exec > >(tee "$OUT/smoke.log") 2>&1
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

# --- The accounts' side of things, before the app starts ---------------------

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

# --- The app -----------------------------------------------------------------

openbox >/dev/null 2>&1 &
sleep 1
HOMEDIR="$(mktemp -d)"
GSK_RENDERER=cairo GDK_BACKEND=x11 XDG_CONFIG_HOME="$HOMEDIR/config" XDG_DATA_HOME="$HOMEDIR/data" \
	MESSENGER_MATRIX_HOMESERVER="$HS" MESSENGER_AUTOLOGIN=@alice:localhost:123456 MESSENGER_DEBUG=1 \
	"$APP" >"$OUT/app.log" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID $KEEPER 2>/dev/null' EXIT

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
place() {
	local id
	id=$(xdotool search --name "^$1\$" | tail -1) && [ -n "$id" ] && xdotool windowmove "$id" "$2" "$3"
	sleep 0.5
}
MAIN="Windows Live Messenger"

say "Signed in"
wait_for "Group conversations"
# With end-to-end encryption (matrix-rust-sdk), a new session asks to be verified.
if appears "Verify this session" 30; then
	shot 00-verify-this-session
	press "Use recovery key" --exact
	shot 00b-recovery-key
	press "Back" --exact
	press "Not now" --exact
	sleep 1
	press "Contacts menu" --exact
	shot 00c-menu-offers-verification
	press "Contacts menu" --exact
else
	echo "no verification prompt: the plain client"
fi

say "The contact list, with the invitation to Book club on top"
wait_for "has invited you to the group conversation"
shot 01-signed-in-invitation 2
at dump >"$OUT/tree-01.txt"

say "Joining it"
press "OK" --exact
sleep 2
wait_for "Book club" --in "$MAIN"
place "$MAIN" 20 20
shot 02-contact-list

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
say "Done: $([ $FAILED = 0 ] && echo 'every step found what it looked for' || echo 'some steps failed, see above')"
exit $FAILED
