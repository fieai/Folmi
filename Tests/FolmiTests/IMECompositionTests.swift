import AppKit
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

final class IMECompositionTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    @MainActor
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func findEditor(in view: NSView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        for subview in view.subviews { if let found = findEditor(in: subview) { return found } }
        return nil
    }

    @MainActor
    func testPinyinCompositionSurvivesFolmiUpdatesAndCommitsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-IME-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        var created: Result<DemoRepository, Error>?
        Task { do { created = .success(try await DemoRepository.create()) } catch { created = .failure(error) } }
        while created == nil { spin(0.05) }
        let demo = try XCTUnwrap(created).get()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")), autoRefresh: true)
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(8)
        while model.busy || model.snapshot == nil { guard Date() < deadline else { return XCTFail("open") }; spin(0.05) }
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
        let original = editor.string
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        // Compose "ni" → "nihao" like a pinyin IME, letting SwiftUI, the gutter and highlighting run in between.
        editor.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.4)
        XCTAssertTrue(editor.hasMarkedText(), "composition lost after first key")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.4)
        XCTAssertTrue(editor.hasMarkedText(), "composition lost after second key")
        editor.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.6)
        XCTAssertTrue(editor.hasMarkedText(), "composition lost while waiting")
        XCTAssertEqual(editor.markedRange(), NSRange(location: 0, length: 6))
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.6)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "你好" + original)
        XCTAssertEqual(model.editorWorkspace?.selectedDocument?.text, "你好" + original)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0), "caret stays after the committed text")

        // A second composition right after the first one.
        editor.setMarkedText("shi", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.4)
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("是", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.6)
        XCTAssertEqual(editor.string, "你好是" + original)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
    }
}
