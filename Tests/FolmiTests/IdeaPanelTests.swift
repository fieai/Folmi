import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Folmi
import FolmiCore

final class IdeaHotKeyTests: XCTestCase {
    func testDefaultIsControlOptionF11() {
        XCTAssertEqual(IdeaHotKey.standard.title, "⌃⌥F11")
    }

    func testRecorderRefusesKeysThatWouldStopTyping() {
        XCTAssertNil(IdeaHotKey(keyCode: UInt16(kVK_ANSI_N), flags: [], characters: "n"))
        XCTAssertNil(IdeaHotKey(keyCode: UInt16(kVK_ANSI_N), flags: .shift, characters: "N"))
        XCTAssertEqual(IdeaHotKey(keyCode: UInt16(kVK_ANSI_N), flags: [.control, .option], characters: "n")?.title, "⌃⌥N")
        XCTAssertEqual(IdeaHotKey(keyCode: UInt16(kVK_Space), flags: .option, characters: " ")?.title, "⌥Space")
        XCTAssertEqual(IdeaHotKey(keyCode: UInt16(kVK_F5), flags: [], characters: nil)?.title, "F5")
    }

    func testOldSettingsGetTheDefaultShortcut() throws {
        let old = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"version":1,"projects":[]}"#.utf8))
        XCTAssertEqual(old.ideaHotKey, .standard)
        var preferences = WorkspacePreferences()
        preferences.ideaHotKey = IdeaHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")
        let decoded = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.ideaHotKey.title, "⌥Space")
    }
}

@MainActor
final class IdeaPanelTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDown() {
        InboxPanel.shared.hide()
        cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanupURLs = []
        super.tearDown()
    }

    private func status(_ demo: DemoRepository) async throws -> String {
        try await CommandRunner.git(["status", "--porcelain", "--untracked-files=all"], at: demo.root, environment: demo.environment)
    }

    func testNotesAreFilesInIdeasAndAnEmptyNoteLeavesNone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Ideas-\(UUID().uuidString)", isDirectory: true)
        cleanupURLs.append(root)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = IdeaStore.newFile(in: root, at: date)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "ideas")
        try IdeaStore.save("# 想法\n\n- [ ] 做个导出\n", to: first)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# 想法\n\n- [ ] 做个导出\n")
        // Same second: the next note gets its own file.
        XCTAssertNotEqual(IdeaStore.newFile(in: root, at: date), first)
        try IdeaStore.save("  \n", to: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testLocalOnlyHidesTheFolderFromGitWithoutTouchingGitignore() async throws {
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        try IdeaStore.save("一条想法\n", to: IdeaStore.newFile(in: demo.root))
        let before = try await status(demo)
        XCTAssertTrue(before.contains("ideas/"))
        try IdeaStore.setLocalOnly(true, root: demo.root)
        XCTAssertTrue(IdeaStore.isLocalOnly(demo.root))
        let hidden = try await status(demo)
        XCTAssertFalse(hidden.contains("ideas/"))
        XCTAssertFalse(hidden.contains(".gitignore"))
        try IdeaStore.setLocalOnly(false, root: demo.root)
        XCTAssertFalse(IdeaStore.isLocalOnly(demo.root))
        let shown = try await status(demo)
        XCTAssertTrue(shown.contains("ideas/"))
    }

    func testPanelWritesAsYouTypeAndComesBackToTheSameNote() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-IdeaPanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        for _ in 0..<200 where model.snapshot == nil || model.busy { try await Task.sleep(for: .milliseconds(25)) }

        InboxPanel.shared.show(model: model)
        let draft = try XCTUnwrap(InboxPanel.shared.draft)
        XCTAssertEqual(InboxPanel.shared.panel?.isVisible, true)
        XCTAssertEqual(draft.root.standardizedFileURL.path, demo.root.standardizedFileURL.path)
        // Typing can start right away: the editor has the caret, in the main editor's colors.
        for _ in 0..<40 where !(InboxPanel.shared.panel?.firstResponder is EditorTextView) { try await Task.sleep(for: .milliseconds(25)) }
        let editor = try XCTUnwrap(InboxPanel.shared.panel?.firstResponder as? EditorTextView)
        XCTAssertEqual(editor.accessibilityIdentifier(), "idea-editor")
        XCTAssertTrue(editor.markdownEditing)
        XCTAssertEqual(editor.font, model.editorPresentation.font())
        draft.text = "- [ ] 导出成 PDF"
        // Written a moment after typing stops, before the panel goes away.
        for _ in 0..<80 where !FileManager.default.fileExists(atPath: draft.url.path) { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(try String(contentsOf: draft.url, encoding: .utf8), "- [ ] 导出成 PDF")

        InboxPanel.shared.hide()
        XCTAssertEqual(InboxPanel.shared.panel?.isVisible, false)
        InboxPanel.shared.show(model: model)
        let again = try XCTUnwrap(InboxPanel.shared.draft)
        XCTAssertEqual(again.url, draft.url)
        XCTAssertEqual(again.text, "- [ ] 导出成 PDF")
        again.text = ""
        InboxPanel.shared.hide()
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.url.path))
    }

    func testOpenInFolmiShowsTheNoteInTheEditor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-IdeaOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        for _ in 0..<200 where model.snapshot == nil || model.busy { try await Task.sleep(for: .milliseconds(25)) }

        InboxPanel.shared.show(model: model)
        let draft = try XCTUnwrap(InboxPanel.shared.draft)
        draft.text = "# 导出\n\n- [ ] 支持 PDF\n"
        let path = draft.relativePath
        InboxPanel.shared.openInFolmi()
        XCTAssertEqual(InboxPanel.shared.panel?.isVisible, false)
        for _ in 0..<120 where model.editorWorkspace?.selectedDocumentID != path { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(model.editorWorkspace?.selectedDocumentID, path)
        XCTAssertEqual(model.content, .editor)
    }
}
