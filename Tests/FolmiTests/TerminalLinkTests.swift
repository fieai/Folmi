import XCTest
import FolmiCore
@testable import Folmi

final class TerminalLinkTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    func testSplitsLineAndColumnInTheFormsToolsPrint() {
        func split(_ text: String) -> [String] {
            let result = TerminalLinks.split(text)
            return [result.path, result.line.map(String.init) ?? "-", result.column.map(String.init) ?? "-"]
        }
        XCTAssertEqual(split("Sources/A.swift:42:7"), ["Sources/A.swift", "42", "7"])
        XCTAssertEqual(split("Sources/A.swift:42:7:"), ["Sources/A.swift", "42", "7"])
        XCTAssertEqual(split("src/app.ts:12"), ["src/app.ts", "12", "-"])
        XCTAssertEqual(split("src/app.ts(12,5)"), ["src/app.ts", "12", "5"])
        XCTAssertEqual(split("docs/a.md#L30"), ["docs/a.md", "30", "-"])
        XCTAssertEqual(split("README.md."), ["README.md", "-", "-"])
        XCTAssertEqual(split("a.py:0"), ["a.py:0", "-", "-"])
        XCTAssertEqual(split("../x/y.go"), ["../x/y.go", "-", "-"])
    }

    func testResolvesAgainstShellDirectoryRootAndPathSuffix() throws {
        let root = try makeProject(["Sources/App/Main.swift", "Tests/AppTests/MainTests.swift", "README.md"])
        let sub = root.appendingPathComponent("Sources")
        let paths = ["README.md", "Sources/App/Main.swift", "Tests/AppTests/MainTests.swift"]
        XCTAssertEqual(TerminalLinks.resolve("App/Main.swift:3:2", root: root, cwd: sub, projectPaths: paths),
                       .file(path: "Sources/App/Main.swift", line: 3, column: 2))
        XCTAssertEqual(TerminalLinks.resolve("./README.md:9", root: root, cwd: nil, projectPaths: paths),
                       .file(path: "README.md", line: 9, column: nil))
        XCTAssertEqual(TerminalLinks.resolve(root.appendingPathComponent("Sources/App/Main.swift").path + ":5", root: root, cwd: nil, projectPaths: paths),
                       .file(path: "Sources/App/Main.swift", line: 5, column: nil))
        XCTAssertEqual(TerminalLinks.resolve("b/README.md", root: root, cwd: nil, projectPaths: paths),
                       .file(path: "README.md", line: nil, column: nil))
        XCTAssertEqual(TerminalLinks.resolve("MainTests.swift:12", root: root, cwd: nil, projectPaths: paths),
                       .file(path: "Tests/AppTests/MainTests.swift", line: 12, column: nil))
        XCTAssertEqual(TerminalLinks.resolve("file://" + root.appendingPathComponent("README.md").path, root: root, cwd: nil, projectPaths: paths),
                       .file(path: "README.md", line: nil, column: nil))
        XCTAssertEqual(TerminalLinks.resolve("https://example.com/a", root: root, cwd: nil, projectPaths: paths),
                       .web(URL(string: "https://example.com/a")!))
        XCTAssertEqual(TerminalLinks.resolve("nowhere/Gone.swift:1", root: root, cwd: nil, projectPaths: paths), .missing("nowhere/Gone.swift"))
        guard case .outside = TerminalLinks.resolve("/etc/hosts:1", root: root, cwd: nil, projectPaths: paths) else {
            return XCTFail("项目之外的文件只在 Finder 中显示")
        }
        guard case .outside = TerminalLinks.resolve("Sources", root: root, cwd: nil, projectPaths: paths) else {
            return XCTFail("文件夹在 Finder 中显示")
        }
    }

    func testSnippetSendsPlainTextOfWholeLines() throws {
        let text = "let a = 1\nlet b = 2\nlet c = 3\n"
        let partial = try XCTUnwrap(TerminalSnippet.make(path: "Sources/A.swift", text: text, selection: NSRange(location: 14, length: 8)))
        XCTAssertEqual(partial.reference, "Sources/A.swift:2-3")
        XCTAssertEqual(partial.text, "let b = 2\nlet c = 3")
        // A triple-clicked line ends at the next line's start; that next line is not sent.
        let line = try XCTUnwrap(TerminalSnippet.make(path: "a.swift", text: text, selection: NSRange(location: 10, length: 10)))
        XCTAssertEqual(line.reference, "a.swift:2")
        let caret = try XCTUnwrap(TerminalSnippet.make(path: "a.rb", text: text, selection: NSRange(location: 3, length: 0)))
        XCTAssertEqual(caret.text, "let a = 1")
        XCTAssertEqual(TerminalSnippet.plain("同一份\n\n"), "同一份")
        XCTAssertNil(TerminalSnippet.plain(" \n"))
        let escaped = try XCTUnwrap(TerminalSnippet.make(path: "a.md", text: "```js\nx\u{1B}[31m\n```", selection: NSRange(location: 6, length: 1)))
        XCTAssertFalse(escaped.text.contains("\u{1B}"), "控制字符不能进入终端")
        XCTAssertNil(TerminalSnippet.make(path: "a", text: "x\n\n\ny", selection: NSRange(location: 2, length: 0)))
        // A phrase inside one line goes as selected, with the line as its reference.
        let phrase = try XCTUnwrap(TerminalSnippet.make(path: "doc.md", text: "第一行\n同一份 Markdown，直接编辑。\n", selection: NSRange(location: 4, length: 3)))
        XCTAssertEqual(phrase.reference, "doc.md:2")
        XCTAssertEqual(phrase.text, "同一份")
        XCTAssertFalse(phrase.text.contains("直接编辑"))
    }

    func testReaderSelectionFindsItsExactSourceRange() {
        let text = "# 标题\n\n离开段落后，标题、**强调**、*斜体* 和 `行内代码` 会原位排版。\n"
        let source = text as NSString
        let lines = source.lineRange(for: NSRange(location: source.range(of: "离开").location, length: 0))
        func found(_ selected: String) -> String? {
            MarkdownReaderView.Coordinator.sourceRange(of: selected, in: text, lines: lines).map { source.substring(with: $0) }
        }
        XCTAssertEqual(found("标题、强调"), "标题、**强调", "the source keeps its own markup between the matched ends")
        XCTAssertEqual(found("斜体 和 行内代码"), "斜体* 和 `行内代码")
        XCTAssertEqual(found("会原位排版"), "会原位排版")
        XCTAssertNil(found("不在这里的字"))
    }

    @MainActor
    func testTabsOpenRenameRestartCloseAndReopenWithNames() async throws {
        let (model, storeURL) = try await openDemo()
        model.toggleTerminal()
        XCTAssertEqual(model.terminalTabs.count, 1)
        let first = try XCTUnwrap(model.terminalSession)
        model.newTerminalTab()
        XCTAssertEqual(model.terminalTabs.count, 2)
        let second = try XCTUnwrap(model.terminalSession)
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.isRunning && second.isRunning)
        model.renameTerminalTab(second.id, to: "  agent  ")
        XCTAssertEqual(second.displayTitle, "agent")
        model.restartTerminal()
        let restarted = try XCTUnwrap(model.terminalSession)
        XCTAssertFalse(restarted === second)
        XCTAssertFalse(second.isRunning)
        XCTAssertEqual(restarted.name, "agent")
        XCTAssertEqual(model.terminalTabs.last?.id, restarted.id, "重开的标签留在原位")
        model.selectTerminalTab(first.id)
        XCTAssertTrue(model.terminalSession === first)
        try model.savePreferencesNow()
        XCTAssertEqual(try WorkspaceStore(url: storeURL).load().projects.first?.terminalTabs, ["", "agent"])

        model.closeTerminalTab(first.id)
        XCTAssertFalse(first.isRunning)
        XCTAssertTrue(model.terminalSession === restarted)
        model.closeTerminalTab(restarted.id)
        XCTAssertTrue(model.terminalTabs.isEmpty)
        XCTAssertFalse(model.showTerminal, "关掉最后一个标签就收起终端")
        model.toggleTerminal()
        XCTAssertEqual(model.terminalTabs.map(\.name), [""])
        _ = model.prepareToQuit()
    }

    @MainActor
    func testOpenLinkUsesTheShellsDirectoryAndRevealsTheLine() async throws {
        let (model, _) = try await openDemo()
        defer { _ = model.prepareToQuit() }
        model.toggleTerminal()
        let terminal = try XCTUnwrap(model.terminalSession)
        try await eventually { terminal.acceptsBracketedPaste }
        terminal.terminalView.process.send(data: Array("cd Sources\r".utf8)[...])
        try await eventually { terminal.currentDirectory?.lastPathComponent == "Sources" }

        model.openTerminalLink("Greeting.swift:2:3", from: terminal)
        let editor = try XCTUnwrap(model.editorWorkspace)
        XCTAssertEqual(editor.selectedDocumentID, "Sources/Greeting.swift")
        XCTAssertEqual(model.content, .editor)
        let document = try XCTUnwrap(editor.selectedDocument)
        let expected = EditorTextPosition.range(line: 2, column: 3, in: document.text)
        XCTAssertEqual(editor.tabStates[document.id]?.selectionLocation, expected.location)

        model.openTerminalLink("Missing.swift:1", from: terminal)
        XCTAssertEqual(editor.notice, "找不到文件：Missing.swift")
    }

    @MainActor
    func testSendSelectionPastesPlainTextWithoutRunningIt() async throws {
        let (model, _) = try await openDemo()
        defer { _ = model.prepareToQuit() }
        model.editPath("Sources/Greeting.swift")
        let document = try XCTUnwrap(model.editorWorkspace?.selectedDocument)
        // Two lines: zsh shows a buffer taller than the small test screen as ">....".
        let start = EditorTextPosition.range(line: 3, column: 1, in: document.text).location
        let end = EditorTextPosition.range(line: 4, column: 5, in: document.text).location
        model.sendEditorSelectionToTerminal(selection: NSRange(location: start, length: end - start))
        let terminal = try XCTUnwrap(model.terminalSession)
        try await eventually { model.paneLayout.focused == .terminal || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        try await Task.sleep(nanoseconds: 500_000_000)
        let screen = String(decoding: terminal.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(screen.contains("struct Greeting {"), screen)
        XCTAssertFalse(screen.contains("Sources/Greeting.swift:3-4"), "只发文字，不带路径")
        XCTAssertFalse(screen.contains("```"), "只发文字，不带代码围栏")
        XCTAssertFalse(screen.contains("command not found"))
        XCTAssertEqual(model.activity.first?.title, "发送文字到终端")
    }

    @MainActor
    func testCommandClickOnAChangedFileOpensItsDiffAndHoverPreviewsIt() async throws {
        let (model, _) = try await openDemo()
        defer { _ = model.prepareToQuit() }
        let change = try XCTUnwrap(model.snapshot?.files.first { !$0.isUntracked && $0.hasWorking })
        model.openTerminalLink(change.path, from: nil)
        try await eventually { model.content == .diff && model.fileDiffs.first?.file.path == change.path }
        XCTAssertEqual(model.selectedFileID, change.id)

        let changed = try await XCTUnwrapAsync(await model.terminalLinkPreview(change.path, from: nil))
        XCTAssertTrue(changed.summary.hasPrefix("+"), changed.summary)
        XCTAssertFalse(changed.lines.isEmpty)
        XCTAssertTrue(changed.lines.contains { $0.kind != .context })

        let changedPaths = Set(model.snapshot?.files.map(\.path) ?? [])
        let clean = try XCTUnwrap(model.browserPaths.first { !changedPaths.contains($0) && !$0.hasSuffix(".png") })
        let plain = try await XCTUnwrapAsync(await model.terminalLinkPreview(clean + ":1", from: nil))
        XCTAssertEqual(plain.summary, "未改动")
        XCTAssertEqual(plain.hint, "⌘ 点击打开第 1 行")
        model.openTerminalLink(change.path + ":1", from: nil)
        XCTAssertEqual(model.content, .editor, "with a line number the file opens in the editor at that line")
    }
    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    func testPreviewTakesFirstChangedLinesWithContext() {
        let hunk = DiffHunk(id: "h", header: "@@ -1,3 +1,3 @@", lines: [
            DiffLine(id: 0, text: "a", kind: .context), DiffLine(id: 1, text: "b", kind: .deletion),
            DiffLine(id: 2, text: "B", kind: .addition), DiffLine(id: 3, text: "c", kind: .context)])
        let diff = FileDiff(file: FileChange(path: "x.txt", indexCode: ".", worktreeCode: "M"), area: .working, rawPatch: "",
                            hunks: [hunk], fingerprint: "f", isPartialSupported: true, notice: nil)
        let preview = TerminalLinkPreview.changed(path: "x.txt", diffs: [diff])
        XCTAssertEqual(preview.summary, "+1 −1")
        XCTAssertEqual(preview.lines.map(\.text), ["a", "b", "B"])
        XCTAssertEqual(preview.lines.map(\.kind), [.context, .removed, .added])
        let file = TerminalLinkPreview.file(path: "y.txt", text: (1...30).map(String.init).joined(separator: "\n"), line: 10, summary: "未改动")
        XCTAssertEqual(file.lines.first?.text, "8", "two lines of lead-in before the named line")
        XCTAssertEqual(file.lines.count, TerminalLinkPreview.maximumLines)
    }

    @MainActor
    func testHoverCellSizeMatchesTheTerminalLayout() throws {
        let root = try makeProject(["a.txt"])
        let session = TerminalSession(root: root, environment: [:], isDemo: true)
        defer { session.stop() }
        let view = session.terminalView
        let cell = try XCTUnwrap(view.cellSize())
        let optimal = view.getOptimalFrameSize()
        XCTAssertEqual(cell.height * CGFloat(view.getTerminal().rows), optimal.height, accuracy: 0.01)
        let spare = optimal.width - cell.width * CGFloat(view.getTerminal().cols)
        XCTAssertTrue((0..<40).contains(spare), "only the scroller's reserve is left over: \(spare)")
    }

    @MainActor
    private func openDemo() async throws -> (FolmiModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-TermLinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let storeURL = directory.appendingPathComponent("workspace.json")
        let model = FolmiModel(store: WorkspaceStore(url: storeURL))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil && model.editorWorkspace != nil && !model.browserPaths.isEmpty }
        return (model, storeURL)
    }

    private func makeProject(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Links-\(UUID().uuidString)", isDirectory: true)
        cleanupURLs.append(root)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
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
