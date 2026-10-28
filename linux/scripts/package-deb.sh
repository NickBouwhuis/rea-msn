#!/bin/sh
# Builds build/wlm-messenger_$VERSION_<arch>.deb: MessengerGTK with the Swift
# runtime linked in statically (the system provides only GTK 4, libcurl and
# libxml2), a launcher entry, and the asset importer as wlm-messenger-import.
# No Microsoft assets are included; users import them from their own installer.
# Needs dpkg-dev; run on the oldest Ubuntu you target (the Depends follow it).
#   VERSION=1.2.3 linux/scripts/package-deb.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PKG="$ROOT/Messenger"
SCRATCH="${SCRATCH:-$PKG/.build}"
VERSION="${VERSION:-0.0.0}"
MAINTAINER="${MAINTAINER:-NickBouwhuis <NickBouwhuis@users.noreply.github.com>}"
ARCH="$(dpkg --print-architecture)"
NAME=wlm-messenger
APP_ID=chat.messenger.wlm81
STAGE="$(mktemp -d)"   # package root
SHLIBS="$(mktemp -d)"  # scratch for dpkg-shlibdeps

swift build -c release --static-swift-stdlib --package-path "$PKG" --scratch-path "$SCRATCH" --product MessengerGTK
BIN="$(swift build -c release --static-swift-stdlib --package-path "$PKG" --scratch-path "$SCRATCH" --show-bin-path)/MessengerGTK"
install -D -m 755 "$BIN" "$STAGE/usr/bin/$NAME"
strip "$STAGE/usr/bin/$NAME"

# The importer keeps the repository layout so it finds re/ by relative path.
SHARE="$STAGE/usr/share/$NAME"
install -D -m 755 "$HERE/import-wlm-assets.sh" "$SHARE/linux/scripts/import-wlm-assets.sh"
install -D -m 644 "$ROOT/re/scripts/wlm_skin.py" "$SHARE/re/scripts/wlm_skin.py"
install -D -m 644 "$ROOT/re/scripts/wlm_rle.py" "$SHARE/re/scripts/wlm_rle.py"
install -D -m 644 "$ROOT/re/data/emoticons.json" "$SHARE/re/data/emoticons.json"
cat > "$STAGE/usr/bin/$NAME-import" <<EOF
#!/bin/sh
exec /usr/share/$NAME/linux/scripts/import-wlm-assets.sh "\$@"
EOF
chmod 755 "$STAGE/usr/bin/$NAME-import"

install -d "$STAGE/usr/share/applications"
cat > "$STAGE/usr/share/applications/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Windows Live Messenger
Comment=Chat with your Escargot (MSN) contacts
Exec=$NAME
Icon=$APP_ID
Categories=Network;InstantMessaging;
StartupWMClass=$APP_ID
EOF
install -D -m 644 "$ROOT/README.md" "$STAGE/usr/share/doc/$NAME/README.md"

mkdir -p "$SHLIBS/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$NAME" "$NAME" > "$SHLIBS/debian/control"
DEPENDS="$(cd "$SHLIBS" && dpkg-shlibdeps -O "$STAGE/usr/bin/$NAME" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"

install -d "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $(du -sk "$STAGE/usr" | cut -f1)
Depends: $DEPENDS
Recommends: 7zip | p7zip-full, python3, ffmpeg, libsecret-tools
Section: net
Priority: optional
Description: Windows Live Messenger 8.1-style client for the Escargot (MSN) service
 A native GTK 4 reimplementation of Windows Live Messenger 8.1 that speaks
 MSNP15 to Escargot. Run wlm-messenger-import with your own WLM 8.1 installer
 (.msi) to import the original look, emoticons and sounds; none are included.
EOF

mkdir -p "$ROOT/build"
DEB="$ROOT/build/${NAME}_${VERSION}_$ARCH.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "Packaged $DEB"
echo "Depends: $DEPENDS"
