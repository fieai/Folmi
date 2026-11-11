import AppKit
import FolmiCore
import SwiftUI
import WebKit
import XCTest
@testable import Folmi

@MainActor
final class MarkdownSideBySideTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDownWithError() throws {
        cleanup.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
    }

    func testModesAndPositionHandoffsBelongToEachColumn() throws {
        let workspace = try workspace()
        let left = workspace.columns.activeID
        let right = try XCTUnwrap(workspace.columns.split("doc.md", from: left, toRight: true, move: false))
        workspace.readerTopLineByColumn[left] = ["doc.md": 60]
        workspace.readerTopLineByColumn[right] = ["doc.md": 140]
        workspace.setReading(false, column: left)
        XCTAssertFalse(workspace.isReading(column: left))
        XCTAssertTrue(workspace.isReading(column: right))
        XCTAssertTrue(workspace.markdownReading, "the split made the right column active")
        XCTAssertEqual(workspace.editorScrollRequests[left]?.line, 60)
        XCTAssertNil(workspace.editorScrollRequests[right])

        workspace.columns.activate(left)
        XCTAssertFalse(workspace.markdownReading)
        workspace.editorTopLineByColumn[left] = { 77 }
        workspace.editorTopLineByColumn[right] = { 180 }
        workspace.markdownReading = true
        XCTAssertEqual(workspace.readerTopLineByColumn[left]?["doc.md"], 77)
        XCTAssertEqual(workspace.readerTopLineByColumn[right]?["doc.md"], 140)
        workspace.setReading(false, column: right)
        XCTAssertTrue(workspace.markdownReading)
        XCTAssertEqual(workspace.editorScrollRequests[right]?.line, 140)
        workspace.columns.activate(right)
        XCTAssertFalse(workspace.markdownReading)
        XCTAssertEqual(workspace.editorScrollRequest?.line, 140)

        var found: [UUID] = []
        workspace.openReaderFindByColumn[left] = { found.append(left) }
        workspace.openReaderFindByColumn[right] = { found.append(right) }
        workspace.openReaderFind?()
        workspace.columns.activate(left)
        workspace.openReaderFind?()
        XCTAssertEqual(found, [right, left])
    }

    func testNewColumnsUseTheSavedDefaultAndModesSurviveTabChanges() throws {
        let workspace = try workspace(reading: false)
        let left = workspace.columns.activeID
        workspace.markdownReading = true
        let right = try XCTUnwrap(workspace.columns.split("doc.md", from: left, toRight: true, move: false))
        XCTAssertFalse(workspace.markdownReading, "new columns use the preference, not their neighbour's current mode")
        XCTAssertTrue(workspace.isReading(column: left))
        try workspace.open(path: "other.md", in: left)
        XCTAssertTrue(workspace.markdownReading)
        try workspace.open(path: "doc.md", in: left)
        XCTAssertTrue(workspace.markdownReading)
        XCTAssertFalse(workspace.isReading(column: right))
    }

    func testClosingAColumnRemovesItsModeAndCallbacks() throws {
        let workspace = try workspace()
        let left = workspace.columns.activeID
        let right = try XCTUnwrap(workspace.columns.split("doc.md", from: left, toRight: true, move: false))
        workspace.setReading(false, column: right)
        workspace.editorTopLineByColumn[right] = { 70 }
        workspace.openReaderFindByColumn[right] = {}
        workspace.readerTopLineByColumn[right] = ["doc.md": 70]
        workspace.readerScrollToLineByColumn[right] = { _ in }
        workspace.editorScrollToLineByColumn[right] = { _, _ in }
        XCTAssertNotNil(workspace.readingByColumn[right])
        try workspace.closeTab(id: "doc.md", in: right)
        XCTAssertEqual(workspace.columns.columns.map(\.id), [left])
        XCTAssertNil(workspace.readingByColumn[right])
        XCTAssertNil(workspace.editorTopLineByColumn[right])
        XCTAssertNil(workspace.openReaderFindByColumn[right])
        XCTAssertNil(workspace.readerTopLineByColumn[right])
        XCTAssertNil(workspace.readerScrollToLineByColumn[right])
        XCTAssertNil(workspace.editorScrollToLineByColumn[right])
        XCTAssertNil(workspace.editorScrollRequests[right])
    }

    func testScrollFollowsOnlyTheSameDocumentsEditingColumn() throws {
        let workspace = try workspace()
        let left = workspace.columns.activeID
        let right = try XCTUnwrap(workspace.columns.split("doc.md", from: left, toRight: true, move: false))
        let other = try XCTUnwrap(workspace.columns.split("other.md", from: right, toRight: true, move: false))
        workspace.setReading(false, column: left)
        var received: [Int] = []
        var unrelated: [Int] = []
        workspace.readerScrollToLineByColumn[right] = { received.append($0) }
        workspace.readerScrollToLineByColumn[other] = { unrelated.append($0) }
        workspace.editorTopLineByColumn[left] = { 88 }
        workspace.followEditorScroll(from: left, documentID: "doc.md", line: 88)
        XCTAssertEqual(received, [88])
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertEqual(workspace.readerTopLineByColumn[right]?["doc.md"], 88)
        XCTAssertEqual(workspace.followingEditorLine(for: "doc.md", column: right), 88)
        workspace.followEditorScroll(from: right, documentID: "doc.md", line: 20)
        XCTAssertEqual(received, [88], "the editor callback ignores reading columns")
        try workspace.open(path: "other.md", in: left)
        workspace.followEditorScroll(from: left, documentID: "doc.md", line: 30)
        XCTAssertEqual(received, [88], "a pending scroll for the previous tab is ignored")
    }

    func testSideBySideSplitsRightAndKeepsTheOriginalColumnActive() async throws {
        let (model, editor, store) = try await demoModel()
        defer { _ = model.prepareToQuit() }
        let left = editor.columns.activeID
        XCTAssertNil(model.markdownSideBySideBlockedReason(column: left))
        model.showMarkdownSideBySide(column: left)
        XCTAssertEqual(editor.columns.columns.count, 2)
        let right = editor.columns.columns[1].id
        XCTAssertEqual(editor.columns.columns.map(\.selected), ["README.md", "README.md"])
        XCTAssertEqual(editor.columns.columns[0].id, left)
        XCTAssertEqual(editor.columns.activeID, left)
        XCTAssertFalse(editor.isReading(column: left))
        XCTAssertTrue(editor.isReading(column: right))
        try model.savePreferencesNow()
        XCTAssertFalse(try WorkspaceStore(url: store).load().markdownReading)
        editor.columns.activate(right)
        try model.savePreferencesNow()
        XCTAssertTrue(try WorkspaceStore(url: store).load().markdownReading)
        model.closeEditorColumn(right)
        XCTAssertNil(editor.readingByColumn[right])
    }

    func testSideBySideReusesTheSameFileEvenWhenFullOrNarrow() async throws {
        let (model, editor, _) = try await demoModel()
        defer { _ = model.prepareToQuit() }
        let left = editor.columns.activeID
        let right = try XCTUnwrap(editor.columns.split("README.md", from: left, toRight: true, move: false))
        editor.columns.split("README.md", from: right, toRight: true, move: false)
        editor.setReading(true, column: left)
        editor.setReading(false, column: right)
        editor.columns.activate(left)
        model.splitRoom[.editor] = false
        XCTAssertNil(model.markdownSideBySideBlockedReason(column: left))
        model.showMarkdownSideBySide(column: left)
        XCTAssertEqual(editor.columns.columns.count, 3)
        XCTAssertFalse(editor.isReading(column: left))
        XCTAssertTrue(editor.isReading(column: right))
        XCTAssertEqual(editor.columns.activeID, left)
    }

    func testSideBySideIsBlockedWhenNoMatchingColumnFits() async throws {
        let (model, editor, _) = try await demoModel()
        defer { _ = model.prepareToQuit() }
        let source = editor.columns.activeID
        model.splitRoom[.editor] = false
        XCTAssertEqual(model.markdownSideBySideBlockedReason(column: source), "窗口太窄，放不下再一栏")
        model.showMarkdownSideBySide(column: source)
        XCTAssertEqual(editor.columns.columns.count, 1)
        model.splitRoom[.editor] = true
        let other = try XCTUnwrap(editor.columns.split(nil, from: source, toRight: true, move: false))
        editor.columns.split(nil, from: other, toRight: true, move: false)
        editor.columns.activate(source)
        let before = editor.columns
        XCTAssertEqual(model.markdownSideBySideBlockedReason(column: source), "最多拆成 3 栏")
        model.showMarkdownSideBySide(column: source)
        XCTAssertEqual(editor.columns, before)
    }

    func testVisibleReaderFollowsNativeScrollingAndRerenderWithoutTakingFocus() async throws {
        _ = NSApplication.shared
        let workspace = try workspace()
        workspace.showsOutline = false
        let left = workspace.columns.activeID
        let right = try XCTUnwrap(workspace.columns.split("doc.md", from: left, toRight: true, move: false))
        workspace.setReading(false, column: left)
        workspace.columns.activate(left)
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            FileEditorPane(workspace: workspace, onSave: {}, column: left)
            FileEditorPane(workspace: workspace, onSave: {}, column: right)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func views<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, of: type) }
        }
        var editor: NSTextView?
        var reader: WKWebView?
        try await eventually {
            host.layoutSubtreeIfNeeded()
            editor = views(host, of: NSTextView.self).first { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            // The left column's reader is created visible and hides itself a turn later; wait until only the
            // right column's reader is left on screen.
            let readers = views(host, of: WKWebView.self).filter { !$0.isHiddenOrHasHiddenAncestor }
            reader = readers.count == 1 ? readers[0] : nil
            return editor != nil && reader != nil && workspace.editorTopLineByColumn[left] != nil
        }
        let textView = try XCTUnwrap(editor), web = try XCTUnwrap(reader)
        try await eventually {
            (try? await web.evaluateJavaScript("document.querySelectorAll('#doc p').length") as? Int) == 250
        }
        XCTAssertTrue(window.makeFirstResponder(textView))
        let starts = MarkdownReaderView.Coordinator.lineStarts(textView.string)
        textView.setSelectedRange(NSRange(location: starts[160], length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        func readerAtEditor() async -> Bool {
            guard let line = workspace.editorTopLineByColumn[left]?() else { return false }
            let script = "(()=>{let target=null;for(const el of document.querySelectorAll('#doc [data-line]')){if(+el.dataset.line<=\(line))target=el;else break}return target?Math.abs(target.getBoundingClientRect().top)<24:false})()"
            return (try? await web.evaluateJavaScript(script) as? Bool) == true
        }
        try await eventually { await readerAtEditor() }
        // Several quick edits exercise the preview debounce; the final render must use the latest scroll position.
        for word in ["新增", " **重点**", " 内容"] { textView.insertText(word, replacementRange: textView.selectedRange()) }
        let updatedStarts = MarkdownReaderView.Coordinator.lineStarts(textView.string)
        textView.setSelectedRange(NSRange(location: updatedStarts[240], length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        try await eventually {
            let rendered = (try? await web.evaluateJavaScript("document.getElementById('doc').textContent.includes('新增 重点 内容')") as? Bool) == true
            guard rendered else { return false }
            return await readerAtEditor()
        }
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(workspace.columns.activeID, left)
        let selection = textView.selectedRange()
        // A layout/programmatic scroll in the preview must not move the source.
        let editorLine = workspace.editorTopLineByColumn[left]?()
        _ = try await web.evaluateJavaScript("wb.scrollToLine(40,false)")
        try await eventually { workspace.readerTopLineByColumn[right]?["doc.md"] == 40 }
        XCTAssertEqual(workspace.editorTopLineByColumn[left]?(), editorLine)
        // Exercise the same wheel-intent path as an interactive scroll and stay partway into a block.
        // A feedback scroll would snap the preview to the start of that block.
        let readerY = try await web.evaluateJavaScript("""
            (()=>{const p=document.querySelector('#doc [data-line="120"]');
            document.body.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:50}));
            window.scrollTo(0,window.scrollY+p.getBoundingClientRect().top+5);return window.scrollY})()
            """) as? Double
        try await eventually { workspace.editorTopLineByColumn[left]?() == 120 }
        try await Task.sleep(nanoseconds: 150_000_000)
        let finalReaderY = try await web.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertNotNil(readerY)
        XCTAssertEqual(finalReaderY, readerY)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === textView)
        // Bringing an inactive reader forward also leaves the editor's keyboard focus alone.
        workspace.setReading(false, column: right)
        try await Task.sleep(nanoseconds: 300_000_000)
        workspace.setReading(true, column: right)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(window.firstResponder === textView)
    }

    private func workspace(reading: Bool = true) throws -> EditorWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-MarkdownColumns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append(root)
        try (0..<250).map { "第 \($0) 段。\n\n" }.joined().write(to: root.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
        try "# 其他文件\n".write(to: root.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        let workspace = EditorWorkspace(root: root, markdownReading: reading)
        try workspace.open(path: "other.md")
        try workspace.open(path: "doc.md")
        return workspace
    }

    private func demoModel() async throws -> (FolmiModel, EditorWorkspace, URL) {
        let demo = try await DemoRepository.create()
        cleanup.append(demo.root.deletingLastPathComponent())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-MarkdownModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup.append(directory)
        let store = directory.appendingPathComponent("workspace.json")
        let model = FolmiModel(store: WorkspaceStore(url: store))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil && model.editorWorkspace != nil }
        model.editPath("README.md")
        return (model, try XCTUnwrap(model.editorWorkspace), store)
    }

    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while try await condition() == false {
            if Date() > deadline { XCTFail("timed out"); throw FolmiFailure(message: "timed out") }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
