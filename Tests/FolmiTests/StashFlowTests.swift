import XCTest
import FolmiCore
@testable import Folmi

/// 临时收起改动 through the model: stash, ⌘Z, and "先收起改动再撤回" from history.
final class StashFlowTests: XCTestCase {
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
    private func openDemo() async throws -> (FolmiModel, DemoRepository) {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-StashTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil }
        return (model, demo)
    }

    @MainActor
    func testStashAllThenUndoBringsEverythingBack() async throws {
        let (model, _) = try await openDemo()
        let before = try XCTUnwrap(model.snapshot)
        XCTAssertFalse(before.files.isEmpty)
        model.stashAllChanges()
        try await eventually("收起") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.files.isEmpty, true)
        XCTAssertEqual(model.snapshot?.stashCount, 1)
        XCTAssertTrue(model.undoLabel?.hasPrefix("收起改动") == true)

        model.openStashes()
        try await eventually("读取列表") { model.stashEntries.count == 1 }
        XCTAssertEqual(model.stashFileLists[model.stashEntries[0].id]?.contains("Notes.txt"), true)

        model.undoGitOperation()
        try await eventually("撤销收起") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.files, before.files, "暂存和未暂存的部分都原样回来")
        XCTAssertEqual(model.snapshot?.stashCount, 0)
    }

    /// 「放回」 brings the newest stash back without opening the list.
    @MainActor
    func testPutBackRestoresTheNewestStash() async throws {
        let (model, _) = try await openDemo()
        let before = try XCTUnwrap(model.snapshot)
        model.stashAllChanges()
        try await eventually("收起") { !model.busy && model.snapshot?.stashCount == 1 }
        model.popLatestStash()
        try await eventually("放回") { !model.busy && model.snapshot?.stashCount == 0 }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.files, before.files)
    }

    @MainActor
    func testStashThenRevertIsTwoUndoSteps() async throws {
        let (model, demo) = try await openDemo()
        let before = try XCTUnwrap(model.snapshot)
        let id = try await CommandRunner.git(["log", "--format=%H", "-1", "--grep=添加更新记录"], at: demo.root, environment: demo.environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        model.stashThenApplyCommit(id, kind: .revert)
        try await eventually("收起并撤回") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.stashCount, 1)
        XCTAssertEqual(model.snapshot?.files.map(\.path), ["docs/changes.md"])
        XCTAssertTrue(model.draftMessage.hasPrefix("Revert"))

        model.undoGitOperation()
        try await eventually("撤销撤回") { !model.busy }
        XCTAssertEqual(model.snapshot?.files.isEmpty, true)
        model.undoGitOperation()
        try await eventually("撤销收起") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.files, before.files)
        XCTAssertEqual(model.snapshot?.stashCount, 0)
    }

    @MainActor
    func testSelectingInTheOtherGroupSwitchesTheDiffArea() async throws {
        let (model, _) = try await openDemo()
        XCTAssertEqual(model.visibleFiles(in: .staged).map(\.path), ["README.md"])
        XCTAssertTrue(model.visibleFiles(in: .working).contains { $0.path == "README.md" })
        model.selectFiles(["README.md"], in: .staged)
        try await eventually("暂存区差异") { model.fileDiff?.area == .staged }
        XCTAssertEqual(model.area, .staged)
        model.selectFiles(["Notes.txt"], in: .working)
        try await eventually("工作区差异") { model.fileDiff?.file.path == "Notes.txt" }
        XCTAssertEqual(model.area, .working)
        XCTAssertEqual(model.selectedFileIDs, ["Notes.txt"])
    }

    /// Commit pressed right after staging a secret, before the background check ran: it still asks first.
    @MainActor
    func testCommitBeforeCheckFinishesStillAsksAboutSecrets() async throws {
        let (model, demo) = try await openDemo()
        try "let key = \"sk-abcdefghijklmnopqrstuvwxyz123\"\n".write(to: demo.root.appendingPathComponent("secret.swift"), atomically: true, encoding: .utf8)
        _ = try await CommandRunner.git(["add", "--", "secret.swift"], at: demo.root, environment: demo.environment)
        model.refresh()
        try await eventually("读到暂存") { !model.busy && model.snapshot?.files.contains { $0.path == "secret.swift" && $0.hasStaged } == true }
        let head = model.snapshot?.head
        model.commitCheckTask?.cancel(); model.commitCheck = nil
        model.draftMessage = "secret-before-check"
        model.commit()
        try await eventually("等检查") { !model.commitCheckWaiting && !model.busy }
        XCTAssertEqual(model.snapshot?.head, head, "没确认就不提交")
        XCTAssertTrue(model.errorMessage?.contains("疑似密钥") == true)
        model.errorMessage = nil
        model.commit()
        try await eventually("确认后提交") { !model.busy && model.snapshot?.head != head }
    }
}
