import AppKit
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

final class ChangeListTests: XCTestCase {
    @MainActor
    func testCopyFilesWritesFileURLsForFinderAndKeepsClipboardOnMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["a space.txt", "改动.swift"].map { directory.appendingPathComponent($0) }
        for url in urls { try Data().write(to: url) }
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }

        XCTAssertTrue(FileActionsMenu.copyFiles(urls, to: clipboard))
        let copied = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(copied?.map(\.path), urls.map(\.path))
        XCTAssertFalse(FileActionsMenu.copyFiles([urls[0], directory.appendingPathComponent("deleted.txt")], to: clipboard))
        XCTAssertEqual(clipboard.pasteboardItems?.count, 2)
    }

    func testGroupingKeepsFileAndFolderAtTheSamePath() {
        let deleted = FileChange(path: "docs", indexCode: "D", worktreeCode: ".")
        let added = FileChange(path: "docs/reference/guide.md", indexCode: "A", worktreeCode: ".")
        let files = [deleted, added]
        let open = ChangeListRow.rows(files, grouped: true, collapsed: [])
        XCTAssertEqual(open, [
            .folder("docs", depth: 0, expanded: true),
            .folder("docs/reference", depth: 1, expanded: true),
            .file(added, depth: 2),
            .file(deleted, depth: 0),
        ])
        XCTAssertEqual(Set(open.map(\.id)).count, open.count)
        XCTAssertEqual(ChangeListRow.rows(files, grouped: true, collapsed: ["docs"]),
                       [.folder("docs", depth: 0, expanded: false), .file(deleted, depth: 0)])
        XCTAssertEqual(ChangeListRow.rows(files, grouped: false, collapsed: ["docs"]),
                       [.file(deleted, depth: 0), .file(added, depth: 0)])
    }

    @MainActor
    func testSwitchingAndFoldingTheRenderedChangesList() async throws {
        let demo = try await DemoRepository.create()
        let directory = demo.root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = demo.root.appendingPathComponent("Guides/Reference")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = "Guides/Reference/Handbook.txt"
        try "Read me\n".write(to: demo.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")), autoRefresh: false)
        model.repositoryURL = demo.root
        let repository = GitRepository(url: demo.root, environment: demo.environment)
        model.repository = repository
        model.snapshot = try await repository.load()
        model.selectFiles([path], in: .working)

        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let host = NSHostingView(rootView: HostedChangesPane(model: model, clipboard: clipboard))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }

        func findTable(in view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        func click(at point: NSPoint) async throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            window.sendEvent(try event(.leftMouseDown))
            while let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                if release.windowNumber == window.windowNumber { window.sendEvent(release) }
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        try await Task.sleep(for: .milliseconds(350))
        let table = try XCTUnwrap(findTable(in: host))
        let flatRowCount = table.numberOfRows
        let toggle = NSPoint(x: host.bounds.width - 10 - Metrics.iconButton / 2,
                             y: host.bounds.height - 10 - Metrics.iconButton / 2)
        try await click(at: toggle)
        XCTAssertEqual(table.numberOfRows, flatRowCount + 3)
        XCTAssertEqual(model.selectedFileIDs, [path])
        let folderRow = table.rect(ofRow: 3)
        try await click(at: table.convert(NSPoint(x: 70, y: folderRow.midY), to: nil))
        XCTAssertEqual(table.numberOfRows, flatRowCount + 1)
        XCTAssertEqual(model.selectedFileIDs, [path])

        model.fileSearch = "Handbook"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try ScreenText.read(host).contains("Handbook.txt"))
        model.fileSearch = ""
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(table.numberOfRows, flatRowCount + 1)

        try await click(at: toggle)
        XCTAssertEqual(table.numberOfRows, flatRowCount)
        XCTAssertEqual(model.selectedFileIDs, [path])

        try await click(at: toggle)
        model.selectFiles(["Notes.txt"], in: .working)
        model.fileSearch = "Handbook"
        try await Task.sleep(for: .milliseconds(300))
        // An inactive XCTest window can handle buttons, but AppKit only selects table rows with the mouse in a key window.
        table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 1), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.selectedFileIDs, [path])
        window.makeFirstResponder(table)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)))
        let copied = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(copied?.map(\.path), [demo.root.appendingPathComponent(path).path])
        model.toggleStageSelectedFiles()
        let deadline = Date().addingTimeInterval(5)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
        let staged = try await repository.load().files.first { $0.path == path }
        XCTAssertEqual(staged?.hasStaged, true)
        XCTAssertEqual(staged?.hasWorking, false)
    }

    private struct HostedChangesPane: View {
        let model: FolmiModel
        let clipboard: NSPasteboard
        @State private var groupByFolder = false
        var body: some View { ChangesPane(model: model, groupByFolder: $groupByFolder, filePasteboard: clipboard) }
    }
}
