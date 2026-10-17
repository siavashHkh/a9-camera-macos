#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
work=$(mktemp -d build/app.XXXXXX)
trap 'rm -rf "$work"' EXIT
app="$work/A9 Camera.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/module-cache
cp Info.plist "$app/Contents/Info.plist"
swiftc -O -target arm64-apple-macos26.0 -module-cache-path build/module-cache Sources/*.swift -o "$app/Contents/MacOS/A9Camera" -framework AppKit -framework CoreBluetooth -framework Network -framework ImageIO
codesign --force --sign - --options runtime --entitlements Entitlements.plist "$app"
rm -rf "build/A9 Camera.app"
mv "$app" "build/A9 Camera.app"
printf 'Built: %s/build/A9 Camera.app\n' "$PWD"
