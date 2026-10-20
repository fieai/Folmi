import XCTest
@testable import FolmiCore
@testable import Folmi

/// ⏎ / ⌫ / ⌘Z on the review page, against a throwaway demo repository.
final class ReviewModelTests: XCTestCase {
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

    /// A model on a demo repository with `review.txt` committed and two separate edits in the work tree.
    @MainActor
    private func makeModel(bom: Bool = false) async throws -> (FolmiModel, URL, DemoRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ReviewTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let file = demo.root.appendingPathComponent("review.txt")
        let lines = (1...30).map { "line \($0)" }
        let mark = bom ? "\u{FEFF}" : ""
        try Data((mark + lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        _ = try await CommandRunner.git(["add", "--", "review.txt"], at: demo.root, environment: demo.environment)
        _ = try await CommandRunner.git(["commit", "-m", "review base"], at: demo.root, environment: demo.environment)
        var edited = lines; edited[0] = "EDIT A"; edited[27] = "EDIT B"
        try Data((mark + edited.joined(separator: "\n") + "\n").utf8).write(to: file)
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开项目") { !model.busy && model.snapshot != nil }
        return (model, file, demo)
    }

    @MainActor
    private func reviewDiff(_ model: FolmiModel, area: ChangeArea = .working) async throws -> FileDiff {
        // The opening banner may be loading the same page at the same time; wait for the finished list.
        await model.loadAllChanges()
        try await eventually("全部改动") { !model.allChangesLoading && model.allChanges.contains { $0.file.path == "review.txt" && $0.area == area } }
        return try XCTUnwrap(model.allChanges.first { $0.file.path == "review.txt" && $0.area == area })
    }

    @MainActor
    func testAcceptStagesAndMarksSeenThenUndoUnstages() async throws {
        let (model, _, demo) = try await makeModel()
        let diff = try await reviewDiff(model)
        XCTAssertEqual(diff.hunks.count, 2)
        model.acceptHunk(diff.hunks[0], in: diff)
        try await eventually("暂存") { !model.busy }
        XCTAssertNil(model.errorMessage)
        let staged = try await CommandRunner.git(["show", ":review.txt"], at: demo.root, environment: demo.environment)
        XCTAssertTrue(staged.contains("EDIT A")); XCTAssertFalse(staged.contains("EDIT B"))
        XCTAssertTrue(model.isSeen(diff.hunks[0], in: diff))
        // The staged copy of the same lines counts as seen too.
        let stagedDiff = try await reviewDiff(model, area: .staged)
        XCTAssertTrue(model.isSeen(stagedDiff.hunks[0], in: stagedDiff))
        model.undoGitOperation()
        try await eventually("撤销") { !model.busy }
        let index = try await CommandRunner.git(["show", ":review.txt"], at: demo.root, environment: demo.environment)
        XCTAssertFalse(index.contains("EDIT A"))
        XCTAssertNotNil(model.redoLabel)
    }

    /// The whole ⏎ / ⌫ / ⌘Z review loop on a file that starts with a BOM, with the first hunk touching line 1.
    @MainActor
    func testReviewLoopKeepsByteOrderMark() async throws {
        let (model, file, demo) = try await makeModel(bom: true)
        let original = try Data(contentsOf: file)
        XCTAssertTrue(original.starts(with: [0xEF, 0xBB, 0xBF]))
        let diff = try await reviewDiff(model)
        XCTAssertEqual(diff.hunks.count, 2)
        model.acceptHunk(diff.hunks[0], in: diff)
        try await eventually("暂存") { !model.busy }
        XCTAssertNil(model.errorMessage)
        let git = GitProcess(directory: demo.root, environment: demo.environment)
        let staged = try git.run(["show", ":review.txt"]).stdout
        XCTAssertTrue(staged.starts(with: Data("\u{FEFF}EDIT A\nline 2\n".utf8)), "staging line 1 keeps the BOM")
        XCTAssertFalse(String(decoding: staged, as: UTF8.self).contains("EDIT B"))

        let rest = try await reviewDiff(model)
        model.rejectHunk(try XCTUnwrap(rest.hunks.first { $0.lines.contains { $0.text == "EDIT B" } }), in: rest)
        try await eventually("丢弃") { !model.busy }
        XCTAssertNil(model.errorMessage)
        let afterReject = try Data(contentsOf: file)
        XCTAssertTrue(afterReject.starts(with: Data("\u{FEFF}EDIT A\n".utf8)))
        XCTAssertFalse(String(decoding: afterReject, as: UTF8.self).contains("EDIT B"))

        model.undoGitOperation()
        try await eventually("撤销丢弃") { !model.busy }
        XCTAssertEqual(try Data(contentsOf: file), original, "⌘Z restores the exact bytes")
        model.undoGitOperation()
        try await eventually("撤销暂存") { !model.busy }
        XCTAssertTrue(try git.run(["show", ":review.txt"]).stdout.starts(with: Data("\u{FEFF}line 1\n".utf8)))
    }

    @MainActor
    func testMarkdownDiffReadsIndexAndWorkTreeVersions() async throws {
        let (model, _, demo) = try await makeModel()
        let doc = demo.root.appendingPathComponent("notes.md")
        try Data("\u{FEFF}# 笔记\r\n\r\n第一版\r\n".utf8).write(to: doc)
        _ = try await CommandRunner.git(["add", "--", "notes.md"], at: demo.root, environment: demo.environment)
        _ = try await CommandRunner.git(["commit", "-m", "notes"], at: demo.root, environment: demo.environment)
        try Data("\u{FEFF}# 笔记\r\n\r\n第二版\r\n".utf8).write(to: doc)
        model.refresh()
        try await eventually("刷新") { !model.busy && model.snapshot?.files.contains { $0.path == "notes.md" } == true }
        let file = try XCTUnwrap(model.snapshot?.files.first { $0.path == "notes.md" })
        let working = try await XCTUnwrapAsync(await model.repository?.diff(for: file, area: .working))
        let texts = try await XCTUnwrapAsync(await model.markdownDiffTexts(working))
        XCTAssertEqual(texts.base, "# 笔记\n\n第一版\n", "index side: BOM dropped and line ends normalized like the editor")
        XCTAssertEqual(texts.current, "# 笔记\n\n第二版\n")
        _ = try await CommandRunner.git(["add", "--", "notes.md"], at: demo.root, environment: demo.environment)
        let staged = try await XCTUnwrapAsync(await model.repository?.diff(for: file, area: .staged))
        let stagedTexts = try await XCTUnwrapAsync(await model.markdownDiffTexts(staged))
        XCTAssertEqual(stagedTexts.base, "# 笔记\n\n第一版\n", "staged: HEAD → index")
        XCTAssertEqual(stagedTexts.current, "# 笔记\n\n第二版\n")
    }
    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    @MainActor
    func testRejectDiscardsHunkAndUndoRestores() async throws {
        let (model, file, _) = try await makeModel()
        let diff = try await reviewDiff(model)
        model.rejectHunk(diff.hunks[1], in: diff)
        try await eventually("丢弃") { !model.busy }
        XCTAssertNil(model.errorMessage)
        var text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("EDIT A")); XCTAssertFalse(text.contains("EDIT B")); XCTAssertTrue(text.contains("line 28"))
        model.undoGitOperation()
        try await eventually("撤销") { !model.busy }
        text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("EDIT B"))
    }

    @MainActor
    func testUndoRefusesWhenFileChangedAfterwards() async throws {
        let (model, file, _) = try await makeModel()
        let diff = try await reviewDiff(model)
        model.rejectHunk(diff.hunks[0], in: diff)
        try await eventually("丢弃") { !model.busy }
        let afterReject = try Data(contentsOf: file)
        try "someone else wrote this\n".write(to: file, atomically: true, encoding: .utf8)
        let label = model.undoLabel
        model.undoGitOperation()
        try await eventually("撤销") { !model.busy }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "someone else wrote this\n")
        // The refused step is still there: once the other edit is gone, the same ⌘Z works.
        XCTAssertEqual(model.undoLabel, label)
        XCTAssertNil(model.redoLabel)
        try afterReject.write(to: file)
        model.errorMessage = nil
        model.undoGitOperation()
        try await eventually("重试撤销") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("EDIT A"))
        XCTAssertNotNil(model.redoLabel)
    }

    @MainActor
    func testCommitUndoKeepsChangesStaged() async throws {
        let (model, _, demo) = try await makeModel()
        let diff = try await reviewDiff(model)
        model.stageFile(diff.file)
        try await eventually("暂存") { !model.busy }
        model.draftMessage = "test: review commit"
        let before = try await CommandRunner.git(["rev-parse", "HEAD"], at: demo.root, environment: demo.environment)
        model.commit()
        try await eventually("提交") { !model.busy }
        XCTAssertNotNil(model.lastCommit)
        model.undoGitOperation()
        try await eventually("撤销提交") { !model.busy }
        let after = try await CommandRunner.git(["rev-parse", "HEAD"], at: demo.root, environment: demo.environment)
        XCTAssertEqual(after, before)
        let staged = try await CommandRunner.git(["diff", "--cached", "--name-only"], at: demo.root, environment: demo.environment)
        XCTAssertTrue(staged.contains("review.txt"))
    }

    /// ⏎ on a new file stages it, and the staged hunk it becomes is already seen: no second ⏎ before "all seen".
    @MainActor
    func testAcceptNewFileNeedsOneReturn() async throws {
        for (name, text) in [("fresh.txt", "first\nsecond\nfirst\n"), ("empty.txt", "")] {
            let (model, _, demo) = try await makeModel()
            model.content = .allChanges
            try Data(text.utf8).write(to: demo.root.appendingPathComponent(name))
            try await model.reload()
            try await eventually("新文件出现") { !model.allChangesLoading && model.allChanges.contains { $0.file.path == name && $0.area == .working } }
            let diff = try XCTUnwrap(model.allChanges.first { $0.file.path == name && $0.area == .working })
            XCTAssertTrue(diff.file.isUntracked)
            model.acceptFile(diff)
            try await eventually("暂存新文件") { !model.busy }
            XCTAssertNil(model.errorMessage)
            let staged = try XCTUnwrap(model.allChanges.first { $0.file.path == name && $0.area == .staged }, name)
            XCTAssertTrue(model.isFileSeen(staged), "\(name) 暂存后应已看过")
            XCTAssertFalse(model.allChanges.contains { $0.file.path == name && $0.area == .working })
        }
    }

    /// "上次还有" only when part of the changes was seen before; a project nobody reviewed yet just says what waits.
    @MainActor
    func testOpeningBannerSaysLastTimeOnlyAfterSomeWasSeen() async throws {
        let (model, _, _) = try await makeModel()
        let diff = try await reviewDiff(model)
        await model.prepareOpeningBanner()
        let fresh = try XCTUnwrap(model.openingBanner)
        XCTAssertFalse(fresh.contains("上次"), fresh)
        XCTAssertTrue(fresh.contains("处改动等你看"), fresh)
        model.markSeen(diff.hunks[0], in: diff)
        await model.prepareOpeningBanner()
        XCTAssertEqual(model.openingBanner?.hasPrefix("上次还有"), true, model.openingBanner ?? "nil")
    }

    /// A folder that is not a repository says so in words and offers to pick another, instead of Git's exit 128.
    @MainActor
    func testOpeningNonRepositoryExplainsAndOffersAnotherFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-NotRepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupURLs.append(directory)
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(directory)
        try await eventually("打开失败") { !model.busy && model.errorMessage != nil }
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.contains("不是 Git 仓库"), message)
        XCTAssertFalse(message.contains("128"), message)
        XCTAssertEqual(model.notRepositoryPath, directory.standardizedFileURL.path)
        XCTAssertNil(model.missingProjectPath)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(FolmiModel.isNotRepository(FolmiError.git(exitCode: 128, message: "fatal: 不是 git 仓库（或者任何父目录）：.git")))
        XCTAssertFalse(FolmiModel.isNotRepository(FolmiError.git(exitCode: 1, message: "not a git repository")))
    }

    /// The change list follows the review page's current file, across areas, without leaving the page.
    @MainActor
    func testChangeListFollowsReviewFocus() async throws {
        let (model, _, demo) = try await makeModel()
        try Data("other\n".utf8).write(to: demo.root.appendingPathComponent("other.txt"))
        try await model.reload()
        model.content = .allChanges
        await model.loadAllChanges()
        let review = try XCTUnwrap(model.allChanges.first { $0.file.path == "review.txt" && $0.area == .working })
        let other = try XCTUnwrap(model.allChanges.first { $0.file.path == "other.txt" })
        model.followReview(review)
        model.followReview(other)
        XCTAssertEqual(model.content, .allChanges)
        XCTAssertEqual(model.selectedFileIDs, [other.file.id])
        XCTAssertEqual(model.selectedFileID, other.file.id)
        XCTAssertEqual(model.fileDiff?.file.path, "other.txt")

        model.stageFile(review.file)
        try await eventually("暂存") { !model.busy }
        let staged = try XCTUnwrap(model.allChanges.first { $0.file.path == "review.txt" && $0.area == .staged })
        model.followReview(staged)
        XCTAssertEqual(model.area, .staged)
        XCTAssertEqual(model.selectedFileIDs, [staged.file.id])

        // Off the review page the list is the user's own selection.
        model.content = .diff
        model.followReview(other)
        XCTAssertEqual(model.selectedFileIDs, [staged.file.id])
    }

    /// A hunk's explanation docks beside the review and diff pages; elsewhere, and for other requests, it still floats.
    @MainActor
    func testExplanationDocksBesideReviewOnly() async throws {
        let (model, _, _) = try await makeModel()
        model.aiAssist = AIAssistState(mode: .explain, source: "review.txt @@", input: "+EDIT A")
        model.content = .allChanges
        XCTAssertTrue(model.assistBesideReview)
        model.content = .diff
        XCTAssertTrue(model.assistBesideReview)
        model.content = .editor
        XCTAssertFalse(model.assistBesideReview)
        model.content = .allChanges
        model.aiAssist = AIAssistState(mode: .ask, source: "review.txt", input: "")
        XCTAssertFalse(model.assistBesideReview)
        model.closeAssist()
        XCTAssertFalse(model.assistBesideReview)
    }

    /// ⌘Z after a ⏎ puts the change back as unseen (the count drops again) and points the review page at it; redo
    /// marks it seen again. The 「已收下」 note only appears once the stage went through.
    @MainActor
    func testUndoAfterAcceptRestoresCountAndFocus() async throws {
        let (model, _, _) = try await makeModel()
        model.content = .allChanges
        await model.loadAllChanges()
        let diff = try await reviewDiff(model)
        let before = model.reviewTally
        XCTAssertNil(model.lastAccept)
        model.acceptHunk(diff.hunks[0], in: diff)
        try await eventually("暂存") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.lastAccept?.path, "review.txt")
        await model.loadAllChanges()
        XCTAssertEqual(model.reviewTally.seen, before.seen + 1)

        model.undoGitOperation()
        try await eventually("撤销") { !model.busy }
        XCTAssertNil(model.errorMessage)
        await model.loadAllChanges()
        XCTAssertEqual(model.reviewTally.seen, before.seen, "撤销后这处应回到未看")
        XCTAssertFalse(model.isSeen(diff.hunks[0], in: diff))
        XCTAssertEqual(model.reviewFocusAfterUndo?.paths, ["review.txt"])
        XCTAssertNil(model.lastAccept)

        model.redoGitOperation()
        try await eventually("重做") { !model.busy }
        await model.loadAllChanges()
        XCTAssertEqual(model.reviewTally.seen, before.seen + 1, "重做后这处又算看过")
    }

    /// A failed stage leaves nothing marked and no 「已收下」 note.
    @MainActor
    func testFailedAcceptShowsNoAcceptedNote() async throws {
        let (model, file, demo) = try await makeModel()
        let diff = try await reviewDiff(model)
        // The index changes under the diff, so the old hunk no longer applies to it.
        try Data("replaced\n".utf8).write(to: file)
        _ = try await CommandRunner.git(["add", "--", "review.txt"], at: demo.root, environment: demo.environment)
        model.acceptHunk(diff.hunks[0], in: diff)
        try await eventually("暂存结束") { !model.busy }
        XCTAssertNil(model.lastAccept)
        XCTAssertFalse(model.isSeen(diff.hunks[0], in: diff))
        model.errorMessage = nil
    }
}
