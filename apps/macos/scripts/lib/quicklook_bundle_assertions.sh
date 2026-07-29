#!/usr/bin/env bash

assert_quicklook_bundle() {
    local app="$1"
    local quicklook="$app/Contents/PlugIns/XZipQuickLook.appex"
    local host_7zz="$app/Contents/Resources/bin/7zz"
    local codesign_bin="${CODESIGN_BIN:-codesign}"
    local plist_buddy_bin="${PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
    local entitlements extension_7zz sandbox_enabled

    [ -d "$quicklook" ] || fail "Missing Quick Look extension"
    if ! extension_7zz="$(find "$quicklook" -name '7zz' -print -quit)"; then
        fail "Could not scan Quick Look extension for 7zz"
    fi
    [ -z "$extension_7zz" ] || fail "Quick Look extension must not contain 7zz"
    [ -x "$host_7zz" ] || fail "Host app 7zz is missing or not executable"
    "$codesign_bin" --verify --strict "$host_7zz" >/dev/null 2>&1 \
        || fail "Host app 7zz signature is invalid"

    if ! entitlements="$(mktemp "${TMPDIR:-/tmp}/xzip-quicklook-entitlements.XXXXXX")"; then
        fail "Could not create Quick Look entitlement temp file"
    fi
    if ! "$codesign_bin" -d --entitlements :- "$quicklook" >"$entitlements" 2>/dev/null; then
        rm -f "$entitlements"
        fail "Could not read Quick Look entitlements"
    fi
    sandbox_enabled="$(
        "$plist_buddy_bin" \
            -c 'Print :com.apple.security.app-sandbox' \
            "$entitlements" 2>/dev/null || true
    )"
    rm -f "$entitlements"
    [ "$sandbox_enabled" = "true" ] \
        || fail "Quick Look app sandbox must be enabled"
}
