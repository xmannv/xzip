#!/usr/bin/env bash
#
# One-time helper to create the Sparkle EdDSA signing key pair for XZip.
#
# What it does:
#   - Locates Sparkle's `generate_keys` tool (from the SPM checkout or a Homebrew
#     install of the Sparkle cask).
#   - Generates the key pair. The PRIVATE key is stored in your login Keychain
#     (item "Private key for signing Sparkle updates"); it is never written to
#     disk or committed.
#   - Prints the PUBLIC key so you can paste it into project.yml (SUPublicEDKey).
#
# Run this ONCE per project/machine. If a key already exists, `generate_keys`
# prints the existing public key instead of creating a new one.
#
# Usage:  bash scripts/generate_sparkle_keys.sh
#
set -euo pipefail

log()  { printf "\033[1;35m==>\033[0m %s\n" "$1"; }
fail() { printf "\033[1;31mERROR:\033[0m %s\n" "$1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ------------------------------------------------------ locate generate_keys ----
GEN_KEYS=""

# 1) On PATH (e.g. copied from the Sparkle cask).
if command -v generate_keys >/dev/null 2>&1; then
    GEN_KEYS="$(command -v generate_keys)"
fi

# 2) Inside the SPM artifacts checkout used by the Xcode project.
if [ -z "$GEN_KEYS" ]; then
    CANDIDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type f -name generate_keys -path "*Sparkle*" 2>/dev/null | head -n 1 || true)"
    [ -n "$CANDIDATE" ] && GEN_KEYS="$CANDIDATE"
fi

# 3) Sparkle Homebrew cask location.
if [ -z "$GEN_KEYS" ]; then
    for p in \
        "/opt/homebrew/Caskroom/sparkle"/*/bin/generate_keys \
        "/usr/local/Caskroom/sparkle"/*/bin/generate_keys; do
        [ -f "$p" ] && GEN_KEYS="$p" && break
    done
fi

[ -n "$GEN_KEYS" ] || fail "Could not find Sparkle's 'generate_keys'.
  Install the tools first, e.g.:
    brew install --cask sparkle
  or build the Sparkle SPM package once in Xcode so DerivedData contains it."

log "Using generate_keys: $GEN_KEYS"

# ------------------------------------------------------------------ generate ----
log "Generating (or reading existing) Sparkle EdDSA key pair"
log "The private key is stored securely in your login Keychain."
echo
"$GEN_KEYS"
echo

log "Copy the 'SUPublicEDKey' value printed above into project.yml:"
printf "    SUPublicEDKey: \"<paste-public-key-here>\"\n"
echo
log "Then run: xcodegen generate  (to propagate the key into Info.plist)"
