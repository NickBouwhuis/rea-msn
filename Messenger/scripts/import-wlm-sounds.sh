#!/bin/sh
# Imports the original WLM 8.1 sounds from YOUR OWN installer (.msi) into
# ~/Library/Application Support/MessengerMac/Sounds for local use. Nothing is
# bundled with the app. Needs 7-Zip (7zz) and ffmpeg (brew install sevenzip ffmpeg).
#
# usage: scripts/import-wlm-sounds.sh /path/to/escargot-wlm-8.1.0178-en.msi
set -eu
MSI="${1:?usage: $0 path/to/wlm-8.1.msi}"
DEST="$HOME/Library/Application Support/MessengerMac/Sounds"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

7zz x -y -o"$WORK/msi" "$MSI" MsgrCore.cab >/dev/null
7zz x -y -o"$WORK/cab" "$WORK/msi/MsgrCore.cab" onlinewma typewma nudgewma newemailwma >/dev/null
mkdir -p "$DEST"
for pair in online:onlinewma type:typewma nudge:nudgewma newemail:newemailwma; do
	name="${pair%%:*}"; src="${pair#*:}"
	ffmpeg -loglevel error -y -i "$WORK/cab/$src" -c:a aac -b:a 128k "$DEST/$name.m4a"
	echo "imported $name.m4a"
done
echo "Sounds installed in $DEST"
