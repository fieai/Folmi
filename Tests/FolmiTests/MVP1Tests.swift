import XCTest
@testable import FolmiCore
@testable import Folmi

final class MarkdownIndexTests: XCTestCase {
    func testHeadingsAndTasksOutsideCode() {
        let text = """
        # Title
        - [ ] open task
        * [x] done task
        1. [ ] numbered task
        ```
        # not a heading
        - [ ] not a task
        ```
        ## Section ##
        -[ ] not a task either
        #nospace
        """
        let entries = MarkdownIndex.parse(text, path: "a.md")
        XCTAssertEqual(entries.map(\.text), ["Title", "open task", "done task", "numbered task", "Section"])
        XCTAssertEqual(entries[0].kind, .heading(1)); XCTAssertEqual(entries[4].kind, .heading(2)); XCTAssertEqual(entries[4].line, 8)
        XCTAssertEqual(entries[2].kind, .task(done: true))
    }

    func testBuildReusesUnchangedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("md-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# A\n- [ ] one\n".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "code".write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let first = MarkdownIndex.build(root: root, paths: ["a.md", "b.swift"], previous: nil)
        XCTAssertEqual(first.files.count, 1); XCTAssertEqual(first.openTasks.count, 1)
        let second = MarkdownIndex.build(root: root, paths: ["a.md", "b.swift"], previous: first)
        XCTAssertEqual(second.revision, first.revision, "unchanged files keep the same index")
        XCTAssertEqual(first.files["a.md"]?.tasks.total, 1)
    }
}

final class PaletteTests: XCTestCase {
    private func item(_ title: String, _ kind: PaletteItem.Kind = .file, subtitle: String = "") -> PaletteItem {
        PaletteItem(id: "\(kind.rawValue):\(title)", kind: kind, title: title, subtitle: subtitle, action: .openFile(title))
    }
    func testRanksTitlePrefixFirstAndFiltersByKind() {
        let items = [item("utility.swift", subtitle: "src/readme"), item("readme.md"), item("提交暂存区", .command), item("Readme heading", .heading)]
        let ranked = PaletteRanking.rank(items, query: "readme", usage: PaletteUsage())
        XCTAssertEqual(ranked.first?.title, "readme.md")
        XCTAssertTrue(ranked.contains { $0.title == "utility.swift" }, "subtitle matches still count")
        XCTAssertEqual(PaletteRanking.rank(items, query: "#read", usage: PaletteUsage()).map(\.title), ["Readme heading"])
        XCTAssertEqual(PaletteRanking.rank(items, query: ">提交", usage: PaletteUsage()).map(\.title), ["提交暂存区"])
        XCTAssertTrue(PaletteRanking.rank(items, query: "zzz", usage: PaletteUsage()).isEmpty)
    }
    func testUsageBoostsWhatYouPick() {
        let items = [item("alpha.md"), item("alpha-notes.md")]
        var usage = PaletteUsage()
        usage.note("file:alpha-notes.md"); usage.note("file:alpha-notes.md")
        XCTAssertEqual(PaletteRanking.rank(items, query: "alpha", usage: usage).first?.title, "alpha-notes.md")
        XCTAssertEqual(PaletteRanking.rank(items, query: "", usage: usage).first?.title, "alpha-notes.md")
    }
    func testFuzzyMultiWordQuery() {
        let items = [item("ReviewFlow.swift", subtitle: "Sources/Folmi/ReviewFlow.swift"), item("Other.swift")]
        XCTAssertEqual(PaletteRanking.rank(items, query: "rvfl", usage: PaletteUsage()).first?.title, "ReviewFlow.swift")
        XCTAssertEqual(PaletteRanking.rank(items, query: "folmi review", usage: PaletteUsage()).first?.title, "ReviewFlow.swift")
    }
}

final class AIEventTests: XCTestCase {
    func testParsesOnlyCompleteLines() throws {
        let event = AIEvent(t: 1, kind: .edit, session: "s", batch: "b", path: "a.txt", tool: "Edit")
        var data = try JSONEncoder().encode(event); data.append(10)
        let half = Data(#"{"t":2,"kind":"st"#.utf8)
        let parsed = AIEventStore.parse(data + half)
        XCTAssertEqual(parsed.events, [event]); XCTAssertEqual(parsed.consumed, data.count)
    }
    func testLocatesLinkedWorktreeGitDir() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locate-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "gitdir: /tmp/main/.git/worktrees/x\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let found = try XCTUnwrap(AIEventStore.locate(from: sub))
        XCTAssertEqual(found.root.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(found.gitDir.path, "/tmp/main/.git/worktrees/x")
    }
}

final class HooksInstallerTests: XCTestCase {
    func testInstallMergesAndUninstallKeepsUserHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = #"{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try mine.write(to: HooksInstaller.settingsURL(root), atomically: true, encoding: .utf8)
        let helper = root.appendingPathComponent("fake-helper")
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("bin/folmi-hook")
        try HooksInstaller.install(root, guarded: true, helper: helper, destination: destination)
        try HooksInstaller.install(root, guarded: true, helper: helper, destination: destination)  // idempotent
        var status = HooksInstaller.status(root)
        XCTAssertTrue(status.installed); XCTAssertTrue(status.guarded)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: HooksInstaller.settingsURL(root))) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2, "user's Stop hook kept, ours added once")
        XCTAssertEqual((hooks["PreToolUse"] as? [Any])?.count, 2)
        XCTAssertNotNil(settings["permissions"])
        try HooksInstaller.uninstall(root)
        status = HooksInstaller.status(root)
        XCTAssertFalse(status.installed)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: HooksInstaller.settingsURL(root))) as? [String: Any])
        XCTAssertEqual(((after["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 1)
        XCTAssertNil((after["hooks"] as? [String: Any])?["PreToolUse"])
    }

    /// A newer App updates the helper that installed hooks run; nothing is installed where there was none.
    func testInstalledHelperFollowsTheBundledOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled"), installed = root.appendingPathComponent("bin/folmi-hook")
        try "new\n".write(to: bundled, atomically: true, encoding: .utf8)
        XCTAssertFalse(try HooksInstaller.refreshInstalledHelper(source: bundled, destination: installed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        try "old\n".write(to: installed, atomically: true, encoding: .utf8)
        XCTAssertTrue(try HooksInstaller.refreshInstalledHelper(source: bundled, destination: installed))
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "new\n")
        XCTAssertFalse(try HooksInstaller.refreshInstalledHelper(source: bundled, destination: installed), "already current")
    }
}

final class AIBatchModelTests: XCTestCase {
    private var cleanup: [URL] = []
    override func tearDown() { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }

    @MainActor
    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            if Date() > deadline { XCTFail(what); throw FolmiFailure(message: what) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    @MainActor
    func testBatchFromHookFilesIsShownAndTakenBack() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanup.append(settings)
        let demo = try await DemoRepository.create()
        cleanup.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("open") { !model.busy && model.snapshot != nil }

        // What folmi-hook would leave behind for one turn that edited README.md and created new.txt.
        let gitDir = try XCTUnwrap(AIEventStore.locate(from: demo.root)).gitDir
        let readme = demo.root.appendingPathComponent("README.md")
        let original = try Data(contentsOf: readme)
        let pre = AIEventStore.preImage("README.md", batch: "b1", gitDir: gitDir)
        try AIEventStore.prepareSnapshot(in: pre.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: pre.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: pre)
        let absent = AIEventStore.absentMarker("new.txt", batch: "b1", gitDir: gitDir)
        try FileManager.default.createDirectory(at: absent.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: absent.path, contents: nil))
        try "changed by agent\n".write(to: readme, atomically: true, encoding: .utf8)
        try "new\n".write(to: demo.root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let events = [AIEvent(t: Date().timeIntervalSince1970 - 2, kind: .start, session: "s", batch: "b1", prompt: "改 README"),
                      AIEvent(t: Date().timeIntervalSince1970 - 1, kind: .edit, session: "s", batch: "b1", path: "README.md", tool: "Edit"),
                      AIEvent(t: Date().timeIntervalSince1970, kind: .stop, session: "s", batch: "b1")]
        let lines = try events.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! + "\n" }.joined()
        try lines.write(to: AIEventStore.events(gitDir: gitDir), atomically: true, encoding: .utf8)

        // The hook's error log: a line already there when the project opened is old; a new one is shown once.
        let errors = AIEventStore.errorLog(gitDir: gitDir)
        try "old line\n".write(to: errors, atomically: true, encoding: .utf8)
        model.readAIEvents()
        XCTAssertFalse(model.activity.contains { $0.title == "Claude 钩子出错" })
        let handle = try FileHandle(forWritingTo: errors)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("没能保存 big.bin 改之前的内容\n".utf8)); try handle.close()
        model.readAIEvents()
        XCTAssertEqual(model.activity.filter { $0.title == "Claude 钩子出错" }.map(\.details), ["没能保存 big.bin 改之前的内容"])
        model.readAIEvents()
        XCTAssertEqual(model.activity.filter { $0.title == "Claude 钩子出错" }.count, 1, "shown once")
        let batch = try XCTUnwrap(model.aiBatches.last)
        XCTAssertEqual(batch.prompt, "改 README"); XCTAssertEqual(Set(batch.restorable), ["README.md", "new.txt"]); XCTAssertTrue(batch.canUndo)
        guard case .finished(let files, _, _)? = model.capsule else { return XCTFail("no finished capsule") }
        XCTAssertEqual(files, 2)
        try await eventually("result captured") { model.aiBatches.last?.expected != nil }

        model.undoLatestAIBatch()
        try await eventually("undo batch") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: readme), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: demo.root.appendingPathComponent("new.txt").path))
        model.undoGitOperation()
        try await eventually("redo agent result") { !model.busy }
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "changed by agent\n")
    }

    /// A turn that ended while the app was closed, then the user edited the same file: reopening must not take the
    /// user's edit for the agent's. With the hook's end snapshot the undo refuses; without one it is not offered.
    @MainActor
    func testBatchEndedWhileClosedNeverOverwritesLaterEdits() async throws {
        for withEndSnapshot in [true, false] {
            let settings = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            cleanup.append(settings)
            let demo = try await DemoRepository.create()
            cleanup.append(demo.root.deletingLastPathComponent())
            let gitDir = try XCTUnwrap(AIEventStore.locate(from: demo.root)).gitDir
            let readme = demo.root.appendingPathComponent("README.md")
            let pre = AIEventStore.preImage("README.md", batch: "b1", gitDir: gitDir)
            try FileManager.default.createDirectory(at: pre.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: readme).write(to: pre)
            try "agent\n".write(to: readme, atomically: true, encoding: .utf8)
            // The stop hook: the files as the turn left them.
            if withEndSnapshot {
                try AIEventStore.snapshotTouched(batch: "b1", root: demo.root, gitDir: gitDir, into: AIEventStore.post(batch: "b1", gitDir: gitDir))
            }
            let then = Date().timeIntervalSince1970 - 600
            let events = [AIEvent(t: then - 2, kind: .start, session: "s", batch: "b1", prompt: "改 README"),
                          AIEvent(t: then - 1, kind: .edit, session: "s", batch: "b1", path: "README.md", tool: "Edit"),
                          AIEvent(t: then, kind: .stop, session: "s", batch: "b1")]
            try events.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! + "\n" }.joined()
                .write(to: AIEventStore.events(gitDir: gitDir), atomically: true, encoding: .utf8)
            try "agent plus HUMAN LATER EDIT\n".write(to: readme, atomically: true, encoding: .utf8)

            let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
            model.aiSettings.autoCommitMessage = false
            model.open(demo.root, environment: demo.environment, demo: true)
            try await eventually("open") { !model.busy && model.snapshot != nil }
            model.readAIEvents()
            try await eventually("result read") { model.aiBatches.last.map { $0.expected != nil || $0.resultUnknown } == true }
            XCTAssertEqual(model.aiBatches.last?.resultUnknown, !withEndSnapshot)
            model.undoLatestAIBatch()
            try await eventually("undo") { !model.busy }
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "agent plus HUMAN LATER EDIT\n")
        }
    }
}
