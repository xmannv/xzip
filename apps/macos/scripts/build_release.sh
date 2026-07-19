#!/usr/bin/env bash
#
# Build, sign, notarize, and package XZip for Developer ID distribution,
# then sign the DMG with the Sparkle EdDSA key and publish a GitHub release.
# The update-appcast workflow (.github/workflows/update-appcast.yml) reacts to
# the published release and deploys appcast.xml to GitHub Pages, which the
# Sparkle clients poll (SUFeedURL).
#
# Prerequisites:
#   - Xcode + command line tools
#   - xcodegen           (brew install xcodegen)
#   - create-dmg         (brew install create-dmg)  [optional, falls back to hdiutil]
#   - Sparkle tools      (generate_keys / sign_update)
#   - GitHub CLI         (brew install gh, then gh auth login)
#   - Developer ID Application cert in the login keychain (7E6Z9B4F2H)
#   - Notarytool credentials stored in a keychain profile (see NOTARY_PROFILE)
#
# Secrets are read from the environment or a local, git-ignored file:
#   notarization_credentials.sh  (exports NOTARY_PROFILE, TEAM_ID, etc.)
#
set -euo pipefail

# ------------------------------------------------------------------ config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
RELEASE_DIR="$ROOT_DIR/release"
APP_NAME="XZip"
SCHEME="XZip"
CONFIGURATION="Release"
TEAM_ID="${TEAM_ID:-7E6Z9B4F2H}"
NOTARY_PROFILE="${NOTARY_PROFILE:-xzip-notary}"
GITHUB_REPO="${GITHUB_REPO:-xmannv/xzip}"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.DeveloperID.plist"
APP_GROUP="group.com.codetay.xzip"

# Load local secrets if present (never committed).
[ -f "$ROOT_DIR/notarization_credentials.sh" ] && source "$ROOT_DIR/notarization_credentials.sh"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xzip-release.XXXXXX")"
TEST_PID=""
cleanup() {
    if [ -n "$TEST_PID" ]; then
        kill "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log()  { printf "\033[1;35m==>\033[0m %s\n" "$1"; }
fail() { printf "\033[1;31mERROR:\033[0m %s\n" "$1" >&2; exit 1; }

assert_keychain_entitlements() {
    local app="$1"
    local expected="${TEAM_ID}.com.codetay.xzip"
    local dump actual_app_id actual_access_group

    dump="$(mktemp)"
    if ! codesign -d --entitlements :- "$app" >"$dump" 2>/dev/null; then
        rm -f "$dump"
        fail "Could not read effective app entitlements"
    fi

    actual_app_id="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :com.apple.application-identifier' \
            "$dump" 2>/dev/null || true
    )"
    actual_access_group="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :keychain-access-groups:0' \
            "$dump" 2>/dev/null || true
    )"
    rm -f "$dump"

    [ "$actual_app_id" = "$expected" ] \
        || fail "Invalid application identifier: '$actual_app_id'"
    [ "$actual_access_group" = "$expected" ] \
        || fail "Invalid Keychain access group: '$actual_access_group'"
}

plist_array_contains() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local index=0 value

    while value="$(/usr/libexec/PlistBuddy -c "Print :${key}:${index}" "$plist" 2>/dev/null)"; do
        [ "$value" = "$expected" ] && return 0
        index=$((index + 1))
    done
    return 1
}

plist_array_authorizes() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local index=0 value prefix

    while value="$(/usr/libexec/PlistBuddy -c "Print :${key}:${index}" "$plist" 2>/dev/null)"; do
        if [ "$value" = "$expected" ]; then
            return 0
        fi
        if [[ "$value" == *\* ]]; then
            prefix="${value%\*}"
            [[ "$expected" == "$prefix"* ]] && return 0
        fi
        index=$((index + 1))
    done
    return 1
}

assert_embedded_profile() {
    local bundle="$1"
    local expected_bundle_id="$2"
    local require_keychain="$3"
    local info="$bundle/Contents/Info.plist"
    local profile="$bundle/Contents/embedded.provisionprofile"
    local decoded="$TEMP_DIR/$(basename "$bundle").profile.plist"
    local entitlements="$TEMP_DIR/$(basename "$bundle").entitlements.plist"
    local expected_app_id="${TEAM_ID}.${expected_bundle_id}"
    local actual_bundle_id profile_team profile_app_id signed_app_id

    [ -f "$info" ] || fail "Missing Info.plist in $bundle"
    actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null || true)"
    [ "$actual_bundle_id" = "$expected_bundle_id" ] \
        || fail "Invalid bundle identifier in $bundle: '$actual_bundle_id'"

    [ -s "$profile" ] || fail "Missing embedded provisioning profile in $bundle"
    security cms -D -i "$profile" >"$decoded" 2>/dev/null \
        || fail "Could not decode provisioning profile in $bundle"

    profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded" 2>/dev/null || true)"
    profile_app_id="$(
        /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded" 2>/dev/null \
            || true
    )"

    [ "$profile_team" = "$TEAM_ID" ] \
        || fail "Invalid provisioning profile team in $bundle: '$profile_team'"
    [ "$profile_app_id" = "$expected_app_id" ] \
        || fail "Invalid provisioning application identifier in $bundle: '$profile_app_id'"
    plist_array_contains "$decoded" \
        'Entitlements:com.apple.security.application-groups' "$APP_GROUP" \
        || fail "Provisioning profile in $bundle does not authorize $APP_GROUP"

    codesign -d --entitlements :- "$bundle" >"$entitlements" 2>/dev/null \
        || fail "Could not read effective entitlements from $bundle"
    signed_app_id="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements" 2>/dev/null || true)"

    [ "$signed_app_id" = "$expected_app_id" ] \
        || fail "Invalid signed application identifier in $bundle: '$signed_app_id'"
    plist_array_contains "$entitlements" \
        'com.apple.security.application-groups' "$APP_GROUP" \
        || fail "Signed entitlements in $bundle do not contain $APP_GROUP"

    if [ "$require_keychain" = true ]; then
        plist_array_authorizes "$decoded" \
            'Entitlements:keychain-access-groups' "$expected_app_id" \
            || fail "Provisioning profile in $bundle does not authorize Keychain group $expected_app_id"
        plist_array_contains "$entitlements" \
            'keychain-access-groups' "$expected_app_id" \
            || fail "Signed entitlements in $bundle do not contain Keychain group $expected_app_id"
    fi
}

assert_launches() {
    local app="$1"
    local executable="$app/Contents/MacOS/$APP_NAME"
    local launch_log="$TEMP_DIR/launch.log"
    local status i

    [ -x "$executable" ] || fail "App executable not found at $executable"
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        fail "Close the running $APP_NAME instance before building a release"
    fi

    : >"$launch_log"
    "$executable" >"$launch_log" 2>&1 &
    TEST_PID=$!

    for i in {1..15}; do
        sleep 0.2
        if ! kill -0 "$TEST_PID" 2>/dev/null; then
            if wait "$TEST_PID"; then
                status=0
            else
                status=$?
            fi
            TEST_PID=""
            tail -n 20 "$launch_log" >&2 || true
            [ "$status" -ne 137 ] \
                || fail "$APP_NAME was killed by code signing validation (SIGKILL, status 137)"
            fail "$APP_NAME exited before the release launch gate completed (status $status)"
        fi
    done

    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
    TEST_PID=""
}

# ------------------------------------------------------------- prepare ----
log "Fetching bundled binaries"
bash "$SCRIPT_DIR/fetch_binaries.sh"

log "Generating Xcode project"
command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"
(cd "$ROOT_DIR" && xcodegen generate)

rm -rf "$BUILD_DIR" "$RELEASE_DIR"
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

log "Running signed Data Protection Keychain CRUD smoke test"
xcodebuild test \
    -project "$ROOT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -allowProvisioningUpdates \
    -derivedDataPath "$BUILD_DIR/KeychainTestDerivedData" \
    -only-testing:XZipTests/KeychainPasswordStoreHostedTests \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | (command -v xcbeautify >/dev/null && xcbeautify || cat)

# --------------------------------------------------------------- build ----
# Restricted App Group and Keychain entitlements require provisioning profiles
# at runtime. Archive and export through Xcode so every executable receives a
# Developer ID profile that authorizes its final entitlements.
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
log "Archiving universal app with automatic provisioning"
xcodebuild archive \
    -project "$ROOT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    ARCHS="x86_64 arm64" \
    ONLY_ACTIVE_ARCH=NO \
    | (command -v xcbeautify >/dev/null && xcbeautify || cat)

log "Exporting Developer ID application"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    | (command -v xcbeautify >/dev/null && xcbeautify || cat)

EXPORTED_APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$EXPORTED_APP" ] || fail "Developer ID export did not produce $EXPORTED_APP"

APP_PATH="$RELEASE_DIR/$APP_NAME.app"
ditto "$EXPORTED_APP" "$APP_PATH"

# Reuse the exact leaf certificate Xcode selected for Developer ID export. A
# different certificate from the same team may not be authorized by the embedded
# profiles and can pass static codesign checks but fail Taskgated at launch.
EXPORTED_CERT_PREFIX="$TEMP_DIR/exported-cert-"
codesign -d --extract-certificates="$EXPORTED_CERT_PREFIX" "$APP_PATH" 2>/dev/null \
    || fail "Could not extract the Xcode-exported signing certificate"
[ -s "${EXPORTED_CERT_PREFIX}0" ] \
    || fail "Xcode export did not contain a leaf signing certificate"
EXPORTED_SIGN_IDENTITY="$(shasum -a 1 "${EXPORTED_CERT_PREFIX}0")"
EXPORTED_SIGN_IDENTITY="${EXPORTED_SIGN_IDENTITY%% *}"
[ -n "$EXPORTED_SIGN_IDENTITY" ] \
    || fail "Could not identify the Xcode-exported signing certificate"

EXPORTED_OUTER_ENTITLEMENTS="$TEMP_DIR/exported-outer-entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" \
    >"$EXPORTED_OUTER_ENTITLEMENTS" 2>/dev/null \
    || fail "Could not capture Xcode-exported outer entitlements"
plutil -lint "$EXPORTED_OUTER_ENTITLEMENTS" >/dev/null \
    || fail "Xcode-exported outer entitlements are not a valid plist"

# ------------------------------------------------- verify universal ----
ARCHS_FOUND="$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")"
log "Architectures: $ARCHS_FOUND"
case "$ARCHS_FOUND" in
    *x86_64*arm64*|*arm64*x86_64*) : ;;
    *) fail "App binary is not universal (got: $ARCHS_FOUND)" ;;
esac

# ------------------------------------------------------------- cleanup ----
# Keep release/XZip.app as the only copy on disk. Stale copies with the same
# bundle id — the exported build above, or builds made by the Xcode IDE in the
# default DerivedData — stay registered with LaunchServices, and Finder "Open
# With" can launch one of them as a second app instance.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
log "Removing intermediate build ($BUILD_DIR)"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$EXPORTED_APP" 2>/dev/null || true
rm -rf "$BUILD_DIR"

XCODE_DD="$HOME/Library/Developer/Xcode/DerivedData"
for stale in "$XCODE_DD/$APP_NAME"-*/Build/Products/*/"$APP_NAME.app"; do
    [ -d "$stale" ] || continue
    log "Removing stale Xcode build ($stale)"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$stale" 2>/dev/null || true
    rm -rf "$stale"
done

# ---------------------------------------- sign inside-out (Developer ID) ----
# Notarization requires EVERY nested Mach-O to be signed with the same Developer
# ID cert, each carrying hardened runtime + a secure timestamp, applied from the
# deepest nested code outward. This replaces every ad-hoc signature from the
# build above.
SIGN_FLAGS=(--force --options runtime --timestamp --sign "$EXPORTED_SIGN_IDENTITY")

# 1) Bundled CLI tools (7zz, …).
log "Signing bundled binaries"
for bin in "$APP_PATH/Contents/Resources/bin/"*; do
    [ -f "$bin" ] || continue
    codesign "${SIGN_FLAGS[@]}" "$bin"
done

# 2) Sparkle.framework nested code, deepest first. The lettered version dir
#    (Versions/A, B, …) is resolved dynamically so a Sparkle bump won't break us.
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    log "Signing Sparkle.framework components"
    SPARKLE_V="$(/bin/ls -d "$SPARKLE_FW"/Versions/[A-Z] 2>/dev/null | head -1)"
    if [ -n "$SPARKLE_V" ]; then
        for xpc in "$SPARKLE_V/XPCServices/Installer.xpc" \
                   "$SPARKLE_V/XPCServices/Downloader.xpc"; do
            [ -d "$xpc" ] && codesign "${SIGN_FLAGS[@]}" "$xpc"
        done
        [ -d "$SPARKLE_V/Updater.app" ] && codesign "${SIGN_FLAGS[@]}" "$SPARKLE_V/Updater.app"
        [ -f "$SPARKLE_V/Autoupdate" ]  && codesign "${SIGN_FLAGS[@]}" "$SPARKLE_V/Autoupdate"
    fi
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW"
fi

# 3) Keep the app extension signatures and profiles produced by Xcode export.
#    Re-signing them manually can detach their restricted entitlements from the
#    provisioning profiles that authorize App Group access.

# 4) Outer app last. Reuse Xcode's effective exported entitlements so injected
#    team/application identifiers remain aligned with its embedded profile.
log "Signing app bundle"
codesign "${SIGN_FLAGS[@]}" \
    --entitlements "$EXPORTED_OUTER_ENTITLEMENTS" \
    "$APP_PATH"

assert_keychain_entitlements "$APP_PATH"
assert_embedded_profile "$APP_PATH" "com.codetay.xzip" true
assert_embedded_profile "$APP_PATH/Contents/PlugIns/XZipFinder.appex" \
    "com.codetay.xzip.FinderSync" false
assert_embedded_profile "$APP_PATH/Contents/PlugIns/XZipQuickLook.appex" \
    "com.codetay.xzip.QuickLook" false
assert_embedded_profile "$APP_PATH/Contents/PlugIns/XZipShare.appex" \
    "com.codetay.xzip.ShareExtension" false
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    || fail "Codesign verification failed"

log "Running exact executable launch gate"
assert_launches "$APP_PATH"

# --------------------------------------------------------------- dmg ----
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
log "Creating DMG ($VERSION)"
if command -v create-dmg >/dev/null; then
    # create-dmg can exit non-zero even after producing a valid DMG (e.g. when it
    # only failed to set the volume icon), so its exit code alone is not
    # trustworthy. Tolerate the exit code, but fail-closed if no DMG was written
    # so a genuine create-dmg failure aborts the release instead of shipping
    # nothing (previously `|| true` swallowed that case entirely).
    create-dmg \
        --volname "$APP_NAME $VERSION" \
        --window-size 540 380 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 140 190 \
        --app-drop-link 400 190 \
        "$DMG_PATH" "$APP_PATH" || true
    [ -s "$DMG_PATH" ] || fail "create-dmg did not produce $DMG_PATH"
else
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$APP_PATH" \
        -ov -format UDZO "$DMG_PATH"
fi

log "Signing DMG"
codesign --force --sign "$EXPORTED_SIGN_IDENTITY" "$DMG_PATH"

# --------------------------------------------------------- notarize ----
log "Submitting for notarization"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait || fail "Notarization failed"

log "Stapling ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler staple "$APP_PATH"

log "Validating notarized artifacts"
xcrun stapler validate "$DMG_PATH" || fail "Stapled DMG validation failed"
xcrun stapler validate "$APP_PATH" || fail "Stapled app validation failed"
spctl --assess --type execute --verbose=4 "$APP_PATH" \
    || fail "Gatekeeper rejected the notarized app"
hdiutil verify "$DMG_PATH" || fail "DMG checksum verification failed"

# Register the notarized copy as the canonical one for LaunchServices.
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_PATH" 2>/dev/null || true

# ------------------------------------------------- sparkle signing ----
# Sign the DMG with the Sparkle EdDSA key. The private key lives in the login
# Keychain (created once via scripts/generate_sparkle_keys.sh); sign_update
# reads it from there by default. The signature is uploaded to the GitHub
# release, where the update-appcast workflow embeds it into appcast.xml.
log "Signing DMG for Sparkle auto-update (EdDSA)"
SIGN_UPDATE=""
command -v sign_update >/dev/null 2>&1 && SIGN_UPDATE="$(command -v sign_update)"
if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -type f -name sign_update -path "*Sparkle*" 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$SIGN_UPDATE" ]; then
    for p in \
        "/opt/homebrew/Caskroom/sparkle"/*/bin/sign_update \
        "/usr/local/Caskroom/sparkle"/*/bin/sign_update; do
        [ -f "$p" ] && SIGN_UPDATE="$p" && break
    done
fi
[ -n "$SIGN_UPDATE" ] || fail "Sparkle 'sign_update' not found (brew install --cask sparkle)"

SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")" || fail "sign_update failed (run scripts/generate_sparkle_keys.sh once?)"
ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' | tail -n 1)"
# EdDSA signatures are base64; reject shell noise before it reaches the appcast.
printf '%s' "$ED_SIGNATURE" | grep -Eq '^[A-Za-z0-9+/=]{80,}$' \
    || fail "Invalid EdDSA signature from sign_update: $SIGN_OUTPUT"
printf '%s\n' "$ED_SIGNATURE" > "$RELEASE_DIR/signature.txt"
log "Signature written to release/signature.txt"

# ------------------------------------------------- github release ----
# Publish DMG + version.json + signature.txt as a GitHub release. Publishing
# triggers the update-appcast workflow, which regenerates appcast.xml on the
# gh-pages branch — i.e. it ships the build to real Sparkle users. Because that
# side effect is irreversible, releasing is OPT-IN: run with
# ENABLE_GITHUB_RELEASE=true to publish. A plain `bash scripts/build_release.sh`
# only builds + notarizes locally.
if [ "${ENABLE_GITHUB_RELEASE:-false}" = true ]; then
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
    RELEASE_TAG="v$VERSION-$BUILD_NUMBER"

    command -v gh >/dev/null || fail "GitHub CLI (gh) not installed (brew install gh)"
    gh auth status >/dev/null 2>&1 || fail "Not authenticated with GitHub (gh auth login)"
    gh release view "$RELEASE_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
        && fail "Release $RELEASE_TAG already exists — bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml"

    printf '{\n    "version": "%s",\n    "build": "%s",\n    "tag": "%s"\n}\n' \
        "$VERSION" "$BUILD_NUMBER" "$RELEASE_TAG" > "$RELEASE_DIR/version.json"

    # Release notes: .release_notes.md if provided, else the latest commit message.
    NOTES_FILE="$RELEASE_DIR/release_notes.md"
    if [ -f "$REPO_ROOT/.release_notes.md" ]; then
        cp "$REPO_ROOT/.release_notes.md" "$NOTES_FILE"
    else
        { echo "## What's New"; echo; git -C "$REPO_ROOT" log -1 --pretty=format:'%s%n%n%b'; } > "$NOTES_FILE"
    fi

    log "Creating GitHub release $RELEASE_TAG"
    gh release create "$RELEASE_TAG" \
        "$DMG_PATH" "$RELEASE_DIR/version.json" "$RELEASE_DIR/signature.txt" \
        --title "$APP_NAME $VERSION (build $BUILD_NUMBER)" \
        --notes-file "$NOTES_FILE" \
        --repo "$GITHUB_REPO"
    rm -f "$NOTES_FILE" "$RELEASE_DIR/version.json"
    log "Release published — update-appcast workflow will deploy appcast.xml to GitHub Pages"
    log "Monitor at: https://github.com/$GITHUB_REPO/actions"
else
    log "Skipping GitHub release (ENABLE_GITHUB_RELEASE=false)"
fi

log "Done. Artifacts in: $RELEASE_DIR"
ls -la "$RELEASE_DIR"
