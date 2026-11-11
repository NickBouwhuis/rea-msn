#!/bin/sh
# Builds matrix-rust-sdk for Linux, for Messenger for Matrix to link: its
# static library, C headers and Swift bindings, into Messenger/Vendor/MatrixSDK.
# With that folder there, the package builds the same encrypting client as on
# macOS (Package.swift looks for it); without it, the plain client.
#
# The commit is the one the macOS build's matrix-rust-components-swift release
# (Messenger/Package.swift) was made from, so both platforms run the same SDK:
# change them together.
#
# Needs git, a C compiler and cmake (for aws-lc), and Rust; rustup installs
# Rust for you when cargo is missing. The first build takes 15 to 30 minutes.
#   sudo apt install git build-essential cmake curl
#   linux/scripts/build-matrix-sdk.sh
set -eu
SDK_COMMIT=e675036b27be102b05ec5c5bff843cf8d739338c  # matrix-rust-components-swift 26.10.27
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../Messenger/Vendor/MatrixSDK"
WORK="${MATRIX_SDK_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/messenger-wlm/matrix-rust-sdk}"

if [ "$(cat "$OUT/commit" 2>/dev/null)" = "$SDK_COMMIT" ] && [ -f "$OUT/lib/libmatrix_sdk_ffi.a" ]; then
	echo "matrix-rust-sdk $SDK_COMMIT is already in $OUT"
	exit 0
fi

if ! command -v cargo >/dev/null; then
	[ -f "$HOME/.cargo/env" ] || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
	. "$HOME/.cargo/env"
fi

mkdir -p "$WORK"
[ -d "$WORK/.git" ] || { git init -q "$WORK"; git -C "$WORK" remote add origin https://github.com/matrix-org/matrix-rust-sdk.git; }
git -C "$WORK" fetch -q --depth 1 origin "$SDK_COMMIT"
git -C "$WORK" checkout -q --detach FETCH_HEAD
cd "$WORK"

# Only the static library, as the SDK's own Apple build asks for it: also
# building the "lib" crate type would switch off the profile's optimisations.
cargo rustc -p matrix-sdk-ffi --crate-type staticlib --release
LIB="$WORK/target/release/libmatrix_sdk_ffi.a"
GEN="$WORK/target/messenger-bindings"
rm -rf "$GEN"
cargo run -p uniffi-bindgen --release -- generate --library "$LIB" --language swift --out-dir "$GEN"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include" "$OUT/swift"
cp "$LIB" "$OUT/lib/"
strip --strip-debug "$OUT/lib/libmatrix_sdk_ffi.a" 2>/dev/null || true
cp "$GEN"/*.h "$OUT/include/"
# One C module for all the generated headers, as the Apple framework has.
{
	echo "module MatrixSDKFFI {"
	for header in "$OUT"/include/*.h; do echo "    header \"$(basename "$header")\""; done
	echo "    export *"
	echo "}"
} > "$OUT/include/module.modulemap"
for source in "$GEN"/*.swift; do
	sed -E 's/canImport\([A-Za-z0-9_]+FFI\)/canImport(MatrixSDKFFI)/; s/^import [A-Za-z0-9_]+FFI$/import MatrixSDKFFI/' "$source" \
		> "$OUT/swift/$(basename "$source")"
done
echo "$SDK_COMMIT" > "$OUT/commit"
echo "matrix-rust-sdk is in $OUT:"
ls -la "$OUT/lib" "$OUT/include" "$OUT/swift"
