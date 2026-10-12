#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Float Tasks requires macOS 13 or later and Xcode command-line tools." >&2
    exit 1
fi
arch="${TARGET_ARCH:-$(uname -m)}"
case "$arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported TARGET_ARCH: $arch" >&2; exit 1 ;;
esac
xcrun --find swiftc >/dev/null

# Keep one certificate identity across local updates so Keychain can recognize
# the app. This file is data, never shell code; names and partial hashes are not
# accepted because they can select a different certificate as Keychain changes.
signing_identity="-"
identity_file="$root/.codesign-identity"
if [[ ${CODE_SIGN_IDENTITY+x} ]]; then
    signing_identity="$CODE_SIGN_IDENTITY"
elif [[ -e "$identity_file" || -L "$identity_file" ]]; then
    if [[ ! -f "$identity_file" || ! -r "$identity_file" ]]; then
        echo "Cannot read .codesign-identity. Fix or remove the local configuration; refusing ad-hoc fallback." >&2
        exit 1
    fi
    # Validate the file before command substitution, which would otherwise
    # silently strip extra trailing newlines. Accept one hash with optional LF.
    # Count unexpected bytes separately: some awk implementations ignore a NUL
    # suffix, and shell variables cannot retain it for subsequent validation.
    if ! unexpected_bytes="$(LC_ALL=C tr -d '0-9A-Fa-f\n' < "$identity_file" | wc -c)" ||
        [[ "$unexpected_bytes" -ne 0 ]] ||
        ! LC_ALL=C awk 'NR != 1 || length($0) != 40 || $0 ~ /[^0-9A-Fa-f]/ { invalid = 1 }
        END { exit invalid || NR != 1 }' "$identity_file"; then
        echo ".codesign-identity must contain one 40-character certificate SHA-1 hash, with at most one trailing newline." >&2
        exit 1
    fi
    signing_identity="$(cat "$identity_file")"
fi

if [[ ${CODE_SIGN_IDENTITY+x} || -e "$identity_file" || -L "$identity_file" ]]; then
    if [[ ! "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        echo "Signing identity must be a full 40-character certificate SHA-1 hash. See docs/SIGNING.md." >&2
        exit 1
    fi
    signing_identity="$(printf '%s' "$signing_identity" | tr '[:lower:]' '[:upper:]')"
    # An untrusted self-signed identity can still provide a stable local code
    # identity. Do not filter it out with -v or add global trust to use it.
    if ! available_identities="$(security find-identity -p codesigning)"; then
        echo "Could not read signing identities from Keychain; refusing ad-hoc fallback." >&2
        exit 1
    fi
    if ! printf '%s\n' "$available_identities" | awk -v desired="$signing_identity" \
        '$1 ~ /^[0-9]+\)$/ && toupper($2) == desired { found = 1 } END { exit !found }'; then
        echo "Configured signing certificate/private key is unavailable. Check Keychain; refusing ad-hoc fallback." >&2
        exit 1
    fi
else
    echo "Warning: No signing identity configured; using ad-hoc signing. Keychain may ask again after updates. See docs/SIGNING.md." >&2
fi

destination="$root/dist/Float Tasks.app"
ensure_safe_replacement() {
    if [[ "$signing_identity" == "-" && ( -e "$destination" || -L "$destination" ) ]]; then
        if ! existing_signature="$(codesign --display --verbose=4 "$destination" 2>&1)"; then
            echo "Cannot inspect the existing app signature. Preserve or move it before rebuilding; refusing ad-hoc replacement." >&2
            exit 1
        fi
        if ! printf '%s\n' "$existing_signature" | awk '$0 == "Signature=adhoc" { found = 1 } END { exit !found }'; then
            echo "The existing dist app is certificate-signed. Configure its signing identity to update it. To intentionally switch to ad-hoc, first move that app out of dist. See docs/SIGNING.md." >&2
            exit 1
        fi
    fi
}
ensure_safe_replacement

mkdir -p "$root/.build" "$root/dist"
stage="$(mktemp -d "$root/.build/app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Float Tasks.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

# Package the original transparent PNG at macOS's standard icon sizes. sips
# preserves its alpha channel; generated iconset/ICNS files stay in build output.
iconset="$stage/FloatTasks.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/Assets/FloatTasks.png" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$root/Assets/FloatTasks.png" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/FloatTasks.icns"

xcrun swiftc -O -swift-version 6 -target "$arch-apple-macosx13.0" \
    "$root/Sources/Models.swift" \
    "$root/Sources/GoogleOAuth.swift" \
    "$root/Sources/GoogleTasksClient.swift" \
    "$root/Sources/Store.swift" \
    "$root/Sources/FloatingUI.swift" \
    "$root/Sources/App.swift" \
    -o "$bundle/Contents/MacOS/FloatTasks" \
    -framework AppKit -framework SwiftUI -framework Security \
    -framework Network -framework CryptoKit

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Float Tasks</string>
<key>CFBundleDisplayName</key><string>Float Tasks</string>
<key>CFBundleIdentifier</key><string>com.iuhachicha.floattasks</string>
<key>CFBundleExecutable</key><string>FloatTasks</string>
<key>CFBundleIconFile</key><string>FloatTasks.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$bundle/Contents/Info.plist"
# Let codesign generate its normal certificate/bundle designated requirement.
# Never weaken it to an identifier-only custom requirement to avoid prompts.
codesign --force --sign "$signing_identity" "$bundle"
codesign --verify --deep --strict "$bundle"
# Replace only this script's generated app bundle. Quit it before rebuilding.
ensure_safe_replacement
rm -rf "$destination"
ditto "$bundle" "$destination"
printf 'Built %s\n' "$destination"
