import XCTest
@testable import FolmiCore
@testable import Folmi

/// 逐个验收 counts only what went through: a failed stage is not "seen", picked lines are not the whole hunk, and
/// ⏎ / ⌫ are named for where the change is (review-flow-optimization-v0.6, P0).
final class ReviewOutcomeTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 8, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)"); throw FolmiFailure(message: description) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// `review.txt` committed, then line 1 and line 28 edited in the work tree: two hunks of one deletion + one addition.
    @MainActor
    private func makeModel() async throws -> (FolmiModel, DemoRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Outcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let file = demo.root.appendingPathComponent("review.txt")
        let lines = (1...30).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try await CommandRunner.git(["add", "--", "review.txt"], at: demo.root, environment: demo.environment)
        _ = try await CommandRunner.git(["commit", "-m", "review base"], at: demo.root, environment: demo.environment)
        var edited = lines; edited[0] = "EDIT A"; edited[27] = "EDIT B"
        try (edited.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开项目") { !model.busy && model.snapshot != nil }
        return (model, demo)
    }

    @MainActor
    private func reviewDiff(_ model: FolmiModel, area: ChangeArea = .working) async throws -> FileDiff {
        await model.loadAllChanges()
        try await eventually("全部改动") { !model.allChangesLoading && model.allChanges.contains { $0.file.path == "review.txt" && $0.area == area } }
        return try XCTUnwrap(model.allChanges.first { $0.file.path == "review.txt" && $0.area == area })
    }

    private func lock(_ demo: DemoRepository) throws -> URL {
        let url = demo.root.appendingPathComponent(".git/index.lock")
        try Data().write(to: url)
        return url
    }

    @MainActor
    func testFailedStageIsNotMarkedSeenOrCounted() async throws {
        let (model, demo) = try await makeModel()
        let diff = try await reviewDiff(model)
        let accepted = model.dailyStats.today().accepted
        // Another git process holds the index: the stage fails.
        let lockURL = try lock(demo)
        model.acceptHunk(diff.hunks[0], in: diff)
        try await eventually("暂存失败") { !model.busy }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isSeen(diff.hunks[0], in: diff), "a stage that failed is not a reviewed change")
        XCTAssertEqual(model.dailyStats.today().accepted, accepted, "nor counted as accepted")
        XCTAssertEqual(model.reviewTally.seen, 0)

        // The same ⏎ works once the lock is gone.
        try FileManager.default.removeItem(at: lockURL)
        model.errorMessage = nil
        let again = try await reviewDiff(model)
        model.acceptHunk(again.hunks[0], in: again)
        try await eventually("重试暂存") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSeen(again.hunks[0], in: again))
        XCTAssertEqual(model.dailyStats.today().accepted, accepted + 1)
    }

    @MainActor
    func testFailedUnstageIsNotCountedAsRejected() async throws {
        let (model, demo) = try await makeModel()
        let working = try await reviewDiff(model)
        model.applyHunk(working.hunks[0], in: working)
        try await eventually("暂存") { !model.busy }
        let staged = try await reviewDiff(model, area: .staged)
        let rejected = model.dailyStats.today().rejected
        let lockURL = try lock(demo)
        defer { try? FileManager.default.removeItem(at: lockURL) }
        model.rejectHunk(staged.hunks[0], in: staged)
        try await eventually("取消暂存失败") { !model.busy }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.dailyStats.today().rejected, rejected)
        let index = try await CommandRunner.git(["show", ":review.txt"], at: demo.root, environment: demo.environment)
        XCTAssertTrue(index.contains("EDIT A"), "still staged")
    }

    /// 收下选中的 1 / 2 行: only that line is staged and marked; the hunk is not reviewed until the rest is.
    @MainActor
    func testAcceptingPickedLinesMarksOnlyThoseLines() async throws {
        let (model, demo) = try await makeModel()
        let diff = try await reviewDiff(model)
        let hunk = diff.hunks[0]
        let added = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        model.toggleAllChangesLine(added.id, in: diff)
        let accepted = model.dailyStats.today().accepted
        model.acceptSelection(hunk, in: diff)
        try await eventually("暂存选中行") { !model.busy && !model.allChangesLoading }
        XCTAssertNil(model.errorMessage)
        let index = try await CommandRunner.git(["show", ":review.txt"], at: demo.root, environment: demo.environment)
        XCTAssertTrue(index.contains("EDIT A")); XCTAssertTrue(index.contains("line 1\n"), "the unpicked deletion stays in the work tree")
        XCTAssertEqual(model.dailyStats.today().accepted, accepted + 1)

        let rest = try await reviewDiff(model)
        let remaining = try XCTUnwrap(rest.hunks.first { $0.lines.contains { $0.kind == .deletion && $0.text == "line 1" } })
        XCTAssertFalse(model.isSeen(remaining, in: rest), "the line left over is still to review")
        let staged = try await reviewDiff(model, area: .staged)
        XCTAssertTrue(model.isSeen(staged.hunks[0], in: staged), "the staged line is reviewed")
        XCTAssertEqual(model.reviewTally.seen, 1, "one hunk of three (the staged line; line 1 and EDIT B are left)")
    }

    /// Picked lines of a staged hunk are confirmed where they are: ⏎ never moves them out of the index.
    @MainActor
    func testConfirmingPickedStagedLinesLeavesIndexAlone() async throws {
        let (model, demo) = try await makeModel()
        let working = try await reviewDiff(model)
        model.stageFile(working.file)
        try await eventually("暂存") { !model.busy }
        let staged = try await reviewDiff(model, area: .staged)
        let hunk = staged.hunks[0]
        let added = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        model.toggleAllChangesLine(added.id, in: staged)
        let before = try await CommandRunner.git(["show", ":review.txt"], at: demo.root, environment: demo.environment)
        model.acceptSelection(hunk, in: staged)
        try await eventually("确认") { !model.busy }
        let after = try await CommandRunner.git(["show", ":review.txt"], at: demo.root, environment: demo.environment)
        XCTAssertEqual(after, before)
        XCTAssertFalse(model.isSeen(hunk, in: staged), "only one of its two lines is confirmed")
        XCTAssertTrue(model.reviewLedger.containsAll(ReviewProgress.hunkKeys(
            DiffHunk(id: hunk.id, header: hunk.header, lines: [added]), in: model.reviewKeys(staged))))
        XCTAssertTrue(model.allChangesSelected(in: hunk, of: staged).isEmpty, "the picked lines are done")
    }

    func testActionNamesFollowWhereTheChangeIs() {
        func diff(_ area: ChangeArea, untracked: Bool = false, partial: Bool = true) -> FileDiff {
            let hunk = DiffHunk(id: "h", header: "@@ -1 +1 @@", lines: [DiffLine(id: 1, text: "a", kind: .deletion), DiffLine(id: 2, text: "b", kind: .addition)])
            let file = FileChange(path: "f", indexCode: untracked ? "?" : (area == .staged ? "M" : "."), worktreeCode: untracked ? "?" : (area == .working ? "M" : "."))
            return FileDiff(file: file, area: area, rawPatch: "", hunks: [hunk], fingerprint: "f", isPartialSupported: partial, notice: nil)
        }
        let working = diff(.working), staged = diff(.staged)
        XCTAssertEqual(ReviewActionNames.make(working, hunk: working.hunks[0]), .init(accept: "收下这处并暂存", reject: "丢弃这处"))
        XCTAssertEqual(ReviewActionNames.make(working, hunk: working.hunks[0], selected: 2).accept, "收下选中的 2 行")
        XCTAssertEqual(ReviewActionNames.make(staged, hunk: staged.hunks[0]), .init(accept: "确认这处", reject: "退回工作区"))
        XCTAssertEqual(ReviewActionNames.make(staged, hunk: nil), .init(accept: "确认整个文件", reject: "整个文件退回工作区"))
        let whole = diff(.working, partial: false)
        XCTAssertEqual(ReviewActionNames.make(whole, hunk: whole.hunks[0]).accept, "收下整个文件", "no silent widening to the whole file")
        XCTAssertEqual(ReviewActionNames.make(working, hunk: nil), .init(accept: "收下整个文件", reject: nil))
        let new = diff(.working, untracked: true)
        XCTAssertEqual(ReviewActionNames.make(new, hunk: new.hunks[0]), .init(accept: "收下整个文件", reject: "删除新文件"))
    }
}
