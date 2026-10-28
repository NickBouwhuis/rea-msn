#!/bin/sh
# Imports the original WLM 8.1 look (UI images, colours, strings, emoticons,
# icon) and sounds from YOUR OWN installer into $XDG_DATA_HOME/messenger-wlm.
# Nothing is bundled. Needs 7-Zip (7zz or 7z), python3 and ffmpeg:
#   sudo apt install 7zip python3 ffmpeg
# usage: linux/scripts/import-wlm-assets.sh /path/to/escargot-wlm-8.1.0178-en.msi
#        (installed from the .deb as: wlm-messenger-import /path/to/….msi)
set -eu
MSI="${1:?usage: $0 path/to/wlm-8.1.msi}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RE="$HERE/../../re/scripts"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/messenger-wlm"
SEVENZ="$(command -v 7zz || command -v 7z)"
STAGE="$DEST/.import"   # extracted installer files; overwritten on each import

mkdir -p "$STAGE"
"$SEVENZ" x -y -o"$STAGE" "$MSI" MsgrCore.cab >/dev/null
"$SEVENZ" x -y -o"$STAGE" "$STAGE/MsgrCore.cab" msgsresdll msgslangdll ctticonico \
	onlinewma typewma nudgewma newemailwma >/dev/null

python3 -I "$RE/wlm_skin.py" "$STAGE/msgsresdll" "$STAGE/msgslangdll" "$DEST/Skin" --icon "$STAGE/ctticonico"
echo "Skin installed in $DEST/Skin"

# The launcher icon (the app's .desktop entry names chat.messenger.wlm81).
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
for size in 16 32 48 256; do
	[ -f "$DEST/Skin/icon/$size.png" ] || continue
	mkdir -p "$ICONS/${size}x${size}/apps"
	cp "$DEST/Skin/icon/$size.png" "$ICONS/${size}x${size}/apps/chat.messenger.wlm81.png"
done
gtk4-update-icon-cache -q -t -f "$ICONS" 2>/dev/null || true

mkdir -p "$DEST/Sounds"
for name in online type nudge newemail; do
	ffmpeg -loglevel error -y -i "$STAGE/${name}wma" "$DEST/Sounds/$name.wav"
done
echo "Sounds installed in $DEST/Sounds"
