import XCTest
import FolmiCore
@testable import Folmi

/// Pulling from the demo's disposable bare remote: preview, fast-forward, ⌘Z back to before the pull.
final class PullFlowTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)"); throw FolmiFailure(message: description) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    @MainActor
    func testPreviewPullThenUndoReturnsToBeforeThePull() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-PullTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create(remoteUpdates: true)
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil }
        let before = try XCTUnwrap(model.snapshot)
        let changed = before.files.map(\.path)

        model.preparePull()
        XCTAssertTrue(model.showPull)
        try await eventually("读取拉取计划") { !model.pullLoading }
        let plan = try XCTUnwrap(model.pullPlan, model.pullProblem ?? "")
        XCTAssertEqual(plan.behind, 1); XCTAssertEqual(plan.ahead, 0)
        XCTAssertEqual(model.pullKind, .fastForward)
        XCTAssertEqual(plan.command(.fastForward), "git merge --ff-only demo/main")
        XCTAssertTrue(model.canPull, model.pullBlockedReason ?? "")

        model.runPull()
        try await eventually("拉取完成") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.showPull)
        XCTAssertEqual(model.snapshot?.behind, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: demo.root.appendingPathComponent("docs/team.md").path))
        XCTAssertEqual(model.snapshot?.files.map(\.path), changed, "没提交的改动原样保留")
        XCTAssertEqual(model.undoLabel, "拉取 demo/main")

        model.undoGitOperation()
        try await eventually("撤销拉取") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.head, before.head)
        XCTAssertEqual(model.snapshot?.files, before.files)
        XCTAssertEqual(model.snapshot?.behind, 1, "撤销后又落后远端一个提交")
        XCTAssertFalse(FileManager.default.fileExists(atPath: demo.root.appendingPathComponent("docs/team.md").path))
    }
}
