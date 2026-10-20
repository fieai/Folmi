import XCTest
import FolmiCore
@testable import Folmi

final class NavigationFlowTests: XCTestCase {
    @MainActor
    private func idle(_ model: FolmiModel) async throws {
        let deadline = Date().addingTimeInterval(8)
        while model.busy {
            guard Date() < deadline else { throw FolmiFailure(message: "演示操作超时") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    private func waitForDiff(_ model: FolmiModel, paths: Set<String>, area: ChangeArea = .working) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Set(model.fileDiffs.map { $0.file.path }) != paths || model.fileDiffs.contains(where: { $0.area != area }) {
            guard Date() < deadline else { throw FolmiFailure(message: "等待左右差异超时") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func open(_ demo: DemoRepository) async throws -> FolmiModel {
        let config = demo.root.deletingLastPathComponent().appendingPathComponent("Folmi-Settings/workspace.json")
        let model = FolmiModel(store: WorkspaceStore(url: config))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await idle(model)
        XCTAssertNotNil(model.projectTree)
        return model
    }

    private func paths(_ nodes: [ProjectFileNode]) -> Set<String> {
        Set(nodes.flatMap { $0.isDirectory ? Array(paths($0.children ?? [])) : [$0.path] })
    }

    @MainActor
    func testTreeOpenHighlightEditSaveReadbackDoesNotStageFiles() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let indexURL = demo.root.appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: indexURL)
        let model = try await open(demo)
        let tree = try XCTUnwrap(model.projectTree)
        XCTAssertTrue(paths(tree.roots).isSuperset(of: ["src/app.js", "scripts/report.py", "config/settings.json"]))
        XCTAssertFalse(paths(tree.roots).contains { $0.hasPrefix(".git/") })
        XCTAssertTrue(tree.roots.contains { $0.path == "scratch" && $0.isDirectory })
        model.editPath("src/app.js")
        try await waitForDiff(model, paths: ["src/app.js"])
        let editor = try XCTUnwrap(model.editorWorkspace)
        let source = try XCTUnwrap(editor.selectedDocument?.text)
        let tokens = try XCTUnwrap(SyntaxTokenizer.tokenize(source, language: SyntaxLanguage(path: "src/app.js")))
        XCTAssertTrue(tokens.tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(tokens.tokens.contains { $0.kind == .string })
        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        let edited = source + "\n// navigation edit saved 🌱\n"
        editor.updateText(id: "src/app.js", text: edited)
        try editor.saveSelected()
        model.fileDidSave()
        try await idle(model)
        XCTAssertEqual(try String(contentsOf: demo.root.appendingPathComponent("src/app.js"), encoding: .utf8), edited)
        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex, "保存编辑不能顺便暂存或刷新写索引")
        let reopened = EditorWorkspace(root: demo.root)
        try reopened.open(path: "src/app.js")
        XCTAssertEqual(reopened.selectedDocument?.text, edited)
        model.editPath("config/settings.json")
        XCTAssertTrue(model.fileDiffs.isEmpty, "干净文件不应显示上一个文件的差异")
        XCTAssertEqual(model.content, .editor)
        try model.savePreferencesNow()
    }

    @MainActor
    func testAlignedReplacementSelectionStagesAndUnstagesOriginalLineIDs() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let before = try await CommandRunner.git(["show", ":src/app.js"], at: demo.root, environment: demo.environment)
        let working = try String(contentsOf: demo.root.appendingPathComponent("src/app.js"), encoding: .utf8)
        let model = try await open(demo)
        model.selectFiles(["src/app.js"])
        try await waitForDiff(model, paths: ["src/app.js"])
        let diff = try XCTUnwrap(model.fileDiffs.first)
        let hunk = try XCTUnwrap(diff.hunks.first { $0.lines.contains { $0.text.contains("retries:") } })
        let aligned = DiffAlignment.rows(in: hunk)
        let pair = try XCTUnwrap(aligned.first { $0.old?.line.text.contains("retries: 2") == true })
        let old = try XCTUnwrap(pair.old), new = try XCTUnwrap(pair.new)
        XCTAssertTrue(new.line.text.contains("retries: 3"))
        model.toggleLine(old.line.id, in: diff)
        model.toggleLine(new.line.id, in: diff)
        model.applySelectedLines(hunk, in: diff)
        try await idle(model)
        let staged = try await CommandRunner.git(["show", ":src/app.js"], at: demo.root, environment: demo.environment)
        XCTAssertTrue(staged.contains("retries: 3"))
        XCTAssertFalse(staged.contains("retries: 2"))
        XCTAssertFalse(staged.contains("const labels"), "不能暂存同一块里没有选择的行")
        XCTAssertEqual(try String(contentsOf: demo.root.appendingPathComponent("src/app.js"), encoding: .utf8), working)
        model.setArea(.staged)
        model.selectFiles(["src/app.js"])
        try await waitForDiff(model, paths: ["src/app.js"], area: .staged)
        let reverse = try XCTUnwrap(model.fileDiffs.first)
        let reverseHunk = try XCTUnwrap(reverse.hunks.first)
        for line in reverseHunk.lines where line.kind == .addition || line.kind == .deletion {
            model.toggleLine(line.id, in: reverse)
        }
        model.applySelectedLines(reverseHunk, in: reverse)
        try await idle(model)
        let restored = try await CommandRunner.git(["show", ":src/app.js"], at: demo.root, environment: demo.environment)
        XCTAssertEqual(restored, before)
        XCTAssertEqual(try String(contentsOf: demo.root.appendingPathComponent("src/app.js"), encoding: .utf8), working)
        try model.savePreferencesNow()
    }

    @MainActor
    func testMultipleAlignedFilesAndEditorTabsKeepSelectionsSeparate() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let model = try await open(demo)
        let selected: Set<String> = ["src/app.js", "scripts/report.py"]
        model.selectFiles(selected)
        try await waitForDiff(model, paths: selected)
        let javascript = try XCTUnwrap(model.fileDiffs.first { $0.file.path == "src/app.js" })
        let python = try XCTUnwrap(model.fileDiffs.first { $0.file.path == "scripts/report.py" })
        let line = try XCTUnwrap(javascript.hunks.flatMap { DiffAlignment.rows(in: $0) }.compactMap(\.new).first { $0.line.kind == .addition })
        model.toggleLine(line.line.id, in: javascript)
        XCTAssertEqual(model.selectedLines[javascript.file.path], [line.line.id])
        XCTAssertTrue((model.selectedLines[python.file.path] ?? []).isEmpty)
        model.editSelectedFiles()
        XCTAssertEqual(Set(model.editorWorkspace?.documents.map(\.path) ?? []), selected)
        XCTAssertEqual(model.selectedFileIDs, selected)
        XCTAssertEqual(model.fileDiffs.count, 2)
        let py = try XCTUnwrap(model.editorWorkspace?.documents.first { $0.path == "scripts/report.py" })
        XCTAssertEqual(SyntaxLanguage(path: py.path), .python)
        let highlights = try XCTUnwrap(SyntaxTokenizer.tokenize(py.text, language: .python))
        XCTAssertTrue(highlights.tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(highlights.tokens.contains { $0.kind == .string })
        try model.savePreferencesNow()
    }

    @MainActor
    func testEditorToDiffFollowsActiveTabWithoutChangingTreeSearch() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let model = try await open(demo)
        model.editPath("src/app.js")
        model.editPath("scripts/report.py")
        try await waitForDiff(model, paths: ["scripts/report.py"])
        model.fileSearch = "report.py"
        model.editorWorkspace?.selectedDocumentID = "src/app.js"
        model.showContent(.diff)
        try await waitForDiff(model, paths: ["src/app.js"])
        XCTAssertEqual(model.fileSearch, "report.py")
        XCTAssertEqual(model.selectedFileID, "src/app.js")
        model.editPath("config/settings.json")
        model.showContent(.diff)
        XCTAssertTrue(model.fileDiffs.isEmpty)
        XCTAssertEqual(model.selectedFileID, "config/settings.json")
        model.refresh()
        try await idle(model)
        XCTAssertTrue(model.fileDiffs.isEmpty, "刷新干净文件时不能跳到其他文件的差异")
        try model.savePreferencesNow()
    }
}
