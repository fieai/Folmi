import XCTest
@testable import Folmi

/// Formulas ($…$, $$…$$, ```math) and Mermaid blocks in the reader's HTML, and the bundled files they load.
final class MarkdownMathTests: XCTestCase {
    func testInlineMathFollowsPandocDollarRules() {
        let html = MarkdownHTML.render("Euler: $e^{i\\pi}+1=0$, costs $5 and $10, a \\$ sign, and $$x_1*y_2$$ inline.")
        XCTAssertTrue(html.contains(#"<span class="math" data-tex="e^{i\pi}+1=0">"#), html)
        XCTAssertTrue(html.contains("costs $5 and $10"), "prices are not math")
        XCTAssertTrue(html.contains("a $ sign"))
        XCTAssertTrue(html.contains(#"<span class="math display" data-tex="x_1*y_2">"#), "emphasis markers inside math stay as they are")
        XCTAssertFalse(MarkdownHTML.render("$ not math $").contains("class=\"math"))
    }

    func testDisplayMathBlocksKeepSourceLines() {
        let html = MarkdownHTML.render("Intro\n\n$$\n\\int_0^1 x\\,dx = \\frac12\n$$\n\n```math\na^2+b^2=c^2\n```\n\n$$ E = mc^2 $$\n")
        XCTAssertTrue(html.contains(#"<div class="math display" data-line="2" data-end="4" data-tex="\int_0^1 x\,dx = \frac12">"#), html)
        XCTAssertTrue(html.contains(#"data-line="6" data-end="8" data-tex="a^2+b^2=c^2""#), html)
        XCTAssertTrue(html.contains(#"data-tex="E = mc^2""#), html)
        // Never closed: stays text.
        XCTAssertFalse(MarkdownHTML.render("$$\nnot closed\n\nnext").contains("class=\"math"))
    }

    func testMermaidBlockKeepsEscapedSource() {
        let html = MarkdownHTML.render("```mermaid\ngraph TD\n  A[开始] --> B{\"<b>x</b>\"}\n```\n")
        XCTAssertTrue(html.contains(#"<div class="mermaid" data-line="0" data-end="3"><pre class="src">graph TD"#), html)
        XCTAssertTrue(html.contains("&lt;b&gt;x&lt;/b&gt;"), "source is escaped, never markup")
    }

    func testBundledAssetsAreServedAndNothingElse() throws {
        let script = try XCTUnwrap(ReaderAssetSchemeHandler.data(for: URL(string: "folmi-asset://local/katex/katex.min.js")!))
        XCTAssertEqual(script.1, "text/javascript"); XCTAssertGreaterThan(script.0.count, 100_000)
        XCTAssertNotNil(ReaderAssetSchemeHandler.data(for: URL(string: "folmi-asset://local/mermaid/mermaid.min.js")!))
        XCTAssertEqual(ReaderAssetSchemeHandler.data(for: URL(string: "folmi-asset://local/katex/fonts/KaTeX_Main-Regular.woff2")!)?.1, "font/woff2")
        // Every font the stylesheet asks for first (woff2) is bundled.
        let css = String(decoding: try XCTUnwrap(ReaderAssetSchemeHandler.data(for: URL(string: "folmi-asset://local/katex/katex.min.css")!)).0, as: UTF8.self)
        let fonts = css.components(separatedBy: "url(fonts/").dropFirst().compactMap { $0.components(separatedBy: ")").first }.filter { $0.hasSuffix(".woff2") }
        XCTAssertFalse(fonts.isEmpty)
        for font in fonts { XCTAssertNotNil(ReaderAssetSchemeHandler.data(for: URL(string: "folmi-asset://local/katex/fonts/" + font)!), font) }
        XCTAssertNil(ReaderAssetSchemeHandler.data(for: URL(string: "folmi-asset://local/../../Package.swift")!))
        XCTAssertNil(ReaderAssetSchemeHandler.data(for: URL(string: "folmi-asset://local/katex/README.md")!))
    }
}
