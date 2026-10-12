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
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
# Replace only this script's generated app bundle. Quit it before rebuilding.
rm -rf "$root/dist/Float Tasks.app"
ditto "$bundle" "$root/dist/Float Tasks.app"
printf 'Built %s\n' "$root/dist/Float Tasks.app"
