#!/bin/sh
# Builds build/Messenger.app (release). Environment:
#   ARCHS="arm64 x86_64"   universal binary (default: this Mac's architecture)
#   VERSION=1.2.3          CFBundleShortVersionString (default 0.0.0; "~suffix" is dropped)
#   BUILD_NUMBER=42        CFBundleVersion (default 1)
#   SIGN_IDENTITY="Developer ID Application: …"  hardened-runtime signing (default: ad-hoc)
#   NO_IMPORTED_ICON=1     don't embed the icon from your imported skin (for builds you share)
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0}"
ARCH_FLAGS=""
for arch in ${ARCHS:-}; do ARCH_FLAGS="$ARCH_FLAGS --arch $arch"; done

swift build -c release $ARCH_FLAGS --product Messenger
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/Messenger"

APP=build/Messenger.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Messenger"

# The real Messenger icon, from the installer you imported with
# scripts/import-wlm-assets.sh (16/32/48 px frames + the 256 px master).
ICON="$HOME/Library/Application Support/MessengerMac/Skin/icon"
if [ -z "${NO_IMPORTED_ICON:-}" ] && [ -f "$ICON/256.png" ]; then
	ICONSET=build/AppIcon.iconset
	rm -rf "$ICONSET" && mkdir -p "$ICONSET"
	cp "$ICON/16.png" "$ICONSET/icon_16x16.png"
	cp "$ICON/32.png" "$ICONSET/icon_16x16@2x.png"
	cp "$ICON/32.png" "$ICONSET/icon_32x32.png"
	sips -z 64 64 "$ICON/256.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
	sips -z 128 128 "$ICON/256.png" --out "$ICONSET/icon_128x128.png" >/dev/null
	cp "$ICON/256.png" "$ICONSET/icon_128x128@2x.png"
	cp "$ICON/256.png" "$ICONSET/icon_256x256.png"
	iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
	echo "note: generic bundle icon; the app shows the imported Messenger icon at runtime"
fi

# The asset importer, for installs without a source checkout; same layout as
# the repository, so the scripts find re/ by relative path.
IMPORT="$APP/Contents/Resources/import"
mkdir -p "$IMPORT/Messenger/scripts" "$IMPORT/re/scripts" "$IMPORT/re/data"
cp scripts/import-wlm-assets.sh scripts/import-wlm-sounds.sh "$IMPORT/Messenger/scripts/"
cp ../re/scripts/wlm_skin.py ../re/scripts/wlm_rle.py "$IMPORT/re/scripts/"
cp ../re/data/emoticons.json "$IMPORT/re/data/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Messenger</string>
	<key>CFBundleDisplayName</key><string>Messenger</string>
	<key>CFBundleIdentifier</key><string>local.messengermac</string>
	<key>CFBundleExecutable</key><string>Messenger</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION%%~*}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ "${SIGN_IDENTITY:--}" = "-" ]; then
	codesign --force --sign - "$APP"
else
	codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Messenger"))"
