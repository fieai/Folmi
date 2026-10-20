import XCTest
import FolmiCore
@testable import Folmi

final class ReviewCommentTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    private let file = FileChange(path: "src/app.js", indexCode: ".", worktreeCode: "M")
    private var hunk: DiffHunk {
        DiffHunk(id: "h", header: "@@ -10,4 +10,5 @@ function main()", lines: [
            DiffLine(id: 1, text: "const a = 1", kind: .context),
            DiffLine(id: 2, text: "const b = 2", kind: .deletion),
            DiffLine(id: 3, text: "const b = 3", kind: .addition),
            DiffLine(id: 4, text: "const c = 4", kind: .addition),
            DiffLine(id: 5, text: "return a", kind: .context)
        ])
    }
    private var diff: FileDiff {
        FileDiff(file: file, area: .working, rawPatch: "", hunks: [hunk], fingerprint: "f", isPartialSupported: true, notice: nil)
    }

    func testReaderCommentKeepsTheMarkdownSourceAndFollowsMovedLines() throws {
        let lines = ["# 标题", "", "第一段 **重点**", "第二段", "结尾"]
        let draft = ReaderCommentDraft(path: "docs/a.md", firstLine: 3, lastLine: 4, quote: "第一段 重点\n第二段")
        let comment = try XCTUnwrap(ReviewComment.make(projectPath: "/p", draft: draft, body: " 说清楚一点 ", fileLines: lines))
        XCTAssertEqual(comment.reference, "docs/a.md:3-4")
        XCTAssertEqual(comment.excerpt, [" 第一段 **重点**", " 第二段"])
        XCTAssertEqual(comment.body, "说清楚一点")
        let moved = comment.located(in: ["新的一行"] + lines)
        XCTAssertEqual(moved.lines, "4-5"); XCTAssertFalse(moved.outdated)
        XCTAssertTrue(comment.located(in: ["# 标题", "", "改写了", "第二段", "结尾"]).outdated)
        // Unreadable file: the selected text stands in; an empty note is refused.
        XCTAssertEqual(ReviewComment.make(projectPath: "/p", draft: draft, body: "x", fileLines: nil)?.excerpt, [" 第一段 重点", " 第二段"])
        XCTAssertNil(ReviewComment.make(projectPath: "/p", draft: draft, body: "  ", fileLines: lines))
    }

    func testLineNumbersFollowTheNewSide() throws {
        let numbers = try XCTUnwrap(ReviewComment.newLineNumbers(hunk))
        XCTAssertEqual(numbers, [1: 10, 2: 11, 3: 11, 4: 12, 5: 13])
    }

    func testSelectedLinesOrWholeHunkAndFormat() throws {
        let selected = try XCTUnwrap(ReviewComment.make(projectPath: "/p", diff: diff, hunk: hunk, selected: [3, 4], body: "  用常量  "))
        XCTAssertEqual(selected.reference, "src/app.js:11-12")
        XCTAssertEqual(selected.formatted, "src/app.js:11-12\n```diff\n+const b = 3\n+const c = 4\n```\n用常量")
        let whole = try XCTUnwrap(ReviewComment.make(projectPath: "/p", diff: diff, hunk: hunk, selected: [99], body: "整块"))
        XCTAssertEqual(whole.lines, "10-13")
        XCTAssertEqual(whole.excerpt.count, 5)
        XCTAssertNil(ReviewComment.make(projectPath: "/p", diff: diff, hunk: hunk, selected: [], body: "  \n"))
        XCTAssertEqual(ReviewComment.formatted([selected, whole]).components(separatedBy: "\n\n").count, 2)
    }

    func testControlCharactersCannotEscapeThePaste() {
        let text = ReviewComment.sanitize("ok\u{1B}[201~rm -rf /\u{7}\u{9B}x\ttab\nline")
        XCTAssertEqual(text, "ok[201~rm -rf /x\ttab\nline")
    }

    @MainActor
    func testSendPastesIntoTheProjectShellWithoutRunningIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && !model.fileDiffs.isEmpty }
        let diff = try XCTUnwrap(model.fileDiffs.first { !$0.hunks.isEmpty })
        model.addReviewComment("echo SHOULD_NOT_RUN_\("X")\nNOTE_MARKER 换一种写法", hunk: try XCTUnwrap(diff.hunks.first), in: diff)
        XCTAssertEqual(model.currentReviewComments.count, 1)

        model.sendReviewCommentsToTerminal()
        let terminal = try XCTUnwrap(model.terminalSession)
        defer { terminal.stop() }
        try await eventually { model.currentReviewComments.isEmpty || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.showTerminal)
        XCTAssertEqual(model.paneLayout.focused, .terminal)
        try await Task.sleep(nanoseconds: 500_000_000)
        let screen = String(decoding: terminal.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(screen.contains(diff.file.path + ":"), screen)
        XCTAssertTrue(screen.contains("NOTE_MARKER"))
        XCTAssertFalse(screen.contains("SHOULD_NOT_RUN_X\nSHOULD_NOT_RUN_X"), "the pasted echo must not have been executed")
        XCTAssertFalse(screen.contains("command not found"))
    }

    func testAnchorKeepsCommentedLinesAndTheirNeighbours() throws {
        let selected = try XCTUnwrap(ReviewComment.make(projectPath: "/p", diff: diff, hunk: hunk, selected: [3, 4], body: "x"))
        XCTAssertEqual(selected.anchor, ["const a = 1", "const b = 3", "const c = 4", "return a"])
        XCTAssertEqual(selected.anchorStart, 10)
        let deletion = try XCTUnwrap(ReviewComment.make(projectPath: "/p", diff: diff, hunk: hunk, selected: [2], body: "x"))
        XCTAssertEqual(deletion.anchor, ["const a = 1", "const b = 3"], "a deletion is anchored by the lines either side of the gap")
        XCTAssertEqual(deletion.lines, "11")
    }

    func testMovedLinesCarryTheCommentAndChangedLinesMakeItOutdated() throws {
        let comment = try XCTUnwrap(ReviewComment.make(projectPath: "/p", diff: diff, hunk: hunk, selected: [3, 4], body: "x"))
        let before = (1...9).map { "line \($0)" }
        let file = before + ["const a = 1", "const b = 3", "const c = 4", "return a", "}"]
        XCTAssertEqual(comment.located(in: file), comment, "unchanged file")

        let moved = comment.located(in: ["// a", "// b"] + file)
        XCTAssertFalse(moved.outdated)
        XCTAssertEqual(moved.lines, "13-14")
        XCTAssertEqual(moved.anchorStart, 12)

        let changed = moved.located(in: before + ["const a = 1", "const b = 4", "const c = 4", "return a"])
        XCTAssertTrue(changed.outdated)
        XCTAssertEqual(changed.lines, "13-14", "an outdated note keeps its last known lines")
        XCTAssertTrue(comment.located(in: nil).outdated, "deleted file")
        XCTAssertFalse(changed.located(in: file).outdated, "reverting the change brings the note back")

        // Of several copies, the one closest to where the note was wins.
        let twice = file + file
        XCTAssertEqual(ReviewComment.locate(anchor: comment.anchor, near: 20, in: twice), 24)
    }

    func testFileLinesSplitCRLFAndSkipBinary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Lines-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupURLs.append(directory)
        let text = directory.appendingPathComponent("crlf.txt"), binary = directory.appendingPathComponent("b.bin")
        try Data("a\r\nb\r\n".utf8).write(to: text)
        try Data([0x61, 0x00, 0x62]).write(to: binary)
        XCTAssertEqual(ReviewComment.fileLines(text), ["a", "b", ""])
        XCTAssertNil(ReviewComment.fileLines(binary))
        XCTAssertNil(ReviewComment.fileLines(directory.appendingPathComponent("missing")))
    }

    @MainActor
    func testCommentsSurviveRestartAndGoOutdatedWhenTheirLinesChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ReviewSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let storeURL = directory.appendingPathComponent("workspace.json")
        let first = FolmiModel(store: WorkspaceStore(url: storeURL))
        first.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !first.busy && !first.fileDiffs.isEmpty }
        let diff = try XCTUnwrap(first.fileDiffs.first { $0.area == .working && !$0.file.isUntracked && !$0.hunks.isEmpty })
        first.addReviewComment("留着下次再发", hunk: try XCTUnwrap(diff.hunks.first), in: diff)
        let original = try XCTUnwrap(first.currentReviewComments.first)
        try first.savePreferencesNow()

        let second = FolmiModel(store: WorkspaceStore(url: storeURL))
        XCTAssertEqual(second.reviewComments, [original], "saved with the project")
        second.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !second.busy && second.snapshot != nil }
        XCTAssertEqual(second.sendableReviewComments.count, 1)

        let fileURL = demo.root.appendingPathComponent(diff.file.path)
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        try ("// 新增一行\n// 再加一行\n" + content).write(to: fileURL, atomically: true, encoding: .utf8)
        await second.relocateReviewComments()
        let moved = try XCTUnwrap(second.currentReviewComments.first)
        XCTAssertFalse(moved.outdated)
        XCTAssertEqual(moved.firstLine, original.firstLine + 2)

        try "全部重写\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await second.relocateReviewComments()
        XCTAssertTrue(try XCTUnwrap(second.currentReviewComments.first).outdated)
        XCTAssertTrue(second.sendableReviewComments.isEmpty, "outdated notes are not sent")
        second.clearOutdatedReviewComments()
        XCTAssertTrue(second.currentReviewComments.isEmpty)
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 8, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
