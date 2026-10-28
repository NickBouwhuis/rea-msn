#!/bin/sh
# Builds MessengerGTK (release) and installs it for the current user:
# ~/.local/bin/wlm-messenger and a launcher entry. import-wlm-assets.sh adds
# the Messenger icon along with the skin.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/../../Messenger"
SCRATCH="${SCRATCH:-$HOME/.build-msn}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_ID=chat.messenger.wlm81

swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" --product MessengerGTK
mkdir -p "$HOME/.local/bin"
install -m 755 "$SCRATCH/release/MessengerGTK" "$HOME/.local/bin/wlm-messenger"

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
