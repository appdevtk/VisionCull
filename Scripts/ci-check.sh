#!/usr/bin/env bash
set -euo pipefail

log="$(mktemp "${RUNNER_TEMP:-/tmp}/visioncull-ci.XXXXXX")"
trap 'rm -f "$log"' EXIT
if "$@" 2>&1 | tee "$log"; then
    exit 0
fi

# Keep compiler and test failures visible in the GitHub run summary.
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    awk '
        /error:|error: |failed|Error Domain|fatal error|command not found|resource fork|No such file/ && count < 20 {
            gsub(/%/, "%25")
            gsub(/\r/, "%0D")
            print "::error::" $0
            count++
        }
    ' "$log"
fi
exit 1
