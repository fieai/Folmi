#!/bin/zsh
# One command for a release: check, test, bump (VERSION, CHANGELOG, website 更新记录, commit, tag), build and sign
# the DMG and publish it with the website (deploy.sh), push, then the GitHub Release with the DMG attached.
set -euo pipefail
app_root="${0:A:h:h}"
cd "$app_root"

usage() {
  cat <<'HELP'
用法：./scripts/ship.sh <minor|patch|major|X.Y.Z> [选项]
      ./scripts/ship.sh --from <步骤>          从失败的那一步接着做（版本已经 bump 过）

一条命令发版：
  1 check    在 main 上、工作区干净、不落后 origin、工具齐全
  2 test     scripts/test.sh 全部测试
  3 bump     VERSION 加一，CHANGELOG「未发布」改成这一版，刷新官网更新记录，提交并打 tag
  4 deploy   deploy.sh：打包签名 DMG、上传、发布官网
  5 push     推送 main 和 tag
  6 release  GitHub Release（预发布），附 DMG 和 SHA256

选项：
  --skip-tests   跳过第 2 步
  --from <步骤>  从 deploy / push / release 接着做，用 VERSION 里现在的版本
  --dry-run      只显示每一步，不改任何东西
发版前先在 CHANGELOG.md 的「## 未发布」里写好这一版改了什么（python3 scripts/bump.py draft 可以起草稿）。
HELP
}
fail() { print -u2 -- "错误：$*"; exit 1; }
step() { print -- "\n▸ $*"; }
# A failed check stops a real release; a dry run notes it and goes on, to show the rest.
must() { if (( dry_run )); then print -- "注意：$*（预演照常继续）"; else fail "$*"; fi }

how="" from="" skip_tests=0 dry_run=0
while (( $# )); do
  case "$1" in
    --skip-tests) skip_tests=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --from) (( $# >= 2 )) || fail '--from 缺少步骤'; from="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    -*) fail "未知参数：$1" ;;
    *) [[ -z "$how" ]] || fail '只能指定一个版本'; how="$1"; shift ;;
  esac
done
steps=(check test bump deploy push release)
if [[ -n "$from" ]]; then
  [[ -z "$how" ]] || fail '--from 用 VERSION 里现在的版本，不要再写版本'
  (( ${steps[(Ie)$from]} )) || fail "没有这一步：$from（可选 ${(j:、:)steps}）"
  (( ${steps[(Ie)$from]} >= 4 )) || fail '--from 只能是 deploy、push 或 release；更早的步骤直接重新运行整条命令'
else
  [[ -n "$how" ]] || { usage; exit 1; }
fi
start=${steps[(Ie)${from:-check}]}
runs() { (( ${steps[(Ie)$1]} >= start )); }

for tool in git gh python3; do command -v "$tool" >/dev/null || fail "缺少工具：$tool"; done
[[ -x scripts/deploy.sh ]] || fail '缺少 scripts/deploy.sh（发布脚本不在仓库里，只在发版的机器上）'

if runs check; then
  step '检查'
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || must '要在 main 上发版'
  [[ -z "$(git status --porcelain)" ]] || must '工作区有未提交的改动'
  git fetch --quiet origin main
  (( $(git rev-list --count HEAD..origin/main) == 0 )) || must 'origin/main 有本地没有的提交，先拉取'
  gh auth status >/dev/null 2>&1 || must 'gh 没有登录：gh auth login'
  python3 scripts/site-changelog.py --check >/dev/null || must '官网的更新记录和 CHANGELOG 不一致'
  python3 scripts/bump.py "$how" --dry-run
fi
if runs test && (( ! skip_tests )); then
  step '测试'
  if (( dry_run )); then print -- 'scripts/test.sh'; else ./scripts/test.sh > "${TMPDIR:-/tmp}/folmi-ship-test.log" 2>&1 || {
    grep -E '\.swift:[0-9]+: error:' "${TMPDIR:-/tmp}/folmi-ship-test.log" | head -20; fail "测试没通过（完整输出：${TMPDIR:-/tmp}/folmi-ship-test.log）"; }; print -- '全部通过'; fi
fi
if runs bump; then
  step '版本和 CHANGELOG'
  if (( dry_run )); then print -- "python3 scripts/bump.py $how"; else python3 scripts/bump.py "$how"; fi
fi

version="$(<VERSION)"
(( dry_run )) && [[ -n "$how" ]] && version="$(python3 scripts/bump.py "$how" --dry-run | sed -nE 's/^版本：.* → ([0-9.]+).*/\1/p')"
tag="v$version"
name="Folmi-v${version}-macOS-arm64-SIGNED-NOT-NOTARIZED-BETA"
if (( ! dry_run )) && (( start >= 4 )); then
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "没有 tag $tag：版本还没 bump，重新运行整条命令"
fi

if runs deploy; then
  step "打包并发布 $tag（DMG 和官网）"
  if (( dry_run )); then print -- 'scripts/deploy.sh'; else ./scripts/deploy.sh; fi
fi
if runs push; then
  step '推送'
  if (( dry_run )); then print -- "git push origin main $tag"; else git push origin main "$tag"; fi
fi
if runs release; then
  step 'GitHub Release'
  if (( dry_run )); then print -- "gh release create $tag --prerelease（附 dist/$name.dmg 和 .sha256）"; exit 0; fi
  [[ -s "dist/$name.dmg" && -s "dist/$name.dmg.sha256" ]] || fail "dist 里没有 $name.dmg，先完成 deploy"
  sha="$(awk '{ print $1 }' "dist/$name.dmg.sha256")"
  notes="${TMPDIR:-/tmp}/folmi-release-$version.md"
  {
    print -- '## 下载\n'
    print -- '| 文件 | 说明 |\n| --- | --- |'
    print -- "| \`$name.dmg\` | macOS 14+，Apple Silicon |\n| \`….dmg.sha256\` | SHA256 校验文件 |\n"
    print -- "SHA256：\`$sha\`\n"
    print -- "\`\`\`sh\nshasum -a 256 $name.dmg\n\`\`\`\n"
    print -- '## 安装\n'
    print -- '1. 打开 DMG，把 Folmi 拖进「应用程序」。'
    print -- '2. 这个版本已用 Developer ID 签名，但还没有完成 Apple 公证。第一次打开如果被系统阻止，请到「系统设置 → 隐私与安全性」点「仍要打开」。\n'
    print -- '## 这一版有什么\n'
    python3 scripts/bump.py notes "$version"
  } > "$notes"
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "dist/$name.dmg" "dist/$name.dmg.sha256" --clobber
    gh release edit "$tag" --notes-file "$notes"
  else
    gh release create "$tag" "dist/$name.dmg" "dist/$name.dmg.sha256" --prerelease \
      --title "Folmi $version 内测版" --notes-file "$notes" --verify-tag
  fi
  print -- "\n已发布 Folmi $version：$(gh release view "$tag" --json url --jq .url)"
fi
