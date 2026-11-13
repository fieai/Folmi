#!/bin/zsh
# Measures launch and switching in the release app against a throwaway repository, then prints a summary.
#   scripts/perf.sh [--budget] [runs] [source-repo]
# With --budget, medians and the large/huge stall ratio are checked; the script exits 1 when one is over.
# The source repository is cloned into a temp folder and edited there; the app uses its own settings file, so neither
# the source nor your normal Folmi settings are touched. The app window comes to the front while it runs.
set -euo pipefail
cd "${0:A:h:h}"
budget=""
if [[ "${1:-}" == "--budget" ]]; then budget="$PWD/scripts/perf-budget.tsv"; shift; fi
runs="${1:-5}"
source_repo="${2:-$HOME/Documents/ZCTD/wf-skills}"
work="$(cd "$(mktemp -d -t folmi-perf)" && pwd -P)"
repo="$work/repository"
large_repo="$work/large-repository"
huge_repo="$work/huge-repository"

git clone --quiet --local --no-hardlinks "$source_repo" "$repo"
# A review-sized change set: edits in a few Markdown files, one large document added, one file deleted.
i=0
markdown=("${(@f)$(cd "$repo" && git -c core.quotePath=false ls-files 'docs/*.md' 'skills/*.md' | head -6)}")
for f in "${markdown[@]}"; do
  print "\n## 测量用改动 $i\n\n这一段是 perf.sh 加的。" >> "$repo/$f"; i=$((i + 1))
done
[[ -f docs/progress-v0.5.md ]] && cp docs/progress-v0.5.md "$repo/docs-progress-large.md"
(cd "$repo" && git rm --quiet "$(git -c core.quotePath=false ls-files 'scripts/*' | head -1)")

for project_repo in "$large_repo" "$huge_repo"; do
  git init --quiet "$project_repo"
  git -C "$project_repo" -c user.name=perf -c user.email=perf@localhost commit --quiet --allow-empty -m perf
done
python3 - "$large_repo" "$huge_repo" <<'PY'
import pathlib, sys
for root_path, subfolders in zip(sys.argv[1:], (1, 4)):
    root = pathlib.Path(root_path)
    for folder in range(50):
        for subfolder in range(subfolders):
            directory = root / f"folder-{folder:02}" / f"child-{subfolder:02}"
            directory.mkdir(parents=True)
            for file in range(100):
                (directory / f"file-{file:03}.txt").write_text("perf\n")
PY

swift build -c release --product Folmi >/dev/null
binary_dir="$(swift build -c release --show-bin-path)"
# Give WindowServer and WebKit a distinct app identity instead of sharing an unbundled process name with Folmi.
app="$work/FolmiPerf.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Folmi" "$app/Contents/MacOS/Folmi"
for resource_bundle in "$binary_dir"/Folmi_Folmi.bundle "$binary_dir"/SwiftTerm_*.bundle(N); do
  /usr/bin/ditto "$resource_bundle" "$app/Contents/Resources/${resource_bundle:t}"
done
python3 - "$app/Contents/Info.plist" <<'PLIST'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleExecutable": "Folmi", "CFBundleIdentifier": "local.folmi.perf",
    "CFBundleName": "FolmiPerf", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
}))
PLIST
while IFS= read -r -d '' code_file; do
  if [[ "$(/usr/bin/file -b "$code_file")" == *Mach-O* ]]; then
    /usr/bin/codesign --force --sign - "$code_file" >/dev/null 2>&1
  fi
done < <(/usr/bin/find "$app/Contents" -type f -print0)
/usr/bin/codesign --force --sign - "$app" >/dev/null 2>&1
binary="$app/Contents/MacOS/Folmi"

# One settings folder for all runs, like daily use: the first run opens the project fresh, later runs restore it
# (saved status, open tabs, reader position) the way a normal launch does.
settings="$work/settings/workspace.json"; mkdir -m 700 -p "${settings:h}"
python3 - "$settings" "$repo" "$large_repo" "$huge_repo" <<'PY'
import json, pathlib, sys
settings, small, large, huge = sys.argv[1:]
projects = [{"rootPath": path, "name": name, "isDemo": False, "environment": {}}
            for path, name in [(small, "perf"), (large, "perf-large"), (huge, "perf-huge")]]
pathlib.Path(settings).write_text(json.dumps({"version": 1, "selectedProjectPath": small, "projects": projects}))
PY

# A freshly signed binary is slow only on its first launch. Warm it and the saved reader once, outside the samples.
print "预热一次（不计入测量）"
if ! timeout 180 "$binary" --workspace-file "$settings" --perf-log "$work/warmup.tsv" --perf-run >/dev/null 2>&1; then
  print "预热运行异常退出" >&2
  exit 1
fi

# Check after building so the wait describes the machine that will actually run the measurements.
cpu_count="$(sysctl -n hw.ncpu)"
read_load() { load_average="$(sysctl -n vm.loadavg | awk '{print $2}')"; }
read_load
load_warning=""
waited_seconds=0
while [[ -n "$budget" ]] && (( load_average > cpu_count && waited_seconds < 600 )); do
  print "测量前机器负载 $load_average（核数 $cpu_count），等待 30 秒（已等待 $waited_seconds 秒）" >&2
  sleep 30
  waited_seconds=$((waited_seconds + 30))
  read_load
done
if (( load_average > cpu_count )); then
  load_warning="⚠ 测量时机器负载 $load_average（核数 $cpu_count），数字仅供参考"
  [[ -n "$budget" ]] || print "$load_warning"
else
  print "测量前机器负载 $load_average（核数 $cpu_count）"
fi

for run in $(seq 1 "$runs"); do
  log="$work/run-$run.tsv"
  timeout 180 "$binary" --workspace-file "$settings" --perf-log "$log" --perf-run >/dev/null 2>&1 || print "第 $run 次运行异常退出" >&2
  print "第 $run 次：$(wc -l < "$log" | tr -d ' ') 条记录"
done

python3 - "$work" "$runs" "$budget" "$load_warning" <<'PY'
import sys, statistics, collections, pathlib
work, runs, budget, load_warning = pathlib.Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
launch, switch = collections.defaultdict(list), collections.defaultdict(list)
for run in range(1, runs + 1):
    for line in (work / f"run-{run}.tsv").read_text().splitlines():
        name, ms, detail = (line.split("\t") + [""])[:3]
        if name == "error": print(f"第 {run} 次出错：{detail}"); continue
        key = name if not name.startswith(("switch.", "reader.")) else f"{name} {detail.split(' ')[0] if name == 'switch.reader' else ''}".strip()
        (launch if name.startswith("launch.") else switch)[key].append(float(ms))
def row(name, values):
    values = sorted(values)
    p90 = values[min(len(values) - 1, int(len(values) * 0.9))]
    print(f"{name:34} 中位 {statistics.median(values):8.1f} ms   P90 {p90:8.1f} ms   最大 {values[-1]:8.1f} ms   n={len(values)}")
print("\n启动（从进程启动算起）")
for name, values in sorted(launch.items(), key=lambda item: statistics.median(item[1])): row(name, values)
print("\n切换（从操作开始算起）")
for name, values in sorted(switch.items()): row(name, values)
print(f"\n原始数据：{work}")
if budget:
    medians = {k: statistics.median(v) for k, v in {**launch, **switch}.items()}
    over = []
    print("\n性能门槛")
    if load_warning: print(load_warning)
    for line in pathlib.Path(budget).read_text().splitlines():
        if not line.strip() or line.startswith("#"): continue
        name, limit = line.rsplit("\t", 1); limit = float(limit)
        if name not in medians: over.append(name); print(f"  ✗ {name}: 没有测到"); continue
        ok = medians[name] <= limit
        if not ok: over.append(name)
        print(f"  {'✓' if ok else '✗'} {name}: {medians[name]:.1f} ms（上限 {limit:.0f}）")
    large_stall, huge_stall = (medians.get(f"switch.{size}Project.stall") for size in ("large", "huge"))
    if large_stall is None or huge_stall is None:
        over.append("switch.hugeProject.stall")
        print("  ✗ switch.hugeProject.stall: 没有测到两项主线程间隔，无法检查相对上限")
    else:
        limit = large_stall * 1.5 + 30
        ok = huge_stall <= limit
        if not ok: over.append("switch.hugeProject.stall")
        print(f"  {'✓' if ok else '✗'} switch.hugeProject.stall: {huge_stall:.1f} ms（switch.largeProject.stall {large_stall:.1f} ms × 1.5 + 30 ms，上限 {limit:.1f} ms）")
    if over: sys.exit(1)
PY
