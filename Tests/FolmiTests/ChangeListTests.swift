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

    func testLargeListDefaultsToCollapsedFolders() {
        let files = (0..<5_000).map {
            FileChange(path: "Folder\($0 / 100)/file\($0).txt", indexCode: "?", worktreeCode: "?")
        }
        XCTAssertEqual(ChangeListRow.rows(files, grouped: false, collapsed: []).count, 50)
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

    func testAutomaticGroupingThresholdAndRowCache() {
        let limit = ChangeListRow.automaticGroupingThreshold
        let files = (0..<limit).map {
            FileChange(path: "Folder/file\($0).txt", indexCode: "?", worktreeCode: "?")
        }
        let flat = files.map { ChangeListRow.file($0, depth: 0) }
        XCTAssertEqual(ChangeListRow.rows(files, grouped: false, collapsed: []), flat)
        XCTAssertEqual(ChangeListRow.rows(files, grouped: true, collapsed: []),
                       [.folder("Folder", depth: 0, expanded: true)] + files.map { .file($0, depth: 1) })
        let over = files + [FileChange(path: "Folder/extra.txt", indexCode: "?", worktreeCode: "?")]
        XCTAssertEqual(ChangeListRow.rows(over, grouped: false, collapsed: []), [.folder("Folder", depth: 0, expanded: false)])
        let cache = ChangeListRowCache()
        let rows = cache.rows(over, grouped: false, collapsed: [], expanded: [])
        for _ in 0..<10 { XCTAssertEqual(cache.rows(over, grouped: false, collapsed: [], expanded: []), rows) }
        XCTAssertEqual(cache.computationCount, 1)
        XCTAssertEqual(cache.rows(over, grouped: false, collapsed: [], expanded: ["Folder"]).count, over.count + 1)
        XCTAssertEqual(cache.computationCount, 2)
    }

    func testPreparedProjectionKeepsCountsAndSearchFresh() async throws {
        let files = (0...ChangeListRow.automaticGroupingThreshold).map {
            FileChange(path: "Folder/child/file\($0).txt", indexCode: "?", worktreeCode: "?")
        }
        func snapshot(_ files: [FileChange], fingerprint: String) -> RepositorySnapshot {
            RepositorySnapshot(root: URL(fileURLWithPath: "/tmp/folmi-projection"), branch: "main", head: nil,
                               files: files, commits: [], branches: [], remotes: [], fingerprint: fingerprint)
        }
        let first = snapshot(files, fingerprint: "first")
        let prepared = await ChangeListInput.prepare(first)
        let input = try XCTUnwrap(prepared)
        let cache = ChangeListRowCache()
        for _ in 0..<10 {
            let filtered = cache.files(first, in: .working, query: "", prepared: input.working)
            XCTAssertEqual(cache.rows(filtered, grouped: false, collapsed: [], expanded: [], prepared: input.working),
                           [.folder("Folder", depth: 0, expanded: false)])
        }
        XCTAssertEqual(cache.computationCount, 1)
        XCTAssertEqual(cache.counts["Folder"], files.count)
        XCTAssertEqual(cache.files(first, in: .working, query: "file500.txt").map(\.path), ["Folder/child/file500.txt"])
        XCTAssertTrue(cache.files(first, in: .staged, query: "").isEmpty)
        let second = snapshot(Array(files.prefix(2)), fingerprint: "second")
        XCTAssertEqual(cache.files(second, in: .working, query: "").count, 2)
    }

    @MainActor
    func testLargeRenderedListRowBoundHeartbeatFoldingCountsAndSearch() async throws {
        let fixture = try await makeLargeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let rendered = RenderedChanges(fixture: fixture, snapshot: fixture.base)
        defer { rendered.close() }
        // Navigation while small must not pre-open old folders when the list first becomes large.
        rendered.model.selectFiles(["Sources/Greeting.swift"], in: .working)
        try await Task.sleep(for: .milliseconds(150))
        rendered.model.selectFiles(["Notes.txt"], in: .working)
        try await Task.sleep(for: .milliseconds(350))
        let heartbeat = MainThreadHeartbeat()
        let start = ContinuousClock.now
        rendered.model.snapshot = fixture.snapshot
        let expected = workingOffset(fixture.snapshot) + largeWorkingRows(fixture.snapshot).count
        let table = try await rendered.waitForRows(expected)
        await rendered.afterFrame()
        heartbeat.stop()
        let elapsed = start.duration(to: .now)
        print("T2 maximum main-thread interval: \(heartbeat.maximumIntervalMilliseconds) ms; elapsed: \(elapsed)")
        XCTAssertLessThanOrEqual(table.numberOfRows, 80)
        XCTAssertLessThanOrEqual(heartbeat.maximumIntervalMilliseconds, 250)
        XCTAssertLessThan(elapsed, .seconds(1))
        let collapsedCount = table.numberOfRows
        try await Task.sleep(for: .milliseconds(350))
        table.scroll(.zero)
        await rendered.afterFrame()
        let text = try ScreenText.read(rendered.host)
        XCTAssertTrue(text.contains("Archive"), text)
        // Archive has 50 direct files, 25 one level down, and 25 two levels down.
        let countedRow = try XCTUnwrap(table.rowView(atRow: workingOffset(fixture.snapshot), makeIfNecessary: true))
        let countText = try ScreenText.read(countedRow)
        XCTAssertTrue(countText.contains("Archive"), countText)
        XCTAssertTrue(countText.contains("100"), countText)
        XCTAssertEqual(ChangeListTree(fixture.snapshot.files.filter(\.hasWorking)).counts["Archive"], 100)
        let folder = workingOffset(fixture.snapshot) + (try XCTUnwrap(largeWorkingRows(fixture.snapshot).firstIndex {
            $0.id == "folder:Folder01"
        }))
        try await rendered.clickRow(folder, in: table)
        XCTAssertEqual(table.numberOfRows, collapsedCount + 100)
        table.scrollRowToVisible(folder + 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try ScreenText.read(rendered.host).contains("Sample.txt"))
        // A fresh snapshot keeps the user's expansion choice.
        rendered.model.snapshot = try await fixture.repository.load()
        _ = try await rendered.waitForRows(collapsedCount + 100)
        try await rendered.clickRow(folder, in: table)
        XCTAssertEqual(table.numberOfRows, collapsedCount)

        rendered.model.fileSearch = "Match"
        _ = try await rendered.waitForRows(workingOffset(fixture.snapshot, stagedCount: 0) + 3)
        try await Task.sleep(for: .milliseconds(350))
        let searchText = try ScreenText.read(rendered.host)
        for color in ["Red", "Blue", "Green"] { XCTAssertTrue(searchText.contains(color + ".txt"), searchText) }
        rendered.model.fileSearch = "file"
        _ = try await rendered.waitForRows(workingOffset(fixture.snapshot, stagedCount: 0) + 50)
        rendered.model.fileSearch = ""
        _ = try await rendered.waitForRows(collapsedCount)
        // Search follows the user's folder layout too, expanding all three matching paths.
        rendered.layout.grouped = true
        rendered.model.fileSearch = "Match"
        _ = try await rendered.waitForRows(workingOffset(fixture.snapshot, stagedCount: 0) + 4)
        try await Task.sleep(for: .milliseconds(350))
        let groupedText = try ScreenText.read(rendered.host)
        XCTAssertTrue(groupedText.contains("Green.txt"), groupedText)
        rendered.model.fileSearch = ""
        _ = try await rendered.waitForRows(collapsedCount)
    }

    @MainActor
    func testOpeningTwoThousandFileFolderDoesNotStall() async throws {
        let fixture = try await makeLargeRepository(bulkFiles: 2_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let rendered = RenderedChanges(fixture: fixture, snapshot: fixture.snapshot)
        defer { rendered.close() }
        let count = workingOffset(fixture.snapshot) + largeWorkingRows(fixture.snapshot).count
        let table = try await rendered.waitForRows(count)
        let row = workingOffset(fixture.snapshot) + (try XCTUnwrap(largeWorkingRows(fixture.snapshot).firstIndex { $0.id == "folder:Bulk" }))
        try await Task.sleep(for: .milliseconds(350))
        let heartbeat = MainThreadHeartbeat()
        try rendered.sendClickRow(row, in: table)
        _ = try await rendered.waitForRows(count + 2_000, timeout: 3)
        await rendered.afterFrame()
        heartbeat.stop()
        print("T4 maximum main-thread interval: \(heartbeat.maximumIntervalMilliseconds) ms")
        XCTAssertLessThanOrEqual(heartbeat.maximumIntervalMilliseconds, 1_000)
    }

    @MainActor
    func testSelectingDeepFileRevealsAndScrollsWithoutOpeningOtherFolders() async throws {
        let fixture = try await makeLargeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let rendered = RenderedChanges(fixture: fixture, snapshot: fixture.snapshot)
        defer { rendered.close() }
        let count = workingOffset(fixture.snapshot) + largeWorkingRows(fixture.snapshot).count
        _ = try await rendered.waitForRows(count)
        let path = "Archive/Nested/Deep/DeepTarget.txt"
        rendered.model.selectFiles([path], in: .working)
        let opened: Set<String> = ["Archive", "Archive/Nested", "Archive/Nested/Deep"]
        let rows = largeWorkingRows(fixture.snapshot, expanded: opened)
        let table = try await rendered.waitForRows(workingOffset(fixture.snapshot) + rows.count)
        try await Task.sleep(for: .milliseconds(200))
        let index = workingOffset(fixture.snapshot) + (try XCTUnwrap(rows.firstIndex { $0.fileID == path }))
        XCTAssertTrue(table.selectedRowIndexes.contains(index), "Selected rows: \(table.selectedRowIndexes), wanted \(index)")
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: index)))
        let selectedText = try ScreenText.read(rendered.host)
        XCTAssertTrue(selectedText.contains("DeepTarget.txt"), selectedText)
        XCTAssertEqual(rows.filter { if case .folder(_, _, true) = $0 { return true }; return false }.count, 3)
        // Manually folding after a reveal stays folded, including across a status refresh.
        table.scrollRowToVisible(workingOffset(fixture.snapshot))
        try await rendered.clickRow(workingOffset(fixture.snapshot), in: table)
        XCTAssertEqual(table.numberOfRows, count)
        rendered.model.snapshot = try await fixture.repository.load()
        _ = try await rendered.waitForRows(count)
        try await rendered.clickRow(workingOffset(fixture.snapshot), in: table)
        XCTAssertEqual(table.numberOfRows, count + 51)

        rendered.model.fileSearch = "NoMatchingFiles"
        try await Task.sleep(for: .milliseconds(250))
        rendered.model.selectFiles(["Archive/Nested/Deep/file075.txt"], in: .working)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(rendered.model.fileSearch, "NoMatchingFiles")
        XCTAssertNil(rendered.table(in: rendered.host))
    }

    @MainActor
    func testRevealingRestoredSelectionKeepsTheCurrentContent() async throws {
        let fixture = try await makeLargeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let path = "Archive/Nested/Deep/DeepTarget.txt"
        let rendered = RenderedChanges(fixture: fixture, snapshot: fixture.snapshot, selectedPath: path, content: .editor)
        defer { rendered.close() }
        let rows = largeWorkingRows(fixture.snapshot, expanded: ["Archive", "Archive/Nested", "Archive/Nested/Deep"])
        _ = try await rendered.waitForRows(workingOffset(fixture.snapshot) + rows.count)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(rendered.model.selectedFileID, path)
        XCTAssertEqual(rendered.model.content, .editor, "Revealing a restored selection must not navigate away from the editor")
    }

    @MainActor
    func testLargeListDisablesLayoutToggleAndRestoresFlatPreference() async throws {
        // XCTest has no accessibility client; opt in so SwiftUI builds the app's semantic tree.
        let accessibilitySetter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        let previous = NSApplication.shared.perform(NSSelectorFromString("accessibilityAttributeValue:"),
                                                    with: "AXEnhancedUserInterface")?.takeUnretainedValue() ?? NSNumber(value: false)
        NSApplication.shared.perform(accessibilitySetter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { NSApplication.shared.perform(accessibilitySetter, with: previous, with: "AXEnhancedUserInterface") }
        let fixture = try await makeLargeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let rendered = RenderedChanges(fixture: fixture, snapshot: fixture.snapshot)
        defer { rendered.close() }
        _ = try await rendered.waitForRows(workingOffset(fixture.snapshot) + largeWorkingRows(fixture.snapshot).count)
        try await Task.sleep(for: .milliseconds(350))
        let toggle = try XCTUnwrap(rendered.layoutButton())
        XCTAssertEqual(toggle.enabled, false)
        XCTAssertEqual(toggle.help, "改动超过 \(ChangeListRow.automaticGroupingThreshold) 个，只能按文件夹展示。")
        try await rendered.clickLayoutToggle()
        XCTAssertFalse(rendered.layout.grouped)
        for index in 0..<50 { try FileManager.default.removeItem(at: fixture.demo.root.appendingPathComponent(index == 0 ? "Archive" : String(format: "Folder%02d", index))) }
        rendered.model.snapshot = try await fixture.repository.load()
        _ = try await rendered.waitForRows(workingOffset(fixture.base) + fixture.base.files.filter(\.hasWorking).count)
        let restored = try XCTUnwrap(rendered.layoutButton())
        XCTAssertEqual(restored.enabled, true)
        XCTAssertEqual(restored.help, "切换为按文件夹展示")
        XCTAssertFalse(rendered.layout.grouped)
        try await rendered.clickLayoutToggle()
        XCTAssertTrue(rendered.layout.grouped)
    }

    private struct LargeRepository {
        let demo: DemoRepository
        let repository: GitRepository
        let base: RepositorySnapshot
        let snapshot: RepositorySnapshot
        var directory: URL { demo.root.deletingLastPathComponent() }
    }

    private func makeLargeRepository(bulkFiles: Int = 0) async throws -> LargeRepository {
        let demo = try await DemoRepository.create()
        let repository = GitRepository(url: demo.root, environment: demo.environment)
        let base = try await repository.load()
        for folder in 0..<50 {
            for index in 0..<100 {
                let parent = (folder == 0 ? "Archive" : String(format: "Folder%02d", folder)) + (folder == 0 && index >= 50 ? (index >= 75 ? "/Nested/Deep" : "/Nested") : "")
                let name = folder == 0 && index == 99 ? "DeepTarget.txt" : folder == 2 && index < 3 ? "Match" + ["Red", "Blue", "Green"][index] + ".txt" : (index == 0 ? "Sample.txt" : String(format: "file%03d.txt", index))
                let url = demo.root.appendingPathComponent(parent).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("small\n".utf8).write(to: url)
            }
        }
        if bulkFiles > 0 {
            let bulk = demo.root.appendingPathComponent("Bulk")
            try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
            for index in 0..<bulkFiles { try Data().write(to: bulk.appendingPathComponent("bulk\(index).txt")) }
        }
        return LargeRepository(demo: demo, repository: repository, base: base, snapshot: try await repository.load())
    }

    private func largeWorkingRows(_ snapshot: RepositorySnapshot, expanded: Set<String> = []) -> [ChangeListRow] {
        ChangeListRow.rows(snapshot.files.filter(\.hasWorking), grouped: false, collapsed: [], expanded: expanded)
    }

    private func workingOffset(_ snapshot: RepositorySnapshot, stagedCount: Int? = nil) -> Int {
        2 + max(1, stagedCount ?? snapshot.files.filter(\.hasStaged).count)
    }

    @MainActor
    private final class LayoutPreference: ObservableObject {
        @Published var grouped = false
    }

    private struct LargeHostedChangesPane: View {
        let model: FolmiModel
        @ObservedObject var layout: LayoutPreference
        var body: some View { ChangesPane(model: model, groupByFolder: $layout.grouped) }
    }

    @MainActor
    private final class RenderedChanges {
        let model: FolmiModel
        let layout = LayoutPreference()
        let host: NSHostingView<LargeHostedChangesPane>
        let window: NSWindow

        init(fixture: LargeRepository, snapshot: RepositorySnapshot, selectedPath: String? = nil, content: FolmiContent = .diff) {
            model = FolmiModel(store: WorkspaceStore(url: fixture.directory.appendingPathComponent("workspace.json")), autoRefresh: false)
            model.repositoryURL = fixture.demo.root
            model.repository = fixture.repository
            model.snapshot = snapshot
            if let selectedPath { model.selectedFileIDs = [selectedPath]; model.selectedFileID = selectedPath }
            model.content = content
            host = NSHostingView(rootView: LargeHostedChangesPane(model: model, layout: layout))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 850),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
        }

        func close() { window.orderOut(nil); window.contentView = nil }

        func table(in view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap { self.table(in: $0) }.first
        }

        func waitForRows(_ count: Int, timeout: TimeInterval = 1) async throws -> NSTableView {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                if let table = table(in: host), table.numberOfRows == count { return table }
                try await Task.sleep(for: .milliseconds(10))
            }
            let table = try XCTUnwrap(table(in: host))
            XCTAssertEqual(table.numberOfRows, count)
            return table
        }

        func afterFrame() async {
            await withCheckedContinuation { continuation in
                PerfLog.afterFrame {
                    self.host.layoutSubtreeIfNeeded(); self.host.displayIfNeeded()
                    continuation.resume()
                }
            }
        }

        func sendClick(_ point: NSPoint) throws {
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
        }

        func positionRow(_ row: Int, in table: NSTableView) {
            // A merely visible row can sit underneath a floating section header and receive no click.
            let y = max(0, table.rect(ofRow: row).midY - table.visibleRect.height / 2)
            table.scroll(NSPoint(x: 0, y: y))
            host.layoutSubtreeIfNeeded()
        }

        func sendClickRow(_ row: Int, in table: NSTableView) throws {
            positionRow(row, in: table)
            try sendClick(table.convert(NSPoint(x: 70, y: table.rect(ofRow: row).midY), to: nil))
        }

        func clickRow(_ row: Int, in table: NSTableView) async throws {
            positionRow(row, in: table)
            await afterFrame()
            try sendClickRow(row, in: table)
            await afterFrame()
            try await Task.sleep(for: .milliseconds(200))
        }

        func clickLayoutToggle() async throws {
            try sendClick(NSPoint(x: host.bounds.width - 10 - Metrics.iconButton / 2,
                                  y: host.bounds.height - 10 - Metrics.iconButton / 2))
            try await Task.sleep(for: .milliseconds(200))
        }

        func layoutButton() -> (enabled: Bool?, help: String?)? {
            func attribute(_ object: NSObject, _ name: String) -> Any? {
                guard object.responds(to: NSSelectorFromString(name)) else { return nil }
                return object.value(forKey: name)
            }
            func find(_ value: Any, depth: Int = 0) -> (enabled: Bool?, help: String?)? {
                guard depth < 30, let object = value as? NSObject else { return nil }
                if attribute(object, "accessibilityIdentifier") as? String == "changes.layout" {
                    return (attribute(object, "isAccessibilityEnabled") as? Bool,
                            attribute(object, "accessibilityHelp") as? String)
                }
                for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
                    if let result = find(child, depth: depth + 1) { return result }
                }
                return nil
            }
            return find(host)
        }
    }

    private struct HostedChangesPane: View {
        let model: FolmiModel
        let clipboard: NSPasteboard
        @State private var groupByFolder = false
        var body: some View { ChangesPane(model: model, groupByFolder: $groupByFolder, filePasteboard: clipboard) }
    }
}
