import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// The agents the AI tab talks to over ACP. Each runs through its ACP adapter with the user's own login.
enum AgentKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var defaultCommand: String {
        self == .claude ? "npx -y @agentclientprotocol/claude-agent-acp" : "npx -y @agentclientprotocol/codex-acp"
    }
    var loginHint: String { self == .claude ? "在终端里运行 claude 登录一次" : "在终端里运行 codex login" }
}

/// Local launch prerequisites, not an authentication check. The default npm adapters bundle their own
/// agent runtime; an independently installed `claude` or `codex` command is not required.
struct AgentAvailability: Equatable, Sendable {
    var executable: String?
    var issue: String?
    var isAvailable: Bool { executable != nil && issue == nil }

    /// `locateTool` may ask the login shell: callers must keep this check off the main thread.
    static func check(command: String, root: URL, locate: (String) -> String? = LocalCLI.locateTool,
                      isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Self {
        guard let first = AgentSession.words(command).first else {
            return Self(issue: "agent 命令是空的：在 AI 设置里填写。")
        }
        let path: String?
        if first.contains("/") {
            let expanded = (first as NSString).expandingTildeInPath
            path = expanded.hasPrefix("/") ? expanded : root.appendingPathComponent(expanded).standardizedFileURL.path
        } else {
            path = locate(first)
        }
        guard let path, isExecutable(path) else {
            return Self(issue: "没有找到 \(first)。\(first == "npx" ? "请安装 Node.js（包含 npx），或在 AI 设置里填写已安装的 ACP 适配器命令。" : "请在 AI 设置里检查 ACP 适配器命令。")")
        }
        if URL(fileURLWithPath: path).lastPathComponent == "npx" {
            // npx's shebang invokes node using the exact PATH passed to the adapter process.
            let folders = (LocalCLI.environment(for: path)["PATH"] ?? "").components(separatedBy: ":")
            guard folders.contains(where: { isExecutable(URL(fileURLWithPath: $0).appendingPathComponent("node").path) }) else {
                return Self(issue: "找到了 npx，但没有找到 Node.js。请安装 Node.js，或在 AI 设置里填写独立 ACP 适配器命令。")
            }
        }
        return Self(executable: path)
    }

    static func detect(commands: [String: String], root: URL) async -> [AgentKind: Self] {
        await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { kind in
                let custom = commands[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (kind, check(command: custom.isEmpty ? kind.defaultCommand : custom, root: root))
            })
        }.value
    }
}

/// Something handed to the agent along with the message: a selection, a diff, a note.
struct AgentContext: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    /// Where it came from, e.g. `file:///repo/a.swift#L12-30`: sent as an ACP resource when the agent takes them.
    var uri: String?
}

/// One conversation with an agent in one project: the adapter process, the ACP session and what it showed.
@MainActor
@Observable
final class AgentSession: Identifiable {
    enum State: Equatable { case idle, starting, ready, running, failed(String) }
    struct ModelOption: Identifiable, Equatable {
        var id: String
        var name: String
    }

    let agent: AgentKind
    let root: URL
    let gitDir: URL?
    let started: Date
    var transcript = ACPTranscript()
    var state = State.idle
    var currentModelID: String?
    var availableModels: [ModelOption] = []
    var isSelectingModel = false
    /// Shown from disk after a restart: the next message starts a new session.
    var restored = false

    private(set) var sessionID: String?
    private(set) var isReadOnly = false
    /// The adapter's name for the conversation (`session_info_update`).
    private(set) var title: String?
    /// Something happened here while it was not on screen: a finished turn or a question waiting.
    var unseen = false
    /// Said once per conversation: another one is changing the same work tree at the same time.
    var warnedSharedWorkTree = false

    /// The adapter process, shared with the other conversations of this agent in the project.
    let host: AgentHost
    @ObservationIgnored private let ownsHost: Bool
    /// Which launch of the host this conversation's id belongs to; -1 when it is not open there.
    @ObservationIgnored private var hostGeneration = -1
    @ObservationIgnored private var modelConfigID: String?
    @ObservationIgnored private var permissions: [String: CheckedContinuation<String?, Never>] = [:]
    /// Called when a turn ends, so the change list catches up with what the agent wrote.
    @ObservationIgnored var onTurnEnded: (() -> Void)?
    /// Called when the agent asks for a permission, so a conversation off screen can say so.
    @ObservationIgnored var onPermission: (() -> Void)?

    /// Without a host the conversation starts its own adapter and ends it on close (tests, restored transcripts).
    init(agent: AgentKind, root: URL, gitDir: URL?, started: Date = Date(), host: AgentHost? = nil) {
        self.agent = agent; self.root = root; self.gitDir = gitDir; self.started = started
        self.host = host ?? AgentHost(agent: agent, root: root)
        ownsHost = host == nil
    }

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isBusy: Bool { state == .starting || state == .running || isSelectingModel }
    var isConnected: Bool { host.isRunning && host.generation == hostGeneration && sessionID != nil }
    var connection: ACPConnection? { host.connection }
    var supportsSessionList: Bool? { host.supportsList }
    var supportsSessionLoad: Bool? { host.supportsLoad }
    /// Nothing here to keep: a tab that a new conversation may take over.
    var isSpare: Bool { restored || (transcript.entries.isEmpty && !isBusy && !isConnected && !isReadOnly) }
    var needsPermission: Bool { transcript.entries.contains { $0.kind == .permission && $0.status == nil } }

    /// The tab's name: the adapter's title, else the first thing said, else 新会话.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        guard let first = transcript.entries.first(where: { $0.kind == .user })?.text else { return "新会话" }
        // Attachments are shown as 〔…〕 on the first line; the request itself names the conversation better.
        let lines = first.split(separator: "\n").map(String.init)
        let said = lines.count > 1 && lines[0].hasPrefix("〔") ? lines.dropFirst().joined(separator: " ") : first
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "新会话" }
        return trimmed.count > 14 ? String(trimmed.prefix(14)) + "…" : trimmed
    }

    // MARK: Sending

    /// Connect without sending a prompt, so the adapter's current model can be inspected and changed first.
    func start(command: String) {
        guard !isBusy, !isConnected, !isReadOnly else { return }
        state = .starting
        Task {
            do { try await connect(command) }
            catch {
                let message = Self.describe(error, agent: agent)
                note(message); state = .failed(message); save()
            }
        }
    }

    /// Only choices advertised by this adapter are sent back; the user's configured default stays intact.
    func selectModel(_ id: String) {
        guard isConnected, !isBusy, !isReadOnly, id != currentModelID,
              availableModels.contains(where: { $0.id == id }), let connection, let sessionID else { return }
        isSelectingModel = true
        Task {
            defer { isSelectingModel = false }
            do {
                let response: JSON
                if let modelConfigID {
                    response = try await connection.request("session/set_config_option", .object([
                        "sessionId": .string(sessionID), "configId": .string(modelConfigID), "value": .string(id),
                    ]))
                } else {
                    response = try await connection.request("session/set_model", .object([
                        "sessionId": .string(sessionID), "modelId": .string(id),
                    ]))
                }
                // Legacy set_model acknowledges with {}; config options return the authoritative new state.
                currentModelID = id
                applyModelConfiguration(response)
                state = .ready
            } catch {
                let message = "切换模型失败：\(Self.describe(error, agent: agent))"
                note(message); state = .failed(message); save()
            }
        }
    }

    func applyModelConfiguration(_ response: JSON) {
        if let option = response["configOptions"]?.array?.first(where: {
            $0["type"]?.string == "select" && ($0["category"]?.string == "model" || $0["id"]?.string == "model")
        }), let configID = option["id"]?.string {
            modelConfigID = configID
            currentModelID = option["currentValue"]?.string
            availableModels = (option["options"]?.array ?? []).flatMap { value -> [JSON] in
                value["options"]?.array ?? [value]
            }.compactMap { value in
                guard let id = value["value"]?.string else { return nil }
                return ModelOption(id: id, name: value["name"]?.string ?? id)
            }
        } else if let models = response["models"] {
            modelConfigID = nil
            currentModelID = models["currentModelId"]?.string
            availableModels = (models["availableModels"]?.array ?? []).compactMap { value in
                guard let id = value["modelId"]?.string else { return nil }
                return ModelOption(id: id, name: value["name"]?.string ?? id)
            }
        }
    }

    func send(_ text: String, context: [AgentContext], command: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !context.isEmpty, !isBusy, !isReadOnly else { return }
        let shown = (context.isEmpty ? "" : context.map { "〔\($0.title)〕" }.joined(separator: " ") + "\n") + message
        transcript.append(.init(id: "user-\(transcript.entries.count)", kind: .user, text: shown))
        state = isConnected ? .running : .starting
        Task { await run(message, context: context, command: command) }
    }

    /// Attachments with a source go as `resource` blocks when the agent takes them; the rest, and all of them for an
    /// agent that does not, go as fenced text before the message.
    nonisolated static func promptBlocks(_ message: String, context: [AgentContext], embedded: Bool) -> [JSON] {
        let resources = embedded ? context.filter { $0.uri != nil } : []
        let pasted = context.filter { item in !resources.contains { $0.id == item.id } }
        let text = pasted.map { "\($0.title)：\n```\n\($0.text)\n```" }.joined(separator: "\n\n")
            + (pasted.isEmpty || message.isEmpty ? "" : "\n\n") + message
        var blocks: [JSON] = resources.map { item in
            .object(["type": .string("resource"), "resource": .object([
                "uri": .string(item.uri ?? ""), "mimeType": .string("text/plain"), "text": .string(item.text),
            ])])
        }
        if !text.isEmpty || blocks.isEmpty {
            // Name what the resources are, so the agent reads "这两处" against the right attachments.
            let named = resources.isEmpty ? text : "附件：" + resources.map(\.title).joined(separator: "、") + "\n\n" + text
            blocks.insert(.object(["type": .string("text"), "text": .string(named)]), at: 0)
        }
        return blocks
    }

    private func run(_ message: String, context: [AgentContext], command: String) async {
        do {
            if !isConnected {
                state = .starting
                try await connect(command)
            }
            guard let connection, let sessionID else { return }
            state = .running
            let result = try await connection.request("session/prompt", .object([
                "sessionId": .string(sessionID),
                "prompt": .array(Self.promptBlocks(message, context: context, embedded: host.embeddedContext)),
            ]))
            let reason = result["stopReason"]?.string ?? "end_turn"
            if reason == "refusal" { note("agent 拒绝了这个请求。") }
            if reason == "max_tokens" || reason == "max_turn_requests" { note("agent 到了单轮上限，停在这里。") }
            if reason == "cancelled" { note("已停止。") }
            state = .ready
        } catch {
            let message = Self.describe(error, agent: agent)
            note(message)
            state = .failed(message)
        }
        save()
        onTurnEnded?()
    }

    /// Opens a session in the project on the shared adapter (with the Folmi MCP server attached).
    private func connect(_ command: String) async throws {
        let connection = try await host.connect(command)
        let created = try await connection.request("session/new", .object([
            "cwd": .string(root.path), "mcpServers": .array(mcpServers),
        ]))
        guard let id = created["sessionId"]?.string else { throw ACPError(code: -1, message: "agent 没有返回会话。") }
        sessionID = id
        attach(id)
        applyModelConfiguration(created)
        restored = false
        state = .ready
        save()
    }

    private func attach(_ id: String) {
        host.register(self, id: id)
        hostGeneration = host.generation
    }

    static var initializeParams: JSON {
        .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false)]),
            "clientInfo": .object(["name": .string("folmi"), "title": .string("Folmi"), "version": .string("1")]),
        ])
    }

    private var mcpServers: [JSON] {
        guard FileManager.default.isExecutableFile(atPath: MCPInstaller.helper.path) else { return [] }
        return [.object(["name": .string(MCPServer.name), "command": .string(MCPInstaller.helper.path),
                         "args": .array([.string("mcp")]), "env": .array([])])]
    }

    /// A Codex conversation shown from its record file, read-only: going on with it here would mean a second client
    /// writing to it (the adapter refuses while the Codex app, CLI or an editor has it open).
    func showRecord(id: String, title: String) async {
        sessionID = id
        self.title = title
        isReadOnly = true
        restored = false
        state = .starting
        let root = self.root.path
        let result: Result<ACPTranscript, ACPError> = await Task.detached(priority: .userInitiated) {
            guard let file = CodexRollout.locate(id: id, home: CodexRollout.home()) else {
                return .failure(ACPError(code: -1, message: "没有找到这个会话的记录文件（~/.codex/sessions）。"))
            }
            guard let data = Self.readRecord(file) else {
                return .failure(ACPError(code: -1, message: "这个会话的记录是压缩过的，装上 zstd（brew install zstd）后才能在这里看。"))
            }
            return .success(CodexRollout.transcript(data, id: id, root: root))
        }.value
        switch result {
        case .success(let transcript):
            self.transcript = transcript
            if transcript.entries.isEmpty { note("这个会话还没有内容。") }
            state = .ready
        case .failure(let error):
            note(error.message); state = .failed(error.message)
        }
    }

    /// Plain JSONL as is; older records are zstd-compressed and need the `zstd` command.
    nonisolated static func readRecord(_ file: URL) -> Data? {
        guard file.pathExtension == "zst" else { return try? Data(contentsOf: file) }
        guard let zstd = LocalCLI.locateTool("zstd") else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", "--", file.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Requests from the agent. Permissions wait for the user; file access is not offered (the agent edits the
    /// work tree itself, and the change list shows what it did).
    func answer(_ method: String, _ params: JSON) async -> Result<JSON, ACPError> {
        guard method == "session/request_permission" else { return .failure(ACPError(code: -32601, message: "Method not found: \(method)")) }
        let id = "permission-\(UUID().uuidString)"
        let call = params["toolCall"]
        let offered: [JSON] = params["options"]?.array ?? []
        let options = offered.compactMap { (option: JSON) -> ACPTranscript.Option? in
            guard let optionID = option["optionId"]?.string else { return nil }
            return ACPTranscript.Option(id: optionID, name: option["name"]?.string ?? optionID, kind: option["kind"]?.string ?? "")
        }
        transcript.append(.init(id: id, kind: .permission, text: call?["title"]?.string ?? "agent 请求权限",
                                toolKind: call?["kind"]?.string, paths: ACPTranscript.paths(call ?? .null), options: options))
        NSApp?.requestUserAttention(.informationalRequest)
        onPermission?()
        let chosen: String? = await withCheckedContinuation { permissions[id] = $0 }
        guard let chosen else { return .success(.object(["outcome": .object(["outcome": .string("cancelled")])])) }
        return .success(.object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(chosen)])]))
    }

    func choose(_ entryID: String, option: ACPTranscript.Option?) {
        guard let continuation = permissions.removeValue(forKey: entryID) else { return }
        if let index = transcript.entries.firstIndex(where: { $0.id == entryID }) { transcript.entries[index].status = option?.name ?? "已取消" }
        continuation.resume(returning: option?.id)
    }

    /// Stops the current turn (the agent answers the prompt with `cancelled`).
    func cancel() {
        guard let connection, let sessionID, state == .running else { return }
        for id in Array(permissions.keys) { choose(id, option: nil) }
        connection.notify("session/cancel", .object(["sessionId": .string(sessionID)]))
    }

    func close() {
        for id in Array(permissions.keys) { choose(id, option: nil) }
        if let sessionID, isConnected { host.unregister(id: sessionID) }
        hostGeneration = -1
        if ownsHost { host.close() }
        currentModelID = nil; availableModels = []; modelConfigID = nil
        if isBusy { state = .idle }
    }

    /// An update the shared adapter routed here.
    func receive(_ update: JSON) {
        switch update["sessionUpdate"]?.string {
        case "config_option_update": applyModelConfiguration(update)
        case "session_info_update": if let title = update["title"]?.string { self.title = title }
        default: transcript.apply(update)
        }
    }

    /// The shared adapter quit: questions waiting can no longer be answered, and the next message reconnects.
    func connectionLost(_ reason: String) {
        for id in Array(permissions.keys) { choose(id, option: nil) }
        hostGeneration = -1
        if state == .ready { state = .idle }
        if !reason.isEmpty, state != .running { note("agent 进程退出了：\(reason.suffix(200))") }
    }

    func notice(_ text: String) { note(text) }

    private func note(_ text: String) {
        transcript.append(.init(id: "notice-\(transcript.entries.count)", kind: .notice, text: text))
    }

    nonisolated static func describe(_ error: Error, agent: AgentKind) -> String {
        let text = (error as? ACPError)?.message ?? error.localizedDescription
        if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("login") {
            return "\(agent.title) 还没登录：\(agent.loginHint)，再回来发送。（\(text.prefix(160))）"
        }
        return text
    }

    /// Splits a command line on spaces, keeping "quoted parts" together.
    nonisolated static func words(_ command: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?
        for character in command {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: Saved conversations

    static func folder(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("sessions", isDirectory: true) }
    private struct Saved: Codable {
        var agent: AgentKind
        var started: Date
        var transcript: ACPTranscript
        var sessionId: String?
        var title: String?

        init(agent: AgentKind, started: Date, transcript: ACPTranscript, sessionId: String?, title: String?) {
            self.agent = agent; self.started = started; self.transcript = transcript; self.sessionId = sessionId; self.title = title
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            agent = try values.decode(AgentKind.self, forKey: .agent)
            started = try values.decode(Date.self, forKey: .started)
            transcript = try values.decode(ACPTranscript.self, forKey: .transcript)
            sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId)
            title = try values.decodeIfPresent(String.self, forKey: .title)
        }
    }

    static func savedSessionIDs(gitDir: URL?, agent: AgentKind) -> Set<String> {
        guard let gitDir, let files = try? FileManager.default.contentsOfDirectory(at: folder(gitDir: gitDir), includingPropertiesForKeys: nil) else { return [] }
        return Set(files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let saved = FolmiShared.read(Saved.self, from: url), saved.agent == agent else { return nil }
            return saved.sessionId
        })
    }

    func save() {
        guard let gitDir, !isReadOnly, !transcript.entries.isEmpty || sessionID != nil else { return }
        let url = Self.folder(gitDir: gitDir).appendingPathComponent("\(agent.rawValue)-\(Int(started.timeIntervalSince1970)).json")
        AppLog.attempt("保存 agent 会话") { try FolmiShared.write(Saved(agent: agent, started: started, transcript: transcript, sessionId: sessionID, title: title), to: url) }
    }

    /// The newest saved conversation in the project, shown read-only until the next message.
    static func latest(root: URL, gitDir: URL?) -> AgentSession? {
        guard let gitDir, let files = try? FileManager.default.contentsOfDirectory(at: folder(gitDir: gitDir), includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "json" }.max { a, b in
            ((try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        // Connecting saves the session id before anything is said; an empty conversation is not worth showing again.
        guard let newest, let saved = FolmiShared.read(Saved.self, from: newest), !saved.transcript.entries.isEmpty else { return nil }
        let session = AgentSession(agent: saved.agent, root: root, gitDir: gitDir, started: saved.started)
        session.transcript = saved.transcript
        session.sessionID = saved.sessionId
        session.title = saved.title
        // Permissions asked in a session that is gone can no longer be answered.
        for index in session.transcript.entries.indices where session.transcript.entries[index].kind == .permission && session.transcript.entries[index].status == nil {
            session.transcript.entries[index].status = "已失效"
        }
        session.restored = true
        return session
    }
}

extension FolmiModel {
    var agentCommand: (AgentKind) -> String {
        { [aiSettings] kind in
            let custom = aiSettings.agentCommands[kind.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
            return custom.isEmpty ? kind.defaultCommand : custom
        }
    }

    /// The AI tab: the project's conversation, restored from disk the first time.
    func openAgentTab() {
        aiTabSelected = true
        agentSession?.unseen = false
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        ensureAgentSession()
    }

    func ensureAgentSession() {
        guard let root = repositoryURL else { return }
        if let session = agentSession, session.root == root { return }
        // Another project: its conversations and adapters end; the new one starts from its last saved conversation.
        for session in agentSessions { session.close() }
        for host in agentHosts.values { host.close() }
        agentSessions = []; agentHosts = [:]
        let session = AgentSession.latest(root: root, gitDir: aiGitDir)
            ?? makeAgentSession(AgentKind(rawValue: aiSettings.defaultAgent) ?? .claude, root: root)
        wire(session)
        agentSessions = [session]
        agentSession = session
    }

    /// The shared adapter for an agent in the open project; a changed command gets a process of its own.
    func agentHost(_ kind: AgentKind, root: URL) -> AgentHost {
        let key = "\(kind.rawValue)\n\(root.path)\n\(agentCommand(kind))"
        if let host = agentHosts[key] { return host }
        let host = AgentHost(agent: kind, root: root)
        agentHosts[key] = host
        return host
    }

    func makeAgentSession(_ kind: AgentKind, root: URL) -> AgentSession {
        AgentSession(agent: kind, root: root, gitDir: aiGitDir, host: agentHost(kind, root: root))
    }

    /// A new conversation in its own tab. An untouched one on screen (or a transcript restored from disk) is replaced
    /// rather than kept beside it.
    func newAgentSession(_ agent: AgentKind? = nil) {
        guard let root = repositoryURL else { return }
        let kind = agent ?? agentSession?.agent ?? AgentKind(rawValue: aiSettings.defaultAgent) ?? .claude
        if aiSettings.defaultAgent != kind.rawValue { aiSettings.defaultAgent = kind.rawValue }
        let session = makeAgentSession(kind, root: root)
        wire(session)
        show(session, replacingSpare: true)
    }

    /// Puts a conversation on screen in a tab next to the current one, or in its place when that one is spare.
    func show(_ session: AgentSession, replacingSpare: Bool) {
        if replacingSpare, let current = agentSession, current.isSpare, let index = agentSessions.firstIndex(where: { $0 === current }) {
            current.close()
            agentSessions[index] = session
        } else if let current = agentSession, let index = agentSessions.firstIndex(where: { $0 === current }) {
            agentSessions.insert(session, at: index + 1)
        } else {
            agentSessions.append(session)
        }
        selectAgentSession(session)
    }

    func selectAgentSession(_ session: AgentSession) {
        agentSession = session
        session.unseen = false
    }

    /// Closing a tab ends the conversation here; it stays in the adapter's list. A busy one cannot be closed.
    func closeAgentSession(_ session: AgentSession) {
        guard !session.isBusy, let index = agentSessions.firstIndex(where: { $0 === session }) else { return }
        session.close()
        agentSessions.remove(at: index)
        if agentSession === session {
            if agentSessions.isEmpty, let root = repositoryURL {
                let fresh = makeAgentSession(session.agent, root: root)
                wire(fresh)
                agentSessions = [fresh]
            }
            selectAgentSession(agentSessions[min(index, agentSessions.count - 1)])
        }
    }

    func wire(_ session: AgentSession) {
        session.onTurnEnded = { [weak self, weak session] in
            self?.refreshInBackground()
            if let session { self?.agentNeedsYou(session, permission: false) }
        }
        session.onPermission = { [weak self, weak session] in
            if let session { self?.agentNeedsYou(session, permission: true) }
        }
    }

    /// Whether the user is looking at this conversation right now.
    func isShowing(_ session: AgentSession) -> Bool {
        agentSession === session && aiTabSelected && showTerminal && (NSApp?.isActive ?? true)
    }

    /// A conversation off screen finished a turn or asks for a permission: its tab and the AI tab get a dot, and a
    /// permission also gets a system notification while Folmi is in the background (finished turns that changed files
    /// already get one from the hooks).
    func agentNeedsYou(_ session: AgentSession, permission: Bool) {
        guard !isShowing(session) else { return }
        session.unseen = true
        if permission, !(NSApp?.isActive ?? true), let root = repositoryURL {
            AINotifier.shared.post(title: "\(session.agent.title) 等你允许 · \(repositoryTitle)",
                                   body: "「\(session.displayTitle)」：\(session.transcript.entries.last { $0.kind == .permission }?.text ?? "")",
                                   project: root.path, opensAgent: true)
        }
    }

    /// The AI tab's dot: a conversation not on screen has something new.
    var agentTabNeedsYou: Bool { agentSessions.contains { $0.unseen } }

    func connectAgent() {
        ensureAgentSession()
        if let session = agentSession, session.restored { newAgentSession(session.agent) }
        guard let session = agentSession else { return }
        session.start(command: agentCommand(session.agent))
    }

    func sendToAgent() {
        ensureAgentSession()
        guard let session = agentSession, !session.isReadOnly, !session.isBusy else { return }
        if session.restored { newAgentSession(session.agent) }
        guard let live = agentSession else { return }
        let text = agentDraft, context = agentContext
        if let finding = SecretScan.findings(in: text + context.map(\.text).joined()).first {
            preferencesStatus = "内容疑似含密钥（\(finding)），没有发给 agent"; NSSound.beep(); return
        }
        if !live.warnedSharedWorkTree, let other = agentSessions.first(where: { $0 !== live && $0.root == live.root && $0.state == .running }) {
            live.warnedSharedWorkTree = true
            live.notice("「\(other.displayTitle)」也在改这个工作区，两边的改动会混在一起：按轮次还分得开，但可能互相覆盖。")
        }
        live.send(text, context: context, command: agentCommand(live.agent))
        agentDraft = ""; agentContext = []
    }

    /// "交给 agent" from the small AI card or ⌘K: the request and its context go into the AI tab's composer.
    func handAssistToAgent() {
        guard let state = aiAssist else { return }
        let question = state.mode == .ask ? (state.turns.last?.question ?? "") : state.mode.title
        if !state.input.isEmpty { agentContext.append(AgentContext(title: state.source, text: String(state.input.prefix(20_000)))) }
        if !question.isEmpty { agentDraft = agentDraft.isEmpty ? question : agentDraft + "\n" + question }
        closeAssist()
        focusAgentComposer()
    }

    func askAgent(_ text: String) {
        agentDraft = text
        openAgentTab()
    }
}

/// One conversation's tab: a hollow dot when idle, a spinner while it works, orange when it waits for a permission,
/// red after an error, accent when something happened while it was off screen.
struct AgentSessionTab: View {
    let session: AgentSession
    let selected: Bool
    let showsAgent: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            indicator.frame(width: 10, height: 10)
            Text((showsAgent ? session.agent.title + " · " : "") + session.displayTitle)
                .themedFont(.caption, points: 11).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).disabled(session.isBusy)
                .help(session.isBusy ? "正在工作，等它做完或先停止再关" : "关掉这个标签（会话还在「会话」列表里）")
                .accessibilityLabel("关掉标签")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .themedBackground(selected ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help("\(session.agent.title) · \(session.displayTitle)\(status)")
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var status: String {
        if session.needsPermission { return " · 等你允许" }
        if session.isBusy { return " · 正在工作" }
        if case .failed = session.state { return " · 出错了" }
        return session.unseen ? " · 有新动静" : ""
    }

    @ViewBuilder private var indicator: some View {
        if session.needsPermission {
            Circle().fill(ThemeColor(token: .modified)).frame(width: 7, height: 7)
        } else if session.isBusy {
            ProgressView().controlSize(.mini).scaleEffect(0.6)
        } else if case .failed = session.state {
            Circle().fill(ThemeColor(token: .removed)).frame(width: 7, height: 7)
        } else if session.unseen {
            Circle().fill(ThemeColor(token: .accent)).frame(width: 7, height: 7)
        } else {
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 7, height: 7)
        }
    }
}

/// The AI tab of the terminal card: the conversations with Claude or Codex.
struct AgentPane: View {
    @Bindable var model: FolmiModel
    @FocusState private var composing: Bool
    @State private var availability: [AgentKind: AgentAvailability]?
    @State private var availabilityRevision = 0
    @State private var checking = false
    /// Said under the issues after a manual re-check, so pressing it visibly did something.
    @State private var checkNote: String?
    @State private var sessionList = AgentSessionList()
    @State private var showingSessions = false

    private struct SessionListRequest: Equatable {
        var root: URL?
        var agent: AgentKind?
        var command: String
        var shown: Bool
    }

    private struct AvailabilityRequest: Equatable {
        var root: URL?
        var commands: [String: String]
        var revision: Int
    }

    private var availableAgents: [AgentKind] {
        AgentKind.allCases.filter { availability?[$0]?.isAvailable == true }
    }

    private var canSend: Bool {
        guard let session = model.agentSession, !session.isReadOnly else { return false }
        if session.state == .ready || session.isBusy { return true }
        return availability?[session.agent]?.isAvailable == true
    }

    var body: some View {
        let _ = PerfLog.body("AgentPane")
        GeometryReader { geometry in
            VStack(spacing: 0) {
                tabs
                Divider()
                header(width: geometry.size.width)
                Divider()
                HStack(spacing: 0) {
                    if showingSessions, geometry.size.width >= 520 {
                        sessionListView.frame(width: 220)
                        Divider()
                    }
                    conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { model.ensureAgentSession(); model.agentSession?.unseen = false; composing = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.aiTabSelected { model.agentSession?.unseen = false }
        }
        .onChange(of: model.agentComposerFocus) { composing = true }
        .task(id: SessionListRequest(root: model.repositoryURL, agent: model.agentSession?.agent,
                                     command: model.agentSession.map { model.agentCommand($0.agent) } ?? "", shown: showingSessions)) {
            // Listing starts an adapter process when none is connected: only when the list is actually open.
            guard showingSessions, let session = model.agentSession else { return }
            await sessionList.refresh(session: session, command: model.agentCommand(session.agent))
        }
        .task(id: AvailabilityRequest(root: model.repositoryURL, commands: model.aiSettings.agentCommands, revision: availabilityRevision)) {
            guard let root = model.repositoryURL else { availability = nil; return }
            checking = true
            defer { checking = false }
            let manual = availabilityRevision > 0
            let result = await AgentAvailability.detect(commands: model.aiSettings.agentCommands, root: root)
            guard !Task.isCancelled else { return }
            if manual { checkNote = result == availability ? "已重新检测，结果没变" : "已重新检测" }
            availability = result
            if let session = model.agentSession, session.state == .idle, session.transcript.entries.isEmpty,
               result[session.agent]?.isAvailable != true,
               let first = AgentKind.allCases.first(where: { result[$0]?.isAvailable == true }) {
                model.newAgentSession(first)
            }
        }
        .onChange(of: model.showAISettings) { _, shown in if !shown { availabilityRevision += 1 } }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if let session = model.agentSession, let current = session.currentModelID {
                HStack(spacing: 8) {
                    if !session.availableModels.isEmpty {
                        Picker("模型", selection: Binding(get: { session.currentModelID ?? current }, set: { session.selectModel($0) })) {
                            if !session.availableModels.contains(where: { $0.id == current }) {
                                Text("\(current)（当前配置）").tag(current)
                            }
                            ForEach(session.availableModels) { Text($0.name).tag($0.id) }
                        }
                        .disabled(session.isBusy || !session.isConnected || session.isReadOnly)
                        .help("只修改当前会话；选项由 agent 返回，可用性由实际请求确认")
                    } else {
                        Text("模型：\(current)")
                    }
                    if session.isSelectingModel { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                }
                .themedFont(.caption, points: 10).padding(.horizontal, 10).padding(.vertical, 5)
                Divider()
            }
            if let availability {
                let issues = AgentKind.allCases.compactMap { kind in
                    availability[kind]?.issue.map { "\(kind.title)：\($0)" }
                }
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(availableAgents.isEmpty ? "没有可启动的 agent" : "部分 agent 暂不可启动")
                            .themedFont(.caption.weight(.medium), points: 11)
                        ForEach(issues, id: \.self) { Text($0).themedFont(.caption, points: 10).fixedSize(horizontal: false, vertical: true) }
                        HStack {
                            Button("AI 设置") { model.showAISettings = true }
                            Button(checking ? "检测中…" : "重新检测") { checkNote = nil; availabilityRevision += 1 }
                                .disabled(checking)
                            if let checkNote { Text(checkNote).themedFont(.caption, points: 10).foregroundStyle(.secondary) }
                        }.controlSize(.small)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ThemeColor(token: .modified, opacity: 0.08))
                }
            }
            if let session = model.agentSession, !(model.theme.style.companion && session.transcript.entries.isEmpty) {
                AgentTranscriptView(model: model, session: session)
                    .overlay(alignment: .bottomTrailing) {
                        if model.theme.style.companion, session.isBusy {
                            CompanionMark(state: .working, size: 40).padding(10).transition(.opacity)
                        }
                    }
            } else if model.theme.style.companion {
                // 琥珀: an empty conversation is Folmi waiting, not a blank page.
                VStack(spacing: 8) {
                    CompanionMark(state: .idle, size: 56)
                    Text("有事就在这里问我").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            Divider()
            if let session = model.agentSession, session.isReadOnly {
                HStack(spacing: 8) {
                    Text("只读：这是 Codex 里的会话记录，在这里不能接着发消息。要接着聊，在终端里用 Codex 打开它。")
                        .themedFont(.caption, points: 11).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if session.agent == .codex, let id = session.sessionID {
                        Button("在终端里接着聊") { model.resumeInTerminal(id) }
                            .controlSize(.small)
                            .help("把 codex resume 命令放进终端，不会按回车；如果它还在 Codex App 里开着，先关掉那边")
                    }
                }
                .padding(10)
            } else {
                composer
            }
        }
    }

    private var sessionListView: some View {
        AgentSessionListView(model: model, list: sessionList, onOpen: { showingSessions = false })
    }

    private func header(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button("会话") { showingSessions.toggle() }
                .controlSize(.small)
                .disabled((model.agentSession?.supportsSessionList ?? sessionList.supportsList) == false)
                .help((model.agentSession?.supportsSessionList ?? sessionList.supportsList) == false
                      ? "这个 agent 不支持列出会话" : "列出这个项目的会话")
                .popover(isPresented: Binding(get: { showingSessions && width < 520 }, set: { if !$0 { showingSessions = false } }), arrowEdge: .bottom) {
                    sessionListView.frame(width: 280, height: 380)
                }
            // The agent is chosen for a conversation that has not started; afterwards a new tab is the way to switch.
            if !availableAgents.isEmpty, model.agentSession?.isSpare ?? true {
                Picker("", selection: Binding<AgentKind?>(get: {
                    guard let kind = model.agentSession?.agent, availableAgents.contains(kind) else { return nil }
                    return kind
                }, set: { if let kind = $0 { model.newAgentSession(kind) } })) {
                    if let current = model.agentSession?.agent, !availableAgents.contains(current) {
                        Text("选择 agent").tag(AgentKind?.none)
                    }
                    ForEach(availableAgents) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).frame(width: 150).labelsHidden()
                .disabled(model.agentSession?.isBusy == true)
                .help("可启动 ACP 适配器；发送时确认登录。会话开始后要换 agent，就开一个新标签")
            }
            Text(statusText).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.agentSession?.state == .running {
                Button("停止") { model.agentSession?.cancel() }.controlSize(.small).keyboardShortcut(".", modifiers: .command)
            }
            if model.agentSession?.isConnected != true {
                let starting = model.agentSession?.state == .starting && model.agentSession?.transcript.entries.isEmpty == true
                Button(action: model.connectAgent) { WaitingLabel(title: starting ? "正在连接…" : "连接", waiting: starting) }
                    .controlSize(.small).disabled(!canSend || model.agentSession?.isBusy == true)
                    .help("先连接并查看模型，再发送第一条消息")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// One tab per conversation, with its state; + opens another next to the current one.
    private var tabs: some View {
        let mixed = Set(model.agentSessions.map(\.agent)).count > 1
        return HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.agentSessions) { session in
                        AgentSessionTab(session: session, selected: session === model.agentSession, showsAgent: mixed,
                                        select: { model.selectAgentSession(session); composing = true },
                                        close: { model.closeAgentSession(session) })
                    }
                }
            }
            if availableAgents.count > 1 {
                Menu {
                    ForEach(availableAgents) { kind in Button("新建 \(kind.title) 会话") { model.newAgentSession(kind); composing = true } }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("新建会话，放在当前标签旁边")
            } else {
                Button { model.newAgentSession(availableAgents.first); composing = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).disabled(availableAgents.isEmpty)
                    .help("新建会话，放在当前标签旁边")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var statusText: String {
        if availability == nil { return "正在检测本机 ACP 适配器…" }
        guard let session = model.agentSession else { return "" }
        if session.restored { return "上次的会话 · 发消息会开新会话" }
        if session.isReadOnly, session.state == .ready { return "只读查看" }
        if session.isSelectingModel { return "正在切换模型…" }
        switch session.state {
        case .idle: return "可先连接选择模型，或直接发送消息"
        case .starting: return "正在启动 \(session.agent.title)…（第一次要下载适配器）"
        case .ready: return "\(session.agent.title) 就绪"
        case .running: return "\(session.agent.title) 正在工作…"
        case .failed: return "出错了，可以再发一次"
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.agentContext.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.agentContext) { item in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip").font(.caption2)
                                Text(item.title).themedFont(.caption, points: 10).lineLimit(1)
                                Button { model.agentContext.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.plain).accessibilityLabel("移除附件")
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .themedCapsule(ThemeColor(token: .accent, opacity: 0.1))
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if model.agentDraft.isEmpty {
                        Text("让 \(model.agentSession?.agent.title ?? "agent") 做点什么…  ⌘⏎ 发送").themedFont(.callout, points: 12)
                            .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
                    }
                    TextEditor(text: $model.agentDraft)
                        .themedFont(.system(size: 12), points: 12).scrollContentBackground(.hidden)
                        .focused($composing).frame(minHeight: 36, maxHeight: 110).fixedSize(horizontal: false, vertical: true)
                }
                Button("发送", action: model.sendToAgent)
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.folmiProminent)
                    .disabled(!canSend || model.agentSession?.isBusy == true || (model.agentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.agentContext.isEmpty))
            }
        }
        .padding(10)
    }
}

struct AgentTranscriptView: View {
    let model: FolmiModel
    let session: AgentSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.transcript.entries.isEmpty {
                        Text("这里就是和 \(session.agent.title) 的对话：它改的文件会照常出现在改动列表里，收不收下仍由你决定。它能通过 MCP 读到你的审阅评论。")
                            .themedFont(.callout, points: 12).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    ForEach(session.transcript.entries) { entry in
                        AgentEntryRow(model: model, session: session, entry: entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: session.transcript.entries.last?.text.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.transcript.entries.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct AgentEntryRow: View {
    let model: FolmiModel
    let session: AgentSession
    let entry: ACPTranscript.Entry

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text).themedFont(.callout, points: 12).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(ThemeColor(token: .accent, opacity: 0.08), in: RoundedRectangle(cornerRadius: 6))
        case .agent:
            Text((try? AttributedString(markdown: entry.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(entry.text))
                .themedFont(.callout, points: 12).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            Text(entry.text).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(3).help(entry.text)
        case .plan:
            Text(entry.text).themedFont(.caption.monospaced(), points: 10).foregroundStyle(.secondary)
        case .notice:
            Label(entry.text, systemImage: "info.circle").themedFont(.caption, points: 10).foregroundStyle(.themed(.modified))
                .fixedSize(horizontal: false, vertical: true)
        case .tool:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary).font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).themedFont(.caption, points: 10).lineLimit(2)
                    paths
                }
            }
        case .permission:
            VStack(alignment: .leading, spacing: 6) {
                Label(entry.text, systemImage: "hand.raised").themedFont(.callout.weight(.medium), points: 12)
                paths
                if let status = entry.status {
                    Text("已选：\(status)").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(entry.options, id: \.id) { option in
                            if option.kind == "allow_once" {
                                Button(option.name) { session.choose(entry.id, option: option) }.buttonStyle(.folmiProminent)
                            } else {
                                Button(option.name) { session.choose(entry.id, option: option) }
                            }
                        }
                    }.controlSize(.small)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor(token: .modified, opacity: 0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var icon: String {
        switch entry.status {
        case "completed": return "checkmark.circle"
        case "failed": return "xmark.circle"
        case "in_progress": return "circle.dotted"
        default: return entry.toolKind == "edit" ? "pencil" : entry.toolKind == "execute" ? "terminal" : "circle"
        }
    }

    @ViewBuilder private var paths: some View {
        if !entry.paths.isEmpty {
            HStack(spacing: 6) {
                ForEach(entry.paths.prefix(4), id: \.self) { path in
                    let relative = path.hasPrefix(session.root.path + "/") ? String(path.dropFirst(session.root.path.count + 1)) : path
                    Button(relative) { model.revealLinked(path: relative, line: nil) }
                        .buttonStyle(.themedLink).themedFont(.caption2.monospaced(), points: 10).lineLimit(1)
                }
            }
        }
    }
}
