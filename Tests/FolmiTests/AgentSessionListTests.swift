import XCTest
@testable import FolmiCore
@testable import Folmi

final class AgentSessionListTests: XCTestCase {
    static let fakeAgent = #"""
    import json, os, sys
    log = sys.argv[1]
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def update(session, name, **values):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": dict(sessionUpdate=name, **values)}})
    for line in sys.stdin:
        m = json.loads(line)
        with open(log, "a") as f:
            f.write(json.dumps(dict(m, pid=os.getpid())) + "\n")
        method = m.get("method")
        p = m.get("params", {})
        result = {}
        if method == "initialize":
            sessions = {"resume": {}}
            if "--no-list" not in sys.argv: sessions["list"] = {}
            result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": "--no-load" not in sys.argv, "sessionCapabilities": sessions}}
        elif method == "session/new": result = {"sessionId": "live-id"}
        elif method == "session/list":
            if "--list-error" in sys.argv:
                send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32603, "message": "list failed: fixture error"}})
                continue
            if "--many" in sys.argv:
                page = int(p.get("cursor", "0"))
                result = {"sessions": [{"sessionId": "many-" + str(page * 120 + i), "cwd": p["cwd"], "title": "会话 " + str(page * 120 + i)} for i in range(120)], "nextCursor": str(page + 1)}
            elif not p.get("cursor"):
                result = {"sessions": [{"sessionId": "live-id", "cwd": p["cwd"], "title": "当前任务", "updatedAt": "2026-10-28T08:10:00Z"}, {"sessionId": "folmi-id", "cwd": p["cwd"], "title": "修复列表", "updatedAt": "2026-10-27T08:00:00Z"}], "nextCursor": "second-page"}
            else:
                result = {"sessions": [{"sessionId": "external-id", "cwd": p["cwd"], "title": "外部调查", "updatedAt": "2026-10-26T08:00:00Z"}, {"sessionId": "untitled-id", "cwd": p["cwd"]}]}
        elif method == "session/load":
            session = p["sessionId"]
            update(session, "user_message_chunk", content={"type": "text", "text": "历史问题"})
            update(session, "agent_message_chunk", content={"type": "text", "text": "历史回答"})
            update(session, "tool_call", toolCallId="history-tool", title="读取 README.md", kind="read", status="completed", locations=[{"path": "README.md"}])
        elif method == "session/prompt":
            update(p["sessionId"], "agent_message_chunk", content={"type": "text", "text": "继续回答"})
            result = {"stopReason": "end_turn"}
        if "id" in m: send({"jsonrpc": "2.0", "id": m["id"], "result": result})
    """#

    @MainActor
    func testDisconnectedListGetsBothPagesForProjectWithoutCreatingSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let list = AgentSessionList()
        await list.refresh(session: fixture.session, command: fixture.command)

        XCTAssertEqual(list.supportsList, true)
        XCTAssertEqual(list.supportsLoad, true)
        XCTAssertFalse(list.isLoading)
        XCTAssertNil(list.error)
        XCTAssertEqual(Set(list.sessions.map(\.id)), ["live-id", "folmi-id", "external-id", "untitled-id"])
        XCTAssertEqual(list.sessions.first(where: { $0.id == "untitled-id" })?.title, "未命名会话")
        XCTAssertNotNil(list.sessions.first(where: { $0.id == "live-id" })?.updatedAt)
        XCTAssertFalse(fixture.session.isConnected)
        XCTAssertNil(fixture.session.sessionID)
        let requests = try readRequests(fixture.log)
        XCTAssertEqual(requests.compactMap { $0["method"]?.string }, ["initialize", "session/list", "session/list"])
        let pages = requests.filter { $0["method"]?.string == "session/list" }
        XCTAssertEqual(pages.map { $0["params"]?["cwd"]?.string }, [fixture.root.path, fixture.root.path])
        XCTAssertNil(pages.first?["params"]?["cursor"]?.string)
        XCTAssertEqual(pages.last?["params"]?["cursor"]?.string, "second-page")
    }

    @MainActor
    func testConnectedListReusesAdapterAndGroupsCurrentLocalAndExternalSessions() async throws {
        let fixture = try makeFixture()
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        try writeSaved(gitDir: fixture.gitDir, sessionID: "folmi-id")
        fixture.session.start(command: fixture.command)
        try await waitUntilIdle(fixture.session)
        XCTAssertEqual(fixture.session.sessionID, "live-id")
        let list = AgentSessionList()
        await list.refresh(session: fixture.session, command: fixture.command)

        let groups = list.groups(current: fixture.session)
        XCTAssertEqual(groups.map(\.title), ["打开着", "在 Folmi 开的", "在别处开的（Codex CLI、App 等）"])
        XCTAssertEqual(groups.map { Set($0.sessions.map(\.id)) }, [Set(["live-id"]), Set(["folmi-id"]), Set(["external-id", "untitled-id"])])
        XCTAssertEqual(list.groups(current: fixture.session, search: "修复").flatMap(\.sessions).map(\.id), ["folmi-id"])
        XCTAssertTrue(list.groups(current: fixture.session, search: "不存在的标题").flatMap(\.sessions).isEmpty)
        let requests = try readRequests(fixture.log)
        XCTAssertEqual(requests.filter { $0["method"]?.string == "initialize" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"]?.string == "session/new" }.count, 1)
        XCTAssertEqual(Set(requests.compactMap { $0["pid"]?.int }).count, 1)
        XCTAssertTrue(fixture.session.isConnected)
    }

    @MainActor
    func testAdapterWithoutListCapabilityDoesNotReceiveListRequest() async throws {
        let fixture = try makeFixture(flags: "--no-list")
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let list = AgentSessionList()
        await list.refresh(session: fixture.session, command: fixture.command)

        XCTAssertEqual(list.supportsList, false)
        XCTAssertTrue(list.sessions.isEmpty)
        XCTAssertFalse(list.isLoading)
        XCTAssertEqual(try readRequests(fixture.log).compactMap { $0["method"]?.string }, ["initialize"])
    }

    @MainActor
    func testLoadReplaysHistoryAndRequiresContinueBeforePromptingLoadedID() async throws {
        let fixture = try makeFixture()
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.session.load(sessionID: "external-id", fromFolmi: false, command: fixture.command)

        XCTAssertEqual(fixture.session.sessionID, "external-id")
        XCTAssertTrue(fixture.session.isReadOnly)
        XCTAssertFalse(fixture.session.restored)
        XCTAssertEqual(fixture.session.transcript.entries.map(\.kind), [.user, .agent, .tool])
        XCTAssertEqual(fixture.session.transcript.entries.map(\.text), ["历史问题", "历史回答", "读取 README.md"])
        XCTAssertEqual(fixture.session.transcript.entries.last?.paths, ["README.md"])
        let history = fixture.session.transcript
        fixture.session.send("还没接管", context: [], command: fixture.command)
        XCTAssertEqual(fixture.session.transcript, history)
        XCTAssertFalse(fixture.session.isBusy)
        XCTAssertFalse(try readRequests(fixture.log).contains { $0["method"]?.string == "session/prompt" })

        fixture.session.continueHere()
        XCTAssertFalse(fixture.session.isReadOnly)
        fixture.session.send("接着做", context: [], command: fixture.command)
        try await waitUntilIdle(fixture.session)
        XCTAssertEqual(fixture.session.transcript.entries.last?.text, "继续回答")
        let requests = try readRequests(fixture.log)
        XCTAssertFalse(requests.contains { $0["method"]?.string == "session/new" })
        let loaded = try XCTUnwrap(requests.first { $0["method"]?.string == "session/load" })
        XCTAssertEqual(loaded["params"]?["cwd"]?.string, fixture.root.path)
        XCTAssertNotNil(loaded["params"]?["mcpServers"]?.array)
        let prompts = requests.filter { $0["method"]?.string == "session/prompt" }
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?["params"]?["sessionId"]?.string, "external-id")
        XCTAssertEqual(AgentSession.savedSessionIDs(gitDir: fixture.gitDir, agent: .codex), ["external-id"])
    }

    @MainActor
    func testLoadingFolmiSessionAlsoStartsReadOnly() async throws {
        let fixture = try makeFixture()
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.session.load(sessionID: "folmi-id", fromFolmi: true, command: fixture.command)
        XCTAssertTrue(fixture.session.isReadOnly)
        fixture.session.send("先别发", context: [], command: fixture.command)
        XCTAssertFalse(try readRequests(fixture.log).contains { $0["method"]?.string == "session/prompt" })
    }

    @MainActor
    func testOldSavedFileWithoutSessionIDStillLoads() throws {
        let fixture = try makeFixture()
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        try writeSaved(gitDir: fixture.gitDir)
        let restored = try XCTUnwrap(AgentSession.latest(root: fixture.root, gitDir: fixture.gitDir))
        defer { restored.close() }
        XCTAssertEqual(restored.agent, .codex)
        XCTAssertTrue(restored.restored)
        XCTAssertEqual(restored.transcript.entries.first?.text, "旧记录")
        XCTAssertTrue(AgentSession.savedSessionIDs(gitDir: fixture.gitDir, agent: .codex).isEmpty)
    }

    @MainActor
    func testListReportsAdapterErrorWithoutChangingMessage() async throws {
        let fixture = try makeFixture(flags: "--list-error")
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let list = AgentSessionList()
        await list.refresh(session: fixture.session, command: fixture.command)
        XCTAssertEqual(list.error, "list failed: fixture error")
        XCTAssertFalse(list.isLoading)
        XCTAssertTrue(list.sessions.isEmpty)
        XCTAssertFalse(try readRequests(fixture.log).contains { $0["method"]?.string == "session/new" })
    }

    @MainActor
    func testListStopsAtTwoHundredSessionsDespiteFurtherCursor() async throws {
        let fixture = try makeFixture(flags: "--many")
        defer { fixture.session.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let list = AgentSessionList()
        await list.refresh(session: fixture.session, command: fixture.command)
        XCTAssertEqual(list.sessions.count, 200)
        XCTAssertEqual(try readRequests(fixture.log).filter { $0["method"]?.string == "session/list" }.count, 2)
    }

    @MainActor
    private func makeFixture(flags: String = "") throws -> (session: AgentSession, root: URL, gitDir: URL, command: String, log: URL) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "needs python3 for the fake agent")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-list-\(UUID().uuidString)").resolvingSymlinksInPath()
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("agent.py"), log = root.appendingPathComponent("requests.jsonl")
        try Self.fakeAgent.write(to: script, atomically: true, encoding: .utf8)
        return (AgentSession(agent: .codex, root: root, gitDir: gitDir), root, gitDir, "/usr/bin/python3 '\(script.path)' '\(log.path)' \(flags)", log)
    }

    private func readRequests(_ log: URL) throws -> [JSON] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { JSON.parse(Data($0.utf8)) }
    }

    @MainActor
    private func writeSaved(gitDir: URL, sessionID: String? = nil) throws {
        let entry = ACPTranscript.Entry(id: "old-user", kind: .user, text: "旧记录")
        var transcript = ACPTranscript()
        transcript.append(entry)
        var saved: [String: Any] = ["agent": "codex", "started": 0,
                                    "transcript": try JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript))]
        if let sessionID { saved["sessionId"] = sessionID }
        let folder = AgentSession.folder(gitDir: gitDir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: saved).write(to: folder.appendingPathComponent("codex-old.json"))
    }

    @MainActor
    private func waitUntilIdle(_ session: AgentSession) async throws {
        let deadline = Date().addingTimeInterval(5)
        while session.isBusy {
            if Date() > deadline { XCTFail("Agent did not become idle: \(session.state)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
