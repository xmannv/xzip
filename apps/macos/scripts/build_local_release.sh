#!/usr/bin/env bash
#
# Build a runnable Release copy of XZip into <project>/release/XZip.app.
#
# This is the lightweight sibling of build_release.sh: it produces a locally
# runnable, ad-hoc-signed app WITHOUT Developer ID signing, notarization, DMG,
# or the Sparkle appcast. Use it to grab a Release build quickly; use
# build_release.sh for actual distribution.
#
# Prerequisites:
#   - Xcode + command line tools
#   - xcodegen  (brew install xcodegen)
#
set -euo pipefail

# ------------------------------------------------------------------ config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DIR="$ROOT_DIR/build/local-release"
RELEASE_DIR="$ROOT_DIR/release"
APP_NAME="XZip"
SCHEME="XZip"
CONFIGURATION="Release"
# Build for the host architecture only, so it launches on this machine.
ARCH="$(uname -m)"

log()  { printf "\033[1;35m==>\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!!\033[0m  %s\n" "$1" >&2; }
fail() { printf "\033[1;31mERROR:\033[0m %s\n" "$1" >&2; exit 1; }

# ------------------------------------------------------------- prepare ----
log "Fetching bundled binaries"
bash "$SCRIPT_DIR/fetch_binaries.sh"

log "Building universal liblzma (LZMA2 support for Quick Look listing)"
bash "$SCRIPT_DIR/build_liblzma.sh"

log "Generating Xcode project"
command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"
(cd "$ROOT_DIR" && xcodegen generate)

mkdir -p "$RELEASE_DIR"
rm -rf "$RELEASE_DIR/$APP_NAME.app"

# --------------------------------------------------------------- build ----
log "Building $CONFIGURATION for $ARCH (ad-hoc signed)"
xcodebuild build \
    -project "$ROOT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=$ARCH" \
    -derivedDataPath "$DERIVED_DIR" \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    | (command -v xcbeautify >/dev/null && xcbeautify || cat)

BUILT_APP="$DERIVED_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
[ -d "$BUILT_APP" ] || fail "Build product not found at $BUILT_APP"

# --------------------------------------------------------------- stage ----
APP_PATH="$RELEASE_DIR/$APP_NAME.app"
log "Copying to $APP_PATH"
cp -R "$BUILT_APP" "$APP_PATH"

# Ad-hoc signatures cannot satisfy restricted App Group, application identifier,
# or Keychain access-group entitlements. Keeping those entitlements produces a
# bundle that passes `codesign --verify` but AMFI kills before launch. The app
# already treats its App Group as unavailable in ad-hoc builds, while extensions
# still need their non-restricted sandbox/file-access entitlements.
log "Ad-hoc signing"
for bin in "$APP_PATH/Contents/Resources/bin/"*; do
    [ -f "$bin" ] || continue
    codesign --force --sign - "$bin"
done

LOCAL_EXTENSION_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$LOCAL_EXTENSION_ENTITLEMENTS"' EXIT
cat > "$LOCAL_EXTENSION_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
EOF

for appex in "$APP_PATH/Contents/PlugIns/"*.appex; do
    [ -d "$appex" ] || continue
    codesign --force --sign - --entitlements "$LOCAL_EXTENSION_ENTITLEMENTS" "$appex"
done
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if ! codesign -d --entitlements :- "$APP_PATH" \
    > "$LOCAL_EXTENSION_ENTITLEMENTS" 2>/dev/null; then
    fail "Could not read effective ad-hoc app entitlements"
fi
if grep -Eq '<key>(com\.apple\.application-identifier|keychain-access-groups|com\.apple\.security\.application-groups)</key>' \
    "$LOCAL_EXTENSION_ENTITLEMENTS"; then
    fail "Ad-hoc app still contains restricted entitlements"
fi
rm -f "$LOCAL_EXTENSION_ENTITLEMENTS"
trap - EXIT

# ------------------------------------------------------------- cleanup ----
# Keep release/XZip.app as the ONLY app copy on disk. The intermediate DerivedData
# build carries the same bundle id, and multiple registered copies confuse
# LaunchServices (e.g. a notification tap can activate a stale copy, surfacing
# a second instance). Unregister it from LaunchServices, then delete it, and
# register release/ as the canonical copy.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
log "Removing intermediate build ($DERIVED_DIR)"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$BUILT_APP" 2>/dev/null || true
    "$LSREGISTER" -f "$APP_PATH" 2>/dev/null || true
fi
rm -rf "$DERIVED_DIR"

# Also sweep copies built by Xcode itself: IDE builds land in the default
# DerivedData (not our custom path above), carry the same bundle id, and stay
# registered with LaunchServices — Finder "Open With" can then launch one of
# them as a second app instance.
XCODE_DD="$HOME/Library/Developer/Xcode/DerivedData"
for stale in "$XCODE_DD/$APP_NAME"-*/Build/Products/*/"$APP_NAME.app"; do
    [ -d "$stale" ] || continue
    log "Removing stale Xcode build ($stale)"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$stale" 2>/dev/null || true
    rm -rf "$stale"
done

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?')"
log "Done. $APP_NAME $VERSION → $APP_PATH"
log "Open it with:  open \"$APP_PATH\""

# --------------------------------------------------- extension limitations ----
# The three extensions are in the bundle and will load, but they were re-signed
# above with sandbox-only entitlements, because an ad-hoc signature cannot carry
# the restricted App Group entitlement they declare. Anything that goes through
# the shared container behaves differently here than in a Developer ID build, so
# testing those flows on this build proves nothing either way.
#
# Named individually so the degraded behaviour is not mistaken for a real bug:
warn "Extensions are NOT fully exercised by this build (no App Group entitlement):"
warn "  Share       - XZIPAppGroup.stage() returns nil without the container, so"
warn "                sharing a file to XZip cannot hand the file over at all."
warn "  Finder Sync - reads its show/hide preference from the shared defaults"
warn "                suite. Unavailable, it defaults to 'show', so the Settings"
warn "                toggle appears to do nothing."
warn "  Quick Look  - declares the group but never reads it, so this stripping is"
warn "                not what stops the appex from working."
warn "Use scripts/build_release.sh (Developer ID) to verify extension behaviour."
