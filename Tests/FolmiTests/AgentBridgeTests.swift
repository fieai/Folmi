import XCTest
@testable import FolmiCore
@testable import Folmi

final class AgentBridgeTests: XCTestCase {
    private var cleanup: [URL] = []
    override func tearDown() { cleanup.forEach { try? FileManager.default.removeItem(at: $0) }; cleanup = [] }

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanup.append(url)
        return url
    }

    @MainActor
    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func testPublishesCommentsAndTakesInReplies() async throws {
        let settings = try folder("bridge")
        let demo = try await DemoRepository.create()
        cleanup.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("open") { !model.busy && model.snapshot != nil }
        let gitDir = try XCTUnwrap(model.aiGitDir)

        model.reviewComments.append(ReviewComment(projectPath: try XCTUnwrap(model.repositoryURL).path, path: "README.md", area: .working,
                                                  firstLine: 2, lastLine: 3, excerpt: ["+hello"], body: "换个说法"))
        model.publishShared()
        let shared = try XCTUnwrap(FolmiShared.read([SharedComment].self, from: FolmiShared.comments(gitDir: gitDir)))
        XCTAssertEqual(shared.map(\.body), ["换个说法"])
        let status = try XCTUnwrap(FolmiShared.read(SharedReviewStatus.self, from: FolmiShared.status(gitDir: gitDir)))
        XCTAssertEqual(status.files.map(\.path).sorted(), model.snapshot?.files.map(\.path).sorted())
        let app = try XCTUnwrap(FolmiShared.read(SharedAppState.self, from: FolmiShared.appState(settingsDirectory: settings)))
        XCTAssertEqual(app.repository, model.repositoryURL?.path)

        // What `mark_comment_addressed` appends; the note shows on the comment, the comment stays until the user confirms.
        try FolmiShared.append(CommentReply(id: shared[0].id, note: "改成了短句", t: 1), to: FolmiShared.replies(gitDir: gitDir))
        try FolmiShared.append(CommentReply(id: "someone-else", note: "x", t: 2), to: FolmiShared.replies(gitDir: gitDir))
        model.readAIEvents()
        XCTAssertEqual(model.currentReviewComments.map(\.addressed), ["改成了短句"])
        model.readAIEvents()
        XCTAssertEqual(model.currentReviewComments.count, 1)
    }

    func testAppWrittenFilesDoNotWakeTheWatcher() {
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/.git/folmi/comments.json"))
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/.git/folmi/review-status.json"))
        XCTAssertFalse(RepositoryWatcher.isRelevant("/repo/.git/folmi/decisions.jsonl"))
        XCTAssertTrue(RepositoryWatcher.isRelevant("/repo/.git/folmi/comment-replies.jsonl"))
        XCTAssertTrue(RepositoryWatcher.isRelevant("/repo/.git/folmi/events.jsonl"))
        XCTAssertTrue(RepositoryWatcher.isRelevant("/repo/docs/comments.json"))
    }

    func testCodexConfigGetsOneBlockAndKeepsTheRest() throws {
        let dir = try folder("codex")
        let config = dir.appendingPathComponent("config.toml"), helper = dir.appendingPathComponent("bin/folmi-hook")
        let source = dir.appendingPathComponent("source-helper")
        try "#!/bin/sh\n".write(to: source, atomically: true, encoding: .utf8)
        let original = "model = \"x\"\n\n[mcp_servers.other]\ncommand = \"npx\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(MCPInstaller.isInstalled(.codex, file: config))
        try MCPInstaller.install(.codex, file: config, helper: helper, source: source)
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(original))
        XCTAssertTrue(text.contains("[mcp_servers.folmi]\ncommand = \"\(helper.path)\"\nargs = [\"mcp\"]"))
        XCTAssertTrue(MCPInstaller.isInstalled(.codex, file: config))
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path), "the helper is copied to its fixed place")
        try MCPInstaller.install(.codex, file: config, helper: helper, source: source)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text, "a second install changes nothing")
    }

    func testClaudeAppConfigMergesIntoExistingServers() throws {
        let dir = try folder("claude-app")
        let config = dir.appendingPathComponent("claude_desktop_config.json"), helper = dir.appendingPathComponent("bin/folmi-hook")
        let source = dir.appendingPathComponent("source-helper")
        try "#!/bin/sh\n".write(to: source, atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.write(to: config, atomically: true, encoding: .utf8)
        try MCPInstaller.install(.claudeApp, file: config, helper: helper, source: source)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(object["theme"] as? String, "dark")
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual((servers["folmi"] as? [String: Any])?["args"] as? [String], ["mcp"])
        XCTAssertTrue(MCPInstaller.isInstalled(.claudeApp, file: config))
        // A file that is not a JSON object is left alone.
        try "[1,2]".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MCPInstaller.install(.claudeApp, file: config, helper: helper, source: source))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "[1,2]")
    }

    func testCodexUpdatePreservesOptionsAndOtherTablesWithoutDuplicateServers() throws {
        let helper = URL(fileURLWithPath: "/new/bin/folmi-hook")
        let original = """
        model = "x"
        [mcp_servers.folmi]
        command = "/old/bin/folmi-hook"
        args = ["mcp"]
        enabled = true
        [mcp_servers.folmi.env]
        EXTRA = "kept"
        [mcp_servers.other]
        command = "npx"

        """
        let updated = try MCPInstaller.codexRegistration(original, helper: helper)
        XCTAssertTrue(updated.contains("[mcp_servers.folmi]\ncommand = \"\(helper.path)\"\nargs = [\"mcp\"]\nenabled = true"))
        XCTAssertTrue(updated.contains("[mcp_servers.folmi.env]\nEXTRA = \"kept\""))
        XCTAssertTrue(updated.hasSuffix("[mcp_servers.other]\ncommand = \"npx\"\n"))
        XCTAssertEqual(try MCPInstaller.codexRegistration(updated, helper: helper), updated)
        XCTAssertEqual(updated.components(separatedBy: "[mcp_servers.folmi]").count, 2)
        XCTAssertThrowsError(try MCPInstaller.codexRegistration("[mcp_servers.folmi]\ncommand = \"custom-server\"\n", helper: helper))
    }
}
