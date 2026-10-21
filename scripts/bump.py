#!/usr/bin/env python3
"""Version and CHANGELOG for a release.

  python3 scripts/bump.py minor|patch|major|X.Y.Z [--dry-run]
      VERSION goes up, CHANGELOG's 「## 未发布」 becomes 「## X.Y.Z — today」, the website's 更新记录 is refreshed,
      then one commit 「Folmi X.Y.Z」 and an annotated tag vX.Y.Z carrying that version's notes.
  python3 scripts/bump.py draft
      Writes a 「## 未发布」 draft from the commit subjects since the last tag, to be reworded before releasing.
  python3 scripts/bump.py notes X.Y.Z
      Prints that version's CHANGELOG section (the GitHub Release text).

A release needs a clean work tree on main and a 「## 未发布」 with at least one item: the notes are written by a
person, not made up from commit messages.
"""
import datetime
import importlib.util
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
VERSION = ROOT / "VERSION"
UNRELEASED = "## 未发布"
PLACEHOLDER = "下一个版本会带上这些，还没有安装包。"


def fail(message):
    sys.exit("错误：" + message)


def git(*args, check=True):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        fail("git " + " ".join(args) + "：" + (result.stderr.strip() or result.stdout.strip()))
    return result.stdout.strip()


def next_version(current, how):
    if re.fullmatch(r"\d+\.\d+\.\d+", how):
        if tuple(map(int, how.split("."))) <= tuple(map(int, current.split("."))):
            fail("新版本 %s 必须大于当前的 %s" % (how, current))
        return how
    major, minor, patch = map(int, current.split("."))
    if how == "major":
        return "%d.0.0" % (major + 1)
    if how == "minor":
        return "%d.%d.0" % (major, minor + 1)
    if how == "patch":
        return "%d.%d.%d" % (major, minor, patch + 1)
    fail("版本要写 major、minor、patch 或 X.Y.Z")


def sections(text):
    """[(heading line, start, end)] of every `## ` section, end exclusive."""
    starts = [m.start() for m in re.finditer(r"^## ", text, re.M)]
    return [(text[s:text.index("\n", s)], s, (starts[i + 1] if i + 1 < len(starts) else len(text))) for i, s in enumerate(starts)]


def unreleased(text):
    """(start, end, body) of the 未发布 section, or None."""
    for heading, start, end in sections(text):
        if heading.strip() == UNRELEASED:
            body = text[text.index("\n", start) + 1:end]
            return start, end, body
    return None


def notes(text, version):
    for heading, start, end in sections(text):
        if re.match(r"^## %s\b" % re.escape(version), heading):
            body = text[text.index("\n", start) + 1:end].strip()
            return body
    fail("CHANGELOG 里没有 %s 这一节" % version)


def release(how, dry_run):
    current = VERSION.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", current):
        fail("VERSION 必须是三段数字：" + current)
    version = next_version(current, how)
    text = CHANGELOG.read_text(encoding="utf-8")
    found = unreleased(text)
    if not found:
        fail("CHANGELOG 里没有「%s」。先写下这一版改了什么（python3 scripts/bump.py draft 可以按提交起个草稿）" % UNRELEASED)
    start, end, body = found
    body = "\n".join(line for line in body.splitlines() if line.strip() != PLACEHOLDER).strip("\n")
    if not re.search(r"^- \S", body, re.M):
        fail("「%s」里还没有任何条目" % UNRELEASED)
    if "（草稿" in body:
        fail("「%s」还是按提交生成的草稿：改成给用户看的话、删掉「（草稿…）」标题后再发版" % UNRELEASED)
    if git("tag", "--list", "v" + version):
        fail("tag v%s 已经存在" % version)
    problems = []
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if branch != "main":
        problems.append("要在 main 上发版，现在在 " + branch)
    if git("status", "--porcelain"):
        problems.append("工作区有未提交的改动，先提交或暂放")
    if problems and not dry_run:
        fail("；".join(problems))
    for problem in problems:
        print("注意：" + problem + "（预演照常继续）")

    today = datetime.date.today().isoformat()
    updated = text[:start] + "## %s — %s\n\n%s\n\n" % (version, today, body) + text[end:].lstrip("\n")
    print("版本：%s → %s（%s）" % (current, version, today))
    if dry_run:
        print("（预演，不改文件）\n\n这一版的说明：\n" + body)
        return
    VERSION.write_text(version + "\n", encoding="utf-8")
    CHANGELOG.write_text(updated, encoding="utf-8")
    spec = importlib.util.spec_from_file_location("site_changelog", ROOT / "scripts" / "site-changelog.py")
    site = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(site)
    site.update(ROOT / "site")
    git("add", "VERSION", "CHANGELOG.md", "site/index.html")
    git("commit", "-q", "-m", "Folmi " + version)
    git("tag", "-a", "--cleanup=verbatim", "v" + version, "-m", "Folmi %s\n\n%s" % (version, body))
    print("已提交「Folmi %s」并打上 tag v%s（还没推送）" % (version, version))


def draft():
    text = CHANGELOG.read_text(encoding="utf-8")
    found = unreleased(text)
    if found and re.search(r"^- \S", found[2], re.M):
        fail("「%s」已经有内容了，直接改它就行" % UNRELEASED)
    last = git("describe", "--tags", "--abbrev=0", "--match", "v*", check=False)
    subjects = git("log", "--no-merges", "--format=%s", (last + "..HEAD") if last else "HEAD").splitlines()
    subjects = [s for s in subjects if s and not re.fullmatch(r"Folmi \d+\.\d+\.\d+", s)]
    if not subjects:
        fail("自 %s 以来没有新提交" % (last or "开始"))
    items = "\n".join("- " + s for s in reversed(subjects))
    block = "%s\n\n%s\n\n### 改动（草稿，按提交整理，发版前改成给用户看的话）\n\n%s\n\n" % (UNRELEASED, PLACEHOLDER, items)
    if found:
        text = text[:found[0]] + block + text[found[1]:].lstrip("\n")
    else:
        first = sections(text)
        at = first[0][1] if first else len(text)
        text = text[:at] + block + text[at:]
    CHANGELOG.write_text(text, encoding="utf-8")
    print("已按 %d 个提交写好「%s」草稿：CHANGELOG.md" % (len(subjects), UNRELEASED))


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__.strip()); sys.exit(0)
    if args[0] == "draft":
        draft()
    elif args[0] == "notes":
        if len(args) != 2:
            fail("用法：bump.py notes X.Y.Z")
        print(notes(CHANGELOG.read_text(encoding="utf-8"), args[1]))
    else:
        release(args[0], dry_run="--dry-run" in args[1:])
