import AppKit
import XCTest
@testable import Folmi
@testable import FolmiCore

final class CommitComposerTests: XCTestCase {
    @MainActor
    func testPaneFocusHandsTheOpenComposerItsKeyboardInput() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        let table = NSTableView(frame: NSRect(x: 0, y: 150, width: 420, height: 350))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        let message = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        root.addSubview(table); root.addSubview(message)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let tracker = PaneFocusTracker()
        tracker.register(root, for: .changes)

        tracker.makeFirstResponder(.changes)
        XCTAssertTrue(window.firstResponder === table)
        tracker.makeFirstResponder(.changes, preferCommitEditor: true)
        XCTAssertTrue(window.firstResponder === message)
        message.insertText("12345", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(message.string, "12345")
    }

    @MainActor
    func testShortcutRevealsAnUnseenDraftInsteadOfCommittingIt() async throws {
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let model = FolmiModel(store: WorkspaceStore(url: demo.root.deletingLastPathComponent().appendingPathComponent("workspace.json")))
        let repository = GitRepository(url: demo.root, environment: demo.environment)
        model.repository = repository
        model.repositoryURL = demo.root
        model.snapshot = try await repository.load()
        model.draftMessage = "Generated message not yet read"
        model.paneLayout.sideTab = .files
        model.paneLayout.close(.changes)
        let head = try await repository.currentHead()

        model.handleCommitShortcut()

        XCTAssertTrue(model.showCommitComposer)
        XCTAssertEqual(model.paneFocusRequest?.prefersCommitEditor, true)
        XCTAssertEqual(model.paneLayout.sideTab, .changes)
        XCTAssertTrue(model.paneLayout.isShown(.changes))
        XCTAssertEqual(model.draftMessage, "Generated message not yet read")
        XCTAssertFalse(model.busy)
        let after = try await repository.currentHead()
        XCTAssertEqual(after, head)
    }
}
