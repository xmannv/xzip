#!/usr/bin/env bash
# Fetch open-source archiver binaries bundled into XZip.app.
# Latest versions as of 2026-07. Re-run to refresh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$ROOT_DIR/Resources/bin"
VENDOR_DIR="$ROOT_DIR/vendor"
mkdir -p "$BIN_DIR" "$VENDOR_DIR"

# --- 7-Zip (primary engine) ---------------------------------------------------
SEVENZIP_VERSION="26.02"
SEVENZIP_TAG="26.02"
SEVENZIP_TAR="7z2602-mac.tar.xz"
SEVENZIP_URL="https://github.com/ip7z/7zip/releases/download/${SEVENZIP_TAG}/${SEVENZIP_TAR}"
# SHA-256 of the upstream tarball. The bundled 7zz is the engine that runs every
# archive operation, and the release pipeline codesigns + notarizes whatever is
# downloaded here — so a swapped upstream asset must be rejected before it is
# trusted. Recompute and update this whenever SEVENZIP_VERSION changes:
#   shasum -a 256 vendor/7z2602-mac.tar.xz
SEVENZIP_SHA256="1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9"

echo "==> Fetching 7-Zip ${SEVENZIP_VERSION} (macOS universal)"
curl -fL --retry 3 -o "$VENDOR_DIR/$SEVENZIP_TAR" "$SEVENZIP_URL"

echo "==> Verifying tarball checksum (SHA-256)"
# Fail-closed: abort before extracting/bundling if the checksum does not match.
echo "${SEVENZIP_SHA256}  $VENDOR_DIR/$SEVENZIP_TAR" | shasum -a 256 -c - \
    || { echo "ERROR: 7-Zip tarball SHA-256 mismatch; refusing to bundle a possibly-tampered binary" >&2; exit 1; }

echo "==> Extracting 7zz"
tar -xf "$VENDOR_DIR/$SEVENZIP_TAR" -C "$VENDOR_DIR"
# The mac archive ships a universal `7zz` binary at the archive root.
cp "$VENDOR_DIR/7zz" "$BIN_DIR/7zz"
chmod +x "$BIN_DIR/7zz"

echo "==> Verifying 7zz"
file "$BIN_DIR/7zz"
"$BIN_DIR/7zz" i | head -5 || true

echo ""
echo "Done. Binaries placed in: $BIN_DIR"
ls -la "$BIN_DIR"
