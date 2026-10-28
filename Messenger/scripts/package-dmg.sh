#!/bin/sh
# Builds Messenger.app (see build-app.sh for ARCHS/VERSION/SIGN_IDENTITY) and
# packages it as build/Messenger-$VERSION.dmg with an Applications link.
# With App Store Connect API credentials it notarizes and staples the app, so
# a copy taken out of the DMG passes Gatekeeper offline too, and then the DMG:
#   NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid>
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0}"
DMG="build/Messenger-$VERSION.dmg"

# Submits a file for notarization and fails, printing Apple's log, unless accepted.
notarize() {
	result="$(xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait --output-format json)"
	echo "$result"
	status="$(echo "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))')"
	if [ "$status" != Accepted ]; then
		id="$(echo "$result" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))')"
		[ -z "$id" ] || xcrun notarytool log "$id" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
		echo "notarization of $1: $status" >&2
		exit 1
	fi
}

./scripts/build-app.sh

if [ -n "${NOTARY_KEY:-}" ]; then
	ditto -c -k --keepParent build/Messenger.app build/Messenger-notarize.zip
	notarize build/Messenger-notarize.zip
	xcrun stapler staple build/Messenger.app
fi

rm -rf build/dmg
mkdir -p build/dmg
cp -R build/Messenger.app build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Messenger -srcfolder build/dmg -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ "${SIGN_IDENTITY:--}" != "-" ]; then
	codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_KEY:-}" ]; then
	notarize "$DMG"
	xcrun stapler staple "$DMG"
fi
echo "Packaged $DMG"
