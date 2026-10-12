#!/bin/bash
set -euo pipefail
umask 077

# Optional manual test, deliberately excluded from run.sh and CI.
# Usage: ./tests/run-signing.sh EXACT_40_HEX_CERTIFICATE_SHA1
# Signing is an explicit step: this script never creates/imports identities,
# changes trust/ACLs, supplies a Keychain password, or falls back to ad-hoc signing.
if [[ $# -ne 1 || ! "$1" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    printf '%s\n' 'FAIL: expected exactly one 40-hex certificate identity argument'
    exit 2
fi
identity="$1"
if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
    printf '%s\n' 'FAIL: this manual Keychain test requires macOS 13 or later'
    exit 2
fi
arch="$(/usr/bin/uname -m)"
case "$arch" in
    arm64|x86_64) ;;
    *) printf '%s\n' 'FAIL: unsupported Mac architecture'; exit 2 ;;
esac
script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
/bin/mkdir -p "$repo_root/.build/signing-tests"
run_dir="$(/usr/bin/mktemp -d "$repo_root/.build/signing-tests/run.XXXXXX")"
identifier='com.floattasks.signing-probe'
service="com.floattasks.signing-probe.$(/usr/bin/uuidgen)"
current="$run_dir/probe"
cleanup_needed=0
printf '%s\n' "$service" > "$run_dir/service.txt"

cleanup() {
    local result=$?
    trap - EXIT
    set +e
    if [[ "$cleanup_needed" == 1 ]]; then
        # First try the current version, then restore A at the same path if B
        # failed continuity. Both delete only this run's exact service/account.
        "$current" delete "$service" > "$run_dir/cleanup.log" 2>&1
        local cleaned=$?
        if [[ "$cleaned" != 0 ]]; then
            /bin/cp "$run_dir/versionA" "$run_dir/cleanup-replacement" &&
                /bin/mv -f "$run_dir/cleanup-replacement" "$current" &&
                "$current" delete "$service" > "$run_dir/cleanup.log" 2>&1
            cleaned=$?
        fi
        if [[ "$cleaned" != 0 ]]; then
            printf '%s\n' 'FAIL: could not confirm synthetic item cleanup; diagnostic directory retained'
            /bin/cat "$run_dir/cleanup.log"
            printf 'Diagnostics: %s\nSynthetic service: %s\nSynthetic account: synthetic-fixture\n' "$run_dir" "$service"
            exit 1
        fi
        /bin/cat "$run_dir/cleanup.log"
    fi
    if [[ "$result" != 0 ]]; then
        printf 'Diagnostic files retained: %s\n' "$run_dir"
        exit "$result"
    fi
    /bin/rm -rf -- "$run_dir"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    printf 'FAIL: %s\n' "$1"
    exit 1
}

for version in A B; do
    /usr/bin/xcrun swiftc -O -swift-version 6 -target "$arch-apple-macosx13.0" \
        -module-cache-path "$run_dir/ModuleCache" -framework Security \
        -D "PROBE_VERSION_$version" "$script_dir/SigningContinuityProbe.swift" \
        -o "$run_dir/version$version" > "$run_dir/build$version.log" 2>&1 || fail "compile version $version"
    /usr/bin/codesign --sign "$identity" --identifier "$identifier" \
        --timestamp=none --force "$run_dir/version$version" \
        > "$run_dir/sign$version.log" 2>&1 || fail "sign version $version"
    /usr/bin/codesign --verify --strict --verbose=2 "$run_dir/version$version" \
        > "$run_dir/verify$version.log" 2>&1 || fail "verify version $version"
    /usr/bin/codesign --display -r- "$run_dir/version$version" \
        > "$run_dir/requirements$version.log" 2>&1 || fail "read version $version requirement"
    /usr/bin/sed -nE 's/^(# )?designated => //p' "$run_dir/requirements$version.log" \
        > "$run_dir/requirement$version.txt"
    [[ -s "$run_dir/requirement$version.txt" ]] || fail "missing version $version requirement"
    /usr/bin/codesign --display --verbose=4 "$run_dir/version$version" \
        > "$run_dir/details$version.log" 2>&1 || fail "read version $version signature details"
done

/usr/bin/cmp -s "$run_dir/requirementA.txt" "$run_dir/requirementB.txt" || fail 'different designated requirements'
# A certificate-anchored default DR must not be an ad-hoc cdhash requirement or
# merely the signing identifier. This does not alter either default requirement.
/usr/bin/grep -Eq '(anchor|certificate) ' "$run_dir/requirementA.txt" || fail 'requirement lacks a certificate anchor'
if /usr/bin/grep -Eq 'cdhash ' "$run_dir/requirementA.txt"; then
    fail 'requirement unexpectedly depends on a build hash'
fi
hash_a="$(/usr/bin/sed -n 's/^CDHash=//p' "$run_dir/detailsA.log")"
hash_b="$(/usr/bin/sed -n 's/^CDHash=//p' "$run_dir/detailsB.log")"
[[ -n "$hash_a" && -n "$hash_b" && "$hash_a" != "$hash_b" ]] || fail 'build hashes must differ'
/usr/bin/codesign --verify --strict -R "$run_dir/requirementA.txt" "$run_dir/versionB" \
    > "$run_dir/cross-verify.log" 2>&1 || fail 'version B does not satisfy version A requirement'
printf '%s\n' 'PASS: different signed builds have identical certificate-anchored requirements'

/bin/cp "$run_dir/versionA" "$current" || fail 'install probe version A'
# Try cleanup even if creation is interrupted after SecItemAdd succeeds but
# before the process reports success. The UUID keeps the query run-specific.
cleanup_needed=1
if ! "$current" add "$service"; then
    fail 'version A could not create synthetic item without UI'
fi
# Atomic replacement avoids rewriting an executable inode whose signature has
# already been cached by macOS. The actual executable path stays unchanged.
/bin/cp "$run_dir/versionB" "$run_dir/replacement" || fail 'stage probe version B'
/bin/mv -f "$run_dir/replacement" "$current" || fail 'replace probe at the same path'
/usr/bin/codesign --verify --strict -R "$run_dir/requirementA.txt" "$current" \
    > "$run_dir/installed-verify.log" 2>&1 || fail 'verify replaced executable'
"$current" read "$service" || fail 'update continuity without UI'
"$current" delete "$service" || fail 'version B cleanup'
cleanup_needed=0
printf '%s\n' 'PASS: signing continuity verification complete'
