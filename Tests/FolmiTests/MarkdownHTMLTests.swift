import XCTest
@testable import Folmi

final class MarkdownHTMLTests: XCTestCase {
    private func html(_ text: String) -> String { MarkdownHTML.render(text) }

    func testHeadingsCarryIDsAndSourceLines() {
        let out = html("# 导出为 PDF\n\n## 验收标准\n\n## 验收标准\n")
        XCTAssertTrue(out.contains(#"<h1 id="导出为-pdf" data-line="0" data-end="0">导出为 PDF</h1>"#), out)
        XCTAssertTrue(out.contains(#"<h2 id="验收标准" data-line="2""#), out)
        XCTAssertTrue(out.contains(#"<h2 id="验收标准-1" data-line="4""#), out)
        XCTAssertTrue(html("# C#\n").contains(">C#</h1>"))
        XCTAssertTrue(html("Title\n===\n").contains(#"<h1 id="title" data-line="0" data-end="1">Title</h1>"#))
    }

    func testParagraphJoinsCJKLinesWithoutSpaceAndKeepsHardBreaks() {
        XCTAssertTrue(html("第一行\n第二行").contains(">第一行第二行</p>"))
        XCTAssertTrue(html("one\ntwo").contains(">one\ntwo</p>"))
        XCTAssertTrue(html("one  \ntwo").contains(">one<br>\ntwo</p>"))
    }

    func testInlineFormatting() {
        let out = html("**粗** *斜* ~~删~~ `a<b` [链接](docs/a.md \"t\") snake_case_name ==亮==")
        XCTAssertTrue(out.contains("<strong>粗</strong>"), out)
        XCTAssertTrue(out.contains("<em>斜</em>"), out)
        XCTAssertTrue(out.contains("<del>删</del>"), out)
        XCTAssertTrue(out.contains("<code>a&lt;b</code>"), out)
        XCTAssertTrue(out.contains(#"<a href="docs/a.md" data-href="docs/a.md" title="t">链接</a>"#), out)
        XCTAssertTrue(out.contains("snake_case_name"), out)
        XCTAssertTrue(out.contains("<mark>亮</mark>"), out)
    }

    func testRawHTMLKeepsOnlyHarmlessTags() {
        let out = html("<script>alert(1)</script> a<br>b <kbd>⌘</kbd> <img src=x onerror=alert(1)> <foo>")
        XCTAssertFalse(out.contains("<script"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertFalse(out.contains("<img"))
        XCTAssertTrue(out.contains("&lt;foo&gt;"))
        XCTAssertTrue(html("段 <script>x</script>").contains("&lt;script&gt;"))
        XCTAssertTrue(out.contains("a<br>b"))
        XCTAssertTrue(out.contains("<kbd>⌘</kbd>"))
    }

    func testHTMLBlocksPassTheAllowList() {
        var options = MarkdownHTML.Options()
        options.imageSource = { $0.hasPrefix("docs/") ? "folmi-file://local/" + $0 : nil }
        let text = """
        <table>
          <tr>
            <td align="center"><img src="docs/screenshots/ios/home.jpg" width="180" onerror="alert(1)" /><br>首页</td>
            <td><img src="nope.jpg" alt="缺"></td>
          </tr>
        </table>

        段落 <img src="docs/a.png" width="20"> 和 <a href="javascript:alert(1)">坏</a> <a href="docs/b.md">好</a>

        <script>alert(1)</script>
        <div style="position:fixed" onclick="x()">块</div>
        """
        let out = MarkdownHTML.render(text, options: options)
        XCTAssertTrue(out.contains(#"<div class="html" data-line="0" data-end="5"><table>"#), out)
        XCTAssertTrue(out.contains(#"<td align="center"><img src="folmi-file://local/docs/screenshots/ios/home.jpg" width="180" loading="lazy"><br>首页</td>"#), out)
        XCTAssertTrue(out.contains(#"<span class="missing-image" title="nope.jpg">缺</span>"#), out)
        XCTAssertTrue(out.contains(#"<img src="folmi-file://local/docs/a.png" width="20" loading="lazy">"#), out)
        XCTAssertTrue(out.contains(#"<a>坏</a>"#), out)
        XCTAssertTrue(out.contains(#"<a href="docs/b.md" data-href="docs/b.md">好</a>"#), out)
        XCTAssertTrue(out.contains("<div>块</div>"), out)
        XCTAssertFalse(out.contains("alert"), out)
        XCTAssertFalse(out.contains("onerror"), out)
        XCTAssertFalse(out.contains("style="), out)
    }

    func testHTMLContainerWrapsMarkdownAcrossBlankLines() {
        let out = html("<div align=\"center\">\n\n# 标题\n\n**粗**\n\n</div>\n\n后文\n\n<!-- 注释\n\n还在注释 -->\n<picture>\n  <source media=\"(prefers-color-scheme: dark)\" srcset=\"https://x.y/d.png\">\n  <img src=\"https://x.y/l.png\"\n       alt=\"图\">\n</picture>")
        XCTAssertTrue(out.hasPrefix(#"<div class="html" data-line="0" data-end="6"><div align="center">"#), out)
        XCTAssertTrue(out.contains(#"<h1 id="标题" data-line="2""#), out)
        XCTAssertTrue(out.contains("<strong>粗</strong>"), out)
        XCTAssertTrue(out.contains(#"<p data-line="8" data-end="8">后文</p>"#), out)
        XCTAssertFalse(out.contains("注释"), out)
        XCTAssertTrue(out.contains(#"<source media="(prefers-color-scheme: dark)" srcset="https://x.y/d.png">"#), out)
        XCTAssertTrue(out.contains(#"<img src="https://x.y/l.png" alt="图" loading="lazy">"#), out)
    }

    func testLinksAndAutolinks() {
        let out = html("see https://example.com/a_(b). and <mailto:x@y.z> 和 [[决策记录|记录]]")
        XCTAssertTrue(out.contains(#"<a href="https://example.com/a_(b)" data-href="https://example.com/a_(b)">"#), out)
        XCTAssertTrue(out.contains(#"data-href="mailto:x@y.z""#), out)
        XCTAssertTrue(out.contains(##"<a class="wiki" href="#" data-href="[[决策记录]]">记录</a>"##), out)
        XCTAssertTrue(html("见http://a.com/x，好").contains(#"data-href="http://a.com/x""#))
    }

    func testTaskListOffsetsPointAtTheMark() {
        let text = "intro\n\n- [x] 完成\n- [ ] 待办\n  - [ ] 子项\n"
        let out = html(text)
        let source = text as NSString
        let offsets = out.components(separatedBy: "data-offset=\"").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        XCTAssertEqual(offsets.count, 3, out)
        XCTAssertEqual(offsets.map { source.substring(with: NSRange(location: $0, length: 1)) }, ["x", " ", " "])
        XCTAssertEqual(offsets.map { source.substring(with: NSRange(location: $0 - 1, length: 3)) }, ["[x]", "[ ]", "[ ]"])
        XCTAssertTrue(out.contains("checked"))
        XCTAssertTrue(out.contains(#"<ul class="tight tasks""#), out)
    }

    func testListsNestAndLoosen() {
        let out = html("1. one\n2. two\n   - inner\n\n3) other\n")
        XCTAssertTrue(out.contains("<ol class=\"tight\""), out)
        XCTAssertTrue(out.contains("<ul class=\"tight\""), out)
        XCTAssertTrue(out.contains("<ol start=\"3\""), out)
        XCTAssertFalse(html("- a\n\n- b\n").contains("tight"))
        XCTAssertTrue(html("2024. 年\n").contains("<p"), "a year followed by a dot is not a list")
    }

    func testFencedCodeIsHighlightedAndEscaped() {
        let out = html("```swift\nfunc a() -> Int { 1 < 2 }\n```\n")
        XCTAssertTrue(out.contains(#"data-lang="swift""#), out)
        XCTAssertTrue(out.contains(#"<span class="tok-keyword">func</span>"#), out)
        XCTAssertTrue(out.contains("1</span> &lt; <span"), out)
        XCTAssertTrue(out.contains(#"data-line="0" data-end="2""#), out)
        XCTAssertTrue(html("```\n# not a heading\n").contains("# not a heading"), "an unclosed fence runs to the end")
    }

    func testTablesWithAlignmentAndPipesInCode() {
        let out = html("| 元素 | 备注 |\n| :-- | --: |\n| `a|b` | x \\| y |\n| 只有一格 |\n")
        XCTAssertTrue(out.contains(#"<th style="text-align:left">元素</th>"#), out)
        XCTAssertTrue(out.contains(#"<td style="text-align:left"><code>a|b</code></td>"#), out)
        XCTAssertTrue(out.contains("x | y"), out)
        XCTAssertEqual(out.components(separatedBy: "<tr").count - 1, 3)
    }

    func testQuotesAlertsRulesAndFrontMatter() {
        XCTAssertTrue(html("> 引用\n> 第二行\n").contains("<blockquote"))
        let alert = html("> [!WARNING]\n> 小心\n")
        XCTAssertTrue(alert.contains(#"class="alert warning""#), alert)
        XCTAssertTrue(alert.contains("警告"), alert)
        XCTAssertTrue(html("a\n\n---\n").contains("<hr"))
        let front = html("---\ntitle: x\n---\n# H\n")
        XCTAssertTrue(front.contains(#"<pre class="frontmatter" data-line="0" data-end="2">title: x</pre>"#), front)
        XCTAssertTrue(front.contains(#"data-line="3""#), front)
    }

    func testImagesUseTheSourceResolver() {
        var options = MarkdownHTML.Options()
        options.imageSource = { $0 == "assets/a.png" ? "folmi-file://local/assets/a.png" : nil }
        let out = MarkdownHTML.render("![图 *一*](assets/a.png) ![缺](missing.png)", options: options)
        XCTAssertTrue(out.contains(#"<img src="folmi-file://local/assets/a.png" alt="图 一""#), out)
        XCTAssertTrue(out.contains(#"<span class="missing-image" title="missing.png">缺</span>"#), out)
    }

    func testLargeDocumentRendersQuickly() {
        let section = "## 标题\n\n段落 **粗体** 和 `代码` 以及 [链接](a.md)。\n\n- [ ] 任务\n- 项目\n\n```js\nconst a = 1\n```\n\n"
        let text = String(repeating: section, count: 2_000)
        measure { _ = MarkdownHTML.render(text) }
    }
}
