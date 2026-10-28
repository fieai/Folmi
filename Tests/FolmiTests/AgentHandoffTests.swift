import AppKit
import XCTest
@testable import FolmiCore
@testable import Folmi

final class AgentHandoffTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDown() {
        for url in cleanupURLs { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
        super.tearDown()
    }

    func testAttachmentsWithSourceGoAsResourcesOnlyWhenTheAgentTakesThem() {
        let file = AgentContext(title: "a.swift:2-3", text: "let a = 1\nlet b = 2", uri: "file:///repo/a.swift#L2-3")
        let diff = AgentContext(title: "a.swift 第 1 处改动", text: "@@ -1 +1 @@\n-x\n+y")

        let embedded = AgentSession.promptBlocks("统一写法", context: [file, diff], embedded: true)
        XCTAssertEqual(embedded.count, 2)
        XCTAssertEqual(embedded[0]["type"]?.string, "text")
        let text = embedded[0]["text"]?.string ?? ""
        XCTAssertTrue(text.hasPrefix("附件：a.swift:2-3"), text)
        XCTAssertTrue(text.contains("a.swift 第 1 处改动：\n```\n@@ -1 +1 @@"), "a diff has no source, so it is pasted")
        XCTAssertTrue(text.hasSuffix("统一写法"))
        XCTAssertEqual(embedded[1]["type"]?.string, "resource")
        XCTAssertEqual(embedded[1]["resource"]?["uri"]?.string, "file:///repo/a.swift#L2-3")
        XCTAssertEqual(embedded[1]["resource"]?["text"]?.string, "let a = 1\nlet b = 2")

        let pasted = AgentSession.promptBlocks("统一写法", context: [file], embedded: false)
        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(pasted[0]["text"]?.string, "a.swift:2-3：\n```\nlet a = 1\nlet b = 2\n```\n\n统一写法")

        XCTAssertEqual(AgentSession.promptBlocks("你好", context: [], embedded: true).map { $0["text"]?.string }, ["你好"])
    }

    func testDiffContextKeepsOnlyPickedChangedLines() {
        let hunk = DiffHunk(id: "h1", header: "@@ -1,3 +1,3 @@", lines: [
            DiffLine(id: 1, text: "same", kind: .context),
            DiffLine(id: 2, text: "old", kind: .deletion),
            DiffLine(id: 3, text: "new", kind: .addition),
            DiffLine(id: 4, text: "other", kind: .addition),
        ])
        let other = DiffHunk(id: "h2", header: "@@ -9 +9 @@", lines: [DiffLine(id: 9, text: "far", kind: .addition)])
        let diff = FileDiff(file: FileChange(path: "a.txt", indexCode: " ", worktreeCode: "M"), area: .working, rawPatch: "",
                            hunks: [hunk, other], fingerprint: "f", isPartialSupported: true, notice: nil)

        let context = FolmiModel.diffContext(diff, lines: [2, 3])
        XCTAssertEqual(context?.title, "a.txt 选中 2 行的改动")
        XCTAssertEqual(context?.text, "@@ -1,3 +1,3 @@\n-old\n+new")
        XCTAssertNil(context?.uri, "a diff is pasted, never read as the file")
        XCTAssertNil(FolmiModel.diffContext(diff, lines: [1]), "a context line alone is not a change")
        XCTAssertNil(FolmiModel.diffContext(diff, lines: []))
        XCTAssertEqual(FolmiModel.patchText([hunk], lines: nil), "@@ -1,3 +1,3 @@\n same\n-old\n+new\n+other")
    }

    @MainActor
    func testSelectionsBecomeAttachmentsInTheComposer() async throws {
        let (model, _) = try await makeModel()
        let text = "one\ntwo\nthree\nfour\n"

        let lines = try XCTUnwrap(model.editorSelectionContext(path: "src/a.swift", text: text, range: NSRange(location: 4, length: 9)))
        XCTAssertEqual(lines.title, "src/a.swift:2-3")
        XCTAssertEqual(lines.text, "two\nthree")
        XCTAssertEqual(lines.uri, try XCTUnwrap(model.repositoryURL).appendingPathComponent("src/a.swift").absoluteString + "#L2-3")

        let whole = try XCTUnwrap(model.editorSelectionContext(path: "src/a.swift", text: text, range: NSRange(location: 2, length: 0)))
        XCTAssertEqual(whole.title, "src/a.swift（整个文件）")
        XCTAssertNil(model.editorSelectionContext(path: "blank.txt", text: "  \n", range: NSRange(location: 0, length: 0)))

        model.agentDraft = "我写了一半"
        model.editorSelectionAI(.handToAgent, path: "src/a.swift", text: text, range: NSRange(location: 4, length: 9))
        model.editorSelectionAI(.handToAgent, path: "src/a.swift", text: text, range: NSRange(location: 4, length: 9))
        XCTAssertEqual(model.agentContext.map(\.title), ["src/a.swift:2-3"], "the same selection twice is attached once")
        XCTAssertEqual(model.agentDraft, "我写了一半", "nothing is sent and the draft stays")
        XCTAssertTrue(model.aiTabSelected)
        XCTAssertEqual(model.agentComposerFocus, 2)
        XCTAssertEqual(model.agentSession?.transcript.entries.count ?? 0, 0)

        // A hunk from the all-changes page; with lines picked, only those.
        model.content = .allChanges
        let diff = try XCTUnwrap(model.allChanges.first)
        let hunk = try XCTUnwrap(diff.hunks.first)
        model.handHunkToAgent(hunk, in: diff)
        XCTAssertEqual(model.agentContext.last?.title, "review.txt 第 1 处改动")
        let added = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        model.toggleAllChangesLine(added.id, in: diff)
        model.handHunkToAgent(hunk, in: diff)
        XCTAssertEqual(model.agentContext.last?.title, "review.txt 选中 1 行的改动")
        XCTAssertEqual(model.agentContext.last?.text, hunk.header + "\n+EDIT A")
        XCTAssertEqual(model.diffSelectionContexts().map(\.title), ["review.txt 选中 1 行的改动"])

        model.askAbout(lines, question: nil)
        XCTAssertEqual(model.aiAssist?.mode, .ask)
        XCTAssertEqual(model.aiAssist?.source, "src/a.swift:2-3")
        XCTAssertEqual(model.aiAssist?.input, "two\nthree")
    }

    /// In a code editor the bar shows after a mouse selection only; selecting with the keyboard stays quiet.
    @MainActor
    func testCodeEditorShowsAIButtonsAfterMouseSelection() throws {
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.string = "let answer = compute(42)\nprint(answer)\n"
        var actions: [EditorSelectionAction] = []
        editor.selectionAI = { action, _ in actions.append(action) }
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)

        editor.setSelectedRange(NSRange(location: 4, length: 6))
        XCTAssertFalse(editor.overlays.isFormatBarShown, "a keyboard selection shows nothing")
        editor.overlays.mouseUp()
        XCTAssertTrue(editor.overlays.isFormatBarShown)

        editor.setSelectedRange(NSRange(location: 4, length: 1))
        editor.overlays.mouseUp()
        XCTAssertFalse(editor.overlays.isFormatBarShown, "one character is not worth a bar")

        editor.setSelectedRange(NSRange(location: 4, length: 6))
        editor.overlays.mouseUp()
        editor.cancelOperation(nil)
        XCTAssertFalse(editor.overlays.isFormatBarShown, "Esc hides it")
        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    private func makeModel() async throws -> (FolmiModel, DemoRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let git = { (arguments: [String]) async throws in _ = try await CommandRunner.git(arguments, at: demo.root, environment: demo.environment) }
        try await git(["add", "-A"]); try await git(["commit", "-q", "-m", "demo state"])
        let file = demo.root.appendingPathComponent("review.txt")
        let lines = (1...30).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "--", "review.txt"]); try await git(["commit", "-q", "-m", "review base"])
        var edited = lines; edited[0] = "EDIT A"
        try (edited.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开项目") { !model.busy && model.snapshot != nil }
        await model.loadAllChanges()
        try await eventually("全部改动") { !model.allChangesLoading && model.allChanges.count == 1 }
        return (model, demo)
    }

    @MainActor
    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTFail("等待超时：\(what)")
    }
}
