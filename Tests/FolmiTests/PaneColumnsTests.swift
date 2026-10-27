import FolmiCore
import SwiftUI
import XCTest
@testable import Folmi

final class PaneColumnsTests: XCTestCase {
    private var cleanup: [URL] = []
    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        super.tearDown()
    }

    func testSplitCopiesOrMovesTheTabAndHalvesTheWidth() throws {
        var layout = PaneColumns(tabs: ["a", "b"], selected: "b")
        let first = layout.activeID
        let right = try XCTUnwrap(layout.split("b", from: first, toRight: true, move: false))
        XCTAssertEqual(layout.columns.map(\.tabs), [["a", "b"], ["b"]], "a copy leaves the file in the old column")
        XCTAssertEqual(layout.activeID, right)
        XCTAssertEqual(layout.fractions, [0.5, 0.5])
        layout.split("a", from: first, toRight: false, move: true)
        XCTAssertEqual(layout.columns.map(\.tabs), [["a"], ["b"], ["b"]], "a move takes the tab out of its column")
        XCTAssertEqual(layout.fractions, [0.25, 0.25, 0.5])
        XCTAssertFalse(layout.canSplit)
        XCTAssertNil(layout.split("a", from: first, toRight: true, move: false), "no fourth column")
    }

    func testMovingTheOnlyTabKeepsItsColumn() throws {
        var layout = PaneColumns(tabs: ["a"], selected: "a")
        layout.split("a", from: layout.activeID, toRight: true, move: true)
        XCTAssertEqual(layout.columns.map(\.tabs), [["a"], ["a"]], "the old column is never left empty")
    }

    func testSelectFindsTheColumnThatHasTheTab() throws {
        var layout = PaneColumns(tabs: ["a", "b"], selected: "a")
        let left = layout.activeID
        let right = try XCTUnwrap(layout.split("b", from: left, toRight: true, move: true))
        layout.select("a")
        XCTAssertEqual(layout.activeID, left)
        XCTAssertEqual(layout.selected, "a")
        layout.select("c")
        XCTAssertEqual(layout.columns[0].tabs, ["a", "c"], "a new tab opens in the active column")
        layout.select("b", in: left)
        XCTAssertEqual(layout.columns[0].tabs, ["a", "c", "b"])
        XCTAssertEqual(layout.columns[1].tabs, ["b"])
        layout.activate(right)
        XCTAssertEqual(layout.selected, "b")
    }

    func testRemovingTheLastTabOfAColumnClosesIt() throws {
        var layout = PaneColumns(tabs: ["a", "b"], selected: "a")
        let right = try XCTUnwrap(layout.split("b", from: layout.activeID, toRight: true, move: true))
        layout.remove("b", from: right)
        XCTAssertFalse(layout.isSplit)
        XCTAssertEqual(layout.fractions, [1])
        XCTAssertEqual(layout.columns[0].tabs, ["a"])
        layout.remove("a")
        XCTAssertEqual(layout.columns.count, 1, "the last column stays, empty")
        XCTAssertNil(layout.selected)
    }

    func testMergeHandsTheTabsToTheNeighbourWithoutLosingAny() throws {
        var layout = PaneColumns(tabs: ["a", "b", "c"], selected: "a")
        let left = layout.activeID
        let right = try XCTUnwrap(layout.split("c", from: left, toRight: true, move: true))
        layout.select("b", in: right)
        layout.merge(right)
        XCTAssertFalse(layout.isSplit)
        XCTAssertEqual(layout.columns[0].tabs, ["a", "b", "c"])
        XCTAssertEqual(layout.selected, "b", "the merged column's file stays in view")
        XCTAssertEqual(layout.activeID, left)
    }

    func testMoveGoesToTheNearestTabColumnPastTheDiff() throws {
        var layout = PaneColumns(tabs: ["a", "b"], selected: "a")
        let left = layout.activeID
        layout.addDiff(atRight: true)
        XCTAssertEqual(layout.columns.map(\.isDiff), [false, true])
        XCTAssertFalse(layout.move("a", from: left, toRight: true), "the diff column takes no tabs")
        let right = try XCTUnwrap(layout.split("b", from: left, toRight: true, move: true))
        XCTAssertEqual(layout.columns.map(\.isDiff), [false, false, true])
        XCTAssertTrue(layout.move("a", from: left, toRight: true))
        XCTAssertEqual(layout.columns.map(\.tabs), [["b", "a"], []], "the emptied column closed and the diff stayed")
        XCTAssertEqual(layout.activeID, right)
    }

    func testDiffColumnNeverStandsAloneAndIsNeverActive() throws {
        var layout = PaneColumns(tabs: ["a"], selected: "a")
        let files = layout.activeID
        layout.addDiff(atRight: false)
        let diff = layout.columns[0].id
        layout.activate(diff)
        XCTAssertEqual(layout.activeID, files)
        layout.merge(files)
        XCTAssertFalse(layout.hasDiff, "closing the only file column beside 差异 closes 差异 instead")
        XCTAssertEqual(layout.columns[0].tabs, ["a"])
        layout.addDiff(atRight: false)
        layout.remove("a")
        XCTAssertEqual(layout.columns.map(\.isDiff), [true, false], "an empty file column stays beside the diff")
    }

    func testResizeKeepsBothColumnsAboveTheMinimum() throws {
        var layout = PaneColumns(tabs: ["a"], selected: "a")
        layout.split("a", from: layout.activeID, toRight: true, move: false)
        layout.resize(0, to: 0.9, minimum: 0.2)
        XCTAssertEqual(layout.fractions[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(layout.fractions[1], 0.2, accuracy: 0.0001)
        layout.equalize()
        XCTAssertEqual(layout.fractions, [0.5, 0.5])
    }

    func testDecodingRepairsBrokenSavedColumns() throws {
        var layout = PaneColumns(tabs: ["a", "b"], selected: "a")
        layout.split("b", from: layout.activeID, toRight: true, move: true)
        layout.addDiff(atRight: true)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(PaneColumns.self, from: data), layout)

        let broken = #"{"columns":[{"id":"\#(UUID())","tabs":[],"isDiff":true}],"fractions":[-1]}"#
        let repaired = try JSONDecoder().decode(PaneColumns.self, from: Data(broken.utf8))
        XCTAssertEqual(repaired.columns.count, 1)
        XCTAssertFalse(repaired.columns[0].isDiff, "a lone diff column becomes an empty file column")
        XCTAssertEqual(repaired.fractions, [1])
        let old = try JSONDecoder().decode(ProjectPreferences.self, from: Data(#"{"rootPath":"/tmp/x","editorTabs":[]}"#.utf8))
        XCTAssertNil(old.editorColumns, "settings from before splitting still load")
    }

    func testKeepDropsClosedTabsAndAddsNewOnesToTheActiveColumn() throws {
        var layout = PaneColumns(tabs: ["1", "2"], selected: "1")
        layout.split("2", from: layout.activeID, toRight: true, move: true)
        layout.keep(["1", "3"])
        XCTAssertEqual(layout.columns.map(\.tabs), [["1", "3"]])
        let renamed = layout.mapTabs { $0 == "1" ? "x" : nil }
        XCTAssertEqual(renamed.columns[0].tabs, ["x"])
    }

    // MARK: Editor

    @MainActor
    func testEditorColumnsShareTheFileAndCloseOnlyTheirTab() throws {
        let root = try project(["a.txt", "b.txt"])
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "a.txt")
        try workspace.open(path: "b.txt")
        let left = workspace.columns.activeID
        let right = try XCTUnwrap(workspace.columns.split("a.txt", from: left, toRight: true, move: false))
        XCTAssertEqual(workspace.selectedDocumentID, "a.txt")
        workspace.updateText(id: "a.txt", text: "edited\n")
        XCTAssertEqual(workspace.documents.count, 2, "one file in two columns is one document")
        XCTAssertFalse(workspace.closingClosesFile("a.txt", in: right))
        try workspace.closeTab(id: "a.txt", in: right)
        XCTAssertFalse(workspace.columns.isSplit)
        XCTAssertEqual(workspace.documents.first { $0.id == "a.txt" }?.text, "edited\n", "the draft is kept in the other column")
        XCTAssertTrue(workspace.closingClosesFile("a.txt", in: left))
        XCTAssertThrowsError(try workspace.closeTab(id: "a.txt", in: left)) { XCTAssertEqual($0 as? FileEditorError, .unsavedChanges) }

        try workspace.open(path: "b.txt", in: try XCTUnwrap(workspace.columns.split("b.txt", from: left, toRight: true, move: true)))
        XCTAssertEqual(workspace.columns.columns.map(\.tabs), [["a.txt"], ["b.txt"]])
        XCTAssertEqual(workspace.closeTabs(.all, around: "b.txt"), 0)
        XCTAssertEqual(workspace.documents.map(\.id), ["a.txt"], "关闭全部 only closes the column's own tabs")
    }

    @MainActor
    func testEditorColumnsComeBackAfterRestart() throws {
        let root = try project(["a.txt", "b.txt"])
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "a.txt")
        try workspace.open(path: "b.txt")
        workspace.columns.split("b.txt", from: workspace.columns.activeID, toRight: false, move: true)
        let saved = workspace.columns
        let reopened = EditorWorkspace(root: root)
        reopened.restoreSession(tabs: workspace.sessionState(), selectedPath: "b.txt", columns: saved)
        XCTAssertEqual(reopened.columns.columns.map(\.tabs), [["b.txt"], ["a.txt"]])
        XCTAssertEqual(reopened.selectedDocumentID, "b.txt")
    }

    // MARK: Model

    @MainActor
    func testDiffColumnAndEditBeside() async throws {
        let (model, _) = try await openDemo()
        defer { _ = model.prepareToQuit() }
        let editor = try XCTUnwrap(model.editorWorkspace)
        let change = try XCTUnwrap(model.snapshot?.files.first { $0.hasWorking && !$0.isUntracked && $0.worktreeCode != "D" })
        model.selectFile(change)
        try await eventually { model.fileDiffs.first?.file.path == change.path }
        XCTAssertEqual(model.content, .diff)
        model.editBeside(try XCTUnwrap(model.fileDiffs.first))
        XCTAssertEqual(editor.columns.columns.map(\.isDiff), [true, false], "the diff on the left, the file on the right")
        XCTAssertEqual(model.content, .editor)
        XCTAssertEqual(editor.selectedDocumentID, change.path)

        // 差异 only moves to the diff column; the file column keeps its file.
        model.showContent(.diff)
        XCTAssertEqual(model.activeColumnID(.editor), editor.columns.columns[0].id)
        let other = try XCTUnwrap(model.snapshot?.files.first { $0.path != change.path && $0.hasWorking })
        model.selectFile(other)
        try await eventually { model.fileDiffs.first?.file.path == other.path }
        XCTAssertEqual(editor.columns.columns[1].selected, change.path, "picking another change leaves the file being edited")
        model.noteColumnClicked(.editor, editor.columns.columns[1].id)
        XCTAssertEqual(model.content, .editor)

        model.closeEditorColumn(editor.columns.columns[1].id)
        XCTAssertFalse(editor.columns.isSplit)
        XCTAssertEqual(model.content, .diff, "closing the files beside 差异 leaves the diff on the whole card")
        XCTAssertEqual(editor.documents.map(\.id), [change.path], "and nothing closed")
    }

    /// On screen: the diff column on the left with its title, the file's tab in the column beside it.
    @MainActor
    func testSplitEditorShowsTheDiffBesideTheFile() async throws {
        let (model, _) = try await openDemo()
        defer { _ = model.prepareToQuit() }
        let change = try XCTUnwrap(model.snapshot?.files.first { $0.hasWorking && !$0.isUntracked && $0.worktreeCode != "D" })
        model.selectFile(change)
        try await eventually { model.fileDiffs.first?.file.path == change.path }
        model.editBeside(try XCTUnwrap(model.fileDiffs.first))
        let tracker = PaneFocusTracker()
        let host = NSHostingView(rootView: EditorCard(model: model, tracker: tracker))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(nanoseconds: 600_000_000)
        // The columns' own title row, below the card's page switcher.
        let text = try ScreenText.read(host, top: 90, skip: 40)
        XCTAssertTrue(text.contains("差异"), text)
        XCTAssertTrue(text.contains((change.path as NSString).lastPathComponent), text)
        XCTAssertEqual(model.splitRoom[.editor], true, "1400 points leave room for a third column")
        // Clicking into the diff column makes it the active one.
        model.noteColumnClicked(.editor, try XCTUnwrap(model.editorWorkspace?.columns.columns.first?.id))
        XCTAssertEqual(model.content, .diff)
    }

    @MainActor
    func testTerminalSplitMovesTabsAndComesBackAfterRestart() async throws {
        let (model, storeURL) = try await openDemo()
        model.toggleTerminal()
        let first = try XCTUnwrap(model.terminalSession)
        let root = try XCTUnwrap(model.repositoryURL?.path)
        model.splitTerminal(toRight: true)
        XCTAssertEqual(model.terminalTabs.count, 2, "splitting a column with one tab opens a new shell beside it")
        let second = try XCTUnwrap(model.terminalSession)
        XCTAssertFalse(first === second)
        var layout = try XCTUnwrap(model.terminalColumns[root])
        XCTAssertEqual(layout.columns.map(\.tabs), [[first.id.uuidString], [second.id.uuidString]])

        model.newTerminalTab()
        let third = try XCTUnwrap(model.terminalSession)
        layout = try XCTUnwrap(model.terminalColumns[root])
        XCTAssertEqual(layout.columns[1].tabs, [second.id.uuidString, third.id.uuidString], "a new tab joins the active column")
        model.selectTerminalTab(first.id)
        XCTAssertEqual(model.terminalColumns[root]?.activeIndex, 0)
        model.moveTerminalTab(third.id, from: layout.columns[1].id, toRight: false)
        XCTAssertEqual(model.terminalColumns[root]?.columns[0].tabs, [first.id.uuidString, third.id.uuidString])
        XCTAssertTrue(model.terminalSession === third)

        try model.savePreferencesNow()
        let saved = try XCTUnwrap(try WorkspaceStore(url: storeURL).load().projects.first?.terminalColumns)
        XCTAssertEqual(saved.columns.map(\.tabs), [["0", "2"], ["1"]], "saved by place in the tab list")

        model.closeTerminalTab(second.id)
        XCTAssertEqual(model.terminalColumns[root]?.isSplit, false, "a column whose last shell ended closes")
        XCTAssertTrue(first.isRunning && third.isRunning)
        _ = model.prepareToQuit()
    }

    // MARK: Helpers

    private func project(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Columns-\(UUID().uuidString)", isDirectory: true)
        cleanup.append(root)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @MainActor
    private func openDemo() async throws -> (FolmiModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Columns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanup.append(directory)
        let demo = try await DemoRepository.create()
        cleanup.append(demo.root.deletingLastPathComponent())
        let storeURL = directory.appendingPathComponent("workspace.json")
        let model = FolmiModel(store: WorkspaceStore(url: storeURL))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil && model.editorWorkspace != nil }
        return (model, storeURL)
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); throw FolmiFailure(message: "timed out") }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}
