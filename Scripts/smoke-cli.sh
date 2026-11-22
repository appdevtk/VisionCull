#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
cli="${1:-$PWD/.build/debug/visioncull}"
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
stage="$(mktemp -d "${temp_root%/}/visioncull-smoke.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/images/album"
cp Tests/VisionCullCoreTests/Fixtures/sample.png "$stage/images/album/one.png"
cp Tests/VisionCullCoreTests/Fixtures/sample.png "$stage/images/two.png"
mode=()
if [[ "$(uname -s)" != "Darwin" ]]; then mode=(--metadata-only); fi

check_output() {
    local expected="$1" output
    shift
    output="$("$@")"
    printf '%s\n' "$output"
    if [[ "$output" != *"$expected"* ]]; then
        printf 'error: expected CLI output to contain %s\n' "$expected" >&2
        exit 1
    fi
}

check_output '2 photos, 2 analyzed, 0 cached, 0 issues' \
    "$cli" scan "$stage/images" "${mode[@]}" --review "$stage/first.json" --cache "$stage/cache"
check_output '2 photos, 0 analyzed, 2 cached, 0 issues' \
    "$cli" scan "$stage/images" "${mode[@]}" --review "$stage/second.json" --cache "$stage/cache"
check_output '[pending] album/one.png' "$cli" preview "$stage/first.json"
"$cli" edit "$stage/first.json" album/one.png --subjects 'plants,flowers' --category Nature \
    --description 'Red & yellow' --date 2026-01-31T14:30:00+01:00 --latitude -52.5 --longitude 13.25
"$cli" approve "$stage/first.json" album/one.png
"$cli" export "$stage/first.json" --output "$stage/export"
grep -F 'Red &amp; yellow' "$stage/export/album/one.xmp"
grep -F '52,30.000000S' "$stage/export/album/one.xmp"
test ! -e "$stage/export/two.xmp"
cmp Tests/VisionCullCoreTests/Fixtures/sample.png "$stage/images/album/one.png"
test ! -e "$stage/images/album/one.xmp"
