#!/bin/sh
# Builds Messenger.app (see build-app.sh for ARCHS/VERSION/SIGN_IDENTITY) and
# packages it as build/Messenger-$VERSION.dmg with an Applications link.
# Notarizes and staples the DMG when App Store Connect API credentials are set:
#   NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid>
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0}"
DMG="build/Messenger-$VERSION.dmg"

# Never ship Microsoft's icon: users get it from their own installer at runtime.
NO_IMPORTED_ICON=1 ./scripts/build-app.sh

rm -rf build/dmg
mkdir -p build/dmg
cp -R build/Messenger.app build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Messenger -srcfolder build/dmg -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ "${SIGN_IDENTITY:--}" != "-" ]; then
	codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_KEY:-}" ]; then
	xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
	xcrun stapler staple "$DMG"
fi
echo "Packaged $DMG"
