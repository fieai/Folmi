import XCTest
import AppKit
import SwiftUI
import Combine
@testable import Folmi

@MainActor
final class EditorSessionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-EditorSession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testSessionRestoresOrderedTabsSelectedDocumentAndCursorWithoutSavingDraftText() throws {
        try write("a.js", "const a = 1;\n")
        try write("notes/b.md", "# title\n")
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "a.js")
        workspace.updateText(id: "a.js", text: "secret unsaved draft")
        workspace.updateEditorState(id: "a.js", selection: NSRange(location: 4, length: 3), scrollOffset: 42)
        try workspace.open(path: "notes/b.md")
        workspace.updateEditorState(id: "notes/b.md", selection: NSRange(location: 2, length: 5), scrollOffset: 20)
        let project = ProjectPreferences(rootPath: root.path, name: "isolated", editorTabs: workspace.sessionState(), selectedEditorPath: workspace.selectedDocumentID)
        let preferences = WorkspacePreferences(projects: [project], appearance: .dark, editorLineHeight: 24)
        let store = WorkspaceStore(url: root.appendingPathComponent("Folmi-Config/workspace.json"))
        try store.save(preferences)
        let loaded = try store.load()
        XCTAssertEqual(loaded, preferences)
        XCTAssertFalse(try String(contentsOf: store.url).contains("secret unsaved draft"))
        let restored = EditorWorkspace(root: root)
        restored.restoreSession(tabs: loaded.projects[0].editorTabs, selectedPath: loaded.projects[0].selectedEditorPath)
        XCTAssertEqual(restored.documents.map(\.path), ["a.js", "notes/b.md"])
        XCTAssertEqual(restored.selectedDocumentID, "notes/b.md")
        XCTAssertEqual(restored.selectedDocument?.text, "# title\n")
        XCTAssertEqual(restored.tabStates["a.js"]?.selectionLocation, 4)
        XCTAssertEqual(restored.tabStates["a.js"]?.selectionLength, 3)
        XCTAssertEqual(restored.tabStates["a.js"]?.scrollOffset, 42)
        XCTAssertFalse(restored.hasUnsavedChanges)
    }

    func testMissingUnsafeAndSymlinkTabsLeaveOtherTabsAvailable() throws {
        try write("good.py", "print('hello')\n")
        let link = root.appendingPathComponent("link.py")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("good.py"))
        let workspace = EditorWorkspace(root: root)
        workspace.restoreSession(tabs: [EditorTabState(path: "missing.js"), EditorTabState(path: "../outside"),
            EditorTabState(path: ".git/config"), EditorTabState(path: "link.py"), EditorTabState(path: "good.py")], selectedPath: "missing.js")
        XCTAssertEqual(workspace.documents.map(\.path), ["good.py"])
        XCTAssertEqual(workspace.selectedDocumentID, "good.py")
        XCTAssertTrue(workspace.errorMessage?.contains("部分编辑标签") == true)
        XCTAssertEqual(workspace.documents[0].text, "print('hello')\n")
    }

    func testRestoringChangedFileClampsPositionsAndClosingRemovesSessionEntry() throws {
        try write("small", "hi😀")
        let workspace = EditorWorkspace(root: root)
        workspace.restoreSession(tabs: [EditorTabState(path: "small", selectionLocation: Int.max, selectionLength: Int.max, scrollOffset: -30)], selectedPath: "small")
        XCTAssertEqual(workspace.tabStates["small"]?.selectionLocation, 4)
        XCTAssertEqual(workspace.tabStates["small"]?.selectionLength, 0)
        XCTAssertEqual(workspace.tabStates["small"]?.scrollOffset, 0)
        try workspace.close(id: "small")
        XCTAssertTrue(workspace.sessionState().isEmpty)
        XCTAssertNil(workspace.tabStates["small"])
    }

    func testUTF16PositionsDoNotSplitEmojiOrCombiningCharacters() {
        let text = "a😀e\u{301}z\n第二行"
        XCTAssertEqual(EditorTextPosition.clamp(NSRange(location: 2, length: 0), in: text), NSRange(location: 1, length: 0))
        XCTAssertEqual(EditorTextPosition.clamp(NSRange(location: 4, length: 0), in: text), NSRange(location: 3, length: 0))
        XCTAssertEqual(EditorTextPosition.clamp(NSRange(location: 1, length: 1), in: text), NSRange(location: 1, length: 2))
        XCTAssertEqual(EditorTextPosition.clamp(NSRange(location: Int.max, length: Int.max), in: text), NSRange(location: text.utf16.count, length: 0))
        XCTAssertEqual(EditorTextPosition.range(line: 2, column: 2, in: text), NSRange(location: 8, length: 0))
        XCTAssertEqual(EditorTextPosition.range(line: 1, column: 999, in: text), NSRange(location: 6, length: 0))
        XCTAssertEqual(EditorTextPosition.range(line: 99, column: 1, in: text), NSRange(location: text.utf16.count, length: 0))
        XCTAssertEqual(EditorTextPosition.range(line: -1, column: Int.min, in: text), NSRange(location: 0, length: 0))
    }

    func testRevealMovesExistingDirtyTabWithoutReloadingOrWritingIt() throws {
        try write("a.py", "one\ntwo\n")
        let workspace = EditorWorkspace(root: root)
        try workspace.open(path: "a.py")
        workspace.updateText(id: "a.py", text: "one\nchanged two\n")
        try workspace.reveal(path: "a.py", line: 2, column: 3)
        XCTAssertEqual(workspace.tabStates["a.py"]?.selectionLocation, 6)
        XCTAssertEqual(workspace.navigationRevision, 1)
        try workspace.reveal(path: "a.py", range: NSRange(location: 4, length: 7))
        XCTAssertEqual(workspace.tabStates["a.py"]?.selectionLength, 7)
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertEqual(workspace.selectedDocument?.text, "one\nchanged two\n")
        XCTAssertTrue(workspace.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.py")), "one\ntwo\n")
    }

    func testPreferenceDefaultsRemainCompatibleWithVersionOne() throws {
        let preferences = try JSONDecoder().decode(WorkspacePreferences.self, from: Data("{\"version\":1,\"projects\":[{\"rootPath\":\"/tmp/old\"}]}".utf8))
        XCTAssertEqual(preferences.editorFontSize, 13)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.editorFontFamily, "JetBrains Mono")
        XCTAssertEqual(preferences.editorLineHeight, 22)
        XCTAssertEqual(preferences.editorTabSize, 2)
        XCTAssertTrue(preferences.editorWrapLines)
        XCTAssertTrue(preferences.projects[0].editorTabs.isEmpty)
        XCTAssertNil(preferences.projects[0].selectedEditorPath)
    }

    func testPreferenceStoreRejectsUnsafeTabsAndInvalidPositionsWithoutOverwriting() throws {
        let store = WorkspaceStore(url: root.appendingPathComponent("Folmi-Config/workspace.json"))
        try store.save(WorkspacePreferences())
        let original = try Data(contentsOf: store.url)
        for path in ["../outside", "/etc/passwd", ".git/config", "a/.GIT/index", "a//b", "a/./b"] {
            let preferences = WorkspacePreferences(projects: [ProjectPreferences(rootPath: root.path, name: "demo", editorTabs: [EditorTabState(path: path)])])
            XCTAssertThrowsError(try store.save(preferences), path)
        }
        for tab in [EditorTabState(path: "safe", selectionLocation: -1), EditorTabState(path: "safe", selectionLength: -1), EditorTabState(path: "safe", scrollOffset: .infinity)] {
            XCTAssertThrowsError(try store.save(WorkspacePreferences(projects: [ProjectPreferences(rootPath: root.path, name: "demo", editorTabs: [tab])])))
        }
        let many = (0...100).map { EditorTabState(path: "file\($0)") }
        XCTAssertThrowsError(try store.save(WorkspacePreferences(projects: [ProjectPreferences(rootPath: root.path, name: "demo", editorTabs: many)])))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }

    func testOwnConfigurationCannotBeWrittenIntoCursorOrVSCodeDirectories() throws {
        for path in ["Library/Application Support/Cursor/User/settings.json", "Library/Application Support/Code/User/keybindings.json", ".cursor/workspace.json", ".vscode/workspace.json"] {
            let destination = root.appendingPathComponent(path)
            let store = WorkspaceStore(url: destination)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(WorkspacePreferences()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testMalformedOptionalCaretFieldsFallBackToSafeDefaults() throws {
        let tab = try JSONDecoder().decode(EditorTabState.self, from: Data("{\"path\":\"safe\",\"selectionLocation\":\"bad\",\"selectionLength\":null,\"scrollOffset\":{}}".utf8))
        XCTAssertEqual(tab, EditorTabState(path: "safe"))
    }

    func testDeleteAndDuplicateLineRespectSelectionBoundaryAndFinalLine() throws {
        let remove = try XCTUnwrap(EditorLineEdit.make(text: "a\nb\nc", selection: NSRange(location: 0, length: 2), duplicate: false))
        XCTAssertEqual(("a\nb\nc" as NSString).replacingCharacters(in: remove.range, with: remove.replacement), "b\nc")
        let duplicate = try XCTUnwrap(EditorLineEdit.make(text: "last", selection: NSRange(location: 2, length: 0), duplicate: true))
        XCTAssertEqual(("last" as NSString).replacingCharacters(in: duplicate.range, with: duplicate.replacement), "last\nlast")
        XCTAssertEqual(duplicate.selection.location, 7)
        let trailing = try XCTUnwrap(EditorLineEdit.make(text: "a\n", selection: NSRange(location: 2, length: 0), duplicate: false))
        XCTAssertEqual(("a\n" as NSString).replacingCharacters(in: trailing.range, with: trailing.replacement), "a")
    }

    func testNativeLineEditsAndIndentationKeepUndoAvailable() throws {
        let editor = SessionTestTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.isRichText = false; editor.allowsUndo = true; editor.string = "a\nb\n"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.testUndoManager.beginUndoGrouping()
        editor.applyLineCommand(duplicate: true)
        editor.testUndoManager.endUndoGrouping()
        XCTAssertEqual(editor.string, "a\nb\nb\n")
        XCTAssertTrue(editor.testUndoManager.canUndo)
        editor.testUndoManager.undo()
        XCTAssertEqual(editor.string, "a\nb\n")
        editor.testUndoManager.removeAllActions()
        editor.string = "def function():"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "def function():\n  ")
        editor.insertTab(nil)
        XCTAssertTrue(editor.string.hasSuffix("\n    "))
    }

    func testNativeBridgeRestoresCaretAndBoundedScrollAfterLayout() async throws {
        _ = NSApplication.shared
        let text = (1...150).map { "line \($0) value\n" }.joined()
        try write("long.py", text)
        let caret = EditorTextPosition.range(line: 70, column: 4, in: text)
        let workspace = EditorWorkspace(root: root)
        workspace.restoreSession(tabs: [EditorTabState(path: "long.py", selectionLocation: caret.location, scrollOffset: 600)], selectedPath: "long.py")
        let host = NSHostingView(rootView: FileEditorPane(workspace: workspace, onSave: {}))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        func findEditor(_ view: NSView) -> EditorTextView? {
            if let editor = view as? EditorTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        let native = try XCTUnwrap(findEditor(host))
        XCTAssertEqual(native.selectedRange(), caret)
        let scroll = try XCTUnwrap(native.enclosingScrollView)
        XCTAssertEqual(scroll.contentView.bounds.minY, 600, accuracy: 2)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, max(0, native.frame.height - scroll.contentSize.height))
        XCTAssertEqual(native.string, text)
        XCTAssertFalse(workspace.hasUnsavedChanges)
    }

    func testNativeEditorTeardownDoesNotPublishIntoDestroyingSwiftUIGraph() async throws {
        _ = NSApplication.shared
        try write("teardown.py", String(repeating: "value = 1\n", count: 80))
        let workspace = EditorWorkspace(root: root)
        workspace.restoreSession(tabs: [EditorTabState(path: "teardown.py", selectionLocation: 25, scrollOffset: 120)], selectedPath: "teardown.py")
        var host: NSHostingView<FileEditorPane>? = NSHostingView(rootView: FileEditorPane(workspace: workspace, onSave: {}))
        host?.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host!.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        var publications = 0
        let subscription = workspace.objectWillChange.sink { publications += 1 }
        let before = workspace.sessionState()
        weak var releasedHost = host
        window.contentView = nil
        host = nil
        window.close()
        for _ in 0..<30 {
            if releasedHost == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(releasedHost)
        XCTAssertEqual(publications, 0, "Dismantling a representable must not publish back into its destroying GraphHost")
        XCTAssertEqual(workspace.sessionState(), before)
        subscription.cancel()
    }

    func testInitialRevealKeepsLineColumnFocusAndTextClearOfGutter() async throws {
        _ = NSApplication.shared
        let text = (1...120).map { "line \($0): unique content\n" }.joined()
        try write("first.py", text)
        let workspace = EditorWorkspace(root: root)
        try workspace.reveal(path: "first.py", line: 65, column: 4)
        let expected = EditorTextPosition.range(line: 65, column: 4, in: text)
        let host = NSHostingView(rootView: FileEditorPane(workspace: workspace, onSave: {}))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        func findEditor(_ view: NSView) -> EditorTextView? {
            if let editor = view as? EditorTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        let native = try XCTUnwrap(findEditor(host))
        let scroll = try XCTUnwrap(native.enclosingScrollView)
        let container = try XCTUnwrap(scroll.superview)
        let gutter = try XCTUnwrap(container.subviews.first { $0.accessibilityIdentifier() == "editor-line-gutter" })
        XCTAssertTrue(window.firstResponder === native, "The first reveal must focus the destination editor without an extra click")
        XCTAssertEqual(native.selectedRange(), expected)
        XCTAssertEqual(workspace.tabStates["first.py"]?.selectionLocation, expected.location)
        XCTAssertGreaterThanOrEqual(scroll.frame.minX, gutter.frame.maxX)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.1)
        XCTAssertEqual(native.frame.minX, 0, accuracy: 0.1)
        let start = native.convert(native.textContainerOrigin, to: container)
        XCTAssertGreaterThanOrEqual(start.x, gutter.frame.maxX + 9)
        if let layout = native.layoutManager, let textContainer = native.textContainer {
            let glyph = layout.glyphIndexForCharacter(at: expected.location)
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y)
            XCTAssertTrue(native.visibleRect.intersects(lineRect), "The destination line must be visible")
            XCTAssertGreaterThan(textContainer.containerSize.width, 1)
        }
        native.insertText("X", replacementRange: native.selectedRange())
        XCTAssertTrue(workspace.selectedDocument?.text.contains("linXe 65") == true)
    }

    /// ⌘K in Markdown source goes on to the app's search; the link shortcut is ⇧⌘K.
    @MainActor
    func testCommandKReachesSearchFromMarkdownSource() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = SessionTestTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = editor
        defer { window.contentView = nil }
        editor.markdownEditing = true
        editor.string = "see docs"
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 4))
        func event(_ flags: NSEvent.ModifierFlags, _ character: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 40))
        }
        XCTAssertFalse(editor.performKeyEquivalent(with: try event(.command, "k")), "⌘K must bubble up to 万能搜索")
        XCTAssertEqual(editor.string, "see docs")
        XCTAssertTrue(editor.performKeyEquivalent(with: try event([.command, .shift], "K")))
        XCTAssertEqual(editor.string, "see [docs]()")
    }

    /// Outside the review page and the text editor, plain ⌘Z is text undo; Git undo is ⌥⌘Z, and hints must say so.
    func testGitUndoHintsNameTheGlobalShortcut() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Folmi")
        // These hints are about places where ⌘Z itself works: the review page and the text editor.
        let allowed: Set<String> = ["AllChangesView.swift", "ChangesCard.swift", "EditorGutter.swift"]
        var offenders: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") && !allowed.contains(name) {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                // Only text inside string literals counts; comments may talk about ⌘Z as the undo stack.
                let code = line.components(separatedBy: " //").first ?? line
                let literals = code.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                for literal in literals where literal.replacingOccurrences(of: "⌥⌘Z", with: "").replacingOccurrences(of: "⇧⌘Z", with: "").contains("⌘Z") {
                    offenders.append("\(name): \(literal)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testProjectSearchShortcutBubblesAndMarkdownShortcutWorksWithOptionCharacters() throws {
        _ = NSApplication.shared
        let editor = SessionTestTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        editor.string = "# source"
        func event(_ flags: NSEvent.ModifierFlags, keyCode: UInt16, character: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode))
        }
        XCTAssertFalse(editor.performKeyEquivalent(with: try event([.command, .shift], keyCode: 3, character: "F")))
        XCTAssertFalse(editor.performKeyEquivalent(with: try event([.command, .control], keyCode: 3, character: "f")))
        XCTAssertFalse(editor.performKeyEquivalent(with: try event([.command, .shift, .option], keyCode: 3, character: "F")))
        XCTAssertTrue(editor.performKeyEquivalent(with: try event([.command, .option], keyCode: 3, character: "ƒ")))
        XCTAssertEqual(editor.lastFinderAction, Int(NSTextFinder.Action.showReplaceInterface.rawValue))
        XCTAssertTrue(editor.performKeyEquivalent(with: try event(.command, keyCode: 3, character: "f")))
        XCTAssertEqual(editor.lastFinderAction, Int(NSTextFinder.Action.showFindInterface.rawValue))
        XCTAssertFalse(editor.performKeyEquivalent(with: try event([.command, .shift, .option], keyCode: 3, character: "ƒ")))
        XCTAssertEqual(editor.lastFinderAction, Int(NSTextFinder.Action.showFindInterface.rawValue))
        var toggles = 0
        editor.toggleMarkdown = { toggles += 1 }
        let markdownShortcut = try event([.shift, .option], keyCode: 46, character: "Â")
        XCTAssertTrue(editor.performKeyEquivalent(with: markdownShortcut))
        XCTAssertEqual(toggles, 1)
        editor.keyDown(with: markdownShortcut)
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(editor.string, "# source", "The option-layout glyph must never be inserted by the Markdown shortcut")
        editor.toggleMarkdown = nil
        XCTAssertFalse(editor.performKeyEquivalent(with: markdownShortcut), "Non-Markdown text input must continue through the standard responder chain")
        XCTAssertEqual(toggles, 2)
    }

    func testThemesAndTypographyChangeOnlyAttributes() throws {
        let editor = SessionTestTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.string = "const hello = 'world'; // 中文😀"
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        let text = editor.string
        let result = try XCTUnwrap(SyntaxTokenizer.tokenize(text, language: .javascript))
        var presentation = EditorPresentation(appearance: .dark)
        SyntaxHighlightApplier.apply(result, to: editor, presentation: presentation)
        let darkKeyword = editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        presentation.appearance = .light; presentation.fontSize = 16
        SyntaxHighlightApplier.apply(result, to: editor, presentation: presentation)
        let lightKeyword = editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(darkKeyword, lightKeyword)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 5))
        XCTAssertEqual((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 16)
        XCTAssertFalse(editor.testUndoManager.canUndo)
        XCTAssertNotEqual(EditorPalette(presentation: EditorPresentation(), effectiveDark: false).background,
                          EditorPalette(presentation: EditorPresentation(), effectiveDark: true).background)
    }
}

@MainActor
private final class SessionTestTextView: EditorTextView {
    let testUndoManager = UndoManager()
    var lastFinderAction: Int?
    override var undoManager: UndoManager? { testUndoManager }
    override func performTextFinderAction(_ sender: Any?) {
        lastFinderAction = (sender as? NSMenuItem)?.tag
    }
}
