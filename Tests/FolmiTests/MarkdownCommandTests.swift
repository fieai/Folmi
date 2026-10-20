import XCTest
import AppKit
@testable import Folmi

@MainActor
final class MarkdownCommandTests: XCTestCase {
    private func apply(_ edit: EditorLineEdit?, to text: String) throws -> String {
        let edit = try XCTUnwrap(edit)
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: Format bar

    func testFormatStateShowsWrappedStylesAndHeading() {
        let text = "## 标题 **粗** 和 *斜* 和 `码`"
        let source = text as NSString
        XCTAssertTrue(MarkdownCommands.formatState(text: text, selection: source.range(of: "粗")).bold)
        XCTAssertTrue(MarkdownCommands.formatState(text: text, selection: source.range(of: "斜")).italic)
        XCTAssertTrue(MarkdownCommands.formatState(text: text, selection: source.range(of: "码")).code)
        let plain = MarkdownCommands.formatState(text: text, selection: source.range(of: "标题"))
        XCTAssertFalse(plain.bold || plain.italic || plain.code)
        XCTAssertEqual(plain.heading, 2)
        XCTAssertTrue(MarkdownCommands.formatState(text: "一\n二", selection: NSRange(location: 0, length: 3)).multiline)
    }

    func testHeadingAppliesToEverySelectedLineInOneEdit() throws {
        let text = "第一行\n## 第二行\n\n第三行\n"
        let edit = MarkdownCommands.heading(text: text, selection: NSRange(location: 1, length: (text as NSString).range(of: "第三").location), level: 3)
        XCTAssertEqual(try apply(edit, to: text), "### 第一行\n### 第二行\n\n### 第三行\n")
        let back = MarkdownCommands.heading(text: "### 第一行", selection: NSRange(location: 4, length: 2), level: 0)
        XCTAssertEqual(try apply(back, to: "### 第一行"), "第一行")
        XCTAssertEqual(back?.selection, NSRange(location: 0, length: 2))
    }

    // MARK: `/` menu

    func testSlashTriggerOnlyWhereAMenuMakesSense() {
        func trigger(_ text: String) -> String? {
            MarkdownCommands.slashTrigger(text: text, selection: NSRange(location: (text as NSString).length, length: 0))?.query
        }
        XCTAssertEqual(trigger("/"), "")
        XCTAssertEqual(trigger("段落 /bg"), "bg")
        XCTAssertEqual(trigger("  、daima"), "daima", "the Chinese input method types 、 for /")
        XCTAssertEqual(trigger("- /"), "", "inside a list item")
        XCTAssertNil(trigger("a/b"), "a path")
        XCTAssertNil(trigger("https://example.com/"), "a URL")
        XCTAssertNil(trigger("看 `code /"), "inside inline code")
        XCTAssertNil(trigger("[文字](docs /"), "inside a link address")
        XCTAssertNil(trigger("```\n/"), "inside a code block")
        XCTAssertNil(trigger("/ 有空格"), "a space ends the query")
    }

    func testSlashSearchRanksChinesePinyinAndEnglish() {
        XCTAssertEqual(MarkdownCommands.slashMatches("").count, MarkdownCommands.slashCommands.count)
        XCTAssertEqual(MarkdownCommands.slashMatches("bg").first?.id, "table")
        XCTAssertEqual(MarkdownCommands.slashMatches("表格").first?.id, "table")
        XCTAssertEqual(MarkdownCommands.slashMatches("daima").first?.id, "code")
        XCTAssertEqual(MarkdownCommands.slashMatches("code").first?.id, "code")
        XCTAssertEqual(MarkdownCommands.slashMatches("h2").first?.id, "h2")
        XCTAssertEqual(MarkdownCommands.slashMatches("代码").first?.id, "code")
        XCTAssertTrue(MarkdownCommands.slashMatches("zzzz").isEmpty)
    }

    func testSlashCommandsReplaceOnlyTheirTrigger() throws {
        func run(_ text: String, _ action: MarkdownCommands.SlashCommand.Action) throws -> (String, NSRange) {
            let trigger = try XCTUnwrap(MarkdownCommands.slashTrigger(text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
            let edit = try XCTUnwrap(MarkdownCommands.slashEdit(action, text: text, trigger: trigger.range))
            return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
        }
        XCTAssertEqual(try run("前\n/bt2", .heading(2)).0, "前\n## ")
        XCTAssertEqual(try run("说明 /", .heading(1)).0, "# 说明 ")
        XCTAssertEqual(try run("## 旧 /", .bullet).0, "- 旧 ", "a block prefix is swapped, the text stays")
        XCTAssertEqual(try run("/db", .task).0, "- [ ] ")
        let (code, caret) = try run("/dm", .code)
        XCTAssertEqual(code, "```\n\n```")
        XCTAssertEqual(caret, NSRange(location: 4, length: 0), "caret inside the block")
        XCTAssertEqual(try run("文字 /", .code).0, "文字 \n```\n\n```")
        XCTAssertEqual(try run("/bg", .table).0, "| 列 1 | 列 2 |\n| --- | --- |\n|  |  |\n")
        XCTAssertEqual(try run("/", .rule).0, "---\n")
        XCTAssertEqual(try run("看 /lj", .link).0, "看 []()")
        XCTAssertEqual(try run("/", .wiki).0, "[[]]")
        XCTAssertNil(MarkdownCommands.slashEdit(.image, text: "/", trigger: NSRange(location: 0, length: 1)))
        let image = MarkdownCommands.imageEdit("![a](assets/a.png)", text: "前 /tp", trigger: NSRange(location: 2, length: 3))
        XCTAssertEqual(try apply(image, to: "前 /tp"), "前 \n![a](assets/a.png)")
    }

    func testSlashMenuThroughTheEditorIsOneUndoAndEscKeepsTheText() throws {
        let editor = GroupedUndoTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.isRichText = false; editor.allowsUndo = true; editor.markdownEditing = true
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.close() }
        window.makeFirstResponder(editor)
        editor.string = "开头\n"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        // Each key press is its own event, as in the app.
        func key(_ action: () -> Void) { editor.testUndo.beginUndoGrouping(); action(); editor.testUndo.endUndoGrouping() }
        key { editor.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertTrue(editor.overlays.isSlashOpen)
        for character in "bg" { key { editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
        XCTAssertEqual(editor.overlays.slashMatches.first?.id, "table")
        key { editor.insertNewline(nil) }
        XCTAssertFalse(editor.overlays.isSlashOpen)
        XCTAssertEqual(editor.string, "开头\n| 列 1 | 列 2 |\n| --- | --- |\n|  |  |\n")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "开头\n/bg", "one undo takes back the command, leaving what was typed")

        editor.string = "x\n"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        key { editor.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        editor.moveDown(nil)
        XCTAssertEqual(editor.overlays.slashSelected, 1)
        editor.cancelOperation(nil)
        XCTAssertFalse(editor.overlays.isSlashOpen)
        key { editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertFalse(editor.overlays.isSlashOpen, "a dismissed menu stays closed for that /")
        key { editor.insertNewline(nil) }
        XCTAssertEqual(editor.string, "x\n/a\n", "Return is a newline again")
    }

    // MARK: Code blocks

    func testFenceCodeAndLanguage() throws {
        let text = "前\n\n```swift title=a\nlet a = 1\n\nlet b = 2\n```\n后\n"
        let source = text as NSString
        let fence = try XCTUnwrap(MarkdownCommands.fence(in: text, at: source.range(of: "let b").location))
        XCTAssertEqual(fence.language, "swift")
        XCTAssertEqual(MarkdownCommands.code(of: fence, in: text), "let a = 1\n\nlet b = 2")
        let changed = try apply(MarkdownCommands.setLanguage("python", of: fence, text: text), to: text)
        XCTAssertEqual(changed, "前\n\n```python title=a\nlet a = 1\n\nlet b = 2\n```\n后\n", "other info stays")
        XCTAssertNil(MarkdownCommands.fence(in: text, at: source.range(of: "后").location))
        let bare = "```\ncode\n```"
        let plain = try XCTUnwrap(MarkdownCommands.fence(in: bare, at: 5))
        XCTAssertEqual(plain.language, "")
        XCTAssertEqual(try apply(MarkdownCommands.setLanguage("bash", of: plain, text: bare), to: bare), "```bash\ncode\n```")
    }

    // MARK: Tables

    private let table = "前\n\n| 名称 | 数量 |\n| --- | ---: |\n| 苹果 | 3 |\n| a \\| b | 12 |\n\n后"

    func testTableRowAndColumnCommandsRewriteOnlyTheTable() throws {
        let source = table as NSString
        let apple = source.range(of: "苹果").location
        let below = try apply(MarkdownTable.insertRow(text: table, at: apple, .below), to: table)
        XCTAssertEqual(below, "前\n\n| 名称 | 数量 |\n| --- | ---: |\n| 苹果 | 3 |\n| | |\n| a \\| b | 12 |\n\n后")
        let above = try apply(MarkdownTable.insertRow(text: table, at: apple, .above), to: table)
        XCTAssertTrue(above.contains("| ---: |\n| | |\n| 苹果 |"), above)
        let right = try apply(MarkdownTable.insertColumn(text: table, at: apple, .right), to: table)
        XCTAssertTrue(right.contains("| 名称 | 列 | 数量 |\n| --- | --- | ---: |\n| 苹果 | | 3 |"), right)
        let deletedRow = try apply(MarkdownTable.deleteRow(text: table, at: apple), to: table)
        XCTAssertFalse(deletedRow.contains("苹果"))
        XCTAssertTrue(deletedRow.hasPrefix("前\n\n") && deletedRow.hasSuffix("\n\n后"))
        XCTAssertNil(MarkdownTable.deleteRow(text: table, at: source.range(of: "名称").location), "the header row stays")
        let deletedColumn = try apply(MarkdownTable.deleteColumn(text: table, at: source.range(of: "3 |").location), to: table)
        XCTAssertEqual(deletedColumn, "前\n\n| 名称 |\n| --- |\n| 苹果 |\n| a \\| b |\n\n后", "an escaped pipe stays in its cell")
        // GFM splits on a pipe inside code too; the extra cell is kept rather than dropped.
        let extra = "| a | b |\n| --- | --- |\n| `x|y` | z |"
        let added = try apply(MarkdownTable.insertRow(text: extra, at: 2, .below), to: extra)
        XCTAssertEqual(added, "| a | b |\n| --- | --- |\n| | |\n| `x | y` | z |")
        let centered = try apply(MarkdownTable.align(text: table, at: apple, .center), to: table)
        XCTAssertTrue(centered.contains("| :---: | ---: |"), centered)
        XCTAssertNil(MarkdownTable.insertRow(text: table, at: 0, .below), "outside a table")
        XCTAssertEqual(MarkdownTable.source(text: table, at: apple), "| 名称 | 数量 |\n| --- | ---: |\n| 苹果 | 3 |\n| a \\| b | 12 |")
    }

    // MARK: Rich-text paste

    func testRichTextBecomesMarkdown() throws {
        let html = """
        <html><body>
        <h2>标题</h2>
        <p>一段 <b>粗体</b>、<em>斜体</em>、<del>删除</del>、<code>code</code> 和 <a href="https://example.com/a b">链接</a>。</p>
        <ul><li>一<ul><li>一点一</li></ul></li><li><input type="checkbox" checked> 完成</li></ul>
        <ol start="3"><li>三</li><li>四</li></ol>
        <blockquote><p>引用</p></blockquote>
        <pre><code class="language-swift">let a = 1
        print(a)</code></pre>
        <table><tr><th>名</th><th>值</th></tr><tr><td>a|b</td><td colspan="2">x</td></tr></table>
        <script>alert(1)</script><iframe src="https://evil.example"></iframe>
        <p><img src="https://example.com/p.png" alt="图"><img src="data:image/png;base64,AAAA" alt="内嵌"></p>
        <p><a href="javascript:alert(1)">危险</a></p>
        </body></html>
        """
        let result = try XCTUnwrap(MarkdownPaste.markdown(fromHTML: html))
        let markdown = result.markdown
        XCTAssertTrue(markdown.hasPrefix("## 标题\n\n一段 **粗体**、*斜体*、~~删除~~、`code` 和 [链接](https://example.com/a%20b)。"), markdown)
        XCTAssertTrue(markdown.contains("- 一\n  - 一点一\n- [x] 完成"), markdown)
        XCTAssertTrue(markdown.contains("3. 三\n4. 四"), markdown)
        XCTAssertTrue(markdown.contains("> 引用"), markdown)
        XCTAssertTrue(markdown.contains("```swift\nlet a = 1\n"), markdown)
        XCTAssertTrue(markdown.contains("| 名 | 值 |  |\n| --- | --- | --- |\n| a\\|b | x |  |"), markdown)
        XCTAssertTrue(markdown.contains("![图](https://example.com/p.png)"), markdown)
        XCTAssertFalse(markdown.contains("alert") && markdown.contains("<script"), "scripts never come through")
        XCTAssertFalse(markdown.contains("evil.example"))
        XCTAssertFalse(markdown.contains("javascript:"))
        XCTAssertTrue(markdown.contains("危险"), "the text of an unsafe link stays")
        XCTAssertFalse(result.notes.isEmpty)
    }

    func testStructurelessHTMLFallsBackToPlainText() {
        // What a code editor puts on the pasteboard: styled spans only.
        let html = #"<div style="font-family: Menlo"><div><span style="color: #c678dd">let</span> a = 1</div><div>b = a * 2</div></div>"#
        XCTAssertNil(MarkdownPaste.markdown(fromHTML: html))
        XCTAssertNil(MarkdownPaste.markdown(fromHTML: "<p>只是一段文字</p>"))
        // Google Docs' outer <b style="font-weight:normal"> is not bold.
        let docs = #"<b style="font-weight:normal;" id="docs-internal-guid-1"><p><span style="font-weight:700">重点</span> 普通</p></b>"#
        XCTAssertEqual(MarkdownPaste.markdown(fromHTML: docs)?.markdown, "**重点** 普通")
    }

    func testPasteBudgetIsEnforced() {
        let huge = "<ul>" + String(repeating: "<li>x</li>", count: 25_000) + "</ul>"
        XCTAssertNil(MarkdownPaste.markdown(fromHTML: huge), "over the node budget the plain text is pasted instead")
    }
}

private final class GroupedUndoTextView: EditorTextView {
    let testUndo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    override var undoManager: UndoManager? { testUndo }
}
