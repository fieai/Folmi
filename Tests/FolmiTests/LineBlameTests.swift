import AppKit
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

final class LineBlameTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    func testBufferLinesMapOntoHeadAroundEdits() {
        XCTAssertEqual(LineBlame.headLines(head: "a\nb\nc\n", current: "a\nb\nc\n"), [0, 1, 2])
        XCTAssertEqual(LineBlame.headLines(head: "a\nb\nc\n", current: "a\nx\nb\nc\n"), [0, nil, 1, 2])
        XCTAssertEqual(LineBlame.headLines(head: "a\nb\nc\n", current: "a\nB\nc\n"), [0, nil, 2])
        XCTAssertEqual(LineBlame.headLines(head: "a\nb\nc\n", current: "a\nc\n"), [0, 2])
        XCTAssertEqual(LineBlame.headLines(head: "a\nb\n", current: "a\nb"), [0, 1], "a missing final newline is not an edit of the line")
        XCTAssertEqual(LineBlame.headLines(head: "", current: "a\n"), [nil])
    }

    func testNoteTextForEachKindOfLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let mine = FileBlame.Commit(id: String(repeating: "1", count: 40), author: "Me", email: "ME@x", date: now.addingTimeInterval(-7_200), subject: "修复登录超时")
        let mate = FileBlame.Commit(id: String(repeating: "2", count: 40), author: "张三", email: "z@x", date: now.addingTimeInterval(-3 * 86_400), subject: "加缓存")
        let blame = FileBlame(path: "a", head: "h", text: "a\nb\n", lineCommits: [0, 1], commits: [mine, mate], userEmail: "me@x")
        XCTAssertEqual(LineBlame.note(line: 0, source: .blame(blame), headLine: 0, unstaged: false, now: now)?.text, "你 · 2 小时前 · 修复登录超时")
        XCTAssertEqual(LineBlame.note(line: 0, source: .blame(blame), headLine: 0, unstaged: false, now: now)?.isMine, true)
        XCTAssertEqual(LineBlame.note(line: 3, source: .blame(blame), headLine: 1, unstaged: true, now: now)?.text, "张三 · 3 天前 · 加缓存")
        XCTAssertEqual(LineBlame.note(line: 2, source: .blame(blame), headLine: nil, unstaged: true, now: now)?.text, "还没收下")
        XCTAssertEqual(LineBlame.note(line: 2, source: .blame(blame), headLine: nil, unstaged: false, now: now)?.text, "已收下 · 还没提交")
        XCTAssertNil(LineBlame.note(line: 2, source: .blame(blame), headLine: nil, unstaged: false, now: now)?.commit)
        XCTAssertEqual(LineBlame.note(line: 0, source: .notInHead, headLine: nil, unstaged: false, now: now)?.text, "新文件 · 还没提交过")
        XCTAssertNil(LineBlame.note(line: 0, source: .unavailable, headLine: nil, unstaged: false, now: now))
    }

    func testRelativeTimes() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(LineBlame.relative(now.addingTimeInterval(-20), now: now), "刚刚")
        XCTAssertEqual(LineBlame.relative(now.addingTimeInterval(-300), now: now), "5 分钟前")
        XCTAssertEqual(LineBlame.relative(now.addingTimeInterval(-3 * 3_600), now: now), "3 小时前")
        XCTAssertEqual(LineBlame.relative(now.addingTimeInterval(-30 * 3_600), now: now), "昨天")
        XCTAssertEqual(LineBlame.relative(now.addingTimeInterval(-5 * 86_400), now: now), "5 天前")
        XCTAssertFalse(LineBlame.relative(now.addingTimeInterval(-90 * 86_400), now: now).contains("前"))
    }

    func testTruncationKeepsTheStartAndGivesUpWhenNothingFits() {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        XCTAssertEqual(EditorTextView.truncated("短", width: 200, attributes: attributes), "短")
        let cut = EditorTextView.truncated("张三 · 3 天前 · 一条很长很长很长很长很长很长很长很长的提交说明", width: 120, attributes: attributes)
        XCTAssertEqual(cut?.hasPrefix("张三"), true)
        XCTAssertEqual(cut?.hasSuffix("…"), true)
        XCTAssertNil(EditorTextView.truncated("张三 · 3 天前", width: 8, attributes: attributes))
    }

    @MainActor
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func findEditor(in view: NSView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        for subview in view.subviews { if let found = findEditor(in: subview) { return found } }
        return nil
    }

    @MainActor
    private func waitFor(_ editor: EditorTextView, _ expected: (String?) -> Bool, timeout: TimeInterval = 6) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while !expected(editor.blameNote?.text), Date() < deadline { spin(0.05) }
        return editor.blameNote?.text
    }

    @MainActor
    func testCaretLineShowsWhoChangedItAndWhetherItIsReceived() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Blame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        var created: Result<DemoRepository, Error>?
        Task { do { created = .success(try await DemoRepository.create()) } catch { created = .failure(error) } }
        while created == nil { spin(0.05) }
        let demo = try XCTUnwrap(created).get()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(8)
        while model.busy || model.snapshot == nil { guard Date() < deadline else { return XCTFail("open") }; spin(0.05) }
        XCTAssertTrue(model.editorLineBlame, "on by default")
        model.editPath("README.md")
        while model.busy { spin(0.05) }
        model.editorWorkspace?.markdownReading = false

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: FolmiView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        spin(1.0)
        let editor = try XCTUnwrap(findEditor(in: try XCTUnwrap(window.contentView)), "editor view")
        window.makeFirstResponder(editor)
        let text = editor.string as NSString
        func caret(on line: String) { editor.setSelectedRange(NSRange(location: text.range(of: line).location, length: 0)) }

        caret(on: "这是独立临时仓库。")
        let committed = waitFor(editor) { $0?.hasSuffix("建立演示基线") == true }
        XCTAssertEqual(committed?.hasSuffix("建立演示基线"), true, "committed line: \(committed ?? "nil")")
        XCTAssertEqual(committed?.hasPrefix("你 · 刚刚"), true, "the user's own commit")
        XCTAssertEqual(editor.blameNote?.opens, true)
        XCTAssertFalse(editor.string.contains("建立演示基线"), "the note is drawn, not inserted into the text")

        caret(on: "这一行已经暂存。")
        XCTAssertEqual(waitFor(editor) { $0 == "已收下 · 还没提交" }, "已收下 · 还没提交")
        XCTAssertEqual(editor.blameNote?.opens, false)
        caret(on: "这一行仍在工作区。")
        XCTAssertEqual(waitFor(editor) { $0 == "还没收下" }, "还没收下")

        // Typing hides it; it comes back once the caret rests, now for an edited line.
        caret(on: "这是独立临时仓库。")
        _ = waitFor(editor) { $0?.hasSuffix("建立演示基线") == true }
        editor.insertText("改", replacementRange: editor.selectedRange())
        XCTAssertNil(editor.blameNote, "hidden while typing")
        XCTAssertEqual(waitFor(editor) { $0 == "还没收下" }, "还没收下", "an edited committed line is no longer that commit's")

        // A selection across lines shows nothing; turning the setting off hides it.
        editor.setSelectedRange(NSRange(location: 0, length: 12))
        spin(0.5)
        XCTAssertNil(editor.blameNote)
        caret(on: "这一行仍在工作区。")
        _ = waitFor(editor) { $0 != nil }
        model.editorLineBlame = false
        XCTAssertNil(waitFor(editor) { $0 == nil }, "the setting turns it off")
    }
}
