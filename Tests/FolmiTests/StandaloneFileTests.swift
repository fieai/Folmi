import AppKit
import XCTest
@testable import Folmi

final class StandaloneFileTests: XCTestCase {
    @MainActor
    func testStandaloneWindowRendersAndSavesAFileOutsideGit() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("独立笔记 #1.txt")
        let other = root.appendingPathComponent("other.txt")
        try "Standalone file\n".write(to: file, atomically: true, encoding: .utf8)
        try "Another file\n".write(to: other, atomically: true, encoding: .utf8)
        let model = FolmiModel(store: WorkspaceStore(url: root.appendingPathComponent("workspace.json")))
        model.gitStartupState = .checking
        var request = URLComponents()
        request.scheme = "folmi"
        request.host = "finder-open"
        request.queryItems = [URLQueryItem(name: "path", value: file.path)]
        model.handleExternalOpen(try XCTUnwrap(request.url))
        let opened = NSApplication.shared.windows.first {
            $0.representedURL?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath()
        }
        let controller = try XCTUnwrap(opened?.windowController as? StandaloneFileWindow)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        let deadline = Date().addingTimeInterval(3)
        while findEditor(in: host) == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let editor = try XCTUnwrap(findEditor(in: host))
        XCTAssertEqual(editor.string, "Standalone file\n")
        XCTAssertNil(model.repositoryURL)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertThrowsError(try controller.workspace.open(path: other.lastPathComponent))

        window.makeFirstResponder(editor)
        editor.insertText("Edited: ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.workspace.hasUnsavedChanges)
        XCTAssertTrue(try model.standaloneFiles.show(file, using: model) === controller)

        let save = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(window.performKeyEquivalent(with: save))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Edited: Standalone file\n")
        XCTAssertFalse(controller.workspace.hasUnsavedChanges)

        editor.insertText("Draft: ", replacementRange: NSRange(location: 0, length: 0))
        try "External change\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(controller.save())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "External change\n")
        XCTAssertEqual(controller.workspace.selectedDocument?.text, "Draft: Edited: Standalone file\n")
    }

    @MainActor
    private func findEditor(in view: NSView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }
}
