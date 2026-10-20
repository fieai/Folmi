#!/bin/zsh
# Everything before handing a build over: debug build with warnings shown, the test suite, the perf budget, then the demo bundle.
set -euo pipefail
cd "${0:A:h:h}"
print "▸ 编译（debug）"; swift build 2>&1 | grep -E "warning:|error:" || true
print "▸ 测试"; ./scripts/test.sh
# 性能门槛会把 App 窗口调到前面跑十几秒；SKIP_PERF=1 跳过。
if [[ -z "${SKIP_PERF:-}" ]]; then print "▸ 性能门槛"; ./scripts/perf.sh --budget 3; fi
print "▸ 打包演示 App"; ./scripts/build-app.sh --editor-preview
