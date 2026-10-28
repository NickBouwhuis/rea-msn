#!/bin/sh
# Builds MessengerGTK (release) and installs it for the current user:
# ~/.local/bin/wlm-messenger, a launcher entry and the Messenger icon.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/../../Messenger"
SCRATCH="${SCRATCH:-$HOME/.build-msn}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_ID=chat.messenger.wlm81

swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" --product MessengerGTK
mkdir -p "$HOME/.local/bin"
install -m 755 "$SCRATCH/release/MessengerGTK" "$HOME/.local/bin/wlm-messenger"

for size in 16 32 48 256; do
	install -D -m 644 "$HERE/../../assets/icon/$size.png" "$DATA/icons/hicolor/${size}x$size/apps/$APP_ID.png"
done
gtk4-update-icon-cache -q -t -f "$DATA/icons/hicolor" 2>/dev/null || true

mkdir -p "$DATA/applications"
cat > "$DATA/applications/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Windows Live Messenger
Comment=Chat with your Escargot (MSN) contacts
Exec=$HOME/.local/bin/wlm-messenger
Icon=$APP_ID
Categories=Network;InstantMessaging;
StartupWMClass=$APP_ID
DESKTOP
echo "Installed wlm-messenger; find it as Windows Live Messenger in your apps."
