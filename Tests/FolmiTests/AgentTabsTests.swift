import XCTest
@testable import FolmiCore
@testable import Folmi

final class AgentTabsTests: XCTestCase {
    /// Numbered sessions; a prompt answers with its own session id, and "ask" asks for a permission first.
    static let fakeAgent = #"""
    import json, os, sys
    log = sys.argv[1]
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    count = 0
    pending = {}
    for line in sys.stdin:
        m = json.loads(line)
        with open(log, "a") as f:
            f.write(json.dumps(dict(m, pid=os.getpid())) + "\n")
        method = m.get("method")
        p = m.get("params", {})
        if "id" in m and "method" not in m:
            sid, rid = pending.pop(m["id"])
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "允许了"}}}})
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
            continue
        result = {}
        if method == "initialize":
            result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"list": {}, "close": {}}}}
        elif method == "session/new":
            count += 1
            result = {"sessionId": "s" + str(count)}
        elif method == "session/prompt":
            sid = p["sessionId"]
            text = p["prompt"][0]["text"]
            if text == "ask":
                pending[9000 + count] = (sid, m["id"])
                send({"jsonrpc": "2.0", "id": 9000 + count, "method": "session/request_permission", "params": {"sessionId": sid, "toolCall": {"title": "运行 make"}, "options": [{"optionId": "ok", "name": "允许一次", "kind": "allow_once"}]}})
                continue
            if text == "title":
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "session_info_update", "title": "修登录超时"}}})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "回答 " + sid}}}})
            result = {"stopReason": "end_turn"}
        elif method == "session/close":
            result = {}
        if "id" in m: send({"jsonrpc": "2.0", "id": m["id"], "result": result})
    """#

    private var cleanupURLs: [URL] = []

    override func tearDown() {
        for url in cleanupURLs { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
        super.tearDown()
    }

    @MainActor
    func testConversationsShareOneAdapterAndGetTheirOwnUpdates() async throws {
        let (root, command, log) = try fixture()
        let host = AgentHost(agent: .codex, root: root)
        defer { host.close() }
        let first = AgentSession(agent: .codex, root: root, gitDir: nil, host: host)
        let second = AgentSession(agent: .codex, root: root, gitDir: nil, host: host)
        first.send("一", context: [], command: command)
        second.send("二", context: [], command: command)
        try await waitUntilIdle(first); try await waitUntilIdle(second)

        XCTAssertEqual(Set([first.sessionID, second.sessionID]), ["s1", "s2"])
        XCTAssertEqual(first.transcript.entries.last?.text, "回答 \(first.sessionID ?? "")")
        XCTAssertEqual(second.transcript.entries.last?.text, "回答 \(second.sessionID ?? "")")
        var requests = try readRequests(log)
        XCTAssertEqual(Set(requests.compactMap { $0["pid"]?.int }).count, 1, "one adapter process for both")
        XCTAssertEqual(requests.filter { $0["method"]?.string == "initialize" }.count, 1)

        // Closing one tab frees its session in the adapter and leaves the other connected.
        let closedID = try XCTUnwrap(first.sessionID)
        first.close()
        XCTAssertFalse(first.isConnected)
        XCTAssertTrue(second.isConnected)
        second.send("还在", context: [], command: command)
        try await waitUntilIdle(second)
        XCTAssertEqual(second.transcript.entries.last?.text, "回答 \(second.sessionID ?? "")")
        requests = try readRequests(log)
        XCTAssertEqual(requests.first { $0["method"]?.string == "session/close" }?["params"]?["sessionId"]?.string, closedID)

        // The adapter quits: both learn it, and the next message starts a new process.
        host.connection?.close()
        try await eventually("断开") { !second.isConnected }
        second.send("重连", context: [], command: command)
        try await waitUntilIdle(second)
        XCTAssertEqual(second.transcript.entries.last?.text, "回答 \(second.sessionID ?? "")")
        XCTAssertEqual(Set(try readRequests(log).compactMap { $0["pid"]?.int }).count, 2)
    }

    @MainActor
    func testTitleFromAdapterNamesTheTab() async throws {
        let (root, command, _) = try fixture()
        let session = AgentSession(agent: .codex, root: root, gitDir: nil)
        defer { session.close() }
        XCTAssertEqual(session.displayTitle, "新会话")
        session.send("把这里改成和 Auth 一样的写法然后补测试", context: [AgentContext(title: "a.swift:1-2", text: "x")], command: command)
        XCTAssertEqual(session.displayTitle, "把这里改成和 Auth 一样…", "attachments are not the name")
        try await waitUntilIdle(session)
        session.send("title", context: [], command: command)
        try await waitUntilIdle(session)
        XCTAssertEqual(session.displayTitle, "修登录超时")
    }

    @MainActor
    func testTabsReplaceSpareOnesAndKeepWorkingOnes() async throws {
        let (model, command) = try await makeModel()
        model.ensureAgentSession()
        let spare = try XCTUnwrap(model.agentSession)
        XCTAssertTrue(spare.isSpare)

        model.newAgentSession(.codex)
        XCTAssertEqual(model.agentSessions.count, 1, "an untouched tab is reused")
        let first = try XCTUnwrap(model.agentSession)
        XCTAssertFalse(first === spare)

        first.send("一", context: [], command: command)
        try await waitUntilIdle(first)
        model.newAgentSession(.codex)
        XCTAssertEqual(model.agentSessions.count, 2)
        let second = try XCTUnwrap(model.agentSession)
        XCTAssertTrue(first.host === second.host, "same agent, same adapter")

        // A working conversation keeps its tab; a finished one closes and the neighbour is shown.
        second.send("ask", context: [], command: command)
        try await eventually("等允许") { second.needsPermission }
        model.closeAgentSession(second)
        XCTAssertEqual(model.agentSessions.count, 2)
        let permission = try XCTUnwrap(second.transcript.entries.last { $0.kind == .permission })
        second.choose(permission.id, option: permission.options.first)
        try await waitUntilIdle(second)
        model.closeAgentSession(second)
        XCTAssertEqual(model.agentSessions.map(\.id), [first.id])
        XCTAssertTrue(model.agentSession === first)

        model.closeAgentSession(first)
        XCTAssertEqual(model.agentSessions.count, 1, "the AI tab always has a conversation")
        XCTAssertTrue(model.agentSession?.isSpare == true)
    }

    @MainActor
    func testConversationOffScreenGetsADotAndSharedWorkTreeIsSaidOnce() async throws {
        let (model, command) = try await makeModel()
        model.openAgentTab()
        model.newAgentSession(.codex)
        let background = try XCTUnwrap(model.agentSession)
        model.agentDraft = "一"
        model.sendToAgent()
        try await waitUntilIdle(background)
        model.newAgentSession(.codex)
        let front = try XCTUnwrap(model.agentSession)
        // The test runner is not the active app, so the first turn already counted as unseen; start clean.
        background.unseen = false
        XCTAssertFalse(model.agentTabNeedsYou)

        background.send("ask", context: [], command: command)
        try await eventually("等允许") { background.needsPermission }
        XCTAssertTrue(background.unseen, "a question in a tab not on screen")
        XCTAssertTrue(model.agentTabNeedsYou)

        model.agentDraft = "二"
        model.sendToAgent()
        XCTAssertTrue(front.transcript.entries.contains { $0.kind == .notice && $0.text.contains("也在改这个工作区") })
        try await waitUntilIdle(front)
        model.agentDraft = "三"
        model.sendToAgent()
        XCTAssertEqual(front.transcript.entries.filter { $0.text.contains("也在改这个工作区") }.count, 1)
        try await waitUntilIdle(front)

        model.selectAgentSession(background)
        XCTAssertFalse(background.unseen)
        let permission = try XCTUnwrap(background.transcript.entries.last { $0.kind == .permission })
        background.choose(permission.id, option: permission.options.first)
        try await waitUntilIdle(background)
    }

    // MARK: Helpers

    @MainActor
    private func fixture() throws -> (root: URL, command: String, log: URL) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs python3 for the fake agent")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tabs-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanupURLs.append(root)
        let script = root.appendingPathComponent("agent.py"), log = root.appendingPathComponent("requests.jsonl")
        try Self.fakeAgent.write(to: script, atomically: true, encoding: .utf8)
        return (root, "/usr/bin/python3 '\(script.path)' '\(log.path)'", log)
    }

    @MainActor
    private func makeModel() async throws -> (FolmiModel, String) {
        let (_, command, _) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.aiSettings.agentCommands = ["codex": command]
        model.aiSettings.defaultAgent = "codex"
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开项目") { !model.busy && model.snapshot != nil }
        addTeardownBlock { @MainActor in
            for session in model.agentSessions { session.close() }
            for host in model.agentHosts.values { host.close() }
        }
        return (model, command)
    }

    private func readRequests(_ log: URL) throws -> [JSON] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { JSON.parse(Data($0.utf8)) }
    }

    @MainActor
    private func waitUntilIdle(_ session: AgentSession) async throws {
        try await eventually("agent 空闲：\(session.state)") { !session.isBusy }
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
