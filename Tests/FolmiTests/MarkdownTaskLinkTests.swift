import AppKit
import XCTest
@testable import Folmi

final class MarkdownTaskLinkTests: XCTestCase {
    func testFindsTheLinkUnderTheClick() {
        let line = "看 [说明](docs/guide.md#L3) 和 <https://a.example/x> 还有 https://b.example/y。"
        let source = line as NSString
        XCTAssertEqual(MarkdownLinks.target(in: line, at: source.range(of: "说明").location), "docs/guide.md#L3")
        XCTAssertEqual(MarkdownLinks.target(in: line, at: source.range(of: "guide").location), "docs/guide.md#L3", "the address part counts too")
        XCTAssertEqual(MarkdownLinks.target(in: line, at: source.range(of: "a.example").location), "https://a.example/x")
        XCTAssertEqual(MarkdownLinks.target(in: line, at: source.range(of: "b.example").location), "https://b.example/y", "trailing 。 is not part of it")
        XCTAssertNil(MarkdownLinks.target(in: line, at: 0))
        XCTAssertEqual(MarkdownLinks.target(in: "![图](img/a b.png)", at: 2), nil, "an address with a space is not a link")
        XCTAssertEqual(MarkdownLinks.target(in: "![图](img/a.png \"标题\")", at: 2), "img/a.png")
        XCTAssertEqual(MarkdownLinks.target(in: "[x](<a.md>)", at: 1), "a.md")
    }

    func testResolvesOnlySafeDestinations() {
        XCTAssertEqual(MarkdownLinks.resolve("https://example.com/a", from: "README.md"), .web(URL(string: "https://example.com/a")!))
        XCTAssertEqual(MarkdownLinks.resolve("mailto:a@example.com", from: "README.md"), .web(URL(string: "mailto:a@example.com")!))
        guard case .refused = MarkdownLinks.resolve("javascript:alert(1)", from: "a.md") else { return XCTFail() }
        guard case .refused = MarkdownLinks.resolve("file:///etc/passwd", from: "a.md") else { return XCTFail() }
        guard case .refused = MarkdownLinks.resolve("../../secret.md", from: "docs/a.md") else { return XCTFail() }
        XCTAssertEqual(MarkdownLinks.resolve("guide.md#L12-L20", from: "docs/index.md"), .file(path: "docs/guide.md", line: 12, anchor: nil))
        XCTAssertEqual(MarkdownLinks.resolve("../src/app.js", from: "docs/index.md"), .file(path: "src/app.js", line: nil, anchor: nil))
        XCTAssertEqual(MarkdownLinks.resolve("/README.md#安装步骤", from: "docs/x/y.md"), .file(path: "README.md", line: nil, anchor: "安装步骤"))
        XCTAssertEqual(MarkdownLinks.resolve("%E8%AF%B4%E6%98%8E.md", from: "a.md"), .file(path: "说明.md", line: nil, anchor: nil))
        XCTAssertEqual(MarkdownLinks.resolve("#快速开始", from: "a.md"), .anchor("快速开始"))
    }

    func testHeadingAnchorsFollowGitHubSlugs() {
        let text = "# Git 工作台\n\n```\n# 不是标题\n```\n## Quick Start!\n### 安装 步骤\n"
        XCTAssertEqual(MarkdownLinks.slug("Quick Start!"), "quick-start")
        XCTAssertEqual(MarkdownLinks.headingLine("quick-start", in: text), 6)
        XCTAssertEqual(MarkdownLinks.headingLine("安装-步骤", in: text), 7)
        XCTAssertEqual(MarkdownLinks.headingLine("git-工作台", in: text), 1)
        XCTAssertNil(MarkdownLinks.headingLine("不是标题", in: text), "lines in a fence are not headings")
    }

    @MainActor
    func testCommandClickOpensLink() throws {
        let editor = TaskTestTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        editor.isRichText = false; editor.allowsUndo = true
        editor.markdownEditing = true
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.string = "- [ ] 买菜\n\n[说明](docs/guide.md)\n"
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        func click(_ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(point, to: nil), modifierFlags: flags,
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
            editor.mouseDown(with: event)
        }
        var opened: String?
        editor.openLink = { opened = $0 }
        let label = (editor.string as NSString).range(of: "说明")
        let glyphs = editor.layoutManager!.glyphRange(forCharacterRange: label, actualCharacterRange: nil)
        let rect = editor.layoutManager!.boundingRect(forGlyphRange: glyphs, in: editor.textContainer!)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        // A plain click goes to NSTextView's own tracking loop, which would wait here for a mouse-up.
        click(NSPoint(x: rect.midX, y: rect.midY), .command)
        XCTAssertEqual(opened, "docs/guide.md")
    }

    @MainActor
    func testWorkspaceFollowsLinksInsideTheProjectOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# 首页\n\n## 安装步骤\n内容\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "一\n二\n三\n".write(to: root.appendingPathComponent("docs/guide.md"), atomically: true, encoding: .utf8)
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "README.md")

        workspace.followLink("docs/guide.md#L3", from: "README.md")
        XCTAssertEqual(workspace.selectedDocumentID, "docs/guide.md")
        XCTAssertEqual(workspace.tabStates["docs/guide.md"]?.selectionLocation, 4, "start of line 3")

        workspace.followLink("../README.md#安装步骤", from: "docs/guide.md")
        XCTAssertEqual(workspace.selectedDocumentID, "README.md")
        XCTAssertEqual(workspace.tabStates["README.md"]?.selectionLocation, ("# 首页\n\n" as NSString).length)

        workspace.followLink("../../outside.md", from: "README.md")
        XCTAssertNotNil(workspace.errorMessage)
        workspace.errorMessage = nil
        workspace.followLink("missing.md", from: "README.md")
        XCTAssertTrue(workspace.errorMessage?.contains("找不到") == true)
        XCTAssertEqual(workspace.selectedDocumentID, "README.md")
    }
}

private final class TaskTestTextView: EditorTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}
