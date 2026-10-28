#!/bin/sh
# Builds MessengerGTK (release) and installs it for the current user:
# ~/.local/bin/wlm-messenger, a launcher entry and the Messenger icon.
# VARIANT=matrix installs Messenger for Matrix as wlm-messenger-matrix instead.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/../../Messenger"
SCRATCH="${SCRATCH:-$HOME/.build-msn}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
case "${VARIANT:-escargot}" in
	matrix) PRODUCT=MatrixMessengerGTK NAME=wlm-messenger-matrix APP_ID=chat.messenger.wlm81.matrix TITLE="Messenger for Matrix" COMMENT="Chat with your Matrix contacts" ;;
	escargot) PRODUCT=MessengerGTK NAME=wlm-messenger APP_ID=chat.messenger.wlm81 TITLE="Windows Live Messenger" COMMENT="Chat with your Escargot (MSN) contacts" ;;
	*) echo "VARIANT is escargot or matrix" >&2; exit 2 ;;
esac

swift build -c release --package-path "$PKG" --scratch-path "$SCRATCH" --product "$PRODUCT"
mkdir -p "$HOME/.local/bin"
install -m 755 "$SCRATCH/release/$PRODUCT" "$HOME/.local/bin/$NAME"

for size in 16 32 48 256; do
	install -D -m 644 "$HERE/../../assets/icon/$size.png" "$DATA/icons/hicolor/${size}x$size/apps/$APP_ID.png"
done
gtk4-update-icon-cache -q -t -f "$DATA/icons/hicolor" 2>/dev/null || true

mkdir -p "$DATA/applications"
cat > "$DATA/applications/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$TITLE
Comment=$COMMENT
Exec=$HOME/.local/bin/$NAME
Icon=$APP_ID
Categories=Network;InstantMessaging;
StartupWMClass=$APP_ID
DESKTOP
echo "Installed $NAME; find it as $TITLE in your apps."
