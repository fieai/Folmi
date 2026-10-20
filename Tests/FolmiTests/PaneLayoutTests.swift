import XCTest
@testable import Folmi

final class PaneLayoutTests: XCTestCase {
    func testDefaultsKeepTerminalCollapsedAndFocusEditor() {
        let layout = PaneLayoutState()
        XCTAssertEqual(layout.focused, .editor)
        XCTAssertNil(layout.maximized)
        XCTAssertEqual(layout.closedPanes, [.terminal])
        XCTAssertTrue(layout.isShown(.changes))
        XCTAssertFalse(layout.isShown(.terminal))
    }

    func testMaximizeHidesOtherCardsAndTogglesBack() {
        var layout = PaneLayoutState()
        layout.toggleMaximize(.changes)
        XCTAssertEqual(layout.maximized, .changes)
        XCTAssertEqual(layout.focused, .changes)
        XCTAssertTrue(layout.isShown(.changes))
        XCTAssertFalse(layout.isShown(.editor))
        layout.toggleMaximize(.changes)
        XCTAssertNil(layout.maximized)
        XCTAssertTrue(layout.isShown(.editor))
    }

    func testMaximizingClosedCardDoesNothing() {
        var layout = PaneLayoutState()
        layout.toggleMaximize(.terminal)
        XCTAssertNil(layout.maximized)
        XCTAssertEqual(layout.focused, .editor)
    }

    func testFocusingAnotherCardLeavesMaximizeAndReopens() {
        var layout = PaneLayoutState()
        layout.close(.changes)
        layout.toggleMaximize(.editor)
        layout.focus(.changes)
        XCTAssertNil(layout.maximized)
        XCTAssertFalse(layout.closed.contains(.changes))
        XCTAssertEqual(layout.focused, .changes)
        layout.toggleMaximize(.changes)
        layout.focus(.changes)
        XCTAssertEqual(layout.maximized, .changes, "re-focusing the maximized card keeps it maximized")
    }

    func testClosingFocusedCardMovesFocusAndClearsMaximize() {
        var layout = PaneLayoutState()
        layout.toggleMaximize(.editor)
        layout.close(.editor)
        XCTAssertNil(layout.maximized)
        XCTAssertEqual(layout.focused, .changes)
        XCTAssertEqual(layout.closedPanes, [.editor, .terminal])
    }

    func testSizesAreClamped() {
        var layout = PaneLayoutState()
        layout.sidebarWidth = 10
        layout.terminalHeight = 10_000
        XCTAssertEqual(layout.sidebarWidth, PaneLayoutState.sidebarRange.lowerBound)
        XCTAssertEqual(layout.terminalHeight, PaneLayoutState.terminalRange.upperBound)
    }

    func testPreferencesRoundTripAndOlderFilesUseDefaults() throws {
        var preferences = WorkspacePreferences()
        preferences.paneLayout.close(.changes)
        preferences.paneLayout.sidebarWidth = 400
        preferences.paneLayout.toggleMaximize(.editor)
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: data), preferences)

        let older = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"version":1,"showTerminal":true}"#.utf8))
        XCTAssertEqual(older.paneLayout, PaneLayoutState())
        let outOfRange = try JSONDecoder().decode(PaneLayoutState.self, from: Data(#"{"sidebarWidth":5,"closed":["changes"]}"#.utf8))
        XCTAssertEqual(outOfRange.sidebarWidth, PaneLayoutState.sidebarRange.lowerBound)
        XCTAssertEqual(outOfRange.closed, [.changes])
    }

    func testLeftBlockTabIsSavedAndOldFilesPaneIsDropped() throws {
        var layout = PaneLayoutState()
        XCTAssertEqual(layout.sideTab, .files)
        layout.sideTab = .changes
        XCTAssertEqual(try JSONDecoder().decode(PaneLayoutState.self, from: JSONEncoder().encode(layout)), layout)
        // A layout saved while the file tree was its own pane still loads; the unknown pane name is ignored.
        let older = try JSONDecoder().decode(PaneLayoutState.self,
                                             from: Data(#"{"closed":["files","terminal"],"focused":"files","filesHeight":300}"#.utf8))
        XCTAssertEqual(older.closed, [.terminal])
        XCTAssertEqual(older.focused, .editor)
        XCTAssertEqual(older.sideTab, .files)
    }

    @MainActor
    func testModelKeepsTerminalPaneInStepWithShowTerminal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-PaneTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))

        model.showTerminal = true
        XCTAssertTrue(model.paneLayout.isOpen(.terminal))
        model.paneLayout.focus(.terminal)
        model.closePane()
        XCTAssertFalse(model.showTerminal, "collapsing the terminal card hides the terminal")
        XCTAssertEqual(model.paneLayout.focused, .editor)

        model.closePane(.changes)
        XCTAssertEqual(model.paneLayout.closedPanes, [.changes, .terminal])
        model.notePaneClicked(.editor)
        XCTAssertEqual(model.paneLayout.focused, .editor)
        model.focusPane(.changes)
        XCTAssertTrue(model.paneLayout.closed.contains(.changes), "no repository open, so focus requests are ignored")
    }
}
