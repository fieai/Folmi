import Foundation
import XCTest
@testable import Folmi

/// Integration checks use only new isolated demos and a private, disposable preferences directory.
final class EditorWorkflowTests: XCTestCase {
    private func makeStore() throws -> WorkspaceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Folmi-EditorWorkflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return WorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
    }

    @MainActor
    private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待超时：\(description)", file: file, line: line)
                throw FolmiFailure(message: "等待超时：\(description)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    @discardableResult
    private func open(_ demo: DemoRepository, model: FolmiModel,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目", file: file, line: line) { !model.busy && model.snapshot != nil }
        XCTAssertNil(model.errorMessage, file: file, line: line)
        return try XCTUnwrap(model.repositoryURL?.path, file: file, line: line)
    }

    @MainActor
    private func search(_ query: String, model: FolmiModel,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> ProjectSearchResult {
        model.showProjectSearch = true
        model.projectSearchQuery = query
        model.performProjectSearch()
        try await eventually("项目全文搜索", file: file, line: line) {
            !model.projectSearching && model.projectSearchResult != nil
        }
        XCTAssertNil(model.errorMessage, file: file, line: line)
        return try XCTUnwrap(model.projectSearchResult, file: file, line: line)
    }

    @MainActor
    private func selectedRange(_ editor: EditorWorkspace, path: String,
                               file: StaticString = #filePath, line: UInt = #line) throws -> NSRange {
        let state = try XCTUnwrap(editor.tabStates[path], file: file, line: line)
        return NSRange(location: state.selectionLocation, length: state.selectionLength)
    }

    @MainActor
    func testQuickOpenFilenameLineAndColumnReachTheActualEditorCaret() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let indexURL = demo.root.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let fileURL = demo.root.appendingPathComponent("src/app.js")
        let bytesBefore = try Data(contentsOf: fileURL)
        let model = FolmiModel(store: store)
        defer { model.cancelProjectSearch(); try? model.savePreferencesNow() }
        try await open(demo, model: model)
        XCTAssertTrue(model.quickOpenPaths.contains("docs/guide.md"))
        model.showQuickOpen = true
        let match = try XCTUnwrap(QuickOpenMatcher.matches(paths: model.quickOpenPaths, query: "app.js:5:3").first)
        model.openQuickMatch(match)
        let editor = try XCTUnwrap(model.editorWorkspace)
        let document = try XCTUnwrap(editor.selectedDocument)
        let lines = document.text.components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 5)
        let expectedLocation = lines.prefix(4).reduce(0) { $0 + ($1 as NSString).length + 1 } + 2
        XCTAssertEqual(document.path, "src/app.js")
        XCTAssertEqual(try selectedRange(editor, path: document.path), NSRange(location: expectedLocation, length: 0))
        XCTAssertEqual(model.content, .editor)
        XCTAssertFalse(model.showQuickOpen)
        XCTAssertEqual(model.quickOpenPaths.first, "src/app.js")
        XCTAssertEqual(try Data(contentsOf: fileURL), bytesBefore)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testSearchHitBOMCRLFUnicodeAndUnsavedOverlaySelectTheSameEditorTextWithoutWritingFilesOrIndex() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let fixturePath = "scratch/positions.py"
        let fixtureURL = demo.root.appendingPathComponent(fixturePath)
        let raw = "\u{FEFF}😀 needle\r\n中文 needle\r\n"
        try Data(raw.utf8).write(to: fixtureURL)
        let diskBefore = try Data(contentsOf: fixtureURL)
        let indexURL = demo.root.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let model = FolmiModel(store: store)
        defer { model.cancelProjectSearch(); try? model.savePreferencesNow() }
        try await open(demo, model: model)
        let diskHits = try await search("needle", model: model).hits.filter { $0.path == fixturePath }
        XCTAssertEqual(diskHits.map(\.line), [1, 2])
        XCTAssertEqual(diskHits.map(\.column), [4, 4])
        for hit in diskHits {
            model.openSearchHit(hit)
            let editor = try XCTUnwrap(model.editorWorkspace)
            let document = try XCTUnwrap(editor.selectedDocument)
            XCTAssertEqual(document.path, fixturePath)
            XCTAssertFalse(document.text.hasPrefix("\u{FEFF}"))
            XCTAssertFalse(document.text.contains("\r"))
            XCTAssertEqual((document.text as NSString).substring(with: try selectedRange(editor, path: fixturePath)), "needle")
        }
        let editor = try XCTUnwrap(model.editorWorkspace)
        let draft = "😀 current\nonly_unsaved_overlay_42 value\n"
        editor.updateText(id: fixturePath, text: draft)
        let overlayResult = try await search("only_unsaved_overlay_42", model: model)
        let hit = try XCTUnwrap(overlayResult.hits.first)
        XCTAssertEqual(overlayResult.hits.count, 1)
        XCTAssertEqual(hit.path, fixturePath)
        XCTAssertEqual(hit.line, 2)
        XCTAssertEqual(hit.column, 1)
        XCTAssertTrue(try XCTUnwrap(overlayResult.notice).contains("含打开文档的当前内容"))
        model.openSearchHit(hit)
        let selected = try selectedRange(editor, path: fixturePath)
        XCTAssertEqual((draft as NSString).substring(with: selected), "only_unsaved_overlay_42")
        XCTAssertTrue(editor.selectedDocument?.isDirty == true)
        XCTAssertEqual(try Data(contentsOf: fixtureURL), diskBefore, "全文搜索和跳转不能保存未保存正文")
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore, "搜索与编辑定位不能刷新写入或暂存索引")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testProjectSessionsKeepTabOrderCaretScrollAndDirtyMemoryThenRestoreSelectedProjectAfterRestart() async throws {
        let first = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: first.root.deletingLastPathComponent()) }
        let second = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: second.root.deletingLastPathComponent()) }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let model = FolmiModel(store: store)
        defer { model.cancelProjectSearch(); try? model.savePreferencesNow() }
        let firstPath = try await open(first, model: model)
        model.editPath("src/app.js")
        model.editPath("docs/guide.md")
        let firstEditor = try XCTUnwrap(model.editorWorkspace)
        let originalSource = try XCTUnwrap(firstEditor.documents.first { $0.path == "src/app.js" }?.text)
        let dirtySource = originalSource + "\n// in-memory-only-session-42\n"
        firstEditor.updateText(id: "src/app.js", text: dirtySource)
        firstEditor.updateEditorState(id: "src/app.js", selection: NSRange(location: 12, length: 5), scrollOffset: 121.5)
        firstEditor.updateEditorState(id: "docs/guide.md", selection: NSRange(location: 7, length: 4), scrollOffset: 245.25)
        firstEditor.selectedDocumentID = "src/app.js"
        let firstStates = firstEditor.sessionState()
        let secondPath = try await open(second, model: model)
        model.editPath("config/settings.json")
        model.editPath("scripts/report.py")
        let secondEditor = try XCTUnwrap(model.editorWorkspace)
        secondEditor.updateEditorState(id: "config/settings.json", selection: NSRange(location: 5, length: 3), scrollOffset: 42.5)
        secondEditor.updateEditorState(id: "scripts/report.py", selection: NSRange(location: 10, length: 2), scrollOffset: 93.75)
        secondEditor.selectedDocumentID = "config/settings.json"
        let secondStates = secondEditor.sessionState()
        model.switchProject(firstPath)
        try await eventually("切回第一个演示项目") { !model.busy }
        XCTAssertTrue(model.editorWorkspace === firstEditor)
        XCTAssertEqual(firstEditor.sessionState(), firstStates)
        XCTAssertEqual(firstEditor.documents.first { $0.path == "src/app.js" }?.text, dirtySource)
        XCTAssertTrue(firstEditor.hasUnsavedChanges)
        model.switchProject(secondPath)
        try await eventually("选中第二个项目后保存") { !model.busy }
        try model.savePreferencesNow()
        let saved = try store.load()
        XCTAssertEqual(saved.selectedProjectPath, secondPath)
        XCTAssertEqual(saved.projects.first { $0.rootPath == firstPath }?.editorTabs, firstStates)
        XCTAssertEqual(saved.projects.first { $0.rootPath == secondPath }?.editorTabs, secondStates)
        XCTAssertFalse(try String(contentsOf: store.url, encoding: .utf8).contains("in-memory-only-session-42"),
                       "个人配置只保存会话位置，不偷偷持久化未保存正文")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        let restarted = FolmiModel(store: WorkspaceStore(url: store.url))
        defer { restarted.cancelProjectSearch(); try? restarted.savePreferencesNow() }
        restarted.restoreStartup()
        try await eventually("重启恢复当前项目和标签") { !restarted.busy && restarted.snapshot != nil }
        let restoredSecond = try XCTUnwrap(restarted.editorWorkspace)
        XCTAssertEqual(restarted.repositoryURL?.path, secondPath)
        XCTAssertEqual(restoredSecond.documents.map(\.path), ["config/settings.json", "scripts/report.py"])
        XCTAssertEqual(restoredSecond.selectedDocumentID, "config/settings.json")
        XCTAssertEqual(restoredSecond.sessionState(), secondStates)
        restarted.switchProject(firstPath)
        try await eventually("重启后切回另一项目") { !restarted.busy }
        let restoredFirst = try XCTUnwrap(restarted.editorWorkspace)
        XCTAssertEqual(restoredFirst.documents.map(\.path), ["src/app.js", "docs/guide.md"])
        XCTAssertEqual(restoredFirst.selectedDocumentID, "src/app.js")
        XCTAssertEqual(restoredFirst.sessionState(), firstStates)
        XCTAssertEqual(restoredFirst.selectedDocument?.text, originalSource)
        XCTAssertFalse(restoredFirst.hasUnsavedChanges)
        XCTAssertEqual(firstEditor.selectedDocument?.text, dirtySource, "重建另一 Model 不得丢失原 Model 的 dirty 内存")
        XCTAssertNil(restarted.errorMessage)
    }

    @MainActor
    func testFontSizeLightDarkAndMarkdownModePersistAcrossRestart() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let model = FolmiModel(store: store)
        defer { model.cancelProjectSearch(); try? model.savePreferencesNow() }
        try await open(demo, model: model)
        model.appearance = .dark
        model.editorFontSize = 18
        XCTAssertEqual(model.editorPresentation.fontSize, 18)
        model.editPath("docs/guide.md")
        XCTAssertTrue(model.isMarkdownDocument)
        XCTAssertTrue(model.editorWorkspace?.markdownReading == true)
        model.toggleMarkdownPreview()
        model.appearance = .light
        model.editorFontSize = 20
        try model.savePreferencesNow()
        let light = FolmiModel(store: WorkspaceStore(url: store.url))
        defer { light.cancelProjectSearch(); try? light.savePreferencesNow() }
        light.restoreStartup()
        try await eventually("恢复浅色和 Markdown 编辑模式") { !light.busy && light.snapshot != nil }
        XCTAssertEqual(light.appearance, .light)
        XCTAssertEqual(light.editorFontSize, 20)
        XCTAssertEqual(light.editorWorkspace?.presentation.appearance, .light)
        XCTAssertEqual(light.editorWorkspace?.presentation.fontSize, 20)
        XCTAssertTrue(light.editorWorkspace?.markdownReading == false)
        XCTAssertEqual(light.editorWorkspace?.selectedDocumentID, "docs/guide.md")
        light.appearance = .dark
        light.editorFontSize = 18
        light.toggleMarkdownPreview()
        try light.savePreferencesNow()
        let dark = FolmiModel(store: WorkspaceStore(url: store.url))
        defer { dark.cancelProjectSearch(); try? dark.savePreferencesNow() }
        dark.restoreStartup()
        try await eventually("恢复深色和 Markdown 阅读模式") { !dark.busy && dark.snapshot != nil }
        XCTAssertEqual(dark.appearance, .dark)
        XCTAssertEqual(dark.editorPresentation.fontSize, 18)
        XCTAssertEqual(dark.editorWorkspace?.presentation, dark.editorPresentation)
        XCTAssertTrue(dark.editorWorkspace?.markdownReading == true)
        XCTAssertNil(dark.errorMessage)
    }

    @MainActor
    func testCancelledAndPreviousProjectSearchesDoNotLandInAnotherProject() async throws {
        let first = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: first.root.deletingLastPathComponent()) }
        let second = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: second.root.deletingLastPathComponent()) }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let model = FolmiModel(store: store)
        defer { model.cancelProjectSearch(); try? model.savePreferencesNow() }
        let firstPath = try await open(first, model: model)
        let secondPath = try await open(second, model: model)
        model.editPath("README.md")
        model.editorWorkspace?.updateText(id: "README.md", text: "second_project_marker_42\n")
        model.switchProject(firstPath)
        try await eventually("返回第一个项目开始搜索") { !model.busy }
        model.editPath("README.md")
        model.editorWorkspace?.updateText(id: "README.md", text: String(repeating: "first_project_marker_42\n", count: 50_000))
        model.showProjectSearch = true
        model.projectSearchQuery = "first_project_marker_42"
        model.performProjectSearch()
        model.switchProject(secondPath)
        try await eventually("切项目使旧搜索失效") { !model.busy && model.repositoryURL?.path == secondPath }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.projectSearchResult)
        XCTAssertFalse(model.projectSearching)
        XCTAssertEqual(model.projectSearchQuery, "")
        let result = try await search("second_project_marker_42", model: model)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits.first?.path, "README.md")
        XCTAssertEqual(result.hits.first?.preview, "second_project_marker_42")
        model.projectSearchQuery = "cancelled_marker_42"
        model.performProjectSearch()
        model.cancelProjectSearch()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.projectSearching)
        XCTAssertNil(model.projectSearchResult)
        XCTAssertNil(model.errorMessage)
    }
}
