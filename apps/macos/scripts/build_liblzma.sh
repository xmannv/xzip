#!/usr/bin/env bash
#
# Build a universal (x86_64 + arm64) static liblzma.a from the pinned XZ Utils
# release, for linking into XZip and its Quick Look extension.
#
# Why this exists: swift-archive's LZMASupport trait links `-llzma`, but no
# system-provided library satisfies a universal build — Homebrew's liblzma is
# host-arch only, and the macOS SDK's liblzma.5.tbd carries x86_64/arm64e slices
# but not plain arm64. A vendored universal static archive is the only
# combination that links for both architectures and adds no runtime dependency.
#
# Output: vendor/liblzma/lib/liblzma.a (+ headers under vendor/liblzma/include).
# Idempotent: skips the build when the output already exists and is universal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor"
OUT_DIR="$VENDOR_DIR/liblzma"

XZ_VERSION="5.8.1"
XZ_TAR="xz-${XZ_VERSION}.tar.gz"
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/${XZ_TAR}"
# SHA-256 of the upstream tarball, pinned like 7zz in fetch_binaries.sh: this
# code is compiled into the app, so a swapped asset must be rejected.
# Recompute when XZ_VERSION changes: shasum -a 256 vendor/xz-<version>.tar.gz
XZ_SHA256="507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543"

log()  { printf "\033[1;35m==>\033[0m %s\n" "$1"; }
fail() { printf "\033[1;31mERROR:\033[0m %s\n" "$1" >&2; exit 1; }

if [ -f "$OUT_DIR/lib/liblzma.a" ]; then
    ARCHS="$(lipo -archs "$OUT_DIR/lib/liblzma.a" 2>/dev/null || true)"
    case "$ARCHS" in
        *x86_64*arm64*|*arm64*x86_64*)
            log "liblzma.a already universal ($ARCHS) — skipping build"
            exit 0
            ;;
    esac
fi

mkdir -p "$VENDOR_DIR"

log "Fetching XZ Utils ${XZ_VERSION}"
curl -fL --retry 3 -o "$VENDOR_DIR/$XZ_TAR" "$XZ_URL"

log "Verifying tarball checksum (SHA-256)"
echo "${XZ_SHA256}  $VENDOR_DIR/$XZ_TAR" | shasum -a 256 -c - \
    || fail "XZ Utils tarball SHA-256 mismatch; refusing to build possibly-tampered sources"

SRC_DIR="$VENDOR_DIR/xz-${XZ_VERSION}"
rm -rf "$SRC_DIR"
tar -xzf "$VENDOR_DIR/$XZ_TAR" -C "$VENDOR_DIR"

MACOS_TARGET="15.0"
build_arch() {
    local arch="$1"
    local prefix="$VENDOR_DIR/liblzma-$arch"
    log "Building liblzma for $arch"
    rm -rf "$prefix"
    ( cd "$SRC_DIR" \
        && make distclean >/dev/null 2>&1 || true )
    ( cd "$SRC_DIR" \
        && CC="clang -arch $arch -mmacosx-version-min=$MACOS_TARGET" \
           ./configure --prefix="$prefix" \
               --disable-shared --enable-static \
               --disable-xz --disable-xzdec --disable-lzmadec \
               --disable-lzmainfo --disable-scripts --disable-doc \
               --host="$arch-apple-darwin" >/dev/null \
        && make -j"$(sysctl -n hw.ncpu)" >/dev/null \
        && make install >/dev/null )
}

build_arch x86_64
build_arch arm64

log "Creating universal liblzma.a"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/lib"
cp -R "$VENDOR_DIR/liblzma-arm64/include" "$OUT_DIR/include"
lipo -create \
    "$VENDOR_DIR/liblzma-x86_64/lib/liblzma.a" \
    "$VENDOR_DIR/liblzma-arm64/lib/liblzma.a" \
    -output "$OUT_DIR/lib/liblzma.a"

lipo -archs "$OUT_DIR/lib/liblzma.a"
rm -rf "$SRC_DIR" "$VENDOR_DIR/liblzma-x86_64" "$VENDOR_DIR/liblzma-arm64"
log "Done: $OUT_DIR/lib/liblzma.a"
