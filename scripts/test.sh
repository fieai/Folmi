#!/bin/zsh
# Runs the test suite under a time limit: an AppKit test that waits on a mouse-up (NSTextView tracking loop)
# would otherwise hang forever. Extra arguments go to `swift test`, e.g. scripts/test.sh --filter PaneLayoutTests
set -euo pipefail
cd "${0:A:h:h}"
limit="${TEST_TIMEOUT:-900}"
if command -v timeout >/dev/null; then exec timeout "$limit" swift test "$@"
elif command -v gtimeout >/dev/null; then exec gtimeout "$limit" swift test "$@"
else
  swift test "$@" & pid=$!
  ( sleep "$limit"; kill -TERM $pid 2>/dev/null ) & watchdog=$!
  # `status` is read-only in zsh, and under `set -e` a failing `wait` would exit before the watchdog is stopped.
  code=0; wait $pid || code=$?; kill $watchdog 2>/dev/null || true; exit $code
fi
