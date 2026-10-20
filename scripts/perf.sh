#!/bin/zsh
# Measures launch and switching in the release app against a throwaway repository, then prints a summary.
#   scripts/perf.sh [--budget] [runs] [source-repo]
# With --budget, medians are checked against scripts/perf-budget.tsv and the script exits 1 when one is over.
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

git clone --quiet --local --no-hardlinks "$source_repo" "$repo"
# A review-sized change set: edits in a few Markdown files, one large document added, one file deleted.
i=0
markdown=("${(@f)$(cd "$repo" && git -c core.quotePath=false ls-files 'docs/*.md' 'skills/*.md' | head -6)}")
for f in "${markdown[@]}"; do
  print "\n## 测量用改动 $i\n\n这一段是 perf.sh 加的。" >> "$repo/$f"; i=$((i + 1))
done
[[ -f docs/progress-v0.5.md ]] && cp docs/progress-v0.5.md "$repo/docs-progress-large.md"
(cd "$repo" && git rm --quiet "$(git -c core.quotePath=false ls-files 'scripts/*' | head -1)")

swift build -c release --product Folmi >/dev/null
binary="$(swift build -c release --show-bin-path)/Folmi"

# One settings folder for all runs, like daily use: the first run opens the project fresh, later runs restore it
# (saved status, open tabs, reader position) the way a normal launch does.
settings="$work/settings/workspace.json"; mkdir -m 700 -p "${settings:h}"
print -r -- "{\"version\":1,\"selectedProjectPath\":\"$repo\",\"projects\":[{\"rootPath\":\"$repo\",\"name\":\"perf\",\"isDemo\":false,\"environment\":{}}]}" > "$settings"
for run in $(seq 1 "$runs"); do
  log="$work/run-$run.tsv"
  timeout 90 "$binary" --workspace-file "$settings" --perf-log "$log" --perf-run >/dev/null 2>&1 || print "第 $run 次运行异常退出" >&2
  print "第 $run 次：$(wc -l < "$log" | tr -d ' ') 条记录"
done

python3 - "$work" "$runs" "$budget" <<'PY'
import sys, statistics, collections, pathlib
work, runs, budget = pathlib.Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
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
    for line in pathlib.Path(budget).read_text().splitlines():
        if not line.strip() or line.startswith("#"): continue
        name, limit = line.rsplit("\t", 1); limit = float(limit)
        if name not in medians: over.append(name); print(f"  ✗ {name}: 没有测到"); continue
        ok = medians[name] <= limit
        if not ok: over.append(name)
        print(f"  {'✓' if ok else '✗'} {name}: {medians[name]:.1f} ms（上限 {limit:.0f}）")
    if over: sys.exit(1)
PY
