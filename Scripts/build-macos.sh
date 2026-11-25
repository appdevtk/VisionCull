#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' "Build the app bundle on macOS with Xcode 16 or newer." >&2
    exit 1
fi

swift build --configuration release --product VisionCullApp
swift build --configuration release --product visioncull \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/Scripts/CLI-Info.plist"
bin_dir="$(swift build --configuration release --show-bin-path)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/visioncull-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/VisionCull.app"
mkdir -p "$app/Contents/MacOS" dist
install -m 755 "$bin_dir/VisionCullApp" "$app/Contents/MacOS/VisionCull"
install -m 644 Scripts/App-Info.plist "$app/Contents/Info.plist"
install -m 755 "$bin_dir/visioncull" "$stage/visioncull"
plutil -lint "$app/Contents/Info.plist" Scripts/CLI-Info.plist
codesign --force --sign - "$app"
codesign --force --sign - "$stage/visioncull"
codesign --verify --strict "$app"
codesign --verify --strict "$stage/visioncull"
"$stage/visioncull" --help >/dev/null
ditto -c -k --keepParent "$app" "$stage/VisionCull-macOS.zip"
mv "$stage/VisionCull-macOS.zip" dist/VisionCull-macOS.zip
install -m 755 "$stage/visioncull" dist/visioncull
ditto "$app" dist/VisionCull.app
