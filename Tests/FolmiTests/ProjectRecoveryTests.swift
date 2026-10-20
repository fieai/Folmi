import XCTest
@testable import Folmi
@testable import FolmiCore

final class ProjectRecoveryTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    @MainActor
    private func model(root: URL, projects: [ProjectPreferences], selected: String? = nil) throws -> FolmiModel {
        let store = WorkspaceStore(url: root.appendingPathComponent("settings/workspace.json"))
        try store.save(WorkspacePreferences(projects: projects, selectedProjectPath: selected))
        return FolmiModel(store: store)
    }

    @MainActor
    func testMissingProjectIsReportedBeforeACachedSnapshotCanBeInstalled() throws {
        let root = try temporaryRoot(), missing = root.appendingPathComponent("moved-away")
        let folmi = try model(root: root, projects: [.init(rootPath: missing.path, name: "原项目")])
        folmi.open(missing)
        XCTAssertEqual(folmi.missingProjectPath, missing.path)
        XCTAssertEqual(folmi.missingProjectName, "原项目")
        XCTAssertNil(folmi.repositoryURL)
        XCTAssertNil(folmi.snapshot)
        XCTAssertFalse(folmi.busy)
        XCTAssertTrue(folmi.errorMessage?.contains(missing.path) == true)
    }

    @MainActor
    func testRelocationKeepsDraftTabsAndCommentIdentityAndPersistsNewRoot() async throws {
        let root = try temporaryRoot(), old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        _ = try await CommandRunner.git(["init", "-q", "--template=", "--initial-branch=main"], at: new)
        var project = ProjectPreferences(rootPath: old.path, name: "我的项目", draftMessage: "未提交的说明")
        project.editorTabs = [EditorTabState(path: "README.md")]
        project.selectedEditorPath = "README.md"
        project.reviewComments = [.init(projectPath: old.path, path: "README.md", area: .working,
                                       firstLine: 1, lastLine: 1, excerpt: ["+hello"], body: "再看看")]
        let folmi = try model(root: root, projects: [project], selected: old.path)
        folmi.missingProjectPath = old.path
        let relocated = await folmi.relocateMissingProject(to: new)
        XCTAssertEqual(relocated?.resolvingSymlinksInPath(), new.resolvingSymlinksInPath())
        let saved = try folmi.store.load(), actual = try XCTUnwrap(saved.projects.first)
        XCTAssertEqual(actual.rootPath, relocated?.path)
        XCTAssertEqual(saved.selectedProjectPath, actual.rootPath)
        XCTAssertEqual(actual.name, "我的项目")
        XCTAssertEqual(actual.draftMessage, "未提交的说明")
        XCTAssertEqual(actual.editorTabs.map(\.path), ["README.md"])
        XCTAssertEqual(actual.reviewComments.first?.id, project.reviewComments.first?.id)
        XCTAssertEqual(actual.reviewComments.first?.projectPath, actual.rootPath)
        XCTAssertNil(folmi.missingProjectPath)
        XCTAssertNil(folmi.errorMessage)
    }

    @MainActor
    func testInvalidRelocationPreservesSavedProject() async throws {
        let root = try temporaryRoot(), old = root.appendingPathComponent("old")
        let folmi = try model(root: root, projects: [.init(rootPath: old.path, name: "保留")], selected: old.path)
        folmi.missingProjectPath = old.path
        let relocated = await folmi.relocateMissingProject(to: root)
        XCTAssertNil(relocated)
        XCTAssertEqual(folmi.missingProjectPath, old.path)
        XCTAssertEqual(try folmi.store.load().projects.map(\.rootPath), [old.path])
        XCTAssertFalse(folmi.busy)
    }

    @MainActor
    func testRemoveOnlyChangesTheProjectListAndSurvivesReopen() throws {
        let root = try temporaryRoot(), folder = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let folmi = try model(root: root, projects: [.init(rootPath: folder.path, name: "移除列表")], selected: folder.path)
        folmi.missingProjectPath = folder.path
        XCTAssertTrue(folmi.removeMissingProject())
        let saved = try folmi.store.load()
        XCTAssertTrue(saved.projects.isEmpty)
        XCTAssertNil(saved.selectedProjectPath)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
        XCTAssertNil(folmi.missingProjectPath)
    }
    @MainActor
    private func repository(_ root: URL, _ name: String) async throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await CommandRunner.git(["init", "-q", "--template=", "--initial-branch=main"], at: folder)
        // The path as Git reports it (/private/var for temporary folders), which is what the app saves.
        let top = try await CommandRunner.git(["rev-parse", "--show-toplevel"], at: folder)
        return URL(fileURLWithPath: top.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    private func waitUntilIdle(_ folmi: FolmiModel) async throws {
        for _ in 0..<200 where folmi.busy { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(folmi.busy)
    }

    @MainActor
    func testRemovingAnotherProjectKeepsItsFolderAndTheOpenProject() async throws {
        let root = try temporaryRoot()
        let a = try await repository(root, "a"), b = try await repository(root, "b")
        let folmi = try model(root: root, projects: [.init(rootPath: a.path, name: "A"), .init(rootPath: b.path, name: "B")])
        folmi.open(a)
        try await waitUntilIdle(folmi)
        folmi.removeProject(b.path)
        XCTAssertEqual(folmi.projects.map(\.name), ["A"])
        XCTAssertEqual(try folmi.store.load().projects.map(\.name), ["A"])
        XCTAssertEqual(folmi.repositoryURL?.path, a.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent(".git").path), "files on disk stay")
    }

    @MainActor
    func testRemovingTheOpenProjectSwitchesFirstAndTheOnlyProjectStays() async throws {
        let root = try temporaryRoot()
        let a = try await repository(root, "a"), b = try await repository(root, "b")
        let folmi = try model(root: root, projects: [.init(rootPath: a.path, name: "A"), .init(rootPath: b.path, name: "B")])
        folmi.open(a)
        try await waitUntilIdle(folmi)
        let openPath = try XCTUnwrap(folmi.repositoryURL?.path)
        XCTAssertTrue(folmi.canRemoveProject(openPath))
        folmi.removeProject(openPath)
        try await waitUntilIdle(folmi)
        XCTAssertEqual(folmi.repositoryURL?.path, b.path)
        XCTAssertEqual(folmi.projects.map(\.name), ["B"])
        XCTAssertFalse(folmi.canRemoveProject(folmi.repositoryURL!.path), "the last project cannot be removed while open")
        folmi.removeProject(folmi.repositoryURL!.path)
        XCTAssertEqual(folmi.projects.map(\.name), ["B"])
    }
}
