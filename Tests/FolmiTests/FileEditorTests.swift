import XCTest
@testable import Folmi

@MainActor
final class FileEditorTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testEditSaveReadbackAndReopen() throws {
        let file = try write("first\n", path: "Notes/hello.txt")
        let workspace = EditorWorkspace(root: temporaryRoot)
        try workspace.open(path: "Notes/hello.txt")
        workspace.updateText(id: "Notes/hello.txt", text: "中文修改\nsecond\n")
        XCTAssertTrue(workspace.hasUnsavedChanges)
        try workspace.saveSelected()
        XCTAssertFalse(workspace.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "中文修改\nsecond\n")
        try workspace.close(id: "Notes/hello.txt")
        try workspace.open(path: "Notes/hello.txt")
        XCTAssertEqual(workspace.selectedDocument?.text, "中文修改\nsecond\n")
    }

    func testTwoTabsRetainIndependentDraftsAndSaveAll() throws {
        _ = try write("a\n", path: "a.txt")
        _ = try write("b\n", path: "b.txt")
        let workspace = EditorWorkspace(root: temporaryRoot)
        try workspace.open(path: "a.txt")
        workspace.updateText(id: "a.txt", text: "a edited\n")
        try workspace.open(path: "b.txt")
        workspace.updateText(id: "b.txt", text: "b edited\n")
        try workspace.open(path: "a.txt")
        XCTAssertEqual(workspace.documents.count, 2)
        XCTAssertEqual(workspace.selectedDocument?.text, "a edited\n")
        try workspace.saveAll()
        XCTAssertFalse(workspace.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: temporaryRoot.appendingPathComponent("a.txt")), "a edited\n")
        XCTAssertEqual(try String(contentsOf: temporaryRoot.appendingPathComponent("b.txt")), "b edited\n")
    }

    func testDirtyCloseRequiresExplicitDiscard() throws {
        _ = try write("original", path: "a.txt")
        let workspace = EditorWorkspace(root: temporaryRoot)
        try workspace.open(path: "a.txt")
        workspace.updateText(id: "a.txt", text: "draft")
        XCTAssertThrowsError(try workspace.close(id: "a.txt")) { XCTAssertEqual($0 as? FileEditorError, .unsavedChanges) }
        XCTAssertEqual(workspace.selectedDocument?.text, "draft")
        try workspace.close(id: "a.txt", discard: true)
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertNil(workspace.selectedDocumentID)
    }

    func testExternalChangeRefusesOverwriteAndPreservesDraft() throws {
        let file = try write("original", path: "a.txt")
        let workspace = EditorWorkspace(root: temporaryRoot)
        try workspace.open(path: "a.txt")
        workspace.updateText(id: "a.txt", text: "my draft")
        try Data("external change".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try workspace.saveSelected()) { XCTAssertEqual($0 as? FileEditorError, .changedOnDisk) }
        XCTAssertEqual(try String(contentsOf: file), "external change")
        XCTAssertEqual(workspace.selectedDocument?.text, "my draft")
        XCTAssertTrue(workspace.hasUnsavedChanges)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path).contains { $0.hasPrefix(".folmi-save-") })
    }

    func testBlocksTraversalAbsolutePathsAndGitMetadata() throws {
        _ = try write("private", path: ".git/config")
        _ = try write("metadata pointer", path: "nested/.git")
        _ = try write("case insensitive", path: "other/.GIT")
        let workspace = EditorWorkspace(root: temporaryRoot)
        for path in ["../outside.txt", "/etc/passwd", "./.git/config", ".git/config", "nested/.git", "other/.GIT", "a//b", "a/../x"] {
            XCTAssertThrowsError(try workspace.open(path: path), path)
        }
        XCTAssertTrue(workspace.documents.isEmpty)
    }

    func testBlocksSymlinksToInsideOutsideAndGitAndAtSaveTime() throws {
        let file = try write("original", path: "regular.txt")
        _ = try write("metadata", path: ".git/config")
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("link.txt"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("outside"), withDestinationURL: temporaryRoot.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("metadata"), withDestinationURL: temporaryRoot.appendingPathComponent(".git"))
        let workspace = EditorWorkspace(root: temporaryRoot)
        for path in ["link.txt", "outside/anything", "metadata/config"] { XCTAssertThrowsError(try workspace.open(path: path), path) }
        try workspace.open(path: "regular.txt")
        workspace.updateText(id: "regular.txt", text: "draft")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: temporaryRoot.appendingPathComponent(".git/config"))
        XCTAssertThrowsError(try workspace.saveSelected())
        XCTAssertEqual(try String(contentsOf: temporaryRoot.appendingPathComponent(".git/config")), "metadata")
        XCTAssertEqual(workspace.selectedDocument?.text, "draft")
    }

    func testPreservesPermissionsBOMAndCRLF() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("你好\r\nsecond\r\n".utf8)
        let file = try write(original, path: "script.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: file.path)
        let workspace = EditorWorkspace(root: temporaryRoot)
        try workspace.open(path: "script.sh")
        XCTAssertEqual(workspace.selectedDocument?.text, "你好\nsecond\n")
        workspace.updateText(id: "script.sh", text: "你好\nthird\n")
        try workspace.saveSelected()
        XCTAssertEqual(try Data(contentsOf: file), Data([0xEF, 0xBB, 0xBF]) + Data("你好\r\nthird\r\n".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o751)
        let reopened = EditorWorkspace(root: temporaryRoot)
        try reopened.open(path: "script.sh")
        XCTAssertEqual(reopened.selectedDocument?.text, "你好\nthird\n")
    }

    func testBinaryInvalidUTF8AndOversizedFilesOpenAsPreviewNotText() throws {
        _ = try write(Data([0x61, 0x00, 0x62]), path: "binary.bin")
        _ = try write(Data([0xFF, 0xFE, 0xFA]), path: "invalid.txt")
        _ = try write(Data(repeating: 0x61, count: 2 * 1_024 * 1_024 + 1), path: "large.txt")
        let workspace = EditorWorkspace(root: temporaryRoot)
        for path in ["binary.bin", "invalid.txt", "large.txt"] { try workspace.open(path: path) }
        XCTAssertEqual(workspace.documents.map(\.preview), [.file, .file, .document])
        XCTAssertTrue(workspace.documents.allSatisfy { $0.text.isEmpty })
        // Asking for the text still refuses what cannot be edited.
        let text = EditorWorkspace(root: temporaryRoot)
        for path in ["binary.bin", "invalid.txt", "large.txt"] { XCTAssertThrowsError(try text.open(path: path, asText: true), path) }
        XCTAssertTrue(text.documents.isEmpty)
    }

    func testMixedNewlineSaveKeepsDiskAndDraftIntact() throws {
        let file = try write("a\r\nb\n", path: "mixed.txt")
        let workspace = EditorWorkspace(root: temporaryRoot)
        try workspace.open(path: "mixed.txt")
        workspace.updateText(id: "mixed.txt", text: "edited\n")
        XCTAssertThrowsError(try workspace.saveSelected()) { XCTAssertEqual($0 as? FileEditorError, .mixedLineEndings) }
        XCTAssertEqual(try String(contentsOf: file), "a\r\nb\n")
        XCTAssertEqual(workspace.selectedDocument?.text, "edited\n")
    }

    func testFileBrowserSkipsMetadataBuildVendorAndLinks() throws {
        for path in ["src/a.swift", "README.md", ".gitignore", ".git/config", "node_modules/a.js", "build/a", ".build/a", "vendor/a", "dist/a", "nested/.GIT/config"] {
            _ = try write("text", path: path)
        }
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("linked-src"), withDestinationURL: temporaryRoot.appendingPathComponent("src"))
        let workspace = EditorWorkspace(root: temporaryRoot)
        XCTAssertEqual(try workspace.filePaths(), [".gitignore", "README.md", "src/a.swift"])
    }

    private func write(_ text: String, path: String) throws -> URL { try write(Data(text.utf8), path: path) }
    private func write(_ data: Data, path: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @MainActor
    func testCloseTabGroupsKeepUnsavedTabs() throws {
        for name in ["a", "b", "c", "d", "e"] { _ = try write("\(name)\n", path: "\(name).txt") }
        func fresh() throws -> EditorWorkspace {
            let workspace = EditorWorkspace(root: temporaryRoot)
            for name in ["a", "b", "c", "d", "e"] { try workspace.open(path: "\(name).txt") }
            workspace.updateText(id: "b.txt", text: "edited\n")
            workspace.selectedDocumentID = "c.txt"
            return workspace
        }
        var workspace = try fresh()
        XCTAssertEqual(workspace.closeTabs(.left, around: "c.txt"), 1)
        XCTAssertEqual(workspace.documents.map(\.id), ["b.txt", "c.txt", "d.txt", "e.txt"], "the unsaved tab stays")
        workspace = try fresh()
        workspace.closeTabs(.right, around: "c.txt")
        XCTAssertEqual(workspace.documents.map(\.id), ["a.txt", "b.txt", "c.txt"])
        workspace = try fresh()
        workspace.closeTabs(.others, around: "d.txt")
        XCTAssertEqual(workspace.documents.map(\.id), ["b.txt", "d.txt"])
        XCTAssertEqual(workspace.selectedDocumentID, "d.txt")
        workspace = try fresh()
        workspace.closeTabs(.saved, around: "a.txt")
        XCTAssertEqual(workspace.documents.map(\.id), ["b.txt"])
        workspace = try fresh()
        workspace.closeTabs(.all, around: "a.txt")
        XCTAssertEqual(workspace.documents.map(\.id), ["b.txt"])
        XCTAssertEqual(workspace.notice, "1 个未保存的标签保留了")
    }
}
