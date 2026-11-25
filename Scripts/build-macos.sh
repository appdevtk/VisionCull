#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' "Build the app bundle on macOS with Xcode 16 or newer." >&2
    exit 1
fi

if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--universal" ) ]]; then
    printf '%s\n' "Usage: Scripts/build-macos.sh [--universal]" >&2
    exit 2
fi

build_products() {
    swift build --configuration release "$@" --product VisionCullApp >&2 || return
    swift build --configuration release "$@" --product visioncull \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/Scripts/CLI-Info.plist" >&2 || return
    swift build --configuration release "$@" --show-bin-path
}

temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
stage="$(mktemp -d "${temp_root%/}/visioncull-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/VisionCull.app"
app_binary="$app/Contents/MacOS/VisionCull"
cli_binary="$stage/visioncull"
mkdir -p "$app/Contents/MacOS" dist

if [[ "${1:-}" == "--universal" ]]; then
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    intel="$(build_products --triple x86_64-apple-macosx15.0 --sdk "$sdk")"
    arm="$(build_products --triple arm64-apple-macosx15.0 --sdk "$sdk")"
    xcrun lipo -create "$intel/VisionCullApp" "$arm/VisionCullApp" -output "$app_binary"
    xcrun lipo -create "$intel/visioncull" "$arm/visioncull" -output "$cli_binary"
    chmod 755 "$app_binary" "$cli_binary"
    for binary in "$app_binary" "$cli_binary"; do
        xcrun lipo -verify_arch x86_64 arm64 "$binary"
        printf '%s: %s\n' "$(basename "$binary")" "$(xcrun lipo -archs "$binary")"
    done
else
    bin_dir="$(build_products)"
    install -m 755 "$bin_dir/VisionCullApp" "$app_binary"
    install -m 755 "$bin_dir/visioncull" "$cli_binary"
fi

install -m 644 Scripts/App-Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" Scripts/CLI-Info.plist
codesign --force --sign - "$app"
codesign --force --sign - "$cli_binary"
codesign --verify --strict "$app"
codesign --verify --strict "$cli_binary"
"$cli_binary" --help >/dev/null
ditto -c -k --keepParent "$app" "$stage/VisionCull-macOS.zip"
mv "$stage/VisionCull-macOS.zip" dist/VisionCull-macOS.zip
install -m 755 "$cli_binary" dist/visioncull
ditto "$app" dist/VisionCull.app
