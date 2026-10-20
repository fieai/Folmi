import XCTest
@testable import FolmiCore
@testable import Folmi

final class AgentSessionTests: XCTestCase {
    static let modelAgent = #"""
    import json, sys
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    legacy = "--legacy" in sys.argv
    model = "configured-unavailable"
    selected_with = ""
    def config():
        return [{"id": "model-choice", "name": "Model", "category": "model", "type": "select", "currentValue": model,
                 "options": [{"group": "Models", "options": [{"value": "chosen-model", "name": "Chosen Model"}, {"value": "rejected", "name": "Rejected Model"}]}]}]
    for line in sys.stdin:
        m = json.loads(line)
        method = m.get("method")
        result = {}
        if method == "initialize": result = {"protocolVersion": 1}
        elif method == "session/new":
            result = {"sessionId": "model-session", "models": {"currentModelId": model, "availableModels": [{"modelId": "chosen-model", "name": "Chosen Model"}, {"modelId": "rejected", "name": "Rejected Model"}]}}
            if not legacy: result["configOptions"] = config()
        elif method in ["session/set_config_option", "session/set_model"]:
            p = m["params"]
            valid = p.get("sessionId") == "model-session" and ((legacy and method == "session/set_model") or (not legacy and method == "session/set_config_option" and p.get("configId") == "model-choice"))
            chosen = p.get("modelId") if legacy else p.get("value")
            if not valid or chosen == "rejected":
                send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32602, "message": "model choice rejected"}})
                continue
            model = chosen
            selected_with = method
            if not legacy:
                result = {"configOptions": config()}
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "model-session", "update": {"sessionUpdate": "config_option_update", "configOptions": config()}}})
        elif method == "session/prompt":
            if model == "configured-unavailable":
                send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -1, "message": "configured model unavailable"}})
                continue
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "model-session", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": selected_with + ":" + model}}}})
            result = {"stopReason": "end_turn"}
        send({"jsonrpc": "2.0", "id": m["id"], "result": result})
    """#

    /// A stand-in ACP adapter: streams a reply, reports an edit, asks permission, ends the turn.
    static let fakeAgent = #"""
    import json, sys
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    prompt_id = None
    for line in sys.stdin:
        m = json.loads(line)
        method = m.get("method")
        if method == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
        elif method == "session/new":
            names = [s["name"] for s in m["params"].get("mcpServers", [])]
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
        elif method == "session/prompt":
            prompt_id = m["id"]
            text = m["params"]["prompt"][0]["text"]
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "收到：" + text.split("\n")[-1]}}}})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Edit README.md", "kind": "edit", "status": "completed", "locations": [{"path": "README.md"}]}}})
            send({"jsonrpc": "2.0", "id": 77, "method": "session/request_permission", "params": {"sessionId": "s1", "toolCall": {"toolCallId": "t2", "title": "Run tests"}, "options": [{"optionId": "ok", "name": "允许一次", "kind": "allow_once"}, {"optionId": "no", "name": "拒绝", "kind": "reject_once"}]}})
        elif method is None and m.get("id") == 77:
            choice = m["result"]["outcome"].get("optionId", "cancelled")
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "选了 " + choice}}}})
            send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "end_turn"}})
    """#

    func testCommandWordsKeepQuotedParts() {
        XCTAssertEqual(AgentSession.words("npx -y @agentclientprotocol/claude-agent-acp"), ["npx", "-y", "@agentclientprotocol/claude-agent-acp"])
        XCTAssertEqual(AgentSession.words(#"/usr/bin/python3 "/tmp/my agent.py"  --x"#), ["/usr/bin/python3", "/tmp/my agent.py", "--x"])
    }

    func testDefaultAdaptersNeedNpxAndNodeButNotStandaloneAgentCLI() {
        for kind in AgentKind.allCases {
            var requested: [String] = []
            let availability = AgentAvailability.check(command: kind.defaultCommand, root: URL(fileURLWithPath: "/project"), locate: {
                requested.append($0)
                return $0 == "npx" ? "/test/node/bin/npx" : nil
            }, isExecutable: { ["/test/node/bin/npx", "/test/node/bin/node"].contains($0) })
            XCTAssertTrue(availability.isAvailable, "\(kind): \(availability.issue ?? "")")
            XCTAssertEqual(requested, ["npx"])
        }
    }

    func testMissingNpxExplainsInstallAndSettings() {
        let availability = AgentAvailability.check(command: AgentKind.codex.defaultCommand, root: URL(fileURLWithPath: "/project"),
                                                  locate: { _ in nil }, isExecutable: { _ in false })
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.issue?.contains("npx") == true)
        XCTAssertTrue(availability.issue?.contains("Node.js") == true)
        XCTAssertTrue(availability.issue?.contains("AI 设置") == true)
    }

    /// Homebrew can leave `bin/npx` linked after `node` was unlinked: the Cellar folder the link points into has node.
    func testLinkedNpxFindsNodeInItsRealFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("npx-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let cellar = base.appendingPathComponent("Cellar/node/23/bin"), bin = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["npx", "node"] {
            let url = cellar.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("npx"), withDestinationURL: cellar.appendingPathComponent("npx"))
        let availability = AgentAvailability.check(command: AgentKind.codex.defaultCommand, root: URL(fileURLWithPath: "/project"),
                                                  locate: { _ in bin.appendingPathComponent("npx").path })
        XCTAssertTrue(availability.isAvailable, availability.issue ?? "")
    }

    func testNpxWithoutNodeIsUnavailable() {
        let availability = AgentAvailability.check(command: AgentKind.codex.defaultCommand, root: URL(fileURLWithPath: "/project"),
                                                  locate: { _ in "/test/bin/npx" }, isExecutable: { $0 == "/test/bin/npx" })
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.issue?.contains("找到了 npx") == true)
    }

    func testCustomAdapterUsesItsOwnExecutableAndReportsInvalidCommand() {
        let root = URL(fileURLWithPath: "/project")
        let custom = AgentAvailability.check(command: #""/custom/my adapter" --stdio"#, root: root,
                                             locate: { _ in XCTFail("absolute custom commands should not search for npx"); return nil },
                                             isExecutable: { $0 == "/custom/my adapter" })
        XCTAssertTrue(custom.isAvailable)
        XCTAssertEqual(custom.executable, "/custom/my adapter")
        let missing = AgentAvailability.check(command: "/missing/custom-adapter --stdio", root: root,
                                              locate: { _ in nil }, isExecutable: { _ in false })
        XCTAssertFalse(missing.isAvailable)
        XCTAssertTrue(missing.issue?.contains("/missing/custom-adapter") == true)
        XCTAssertTrue(missing.issue?.contains("AI 设置") == true)
    }

    func testRelativeCustomAdapterResolvesFromProjectDirectory() {
        let availability = AgentAvailability.check(command: "./tools/adapter --stdio", root: URL(fileURLWithPath: "/project"),
                                                  locate: { _ in nil }, isExecutable: { $0 == "/project/tools/adapter" })
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.executable, "/project/tools/adapter")
    }

    @MainActor
    func testConnectKeepsConfiguredModelAndSelectionRecoversFailedPrompt() async throws {
        let (session, root, command) = try modelSession()
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        session.start(command: command)
        try await waitUntilIdle(session)
        XCTAssertEqual(session.state, .ready)
        XCTAssertTrue(session.transcript.entries.isEmpty, "Connecting must not send a model prompt")
        XCTAssertEqual(session.currentModelID, "configured-unavailable", "Do not replace a configured model silently")
        XCTAssertEqual(session.availableModels.map(\.id), ["chosen-model", "rejected"])

        session.send("hi", context: [], command: command)
        try await waitUntilIdle(session)
        guard case .failed = session.state else { return XCTFail("Expected failed default model prompt") }
        XCTAssertTrue(session.isConnected, "Keep the connection so a model can be selected after failure")
        session.selectModel("chosen-model")
        try await waitUntilIdle(session)
        XCTAssertEqual(session.currentModelID, "chosen-model")
        XCTAssertEqual(session.state, .ready)
        session.send("retry", context: [], command: command)
        try await waitUntilIdle(session)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.transcript.entries.last?.text, "session/set_config_option:chosen-model")
    }

    @MainActor
    func testLegacyModelSelectionUsesSetModelAndRejectKeepsPreviousModel() async throws {
        let (session, root, command) = try modelSession(legacy: true)
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        session.start(command: command)
        try await waitUntilIdle(session)
        session.selectModel("not-advertised")
        XCTAssertEqual(session.currentModelID, "configured-unavailable")
        XCTAssertFalse(session.isSelectingModel)
        session.selectModel("rejected")
        try await waitUntilIdle(session)
        XCTAssertEqual(session.currentModelID, "configured-unavailable")
        XCTAssertTrue(session.transcript.entries.last?.text.contains("切换模型失败") == true)
        session.selectModel("chosen-model")
        try await waitUntilIdle(session)
        XCTAssertEqual(session.currentModelID, "chosen-model")
        session.send("hi", context: [], command: command)
        try await waitUntilIdle(session)
        XCTAssertEqual(session.transcript.entries.last?.text, "session/set_model:chosen-model")
    }

    @MainActor
    private func modelSession(legacy: Bool = false) throws -> (AgentSession, URL, String) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs python3")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("agent.py")
        try Self.modelAgent.write(to: script, atomically: true, encoding: .utf8)
        return (AgentSession(agent: .codex, root: root, gitDir: nil), root, "/usr/bin/python3 '\(script.path)'\(legacy ? " --legacy" : "")")
    }

    @MainActor
    private func waitUntilIdle(_ session: AgentSession) async throws {
        let deadline = Date().addingTimeInterval(5)
        while session.isBusy {
            if Date() > deadline { XCTFail("Agent did not become idle: \(session.state)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testConversationWithPermissionAndSavedTranscript() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs python3 for the fake agent")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)").resolvingSymlinksInPath()
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake_agent.py")
        try Self.fakeAgent.write(to: script, atomically: true, encoding: .utf8)

        let session = AgentSession(agent: .claude, root: root, gitDir: gitDir)
        var turns = 0
        session.onTurnEnded = { turns += 1 }
        session.send("把 README 改短", context: [AgentContext(title: "README.md", text: "# Hello")], command: "/usr/bin/python3 '\(script.path)'")
        let deadline = Date().addingTimeInterval(15)
        while !session.transcript.entries.contains(where: { $0.kind == .permission }) {
            if Date() > deadline { return XCTFail("no permission request: \(session.transcript.entries) \(session.state)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(session.state, .running)
        let permission = try XCTUnwrap(session.transcript.entries.first { $0.kind == .permission })
        XCTAssertEqual(permission.options.map(\.name), ["允许一次", "拒绝"])
        session.choose(permission.id, option: permission.options[0])
        while session.state != .ready {
            if Date() > deadline { return XCTFail("turn did not end: \(session.state)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(turns, 1)
        let kinds = session.transcript.entries.map(\.kind)
        XCTAssertEqual(kinds, [.user, .agent, .tool, .permission, .agent])
        XCTAssertTrue(session.transcript.entries[0].text.contains("〔README.md〕"))
        XCTAssertEqual(session.transcript.entries[1].text, "收到：把 README 改短")
        XCTAssertTrue(session.transcript.entries[0].text.hasSuffix("把 README 改短"))
        XCTAssertEqual(session.transcript.entries[3].status, "允许一次")
        XCTAssertEqual(session.transcript.entries[4].text, "选了 ok")
        session.close()

        let restored = try XCTUnwrap(AgentSession.latest(root: root, gitDir: gitDir))
        XCTAssertTrue(restored.restored)
        XCTAssertEqual(restored.transcript.entries.map(\.kind), kinds)
    }

    @MainActor
    func testMissingAdapterSaysWhat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = AgentSession(agent: .codex, root: root, gitDir: nil)
        session.send("hi", context: [], command: "/nonexistent/agent-acp")
        let deadline = Date().addingTimeInterval(5)
        while session.isBusy || session.state == .idle { if Date() > deadline { return XCTFail("still \(session.state)") }; try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .failed(let message) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertTrue(message.contains("没有找到"))
        XCTAssertEqual(session.transcript.entries.last?.kind, .notice)
    }
}
