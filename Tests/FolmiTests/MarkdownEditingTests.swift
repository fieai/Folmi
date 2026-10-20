import AppKit
import XCTest
@testable import Folmi

final class MarkdownEditingTests: XCTestCase {
    /// Applies an edit and returns the text with `|` at the caret (or `[…]` around a selection).
    private func run(_ edit: EditorLineEdit?, on text: String) -> String? {
        guard let edit else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        if edit.selection.length == 0 { return result.replacingCharacters(in: edit.selection, with: "|") }
        let marked = result.replacingCharacters(in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "]") as NSString
        return marked.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "[")
    }
    /// Splits "ab|cd" or "a[bc]d" into text and selection.
    private func parse(_ marked: String) -> (String, NSRange) {
        let source = marked as NSString
        let bar = source.range(of: "|")
        if bar.location != NSNotFound { return (source.replacingCharacters(in: bar, with: ""), NSRange(location: bar.location, length: 0)) }
        let open = source.range(of: "["), close = source.range(of: "]", options: .backwards)
        let text = source.replacingCharacters(in: close, with: "") as NSString
        return (text.replacingCharacters(in: open, with: ""), NSRange(location: open.location, length: close.location - open.location - 1))
    }
    private func newline(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return run(MarkdownEditing.newline(text: text, selection: selection, tabSize: 2), on: text)
    }

    func testReturnContinuesListsTasksNumbersAndQuotes() {
        XCTAssertEqual(newline("- 苹果|"), "- 苹果\n- |")
        XCTAssertEqual(newline("  * a|"), "  * a\n  * |")
        XCTAssertEqual(newline("9. a|"), "9. a\n10. |")
        XCTAssertEqual(newline("1) a|"), "1) a\n2) |")
        XCTAssertEqual(newline("- [x] 已完成|"), "- [x] 已完成\n- [ ] |", "a new task starts unchecked")
        XCTAssertEqual(newline("> 引用|"), "> 引用\n> |")
        XCTAssertEqual(newline("> > a|"), "> > a\n> > |")
        XCTAssertEqual(newline("- ab|cd"), "- ab\n- |cd", "splits the item at the caret")
    }

    func testReturnOnEmptyItemOutdentsThenEndsTheList() {
        XCTAssertEqual(newline("- a\n  - |"), "- a\n- |")
        XCTAssertEqual(newline("- a\n- |"), "- a\n|")
        XCTAssertEqual(newline("- a\n- [ ] |"), "- a\n|")
        XCTAssertEqual(newline("> a\n> |"), "> a\n|")
    }

    func testReturnLeavesOtherLinesToTheEditor() {
        XCTAssertNil(newline("普通段落|"))
        XCTAssertNil(newline("---|"), "a rule is not a list")
        XCTAssertNil(newline("* * *|"))
        XCTAssertNil(newline("-|"), "a marker needs a space")
        XCTAssertNil(newline("```\n- 代码里|\n```"), "no continuation inside a fence")
        XCTAssertNotNil(newline("```\ncode\n```\n- 之后|"))
        XCTAssertNil(newline("-| a"), "caret inside the marker")
    }

    func testTabIndentsListItemsOnly() {
        let (text, selection) = parse("- a\n- [b\n- c]\n")
        XCTAssertEqual(run(MarkdownEditing.indent(text: text, selection: selection, outdent: false, tabSize: 2), on: text), "- a\n  - [b\n  - c]\n")
        let (nested, caret) = parse("    - x|")
        XCTAssertEqual(run(MarkdownEditing.indent(text: nested, selection: caret, outdent: true, tabSize: 2), on: nested), "  - x|")
        XCTAssertNil(MarkdownEditing.indent(text: "- a", selection: NSRange(location: 1, length: 0), outdent: true, tabSize: 2), "nothing to outdent")
        XCTAssertNil(MarkdownEditing.indent(text: "段落\n- a", selection: NSRange(location: 0, length: 5), outdent: false, tabSize: 2))
    }

    private func wrap(_ marked: String, _ marker: String) -> String? {
        let (text, selection) = parse(marked)
        return run(MarkdownEditing.toggleWrap(text: text, selection: selection, marker: marker), on: text)
    }

    func testFormattingShortcutsToggle() {
        XCTAssertEqual(wrap("a [词] b", "**"), "a **[词]** b")
        XCTAssertEqual(wrap("a **[词]** b", "**"), "a [词] b", "selection inside the markers")
        XCTAssertEqual(wrap("a [**词**] b", "**"), "a [词] b", "selection including the markers")
        XCTAssertEqual(wrap("a |b", "**"), "a **|**b")
        XCTAssertEqual(wrap("a **|**b", "**"), "a |b", "an empty pair toggles off")
        XCTAssertEqual(wrap("**[粗]**", "*"), "***[粗]***", "italic on bold adds, does not strip a bold star")
        XCTAssertEqual(wrap("*[斜]*", "*"), "[斜]")
        XCTAssertEqual(wrap("[x]", "~~"), "~~[x]~~")
        XCTAssertEqual(wrap("[x]", "`"), "`[x]`")
    }

    func testLinkAndHeading() {
        let (text, selection) = parse("看 [文档] 吧")
        XCTAssertEqual(run(MarkdownEditing.link(text: text, selection: selection), on: text), "看 [文档](|) 吧")
        let (url, urlSelection) = parse("[https://example.com]")
        XCTAssertEqual(run(MarkdownEditing.link(text: url, selection: urlSelection), on: url), "[|](https://example.com)")
        XCTAssertEqual(run(MarkdownEditing.link(text: "", selection: NSRange(location: 0, length: 0)), on: ""), "[|]()")

        let (line, caret) = parse("标|题")
        XCTAssertEqual(run(MarkdownEditing.heading(text: line, selection: caret, level: 2), on: line), "## 标|题")
        let (heading, headingCaret) = parse("## 标|题")
        XCTAssertEqual(run(MarkdownEditing.heading(text: heading, selection: headingCaret, level: 3), on: heading), "### 标|题")
        XCTAssertEqual(run(MarkdownEditing.heading(text: heading, selection: headingCaret, level: 2), on: heading), "标|题", "same level again")
        XCTAssertEqual(run(MarkdownEditing.heading(text: heading, selection: headingCaret, level: 0), on: heading), "标|题")
    }

    private func type(_ character: Character, _ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return run(MarkdownEditing.typed(character, text: text, selection: selection), on: text)
    }

    func testBracketsAndQuotesPair() {
        XCTAssertEqual(type("(", "a |"), "a (|)")
        XCTAssertEqual(type("(", "a |b"), nil, "no pair right before a word")
        XCTAssertEqual(type("[", "|，"), "[|]，")
        XCTAssertEqual(type(")", "(a|)"), "(a)|", "steps over the closing half")
        XCTAssertEqual(type("\"", "说 |"), "说 \"|\"")
        XCTAssertNil(type("\"", "it|"), "a quote after a word is typed as is")
        XCTAssertNil(type("`", "``|"), "the third backtick of a fence is typed as is")
        XCTAssertEqual(type("*", "[强调]"), "*[强调]*", "wrap a selection")
        XCTAssertNil(type("*", "a |"), "a lone star is a list marker or emphasis, not a pair")
        let (text, selection) = parse("(|)")
        XCTAssertEqual(run(MarkdownEditing.deleteBackward(text: text, selection: selection), on: text), "|")
        XCTAssertNil(MarkdownEditing.deleteBackward(text: "(a)", selection: NSRange(location: 2, length: 0)))
    }

    func testEditorAppliesCommandsAsUndoableEdits() {
        let editor = MarkdownTestTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.isRichText = false; editor.allowsUndo = true
        editor.markdownEditing = true
        editor.string = "- 一"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.testUndoManager.beginUndoGrouping()
        editor.insertNewline(nil)
        editor.testUndoManager.endUndoGrouping()
        XCTAssertEqual(editor.string, "- 一\n- ")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0))
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "- 一\n  - ")
        editor.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "- 一\n  - ()")
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "- 一\n  - ")
        editor.testUndoManager.removeAllActions()

        editor.string = "- 一"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.testUndoManager.beginUndoGrouping()
        editor.insertNewline(nil)
        editor.testUndoManager.endUndoGrouping()
        editor.testUndoManager.undo()
        XCTAssertEqual(editor.string, "- 一")

        // Other files keep the plain behaviour.
        editor.markdownEditing = false
        editor.string = "- 一"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "- 一\n")
    }
}

private final class MarkdownTestTextView: EditorTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}
