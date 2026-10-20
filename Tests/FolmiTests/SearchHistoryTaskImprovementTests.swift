import Foundation
import FolmiCore
import XCTest
@testable import Folmi

final class HistoryFilterTests: XCTestCase {
    private let commits = [
        CommitNode(id: "abcdef123456", parents: [], shortID: "abcdef1", author: "Alice 张", email: "alice@example.test", date: Date(), refs: ["HEAD -> feature/search", "tag: v2"], subject: "修复搜索显示"),
        CommitNode(id: "987654fedcba", parents: [], shortID: "987654f", author: "Bob", email: "bob@example.test", date: Date(), refs: ["origin/main"], subject: "添加文档")
    ]

    func testSearchesIDsSubjectsAuthorsEmailsAndRefNames() {
        for query in ["ABCDEF12", "搜索", "alice 张", "alice@example", "FEATURE/search", "v2", "搜索 Alice"] {
            XCTAssertEqual(HistoryFilter.matches(commits, query: query).map(\.id), [commits[0].id], query)
        }
        XCTAssertEqual(HistoryFilter.matches(commits, query: "main").map(\.id), [commits[1].id])
        XCTAssertEqual(HistoryFilter.matches(commits, query: " \n "), commits)
        XCTAssertTrue(HistoryFilter.matches(commits, query: "搜索 Bob").isEmpty)
    }
}

final class MarkdownTaskCompletionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-task-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ text: String, path: String = "tasks.md") throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    private func task(_ text: String, line: Int = 0) -> MarkdownIndex.Entry {
        MarkdownIndex.Entry(path: "tasks.md", line: line, kind: .task(done: false), text: text)
    }

    @MainActor
    func testCompletionSavesOnlyTaskMarkPreservesBOMCRLFAndSelection() throws {
        try write("\u{FEFF}# 计划\r\n  2) [ ] 完成🧪\r\n")
        try write("other", path: "other.txt")
        let editor = EditorWorkspace(root: root)
        try editor.open(path: "other.txt")
        XCTAssertTrue(try editor.completeIndexedTask(task("完成🧪", line: 1)))
        XCTAssertEqual(editor.selectedDocumentID, "other.txt")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tasks.md")), Data("\u{FEFF}# 计划\r\n  2) [x] 完成🧪\r\n".utf8))
        XCTAssertFalse(try XCTUnwrap(editor.documents.first { $0.path == "tasks.md" }).isDirty)
    }

    @MainActor
    func testCompletionJoinsExistingDraftWithoutSavingUnrelatedEdits() throws {
        let original = "- [ ] task\nold\n"
        try write(original)
        let editor = EditorWorkspace(root: root)
        try editor.open(path: "tasks.md")
        editor.updateText(id: "tasks.md", text: "- [ ] task\nnew unsaved text\n")
        XCTAssertFalse(try editor.completeIndexedTask(task("task")))
        XCTAssertEqual(editor.selectedDocument?.text, "- [x] task\nnew unsaved text\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tasks.md"), encoding: .utf8), original)
    }

    @MainActor
    func testDiskConflictRefusesOverwriteAndRetainsCompletionDraft() throws {
        try write("- [ ] task\n")
        let editor = EditorWorkspace(root: root)
        try editor.open(path: "tasks.md")
        try write("- [ ] task\nexternal edit\n")
        XCTAssertThrowsError(try editor.completeIndexedTask(task("task"))) { XCTAssertEqual($0 as? FileEditorError, .changedOnDisk) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tasks.md"), encoding: .utf8), "- [ ] task\nexternal edit\n")
        XCTAssertEqual(editor.selectedDocument?.text, "- [x] task\n")
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    @MainActor
    func testStaleIndexNeverCompletesAnotherTaskAtTheOldLine() throws {
        try write("- [ ] different task\n- [ ] old task\n")
        let editor = EditorWorkspace(root: root)
        XCTAssertThrowsError(try editor.completeIndexedTask(task("old task")))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tasks.md"), encoding: .utf8), "- [ ] different task\n- [ ] old task\n")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    @MainActor
    func testTaskListAndProgressUseLiveDraftInsteadOfStaleDiskIndex() throws {
        try write("- [ ] first\n- [ ] second\n")
        let model = FolmiModel(store: WorkspaceStore(url: root.appendingPathComponent("workspace.json")))
        model.markdownIndex = MarkdownIndex.build(root: root, paths: ["tasks.md"], previous: nil)
        let editor = EditorWorkspace(root: root)
        model.editorWorkspace = editor
        try editor.open(path: "tasks.md")
        editor.updateText(id: "tasks.md", text: "- [x] first\n- [ ] renamed draft task\n")
        XCTAssertEqual(model.currentMarkdownTasks.map(\.text), ["renamed draft task"])
        XCTAssertEqual(model.currentMarkdownTaskCount(for: "tasks.md"), TaskCount(done: 1, total: 2))
        XCTAssertEqual(model.markdownIndex?.openTasks.count, 2)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tasks.md"), encoding: .utf8), "- [ ] first\n- [ ] second\n")
    }

    @MainActor
    func testCheckboxTextInsideFencedCodeCannotBeCompleted() throws {
        try write("```md\n- [ ] task\n```\n")
        let editor = EditorWorkspace(root: root)
        XCTAssertThrowsError(try editor.completeIndexedTask(task("task", line: 1)))
        XCTAssertFalse(editor.hasUnsavedChanges)
    }
}

final class HistoryContinuationTests: XCTestCase {
    @MainActor
    func testContinuationKeepsSelectionAndExhaustsHistoryWithoutDuplicates() async throws {
        let demo = try await DemoRepository.create()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-history-continuation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: directory)
        }
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        // This test exercises history pagination against a real Git repository. Install that dependency directly:
        // model.open also starts terminal/UI, watcher, AI and other startup work unrelated to pagination, making
        // the old polling deadline a test of the entire app's startup rather than the behavior below.
        let repository = GitRepository(url: demo.root, environment: demo.environment)
        model.repository = repository
        model.repositoryURL = demo.root
        model.snapshot = try await repository.load()
        model.historyRequestedLimit = 2
        await model.loadHistory()
        XCTAssertEqual(model.history.count, 2)
        XCTAssertTrue(model.historyHasMore)
        let selected = try XCTUnwrap(model.history.last?.id)
        await model.selectCommit(selected)
        await model.loadMoreHistory()
        XCTAssertEqual(model.history.count, 5)
        XCTAssertEqual(Set(model.history.map(\.id)).count, 5)
        XCTAssertEqual(model.selectedCommitID, selected)
        XCTAssertEqual(model.commitDetail?.id, selected)
        XCTAssertFalse(model.historyHasMore)
        XCTAssertEqual(model.historyRows.count, model.history.count)
        let limit = model.historyRequestedLimit
        await model.loadMoreHistory()
        XCTAssertEqual(model.historyRequestedLimit, limit)
    }
}
