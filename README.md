# Messenger: Windows Live Messenger 8.1 for macOS and Linux

This project reverse-engineers the Escargot build of Windows Live Messenger 8.1.0178 with
[rea](https://github.com/morluto/rea) and Ghidra. It then reimplements the client natively for macOS
(Swift, SwiftUI and AppKit) and Linux (Swift and GTK 4), speaking the same MSNP15 + Passport SSO +
ABCH protocols to the same Escargot servers. Both apps draw WLM 8.1's own UI resources, decoded from
your installer.

Project page: https://nickbouwhuis.github.io/rea-msn/

The reverse-engineering write-up, with addresses and evidence, is in
[docs/RE-FINDINGS.md](docs/RE-FINDINGS.md).

```
re/                    rea/Ghidra helpers, challenge oracle, DirectUI RLE decoder + skin compiler
docs/RE-FINDINGS.md    what the binaries do and how each part maps to the ports
Messenger/             Swift package
  Sources/MSNKit       shared protocol library: MSNP15 NS/SB, Passport RST + MBI, CHL/QRY, ABCH, Storage
  Sources/MatrixKit    the same client surface over Matrix (matrix-rust-sdk on macOS; experimental)
  Sources/Messenger    macOS app (SwiftUI/AppKit)
  Sources/MessengerGTK Linux app (GTK 4 via Sources/CGtk)
  Sources/msnctl       CLI: sign in, send messages, run the end-to-end scenario
  Tests/               unit tests pinned to server-generated and decompiled-code vectors
  scripts/             macOS: build-app.sh, package-dmg.sh, import-wlm-assets.sh, import-wlm-sounds.sh
linux/scripts/         Linux: import-wlm-assets.sh, install.sh, package-deb.sh, vmpal (VMPal CLI wrapper)
devserver/             Docker image of the open-source Escargot server, for local testing
devserver/matrix/      a throwaway Synapse homeserver for testing MatrixKit
```

## Install a release

Download the DMG (macOS 14+, Apple Silicon and Intel) or the `.deb` for your Ubuntu release and
architecture (`ubuntu24.04` or `ubuntu26.04`, amd64 or arm64) from the repository's Releases page. Neither contains anything from
Microsoft. After installing, import the look, emoticons and sounds from your own copy of the Escargot
WLM 8.1 installer (`escargot-wlm-8.1.0178-en.msi`):

```sh
# macOS (needs: brew install sevenzip ffmpeg)
/Applications/Messenger.app/Contents/Resources/import/Messenger/scripts/import-wlm-assets.sh ~/Downloads/escargot-wlm-8.1.0178-en.msi

# Ubuntu (the .deb recommends 7zip, python3 and ffmpeg)
sudo apt install ./wlm-messenger_*ubuntu24.04_amd64.deb
wlm-messenger-import ~/Downloads/escargot-wlm-8.1.0178-en.msi
```

Releases built without signing secrets are ad-hoc signed, so macOS blocks the first launch. Open the
app once, then allow it under System Settings › Privacy & Security › "Open Anyway".

### How releases are built

`.github/workflows/build.yml` runs on every push and pull request. It runs the unit tests, then builds:
- the universal DMG on macOS (`Messenger/scripts/package-dmg.sh`)
- a `.deb` per Ubuntu release (24.04, 26.04) and architecture (amd64, arm64), using
  `linux/scripts/package-deb.sh` with the Swift runtime statically linked. Each release needs its own
  package because system library versions differ (24.04 has `libxml2.so.2`, 26.04 `libxml2.so.16`).

The packages are uploaded as workflow artifacts. Pushing a tag such as `v0.1.0` also publishes them
as a GitHub release. To sign and notarize the DMG, add the repository secrets listed at the top of
the workflow: a Developer ID Application certificate and an App Store Connect API key.

## macOS

Requires macOS 14+ and Xcode or the Swift 5.10+ toolchain.

```sh
cd Messenger
./scripts/import-wlm-assets.sh ~/Downloads/escargot-wlm-8.1.0178-en/escargot-wlm-8.1.0178-en.msi
./scripts/build-app.sh            # → build/Messenger.app (ad-hoc signed)
open build/Messenger.app
```

The import needs `7zz`, `python3` and `ffmpeg` (`brew install sevenzip ffmpeg`). It decodes
msgsres.dll's DirectUI resources, including Microsoft's custom RLE image format, into
`~/Library/Application Support/MessengerMac/{Skin,Sounds}`. The views then use them by their original
resource IDs: the frame, header and "vapor", status icons, toolbar icons, buttons, checkboxes, the
Messenger icon, the emoticon set (32-bit, with WLM's animated emoticons), Tahoma 8 pt and the stylesheet colours. Run the import before
`build-app.sh` so the app bundle gets the real icon. Without the import the app falls back to a drawn
approximation.

## Linux

Tested on Ubuntu 26.04 (GNOME, Wayland) with Swift 6.4 from [swiftly](https://www.swift.org/install/linux/).

```sh
sudo apt install libgtk-4-dev 7zip python3 ffmpeg
linux/scripts/import-wlm-assets.sh ~/Downloads/escargot-wlm-8.1.0178-en.msi   # → ~/.local/share/messenger-wlm
linux/scripts/install.sh                                                      # → ~/.local/bin/wlm-messenger
```

`install.sh` builds a release binary (scratch path `~/.build-msn`, override with `SCRATCH=`) and adds
a "Windows Live Messenger" launcher; the import installs the Messenger icon for it. Settings are
kept in `~/.config/messenger-wlm/settings.json`. "Remember my password" uses the Secret Service
(`secret-tool`), notifications use GNotification, and sounds play through `pw-play`, `paplay` or `aplay`.

The GTK app uses the same skin data as the macOS one. Nine-slice images become CSS `border-image`, and
emoticons are inline paintables in the conversation text.

## Signing in

Sign in as `<username>@escargot.chat`. That is your Escargot username, not the e-mail address you
registered with. Create an account at https://escargot.chat if you don't have one. The "Service"
picker at the bottom of the sign-in window switches between Escargot, the local Docker server, or
another host.

## What works

- Passport/RPS SSO sign-in (MSNP15), with the WLM 8.1 client identity, challenge credentials and
  capability bits taken from the binary
- Contact list from ABCH: groups, search, personal messages, "now playing"
- Status (Online/Busy/Be Right Back/Away/On the Phone/Out to Lunch/Appear Offline), display name and
  personal message, roamed through the Storage service
- Add, delete, block and unblock contacts; the "X has added you" prompt
- Conversations: formatted text (font, colour, bold, italic), WLM emoticons, typing indicator, nudges
  (window shake), multi-packet messages, delivery-failure notices
- WLM-style toasts (macOS) or desktop notifications (Linux), sounds, and "remember me / my password"
  through the Keychain or the Secret Service

The port has no P2P stack, so display pictures, file transfer, winks, voice and video are not
supported, and neither are offline messages. See the RE notes for details.

## Matrix (experimental)

Sign in with a Matrix ID such as `@you:matrix.org` instead of an e-mail address, and the same
windows talk to a Matrix homeserver through MatrixKit. On macOS that runs on
[matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-components-swift), the engine Element X
uses, so conversations are end-to-end encrypted and your existing Element chats work. Linux still
uses a plain client-server client without encryption, until the SDK is built there. The homeserver
is found through the server's
`.well-known`; to set one by hand, use the field under "Connect to" (macOS) or "Matrix homeserver..."
in the service menu (Linux). When the homeserver signs people in through the browser (SSO, such as
MAS), the sign-in window notices and drops the password box: "Sign in" opens the homeserver's page in
your browser, which sends a one-time token back to Messenger on a 127.0.0.1 port. WLM concepts map
onto Matrix like this:

| WLM | Matrix |
| --- | --- |
| Contact list | users in `m.direct` with a DM room you're in, plus the other person in any two-person room |
| "X has added you" | an invite to a direct chat (`is_direct`); declining leaves the room and blocks |
| Block | `m.ignored_user_list` |
| Status | presence: Online is `online`, Appear Offline is `offline`, the away-type statuses are `unavailable` (shown as Away) |
| Personal message | presence `status_msg` |
| Messages | `m.room.message`; font and colour go out as HTML, and the exact WLM font in a namespaced key |
| Nudge | an `m.emote` ("* Alice just sent you a nudge.") with a namespaced flag |
| Typing | `m.typing` |

On macOS, Messenger is a session (device) on your account like any other. It keeps the session in the
Keychain, with its encryption keys in a passphrase-protected store under
`~/Library/Application Support/MessengerMac/Matrix`, so it stays the same session, and stays
verified, between launches. "Sign out" keeps it when "Remember me" is ticked, and logs it out
otherwise. After the first sign-in Messenger asks you to verify the session, by comparing emoji with
Element or another of your sessions (either side can start), or with your recovery key (Actions ▸
Verify This Session). Until then, other people's apps may not share message keys with it.
Messages that can't be decrypted yet show a notice; the message follows if its key arrives later.

Not supported yet:
- Group rooms: only one-to-one chats are shown.
- Matrix's newer OAuth 2.0 sign-in. Browser sign-in goes through the older SSO login that MAS and
  Synapse still offer for existing clients.
- Message history: like WLM, a conversation starts empty.
- Presence comes from polling every 10 seconds (the SDK doesn't expose presence events). On servers
  with presence turned off, contacts always look Offline, but you can still message them.
- Linux: encryption and verification (see above).

## Testing

```sh
cd devserver && docker compose up -d --build     # local Escargot: NS :1863, SB :1864, HTTP :8081
cd ../Messenger
swift test                                       # protocol unit tests
swift run msnctl --local e2e alice@example.com bob@example.com 123456
```

The e2e scenario signs in two clients and checks each WLM feature end to end:
sign-in, a rejected bad password, presence, name and PSM, contact add and approval, IM in both
directions, typing, nudge, offline delivery failure, block/unblock, and roaming after re-sign-in.
Seeded test accounts are `alice@`, `bob@` and `carol@example.com`, all with password `123456`.

The Matrix backend has the same scenario against a local Synapse (`@alice`, `@bob` and
`@carol:localhost`, password `123456`). On macOS it also checks, over the plain API, that the server
only ever stores ciphertext. Carol's account sends a message nobody can decrypt, which must show as a
notice and be answered encrypted (on Linux: refused). `verify-wait` and `verify` run both sides of
emoji verification between two sessions of a fresh account:

```sh
docker compose -f devserver/matrix/docker-compose.yml up -d     # Synapse on :8008
cd Messenger
swift run msnctl --matrix http://127.0.0.1:8008 e2e @alice:localhost @bob:localhost 123456 @carol:localhost
swift run msnctl --matrix http://127.0.0.1:8008 verify-wait @dave:localhost 123456 &   # first session
swift run msnctl --matrix http://127.0.0.1:8008 verify @dave:localhost 123456          # asks to be verified
```
`msnctl --escargot check you@escargot.chat -` is a read-only sign-in summary against the live
service (Appear Offline; `-` reads the password from `$MSN_PASSWORD`).

Developer hooks for both apps: `MESSENGER_SERVER=local|escargot|<host>` and
`MESSENGER_AUTOLOGIN=alice@example.com:123456` sign in directly, and `MESSENGER_DEBUG=1` prints the
MSNP wire log. For Matrix, `MESSENGER_MATRIX_HOMESERVER=http://127.0.0.1:8008` and
`MESSENGER_AUTOLOGIN=@alice:localhost:123456`; `MESSENGER_MATRIX_EPHEMERAL=1` keeps the session in
memory and a temporary folder rather than the Keychain. `MSNKIT_POSIX_TRANSPORT=1` makes macOS use the POSIX socket transport that Linux uses.

### Linux in a VMPal VM

The Linux port was developed in an Ubuntu VM run by VMPal, with this repository
shared at `/media/VMPal/rea-msn`. To let the VM reach the dev server on the Mac (192.168.128.1 on
VMPal's "local VMs" network):

```sh
cd devserver && docker compose -f docker-compose.yml -f docker-compose.vm.yml up -d
linux/scripts/vmpal exec <vm> -- /bin/bash -lc '. ~/.local/share/swiftly/env.sh &&
  swift run --package-path /media/VMPal/rea-msn/Messenger --scratch-path ~/.build-msn
  msnctl --host 192.168.128.1 e2e alice@example.com bob@example.com 123456'
```

## Reproducing the reverse engineering

```sh
re/scripts/extract.sh path/to/escargot-wlm-8.1.0178-en.msi /tmp/wlm
cp re/scripts/rea-env.sh.example re/scripts/rea-env.sh   # edit paths
. re/scripts/rea-env.sh && re/scripts/decompile.sh /tmp/wlm/targets /tmp/wlm/decomp
python3 re/scripts/xorstr.py /tmp/wlm/targets/msnmsgr.exe  # decodes the challenge product ID/key
python3 re/scripts/wlm_skin.py msgsresdll msgslangdll out/  # DirectUI resources → skin.json + PNGs
```

## Legal

Windows Live Messenger and its assets are Microsoft's. The apps and their releases contain no
Microsoft code, artwork or sounds: the UI images, icon, emoticons, strings and sounds are only decoded
locally from an installer you already have. The one exception is the project page, whose example
conversation shows ten of Messenger's emoticons and its default display picture (`site/emoticons`,
`site/pictures`) for illustration. Reverse engineering was done for interoperability with the Escargot
service. The dev server image clones the Escargot server source (CC BY-NC 4.0) at build time.
