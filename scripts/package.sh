#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
stage_root=$(mktemp -d build/package.XXXXXX)
trap 'rm -rf "$stage_root"' EXIT
stage="$stage_root/A9 Camera"
mkdir -p "$stage" dist
ditto --norsrc --noextattr "build/A9 Camera.app" "$stage/A9 Camera.app"
cp docs/START-HERE.txt "$stage/START HERE.txt"
cp docs/TEST-RESULTS.md "$stage/TEST-RESULTS.md"
cp docs/SECURITY-REVIEW.md "$stage/SECURITY-REVIEW.md"
archive="A9-Camera-${version}-macOS-Apple-Silicon.zip"
# zip metadata contains only the fresh staging files; no resource forks or xattrs.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$stage" "dist/$archive"
(cd dist && shasum -a 256 "$archive" > SHA256SUMS.txt)
printf 'Packaged: dist/%s\n' "$archive"
