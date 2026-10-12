#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This optional native UI test requires a logged-in macOS desktop session." >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Install Xcode Command Line Tools with Swift 6 before running this test." >&2
    exit 1
fi

tests_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$(cd "$tests_dir/../Sources" && pwd)"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/floattasks-scroll-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

architecture="$(uname -m)"
case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Unsupported Mac architecture: $architecture" >&2; exit 1 ;;
esac

echo "Building native scroll layout checks with synthetic tasks…"
xcrun swiftc -O -swift-version 6 -target "$architecture-apple-macosx13.0" \
    -module-cache-path "$test_build_dir/ModuleCache" \
    "$source_dir/Models.swift" "$source_dir/FloatingUI.swift" "$tests_dir/ScrollLayoutTests.swift" \
    -o "$test_build_dir/FloatTasksScrollLayoutTests"

echo "Checking top/bottom scrolling and narrow-window resizing (about 20 seconds)…"
"$test_build_dir/FloatTasksScrollLayoutTests"
