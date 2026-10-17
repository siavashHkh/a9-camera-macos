#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="build/A9 Camera.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/module-cache
cp Info.plist "$app/Contents/Info.plist"
swiftc -O -target arm64-apple-macos26.0 -module-cache-path build/module-cache Sources/*.swift -o "$app/Contents/MacOS/A9Camera" -framework AppKit -framework CoreBluetooth -framework Network
codesign --force --sign - "$app"
printf 'Built: %s/%s\n' "$PWD" "$app"
