#!/usr/bin/env python3
"""Fills the website from CHANGELOG.md: the 更新记录 section and the version over the download button.

  python3 scripts/site-changelog.py [--site site] [--check]

Each `## <version> — <date>` becomes one entry (the newest released one open and marked 最新), `## 未发布` one
marked 开发中. The download area shows the newest released version, so it matches the package the deploy links to.
Only the text between the <!-- changelog:start/end --> and <!-- version:start/end --> markers is replaced.
--check fails when the page is out of date instead of writing it (deploy-site.py writes it before publishing).
"""
import argparse
from html import escape
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent


def inline(text):
    """`code`, **bold** and [links](url) in otherwise escaped text."""
    out, last = [], 0
    for match in re.finditer(r"`([^`]+)`|\*\*([^*]+)\*\*|\[([^\]]+)\]\(([^)\s]+)\)", text):
        out.append(escape(text[last:match.start()], quote=False))
        code, bold, label, url = match.groups()
        if code is not None:
            out.append("<code>" + escape(code, quote=False) + "</code>")
        elif bold is not None:
            out.append("<b>" + escape(bold, quote=False) + "</b>")
        elif re.match(r"https?://", url):
            out.append('<a href="%s" target="_blank" rel="noopener">%s</a>' % (escape(url), escape(label, quote=False)))
        else:
            # A path in the repository (VERSION, LICENSE…): link it on GitHub.
            out.append('<a href="https://github.com/fieai/Folmi/blob/main/%s" target="_blank" rel="noopener">%s</a>'
                       % (escape(url), escape(label, quote=False)))
        last = match.end()
    out.append(escape(text[last:], quote=False))
    return "".join(out)


def parse(markdown):
    """[(title, date or None, unreleased, [lines])] for every `## ` section, in file order."""
    entries = []
    for line in markdown.splitlines():
        heading = re.match(r"^## (.+?)\s*$", line)
        if heading:
            title = heading[1]
            dated = re.match(r"^(\d+\.\d+\.\d+)\s*[—-]+\s*(\d{4}-\d{2}-\d{2})$", title)
            entries.append({"version": dated[1] if dated else None, "date": dated[2] if dated else None,
                            "unreleased": title.strip() == "未发布", "title": title, "lines": []})
        elif entries:
            entries[-1]["lines"].append(line)
    return entries


def body(lines):
    html, items, paragraph = [], [], []

    def flush():
        if items:
            html.append("<ul>" + "".join("<li>" + inline(item) + "</li>" for item in items) + "</ul>")
            items.clear()
        if paragraph:
            html.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    for line in lines:
        if line.startswith("### "):
            flush(); html.append("<h4>" + inline(line[4:].strip()) + "</h4>")
        elif line.startswith("- "):
            if paragraph: flush()
            items.append(line[2:].strip())
        elif line.strip():
            if items: flush()
            paragraph.append(line.strip())
        else:
            flush()
    flush()
    return "".join(html)


def render(entries):
    latest = next((e for e in entries if e["version"]), None)
    parts = []
    for entry in entries:
        if entry["unreleased"]:
            title = '<span>下一个版本<span class="tag">开发中</span></span>'
            opened = False
        elif entry["version"]:
            tag = '<span class="tag">最新</span>' if entry is latest else ""
            title = '<span>v%s<span class="when">%s</span>%s</span>' % (escape(entry["version"]), escape(entry["date"]), tag)
            opened = entry is latest
        else:
            title = "<span>" + inline(entry["title"]) + "</span>"
            opened = False
        parts.append("      <details%s><summary>%s</summary>%s</details>" % (" open" if opened else "", title, body(entry["lines"])))
    version = "v%s · 内测中 · %s 发布" % (latest["version"], latest["date"]) if latest else "内测中"
    return "\n".join(parts), version


def fill(page, changelog, version):
    page, found = re.subn(r"(<!-- changelog:start -->)(.*?)(<!-- changelog:end -->)",
                          lambda m: m[1] + "\n" + changelog + "\n" + m[3], page, flags=re.S)
    if found != 1:
        raise ValueError("site/index.html 里要有一对 <!-- changelog:start --> / <!-- changelog:end -->")
    page, found = re.subn(r"(<!-- version:start -->)(.*?)(<!-- version:end -->)", lambda m: m[1] + version + m[3], page, flags=re.S)
    if found != 1:
        raise ValueError("site/index.html 里要有一对 <!-- version:start --> / <!-- version:end -->")
    return page


def update(site, check=False):
    """Writes the page from CHANGELOG.md; returns whether it changed. With check, raises instead of writing."""
    entries = parse((ROOT / "CHANGELOG.md").read_text(encoding="utf-8"))
    latest = next((e for e in entries if e["version"]), None)
    version_file = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if latest and latest["version"] != version_file:
        raise ValueError("CHANGELOG 最新的已发布版本是 %s，VERSION 是 %s：发布新版时两处要一起改" % (latest["version"], version_file))
    index = Path(site) / "index.html"
    page = index.read_text(encoding="utf-8")
    updated = fill(page, *render(entries))
    if updated == page:
        return False
    if check:
        raise ValueError("官网的更新记录和 CHANGELOG.md 不一致：运行 python3 scripts/site-changelog.py")
    index.write_text(updated, encoding="utf-8")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--site", type=Path, default=ROOT / "site")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        print("已更新官网的更新记录" if update(args.site, args.check) else "官网的更新记录已是最新")
    except ValueError as error:
        sys.exit("错误：" + str(error))
