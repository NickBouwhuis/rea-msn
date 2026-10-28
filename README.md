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
  Sources/Messenger    macOS app (SwiftUI/AppKit)
  Sources/MessengerGTK Linux app (GTK 4 via Sources/CGtk)
  Sources/msnctl       CLI: sign in, send messages, run the end-to-end scenario
  Tests/               unit tests pinned to server-generated and decompiled-code vectors
  scripts/             macOS: build-app.sh, package-dmg.sh, import-wlm-assets.sh, import-wlm-sounds.sh
linux/scripts/         Linux: import-wlm-assets.sh, install.sh, package-deb.sh, vmpal (VMPal CLI wrapper)
devserver/             Docker image of the open-source Escargot server, for local testing
```

## Install a release

Download the DMG (macOS 14+, Apple Silicon and Intel) or the `.deb` for your Ubuntu release and
architecture (`ubuntu24.04` or `ubuntu26.04`, amd64 or arm64) from the repository's Releases page.
Apart from the Messenger icon, neither contains anything from Microsoft. After installing, import the
look, emoticons and sounds from your own copy of the Escargot WLM 8.1 installer
(`escargot-wlm-8.1.0178-en.msi`):

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
as a GitHub release. To sign and notarize the DMG, run `Messenger/scripts/set-signing-secrets.sh` with your exported
Developer ID Application certificate (.p12) and an App Store Connect API key; it stores them as the
repository secrets the workflow uses, and its header explains how to get both.

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
emoticon set (32-bit, with WLM's animated emoticons), Tahoma 8 pt and the stylesheet colours. Without
the import the app falls back to a drawn approximation. The app icon comes from `assets/icon`.

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
`msnctl --escargot check you@escargot.chat -` is a read-only sign-in summary against the live
service (Appear Offline; `-` reads the password from `$MSN_PASSWORD`).

Developer hooks for both apps: `MESSENGER_SERVER=local|escargot|<host>` and
`MESSENGER_AUTOLOGIN=alice@example.com:123456` sign in directly, and `MESSENGER_DEBUG=1` prints the
MSNP wire log. `MSNKIT_POSIX_TRANSPORT=1` makes macOS use the POSIX socket transport that Linux uses.

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

Windows Live Messenger and its assets are Microsoft's. Apart from the Messenger icon (`assets/icon`,
from WLM 8.1's `ctticon.ico`), the apps and their releases contain no Microsoft code, artwork or
sounds: the UI images, emoticons, strings and sounds are only decoded locally from an installer you
already have. The project page's example conversation also shows ten of Messenger's emoticons and its
default display picture (`site/emoticons`, `site/pictures`) for illustration. Reverse engineering was done for interoperability with the Escargot
service. The dev server image clones the Escargot server source (CC BY-NC 4.0) at build time.
