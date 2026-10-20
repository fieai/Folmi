import XCTest
import AppKit
import SwiftUI
import WebKit
import FolmiCore
@testable import Folmi

@MainActor
final class MarkdownReaderTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        root = root.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    func testCleanDocumentsFollowTheDiskAndDirtyOnesAreKept() throws {
        try write("a.md", "# one\n")
        try write("b.md", "# two\n")
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "a.md")
        try workspace.open(path: "b.md")
        workspace.updateText(id: "b.md", text: "# two edited\n")
        XCTAssertEqual(workspace.reloadCleanDocuments(), [], "nothing changed on disk")
        try write("a.md", "# one, by the agent\n")
        try write("b.md", "# two, by the agent\n")
        XCTAssertEqual(workspace.reloadCleanDocuments(), ["a.md"])
        XCTAssertEqual(workspace.documents.first { $0.id == "a.md" }?.text, "# one, by the agent\n")
        XCTAssertFalse(workspace.documents.first { $0.id == "a.md" }!.isDirty)
        XCTAssertNotNil(workspace.externalChanges["a.md"])
        XCTAssertEqual(workspace.documents.first { $0.id == "b.md" }?.text, "# two edited\n", "unsaved edits are never replaced")
        workspace.dismissExternalChange("a.md")
        XCTAssertNil(workspace.externalChanges["a.md"])
        // The reloaded document saves normally afterwards (its disk fingerprint was updated).
        workspace.selectedDocumentID = "a.md"
        workspace.updateText(id: "a.md", text: "# one, then me\n")
        XCTAssertNoThrow(try workspace.saveSelected())
        XCTAssertEqual(try read("a.md"), "# one, then me\n")
    }

    func testToggleTaskFlipsOnlyTheMarkAndSavesACleanDocument() throws {
        let text = "- [ ] 第一\n- [x] 第二\n"
        try write("todo.md", text)
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "todo.md")
        let html = MarkdownHTML.render(text)
        let offsets = html.components(separatedBy: "data-offset=\"").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        try workspace.toggleTask(at: offsets[0], in: "todo.md")
        XCTAssertEqual(try read("todo.md"), "- [x] 第一\n- [x] 第二\n")
        XCTAssertFalse(workspace.hasUnsavedChanges)
        // With other unsaved edits the toggle joins them instead of saving.
        workspace.updateText(id: "todo.md", text: "- [x] 第一\n- [x] 第二\n草稿\n")
        try workspace.toggleTask(at: offsets[1], in: "todo.md")
        XCTAssertEqual(workspace.selectedDocument?.text, "- [x] 第一\n- [ ] 第二\n草稿\n")
        XCTAssertEqual(try read("todo.md"), "- [x] 第一\n- [x] 第二\n")
        // An offset that is not a task mark changes nothing.
        try workspace.toggleTask(at: 0, in: "todo.md")
        try workspace.toggleTask(at: 4, in: "todo.md")
        XCTAssertEqual(workspace.selectedDocument?.text, "- [x] 第一\n- [ ] 第二\n草稿\n")
    }

    func testEditHereLeavesReadingAtTheLine() throws {
        try write("doc.md", "# a\n\nline two\n\nline four\n")
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "doc.md")
        XCTAssertTrue(workspace.markdownReading)
        workspace.readerTopLine["doc.md"] = 2
        workspace.editMarkdown(at: 4, in: "doc.md")
        XCTAssertFalse(workspace.markdownReading)
        XCTAssertEqual(workspace.editorScrollRequest?.line, 2, "the editor keeps the reader's view")
        XCTAssertEqual(workspace.tabStates["doc.md"]?.selectionLocation, ("# a\n\nline two\n\n" as NSString).length)
    }

    func testSwitchingCarriesThePlaceBetweenReaderAndEditor() throws {
        let text = (0..<200).map { "第 \($0) 行\n" }.joined()
        try write("long.md", text)
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "long.md")
        // Reader → editor: the reader's top line goes to the editor, and a far-away caret moves there.
        workspace.readerTopLine["long.md"] = 120
        workspace.markdownReading = false
        XCTAssertEqual(workspace.editorScrollRequest?.line, 120)
        let starts = MarkdownReaderView.Coordinator.lineStarts(text)
        XCTAssertEqual(workspace.tabStates["long.md"]?.selectionLocation, starts[120])
        // Editor → reader: the editor's top visible line becomes the reader's place.
        workspace.editorTopLine = { 77 }
        workspace.markdownReading = true
        XCTAssertEqual(workspace.readerTopLine["long.md"], 77)
        // A caret already near the place stays where it is.
        workspace.updateEditorState(id: "long.md", selection: NSRange(location: starts[130], length: 0), scrollOffset: 0)
        workspace.readerTopLine["long.md"] = 120
        workspace.markdownReading = false
        XCTAssertEqual(workspace.tabStates["long.md"]?.selectionLocation, starts[130])
    }

    func testProjectImagesOnlyAndNothingOutsideTheRoot() throws {
        try write("docs/assets/a.png", "png")
        try write("secret.txt", "no")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        func load(_ path: String) -> Data? { ProjectFileSchemeHandler.data(for: URL(string: "folmi-file://local/" + path)!, root: root) }
        XCTAssertEqual(load("docs/assets/a.png"), Data("png".utf8))
        XCTAssertNil(load("secret.txt"), "only image types are served")
        XCTAssertNil(load("../" + outside.lastPathComponent))
        XCTAssertNil(load("docs/missing.png"))
        XCTAssertEqual(MarkdownReaderPage.imageSource("assets/a.png", from: "docs/spec.md"), "folmi-file://local/docs/assets/a.png")
        XCTAssertEqual(MarkdownReaderPage.imageSource("/docs/assets/a b.png", from: "docs/spec.md"), "folmi-file://local/docs/assets/a%20b.png")
        XCTAssertNil(MarkdownReaderPage.imageSource("../../x.png", from: "docs/spec.md"))
        XCTAssertEqual(MarkdownReaderPage.imageSource("https://e.com/a.png", from: "x.md"), "https://e.com/a.png")
    }

    /// The page script and styles load in a real web view: the document renders, task boxes and code tools appear,
    /// and changed blocks get their marks.
    func testReaderRendersInAWebView() async throws {
        _ = NSApplication.shared
        try write("spec.md", "# 导出为 PDF\n\n正文一段。\n\n- [ ] 待办\n\n```swift\nlet a = 1\n```\n")
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "spec.md")
        workspace.loadIndexBase = { path in
            IndexBase(GitRepository.IndexFile(path: path, mode: "100644", object: "0", data: Data("# 导出为 PDF\n\n旧的正文。\n".utf8)))
        }
        let host = NSHostingView(rootView: FileEditorPane(workspace: workspace, onSave: {}))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        var webView: WKWebView?
        var state = ""
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            webView = webView ?? find(host)
            if let webView {
                let script = "[document.querySelectorAll('h1').length, document.querySelectorAll('input.task').length, "
                    + "document.querySelectorAll('.code .tools button').length, document.querySelectorAll('[data-mark]').length, typeof wb].join(',')"
                state = (try? await webView.evaluateJavaScript(script) as? String) ?? ""
                if state == "1,1,1,3,object" { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(webView, "reading mode shows the web view, not the text view")
        XCTAssertEqual(state, "1,1,1,3,object", "heading, task, copy button, three changed blocks (paragraph, list item, code)")
        // The find bar highlights matches, counts them, and leaves the text as it was when closed.
        let web = try XCTUnwrap(webView)
        let found = try await web.evaluateJavaScript(
            "document.getElementById('find-q').value='正文';wb.find();[document.querySelectorAll('mark.find').length,document.getElementById('find-n').textContent].join(',')") as? String
        XCTAssertEqual(found, "1,1/1")
        let closed = try await web.evaluateJavaScript(
            "document.querySelector('#find button[data-dir=\"0\"]').click();[document.querySelectorAll('mark.find').length,document.querySelector('p').textContent].join(',')") as? String
        XCTAssertEqual(closed, "0,正文一段。")
        // Switching to 编辑 keeps the page loaded behind the source editor and hides it once the fade is over.
        func findText(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.lazy.compactMap(findText).first
        }
        workspace.markdownReading = false
        var swapped = false
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if find(host) === web, web.isHidden, let text = findText(host), !text.isHiddenOrHasHiddenAncestor { swapped = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(swapped)
        workspace.markdownReading = true
        var back = false
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if !web.isHidden, let text = findText(host), text.isHiddenOrHasHiddenAncestor { back = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(back)
    }

    @MainActor
    func testPrefetchFillsTheRenderCacheOnce() async throws {
        let path = "prefetch-\(UUID().uuidString).md", text = "# 标题\n\n正文 **粗体**\n"
        XCTAssertNil(ReaderRenderCache.find(path: path, text: text))
        ReaderRenderCache.prefetch([(path: path, text: text)])
        let rendered = await ReaderRenderCache.render(path: path, text: text, priority: .userInitiated)
        XCTAssertTrue(rendered.html.contains("<strong>粗体</strong>"))
        XCTAssertEqual(ReaderRenderCache.find(path: path, text: text)?.html, rendered.html)
        XCTAssertNil(ReaderRenderCache.find(path: path, text: text + "改"), "a changed text is rendered again")
    }

    func testReaderTextMatchesTheEditorText() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# 标题\r\n正文\r\n".utf8)
        XCTAssertEqual(EditorWorkspace.readerText(data), "# 标题\n正文\n", "prefetched text must equal what the editor holds")
        XCTAssertNil(EditorWorkspace.readerText(Data([0xFF, 0x00])))
    }

    func testMarkdownDiffMarksNewBlocksAndKeepsRemovedTextRendered() {
        let base = "# 标题\n\n旧的一段。\n\n```swift\nlet a = 1\n```\n\n要删掉的段落。\n"
        let current = "# 标题\n\n新的一段 **加粗**。\n\n```swift\nlet a = 2\n```\n\n新加的段落。\n"
        let page = MarkdownDiffPage.build(path: "doc.md", base: base, current: current)
        XCTAssertTrue(page.html.contains("<strong>加粗</strong>"))
        XCTAssertFalse(page.marks.isEmpty)
        XCTAssertTrue(page.marks.allSatisfy { ($0[2] as? String) == "mod" || ($0[2] as? String) == "add" })
        let olds = page.olds.compactMap { $0[1] as? String }
        XCTAssertTrue(olds.contains { $0.contains("旧的一段") })
        XCTAssertTrue(olds.contains { $0.contains("要删掉的段落") })
        XCTAssertTrue(olds.contains { $0.contains("class=\"code\"") && $0.contains("1") }, "an old line from inside a code block stays code")
        XCTAssertEqual(MarkdownDiffPage.normalized("\u{FEFF}a\r\nb\rc"), "a\nb\nc")
        XCTAssertTrue(MarkdownDiffPage.build(path: "doc.md", base: current, current: current).olds.isEmpty)
    }
}
