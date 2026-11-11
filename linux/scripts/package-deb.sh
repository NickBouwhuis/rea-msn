#!/bin/sh
# Builds build/wlm-messenger_$VERSION~<distro>_<arch>.deb: MessengerGTK with the
# Swift runtime linked in statically (the system provides only GTK 4, libcurl
# and libxml2), a launcher entry, and the asset importer as wlm-messenger-import.
# No Microsoft assets are included; users import them from their own installer.
# Needs dpkg-dev. The Depends come from the release it's built on, and sonames
# differ between releases (libxml2.so.2 on 24.04, .so.16 on 26.04), so build
# once per Ubuntu release; the version carries it, e.g. 1.2.3~ubuntu24.04.
#   VERSION=1.2.3 linux/scripts/package-deb.sh
# VARIANT=matrix packages Messenger for Matrix (MatrixMessengerGTK) as
# wlm-messenger-matrix instead.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PKG="$ROOT/Messenger"
SCRATCH="${SCRATCH:-$PKG/.build}"
VERSION="${VERSION:-0.0.0}"
MAINTAINER="${MAINTAINER:-NickBouwhuis <NickBouwhuis@users.noreply.github.com>}"
ARCH="$(dpkg --print-architecture)"
DIST="$(. /etc/os-release && echo "$ID$VERSION_ID")"
DEB_VERSION="$VERSION~$DIST"
case "${VARIANT:-escargot}" in
	matrix)
		PRODUCT=MatrixMessengerGTK NAME=wlm-messenger-matrix APP_ID=chat.messenger.wlm81.matrix
		TITLE="Messenger for Matrix" COMMENT="Chat with your Matrix contacts"
		SUMMARY="Windows Live Messenger 8.1-style client for Matrix"
		ABOUT="the Matrix client-server API" ;;
	escargot)
		PRODUCT=MessengerGTK NAME=wlm-messenger APP_ID=chat.messenger.wlm81
		TITLE="Windows Live Messenger" COMMENT="Chat with your Escargot (MSN) contacts"
		SUMMARY="Windows Live Messenger 8.1-style client for the Escargot (MSN) service"
		ABOUT="MSNP15 to Escargot" ;;
	*) echo "VARIANT is escargot or matrix" >&2; exit 2 ;;
esac
STAGE="$(mktemp -d)"   # package root
SHLIBS="$(mktemp -d)"  # scratch for dpkg-shlibdeps

# Messenger for Matrix is packaged with end-to-end encryption: on matrix-rust-sdk.
[ "${VARIANT:-escargot}" != matrix ] || "$HERE/build-matrix-sdk.sh"
swift build -c release --static-swift-stdlib --package-path "$PKG" --scratch-path "$SCRATCH" --product "$PRODUCT"
BIN="$(swift build -c release --static-swift-stdlib --package-path "$PKG" --scratch-path "$SCRATCH" --show-bin-path)/$PRODUCT"
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
Name=$TITLE
Comment=$COMMENT
Exec=$NAME
Icon=$APP_ID
Categories=Network;InstantMessaging;
StartupWMClass=$APP_ID
EOF
for size in 16 32 48 256; do
	install -D -m 644 "$ROOT/assets/icon/$size.png" "$STAGE/usr/share/icons/hicolor/${size}x$size/apps/$APP_ID.png"
done
install -D -m 644 "$ROOT/README.md" "$STAGE/usr/share/doc/$NAME/README.md"

mkdir -p "$SHLIBS/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$NAME" "$NAME" > "$SHLIBS/debian/control"
DEPENDS="$(cd "$SHLIBS" && dpkg-shlibdeps -O "$STAGE/usr/bin/$NAME" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"

install -d "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $NAME
Version: $DEB_VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $(du -sk "$STAGE/usr" | cut -f1)
Depends: $DEPENDS
Recommends: 7zip | p7zip-full, python3, ffmpeg, libsecret-tools
Section: net
Priority: optional
Description: $SUMMARY
 A native GTK 4 reimplementation of Windows Live Messenger 8.1 that speaks
 $ABOUT. Run $NAME-import with your own WLM 8.1 installer
 (.msi) to import the original look, emoticons and sounds; none are included.
EOF

mkdir -p "$ROOT/build"
DEB="$ROOT/build/${NAME}_${DEB_VERSION}_$ARCH.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "Packaged $DEB"
echo "Depends: $DEPENDS"
