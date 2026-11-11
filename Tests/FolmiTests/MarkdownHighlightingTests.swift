import XCTest
import AppKit
@testable import Folmi

final class MarkdownHighlightingTests: XCTestCase {
    func testMarkdownFilesUseTheMarkdownScanner() {
        for path in ["README.md", "notes.MARKDOWN", "a.mdown", "b.mkd"] { XCTAssertEqual(SyntaxLanguage(path: path), .markdown, path) }
        XCTAssertEqual(SyntaxLanguage.markdown.title, "Markdown")
    }

    func testHeadingsListsQuotesAndTasks() throws {
        let text = "# 标题 `code` #\n#hashtag\n- [x] 完成\n12. 第二项\n> 引用 **重点**\n---\n"
        let result = try tokens(text)
        XCTAssertEqual(result[.heading], ["标题 `code`"])
        XCTAssertEqual(result[.code], ["code"])
        XCTAssertEqual(result[.listMarker], ["-", "[x]", "12."])
        XCTAssertEqual(result[.strong], ["重点"])
        XCTAssertEqual(result[.markup], ["# ", "`", "`", " #", ">", "**", "**", "---"])
    }

    func testEmphasisNestsAndSkipsWordUnderscoresAndArithmetic() throws {
        let text = "**粗 [链接](https://a.b) 体** and *斜* ~~删~~ ***都***\nsnake_case_name, 2 * 3 * 4, `*不是*`\n"
        let result = try tokens(text)
        XCTAssertEqual(result[.strong], ["粗 [链接](https://a.b) 体", "都"])
        XCTAssertEqual(result[.emphasis], ["斜", "都"])
        XCTAssertEqual(result[.strikethrough], ["删"])
        XCTAssertEqual(result[.link], ["https://a.b"])
        XCTAssertEqual(result[.code], ["*不是*"])
    }

    func testLinksImagesWikiLinksAutolinksAndDefinitions() throws {
        let text = "![图](assets/a.png \"标题\") [[笔记]] <https://x.y> 见 https://example.com/a。\n[ref]: https://r.s\n<!-- 注释 -->\n"
        let result = try tokens(text)
        XCTAssertEqual(result[.link], ["assets/a.png", "笔记", "https://x.y", "https://example.com/a", "https://r.s"])
        XCTAssertEqual(result[.string], ["\"标题\""])
        XCTAssertEqual(result[.comment], ["<!-- 注释 -->"])
    }

    func testFencedCodeIsColoredInItsLanguageAndHidesMarkdown() throws {
        let text = "```swift\nlet x = \"# not heading\"\n```\n**after**\n"
        let result = try tokens(text)
        XCTAssertEqual(result[.keyword], ["let"])
        XCTAssertEqual(result[.string], ["\"# not heading\""])
        XCTAssertNil(result[.heading])
        XCTAssertEqual(result[.markup], ["```swift", "```", "**", "**"])
        XCTAssertEqual(result[.strong], ["after"])
    }

    func testUnclosedFenceFrontMatterTablesAndMath() throws {
        let text = "---\ntitle: 文档\n---\n| a | `b|c` |\n|---|:-:|\n公式 $x^2$ 和 $5 与 $10\n```py\nreturn 1"
        let result = try tokens(text)
        XCTAssertEqual(result[.variable], ["title"])
        XCTAssertEqual(result[.code], ["b|c", "x^2"])
        XCTAssertEqual(result[.keyword], ["return"])
        XCTAssertEqual(result[.markup], ["---", "---", "|", "|", "`", "`", "|", "|---|:-:|", "$", "$", "```py"])
    }

    func testCRLFLinesLimitsAndCancellation() throws {
        let text = "# A\r\n- b\r\n"
        let result = try tokens(text)
        XCTAssertEqual(result[.heading], ["A"])
        XCTAssertEqual(result[.listMarker], ["-"])
        let many = String(repeating: "**a** `b` [c](d)\n", count: 200)
        let limited = try XCTUnwrap(SyntaxTokenizer.tokenize(many, language: .markdown, maximumTokens: 30))
        XCTAssertTrue(limited.isLimited)
        XCTAssertLessThanOrEqual(limited.tokens.count, 30)
        XCTAssertNil(SyntaxTokenizer.tokenize(many, language: .markdown, isCancelled: { true }))
    }

    func testTokensAreSortedInsideTheTextAndContainersComeFirst() throws {
        let text = "# **粗** 👩🏽‍💻 `c`\n> - [ ] *a* [b](c)\n"
        let result = try XCTUnwrap(SyntaxTokenizer.tokenize(text, language: .markdown))
        var previous = (location: 0, length: Int.max)
        for token in result.tokens {
            XCTAssertGreaterThan(token.range.length, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), text.utf16.count)
            XCTAssertTrue(token.range.location > previous.location ||
                          (token.range.location == previous.location && token.range.length <= previous.length))
            previous = (token.range.location, token.range.length)
        }
    }

    @MainActor
    func testApplierMakesHeadingsAndStrongBoldWithoutTouchingTheText() throws {
        let editor = NSTextView()
        editor.string = "# 标题\n**粗** *斜* ~~删~~"
        let presentation = EditorPresentation()
        SyntaxHighlightApplier.apply(try XCTUnwrap(SyntaxTokenizer.tokenize(editor.string, language: .markdown)),
                                     to: editor, presentation: presentation)
        let storage = try XCTUnwrap(editor.textStorage)
        func font(at location: Int) -> NSFont? { storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont }
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(font(at: 2))).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(font(at: 7))).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: try XCTUnwrap(font(at: 11))).contains(.boldFontMask))
        XCTAssertNotNil(storage.attribute(.obliqueness, at: 12, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.strikethroughStyle, at: 17, effectiveRange: nil))
        XCTAssertEqual(editor.string, "# 标题\n**粗** *斜* ~~删~~")
        // A second pass with no tokens clears every Markdown attribute.
        SyntaxHighlightApplier.apply(SyntaxHighlightResult(tokens: [], scannedUTF16Count: 0, isLimited: false), to: editor, presentation: presentation)
        XCTAssertNil(storage.attribute(.obliqueness, at: 12, effectiveRange: nil))
        XCTAssertFalse(NSFontManager.shared.traits(of: try XCTUnwrap(font(at: 2))).contains(.boldFontMask))
    }

    func testReaderLeavesMarkdownFencesUncolored() {
        XCTAssertEqual(MarkdownCodeHighlight.html("# **a**", language: "md"), "# **a**")
    }

    private func tokens(_ text: String) throws -> [SyntaxTokenKind: [String]] {
        let result = try XCTUnwrap(SyntaxTokenizer.tokenize(text, language: .markdown))
        var out: [SyntaxTokenKind: [String]] = [:]
        for token in result.tokens { out[token.kind, default: []].append((text as NSString).substring(with: token.range)) }
        return out
    }
}
