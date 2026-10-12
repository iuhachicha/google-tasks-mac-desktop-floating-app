#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "These native macOS tests require macOS 13 or later and Xcode Command Line Tools." >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Install Xcode Command Line Tools with xcode-select --install, then run this script again." >&2
    exit 1
fi

tests_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$(cd "$tests_dir/../Sources" && pwd)"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/floattasks-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

architecture="$(uname -m)"
case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Unsupported Mac architecture: $architecture" >&2; exit 1 ;;
esac
compiler_flags=(-swift-version 6 -target "$architecture-apple-macosx13.0" -module-cache-path "$test_build_dir/ModuleCache")

# Compiling/running this generator requires only Foundation, with no Python or
# downloaded packages. Checked boundaries prevent a source refactor from silently
# restoring real Keychain, browser, or token-service calls inside the tests.
xcrun swiftc "${compiler_flags[@]}" "$tests_dir/PrepareOAuthFixture.swift" -o "$test_build_dir/prepare-fixture"
"$test_build_dir/prepare-fixture" "$source_dir/GoogleOAuth.swift" "$test_build_dir/GoogleOAuthFixture.swift"

echo "Testing OAuth security and its temporary IPv4 loopback callback…"
xcrun swiftc "${compiler_flags[@]}" "$test_build_dir/GoogleOAuthFixture.swift" \
    "$tests_dir/OAuthTestDoubles.swift" "$tests_dir/OAuthTests.swift" -o "$test_build_dir/oauth-tests"
"$test_build_dir/oauth-tests"

echo "Testing persistent sign-in with in-memory credentials and token responses…"
xcrun swiftc "${compiler_flags[@]}" "$test_build_dir/GoogleOAuthFixture.swift" \
    "$tests_dir/OAuthTestDoubles.swift" "$tests_dir/PersistenceTests.swift" -o "$test_build_dir/persistence-tests"
"$test_build_dir/persistence-tests"

echo "Testing the Tasks API client with synthetic transport responses…"
xcrun swiftc "${compiler_flags[@]}" "$source_dir/Models.swift" "$source_dir/GoogleTasksClient.swift" \
    "$tests_dir/GoogleTasksClientTests.swift" -o "$test_build_dir/api-tests"
"$test_build_dir/api-tests"

echo "Testing account-switch and disconnect cache privacy with synthetic accounts…"
xcrun swiftc "${compiler_flags[@]}" "$source_dir/Models.swift" "$source_dir/Store.swift" \
    "$tests_dir/StorePrivacyTests.swift" -o "$test_build_dir/store-tests"
FLOATTASKS_DATA_DIR="$test_build_dir/store-fixtures" FLOATTASKS_TEST_ISOLATED=1 "$test_build_dir/store-tests"

echo "All tests passed. Temporary build files will be removed on exit."
