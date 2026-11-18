#!/bin/zsh
# Runs the test suite under a time limit: an AppKit test that waits on a mouse-up (NSTextView tracking loop)
# would otherwise hang forever. Extra arguments go to `swift test`, e.g. scripts/test.sh --filter PaneLayoutTests
set -euo pipefail
cd "${0:A:h:h}"
limit="${TEST_TIMEOUT:-900}"

# A LaunchServices helper has its own permissions. Avoid protected folders such as Documents.
test_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
FOLMI_PTY_TEST_DIRECTORY="$(mktemp -d "$test_parent/folmi-pty-tests.XXXXXX")"
export FOLMI_PTY_TEST_DIRECTORY
function test_pty_pids() {
  # Scope this check to this invocation, including when other worktrees run App tests at the same time.
  /bin/ps -ww -axo pid=,args= | LC_ALL=C /usr/bin/awk -v root="$FOLMI_PTY_TEST_DIRECTORY/" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      if (index($0, root) == 1 && /\/(folmi-pty-[0-9a-f]+|FolmiTerminal-[0-9a-f]+\.app\/Contents\/MacOS\/folmi-pty) serve --socket / && index($0, " --run-directory " root)) print pid
    }'
}
function check_test_ptys() {
  local code=$? pid
  local -a pids
  pids=(${(f)"$(test_pty_pids)"})
  if (( ${#pids} )); then
    print -u2 "测试结束后仍有 folmi-pty 进程（PID：${pids[*]}）"
    code=1
    for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for delay in {1..50}; do
      pids=(${(f)"$(test_pty_pids)"})
      (( ${#pids} )) || break
      sleep 0.1
    done
    for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  fi
  rm -rf -- "$FOLMI_PTY_TEST_DIRECTORY"
  exit "$code"
}
trap check_test_ptys EXIT

if command -v timeout >/dev/null; then timeout "$limit" swift test "$@"
elif command -v gtimeout >/dev/null; then gtimeout "$limit" swift test "$@"
else
  swift test "$@" & pid=$!
  ( sleep "$limit"; kill -TERM $pid 2>/dev/null ) & watchdog=$!
  # `status` is read-only in zsh, and under `set -e` a failing `wait` would exit before the watchdog is stopped.
  code=0; wait $pid || code=$?; kill $watchdog 2>/dev/null || true; exit $code
fi
