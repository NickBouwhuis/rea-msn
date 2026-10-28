#!/bin/sh
# Imports the original WLM 8.1 look (UI images, colours, strings, emoticons,
# icon) and sounds from YOUR OWN installer into
# ~/Library/Application Support/MessengerMac.
# Nothing is bundled with the app; Messenger falls back to a drawn look
# without it. Needs 7-Zip (7zz), python3 and ffmpeg (brew install sevenzip ffmpeg).
#
# usage: scripts/import-wlm-assets.sh /path/to/escargot-wlm-8.1.0178-en.msi
set -eu
MSI="${1:?usage: $0 path/to/wlm-8.1.msi}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RE="$HERE/../../re/scripts"
DEST="$HOME/Library/Application Support/MessengerMac"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

7zz x -y -o"$WORK/msi" "$MSI" MsgrCore.cab >/dev/null
7zz x -y -o"$WORK/cab" "$WORK/msi/MsgrCore.cab" msgsresdll msgslangdll ctticonico >/dev/null

rm -rf "$DEST/Skin.new"
python3 -I "$RE/wlm_skin.py" "$WORK/cab/msgsresdll" "$WORK/cab/msgslangdll" "$DEST/Skin.new" --icon "$WORK/cab/ctticonico"
rm -rf "$DEST/Skin"
mv "$DEST/Skin.new" "$DEST/Skin"
echo "Skin installed in $DEST/Skin"

"$HERE/import-wlm-sounds.sh" "$MSI"
