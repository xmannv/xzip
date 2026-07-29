#!/usr/bin/env bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../lib/quicklook_bundle_assertions.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xzip-quicklook-assertions.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'assertion failed: %s\n' "$1" >&2
    exit 1
}

assert_test() {
    local condition="$1"
    local message="$2"

    if ! eval "$condition"; then
        printf 'test failed: %s\n' "$message" >&2
        exit 1
    fi
}

assert_expected_failure() {
    local message="$1"

    shift
    if ( "$@" >/dev/null 2>&1 ); then
        printf 'expected failure: %s\n' "$message" >&2
        exit 1
    fi
}

assert_entitlement_temps_cleaned() {
    local message="$1"

    assert_test '[ -z "$(find "$ENTITLEMENTS_TMP" -mindepth 1 -print -quit)" ]' "$message"
}

APP="$TEST_ROOT/XZip.app"
QUICKLOOK="$APP/Contents/PlugIns/XZipQuickLook.appex"
HOST_7ZZ="$APP/Contents/Resources/bin/7zz"
EXTENSION_7ZZ="$QUICKLOOK/Contents/Resources/bin/7zz"
EXTENSION_RESOURCE_7ZZ="$QUICKLOOK/Contents/Resources/7zz"
EXTENSION_MACOS_7ZZ="$QUICKLOOK/Contents/MacOS/7zz"
ENTITLEMENTS_TMP="$TEST_ROOT/entitlements-tmp"
mkdir -p "$QUICKLOOK/Contents/Resources/bin" "$(dirname "$HOST_7ZZ")" "$ENTITLEMENTS_TMP"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOST_7ZZ"
chmod +x "$HOST_7ZZ"

FAKE_CODESIGN="$TEST_ROOT/codesign"
cat >"$FAKE_CODESIGN" <<'EOF'
#!/usr/bin/env bash

if [ "$#" -eq 3 ] \
    && [ "$1" = "--verify" ] \
    && [ "$2" = "--strict" ] \
    && [ "$3" = "$FAKE_EXPECTED_HOST_7ZZ" ]; then
    [ "${FAKE_SIGNATURE_VALID:-true}" = "true" ]
    exit
fi

if [ "$#" -eq 4 ] \
    && [ "$1" = "-d" ] \
    && [ "$2" = "--entitlements" ] \
    && [ "$3" = ":-" ] \
    && [ "$4" = "$FAKE_EXPECTED_QUICKLOOK" ]; then
    [ "${FAKE_ENTITLEMENTS_READABLE:-true}" = "true" ] || exit 1
    if [ "${FAKE_SANDBOX_ENABLED:-true}" = "true" ]; then
        printf '<plist><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>\n'
    else
        printf '<plist><dict><key>com.apple.security.app-sandbox</key><false/></dict></plist>\n'
    fi
    exit 0
fi

exit 1
EOF
chmod +x "$FAKE_CODESIGN"

FAKE_PLIST_BUDDY="$TEST_ROOT/PlistBuddy"
cat >"$FAKE_PLIST_BUDDY" <<'EOF'
#!/usr/bin/env bash

[ "$#" -eq 3 ] || exit 1
[ "$1" = "-c" ] || exit 1
[ "$2" = 'Print :com.apple.security.app-sandbox' ] || exit 1
plist="$3"
[ -f "$plist" ] || exit 1
case "$plist" in
    "$FAKE_EXPECTED_ENTITLEMENTS_DIR"/xzip-quicklook-entitlements.??????) ;;
    *) exit 1 ;;
esac

if grep -q '<true/>' "$plist"; then
    printf 'true\n'
else
    printf 'false\n'
fi
EOF
chmod +x "$FAKE_PLIST_BUDDY"

export CODESIGN_BIN="$FAKE_CODESIGN"
export PLIST_BUDDY_BIN="$FAKE_PLIST_BUDDY"
export TMPDIR="$ENTITLEMENTS_TMP"
export FAKE_SIGNATURE_VALID=true
export FAKE_ENTITLEMENTS_READABLE=true
export FAKE_SANDBOX_ENABLED=true
export FAKE_EXPECTED_HOST_7ZZ="$HOST_7ZZ"
export FAKE_EXPECTED_QUICKLOOK="$QUICKLOOK"
export FAKE_EXPECTED_ENTITLEMENTS_DIR="$ENTITLEMENTS_TMP"

assert_expected_failure "codesign verify without --strict" \
    "$FAKE_CODESIGN" --verify "$HOST_7ZZ"
assert_expected_failure "codesign verify with wrong target" \
    "$FAKE_CODESIGN" --verify --strict "$APP"
assert_expected_failure "codesign verify with extra argument" \
    "$FAKE_CODESIGN" --verify --strict "$HOST_7ZZ" unexpected
assert_expected_failure "codesign entitlement dump without stdout selector" \
    "$FAKE_CODESIGN" -d --entitlements "$QUICKLOOK"
assert_expected_failure "codesign entitlement dump with wrong target" \
    "$FAKE_CODESIGN" -d --entitlements :- "$APP"
assert_expected_failure "codesign entitlement dump with extra argument" \
    "$FAKE_CODESIGN" -d --entitlements :- "$QUICKLOOK" unexpected
printf '<plist><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>\n' \
    >"$ENTITLEMENTS_TMP/malformed.plist"
assert_expected_failure "PlistBuddy with wrong entitlement key" \
    "$FAKE_PLIST_BUDDY" -c 'Print :wrong-key' "$ENTITLEMENTS_TMP/malformed.plist"
assert_expected_failure "PlistBuddy with wrong same-directory entitlement filename" \
    "$FAKE_PLIST_BUDDY" -c 'Print :com.apple.security.app-sandbox' \
    "$ENTITLEMENTS_TMP/malformed.plist"
assert_expected_failure "PlistBuddy with wrong entitlement file" \
    "$FAKE_PLIST_BUDDY" -c 'Print :com.apple.security.app-sandbox' "$HOST_7ZZ"
assert_expected_failure "PlistBuddy with extra argument" \
    "$FAKE_PLIST_BUDDY" -c 'Print :com.apple.security.app-sandbox' \
    "$ENTITLEMENTS_TMP/malformed.plist" unexpected
rm -f "$ENTITLEMENTS_TMP/malformed.plist"

# shellcheck source=/dev/null
source "$HELPER"

assert_quicklook_bundle "$APP"
assert_entitlement_temps_cleaned "happy path must clean the entitlement temp file"

printf '#!/usr/bin/env bash\nexit 0\n' >"$EXTENSION_7ZZ"
chmod +x "$EXTENSION_7ZZ"
assert_expected_failure "extension-local 7zz" assert_quicklook_bundle "$APP"
rm -f "$EXTENSION_7ZZ"

printf '#!/usr/bin/env bash\nexit 0\n' >"$EXTENSION_RESOURCE_7ZZ"
assert_expected_failure "extension Resources 7zz" assert_quicklook_bundle "$APP"
rm -f "$EXTENSION_RESOURCE_7ZZ"

mkdir -p "$(dirname "$EXTENSION_MACOS_7ZZ")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$EXTENSION_MACOS_7ZZ"
assert_expected_failure "extension MacOS 7zz" assert_quicklook_bundle "$APP"
rm -f "$EXTENSION_MACOS_7ZZ"

ln -s "$TEST_ROOT/outside-bundle" "$EXTENSION_RESOURCE_7ZZ"
assert_expected_failure "extension symlink named 7zz" assert_quicklook_bundle "$APP"
rm -f "$EXTENSION_RESOURCE_7ZZ"

rm -f "$HOST_7ZZ"
assert_expected_failure "missing host 7zz" assert_quicklook_bundle "$APP"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOST_7ZZ"
chmod +x "$HOST_7ZZ"

export FAKE_SIGNATURE_VALID=false
assert_expected_failure "invalid host 7zz signature" assert_quicklook_bundle "$APP"
export FAKE_SIGNATURE_VALID=true

export FAKE_SANDBOX_ENABLED=false
assert_expected_failure "Quick Look sandbox disabled" assert_quicklook_bundle "$APP"
assert_entitlement_temps_cleaned "sandbox failure must clean the entitlement temp file"
export FAKE_SANDBOX_ENABLED=true

export FAKE_ENTITLEMENTS_READABLE=false
assert_expected_failure "unreadable Quick Look entitlements" assert_quicklook_bundle "$APP"
assert_entitlement_temps_cleaned "entitlement read failure must clean the temp file"

printf 'PASS: Quick Look bundle assertions\n'
