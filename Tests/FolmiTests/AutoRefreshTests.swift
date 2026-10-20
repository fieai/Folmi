import XCTest
import FolmiCore
@testable import Folmi

final class AutoRefreshTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    func testWatcherIgnoresGitInternalsLocksAndDependencyFolders() {
        XCTAssertTrue(RepositoryWatcher.isRelevant("/repo/Sources/app.swift"))
        XCTAssertFalse(RepositoryWatcher.isGitPath("/repo/Sources/app.swift", gitDirectories: []))
        XCTAssertTrue(RepositoryWatcher.isGitPath("/repo/.git/refs/heads/main", gitDirectories: []))
        XCTAssertTrue(RepositoryWatcher.isGitPath("/elsewhere/worktrees/wt/HEAD", gitDirectories: ["/elsewhere/"]))
        XCTAssertTrue(RepositoryWatcher.isRelevant("/repo/.git/index"))
        XCTAssertTrue(RepositoryWatcher.isRelevant("/repo/.git/HEAD"))
        XCTAssertTrue(RepositoryWatcher.isRelevant("/repo/.git/refs/heads/main"))
        XCTAssertTrue(RepositoryWatcher.isRelevant("/main/.git/worktrees/feature/index"))
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/.git/index.lock"))
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/.git/objects/ab/cdef"))
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/.git/logs/HEAD"))
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/web/node_modules/pkg/index.js"))
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/.build/debug/app.o"))
    }

    @MainActor
    func testOutsideChangesRefreshQuietlyAndKeepUnaffectedLineSelection() async throws {
        let model = FolmiModel(store: try makeStore(), autoRefresh: true)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil && !model.fileDiffs.isEmpty }

        let diff = try XCTUnwrap(model.fileDiffs.first { $0.isPartialSupported })
        let line = try XCTUnwrap(diff.hunks.flatMap(\.lines).first { $0.kind == .addition || $0.kind == .deletion })
        model.toggleLine(line.id, in: diff)
        XCTAssertEqual(model.selectedLines[diff.file.path], [line.id])

        // Unchanged status: nothing is replaced.
        model.refreshInBackground()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.autoRefreshCount, 0)

        // A new file written by another tool shows up without ⌘R, and the selected lines of the untouched file survive.
        try "outside\n".write(to: demo.root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try await eventually("文件监听发现新文件") { model.snapshot?.files.contains { $0.path == "outside.txt" } == true }
        try await eventually("后台刷新结束") { model.autoRefreshCount >= 1 }
        XCTAssertEqual(model.selectedLines[diff.file.path], [line.id])
        XCTAssertNil(model.errorMessage)

        // Changing the selected file itself drops its now-stale line selection.
        let target = demo.root.appendingPathComponent(diff.file.path)
        try (try String(contentsOf: target, encoding: .utf8) + "appended by another tool\n").write(to: target, atomically: true, encoding: .utf8)
        try await eventually("选中文件改动后丢弃过期选择") { model.selectedLines[diff.file.path] == nil }
        XCTAssertTrue(model.fileDiffs.first { $0.file.path == diff.file.path }?.rawPatch.contains("appended by another tool") == true)

        // A commit made in a terminal moves HEAD; the history and status follow.
        let oldHead = model.snapshot?.head
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", demo.root.path, "commit", "-qam", "terminal commit"]
        git.environment = ProcessInfo.processInfo.environment.merging(demo.environment) { _, new in new }
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        try await eventually("终端提交后 HEAD 更新") { model.snapshot?.head != oldHead && model.snapshot?.commits.first?.subject == "terminal commit" }
    }

    @MainActor
    func testModelsWithoutAutoRefreshDoNotWatch() async throws {
        let model = FolmiModel(store: try makeStore())
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil }
        try "outside\n".write(to: demo.root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(model.snapshot?.files.contains { $0.path == "outside.txt" } == true)
        XCTAssertEqual(model.autoRefreshCount, 0)
    }

    private func makeStore() throws -> WorkspaceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-AutoRefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        return WorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 8,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)", file: file, line: line); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
