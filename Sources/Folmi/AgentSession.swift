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
}

/// One conversation with an agent in one project: the adapter process, the ACP session and what it showed.
@MainActor
@Observable
final class AgentSession {
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

    @ObservationIgnored private var connection: ACPConnection?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var modelConfigID: String?
    @ObservationIgnored private var permissions: [String: CheckedContinuation<String?, Never>] = [:]
    /// Called when a turn ends, so the change list catches up with what the agent wrote.
    @ObservationIgnored var onTurnEnded: (() -> Void)?

    init(agent: AgentKind, root: URL, gitDir: URL?, started: Date = Date()) {
        self.agent = agent; self.root = root; self.gitDir = gitDir; self.started = started
    }

    var isBusy: Bool { state == .starting || state == .running || isSelectingModel }
    var isConnected: Bool { connection?.isRunning == true && sessionID != nil }

    // MARK: Sending

    /// Connect without sending a prompt, so the adapter's current model can be inspected and changed first.
    func start(command: String) {
        guard !isBusy, !isConnected else { return }
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
        guard isConnected, !isBusy, id != currentModelID,
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
        guard !message.isEmpty || !context.isEmpty, !isBusy else { return }
        let shown = (context.isEmpty ? "" : context.map { "〔\($0.title)〕" }.joined(separator: " ") + "\n") + message
        transcript.append(.init(id: "user-\(transcript.entries.count)", kind: .user, text: shown))
        let prompt = context.map { "\($0.title)：\n```\n\($0.text)\n```" }.joined(separator: "\n\n") + (context.isEmpty ? "" : "\n\n") + message
        state = isConnected ? .running : .starting
        Task { await run(prompt, command: command) }
    }

    private func run(_ prompt: String, command: String) async {
        do {
            if connection?.isRunning != true || sessionID == nil {
                state = .starting
                try await connect(command)
            }
            guard let connection, let sessionID else { return }
            state = .running
            let result = try await connection.request("session/prompt", .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
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

    /// Starts the adapter, says hello, opens a session in the project (with the Folmi MCP server attached).
    private func connect(_ command: String) async throws {
        connection?.close()
        sessionID = nil; currentModelID = nil; availableModels = []; modelConfigID = nil
        let words = Self.words(command), root = self.root
        let availability = await Task.detached { AgentAvailability.check(command: command, root: root) }.value
        guard let executable = availability.executable, availability.isAvailable else {
            throw ACPError(code: -1, message: availability.issue ?? "agent 无法启动：请检查 AI 设置。")
        }
        let session = ACPConnection.self
        let connection = try session.launch(
            executable: URL(fileURLWithPath: executable), arguments: Array(words.dropFirst()), directory: root,
            environment: LocalCLI.environment(for: executable),
            requests: { [weak self] method, params in
                guard let self else { return .failure(ACPError(code: -32603, message: "会话已关闭")) }
                return await self.answer(method, params)
            },
            notifications: { [weak self] method, params in
                guard method == "session/update", let update = params["update"] else { return }
                // FIFO onto the main thread: chunks must arrive in order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.transcript.apply(update)
                        if update["sessionUpdate"]?.string == "config_option_update" { self?.applyModelConfiguration(update) }
                    }
                }
            })
        connection.onClose = { [weak self] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.connection === connection else { return }
                    self.sessionID = nil
                    if self.state == .ready { self.state = .idle }
                    if !reason.isEmpty, self.state != .running { self.note("agent 进程退出了：\(reason.suffix(200))") }
                }
            }
        }
        self.connection = connection
        _ = try await connection.request("initialize", .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false)]),
            "clientInfo": .object(["name": .string("folmi"), "title": .string("Folmi"), "version": .string("1")]),
        ]))
        var servers: [JSON] = []
        if FileManager.default.isExecutableFile(atPath: MCPInstaller.helper.path) {
            servers.append(.object(["name": .string(MCPServer.name), "command": .string(MCPInstaller.helper.path),
                                    "args": .array([.string("mcp")]), "env": .array([])]))
        }
        let created = try await connection.request("session/new", .object(["cwd": .string(root.path), "mcpServers": .array(servers)]))
        guard let id = created["sessionId"]?.string else { throw ACPError(code: -1, message: "agent 没有返回会话。") }
        sessionID = id
        applyModelConfiguration(created)
        restored = false
        state = .ready
    }

    /// Requests from the agent. Permissions wait for the user; file access is not offered (the agent edits the
    /// work tree itself, and the change list shows what it did).
    private func answer(_ method: String, _ params: JSON) async -> Result<JSON, ACPError> {
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
        connection?.close(); connection = nil; sessionID = nil
        currentModelID = nil; availableModels = []; modelConfigID = nil
        if isBusy { state = .idle }
    }

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
    private struct Saved: Codable { var agent: AgentKind; var started: Date; var transcript: ACPTranscript }

    func save() {
        guard let gitDir, !transcript.entries.isEmpty else { return }
        let url = Self.folder(gitDir: gitDir).appendingPathComponent("\(agent.rawValue)-\(Int(started.timeIntervalSince1970)).json")
        AppLog.attempt("保存 agent 会话") { try FolmiShared.write(Saved(agent: agent, started: started, transcript: transcript), to: url) }
    }

    /// The newest saved conversation in the project, shown read-only until the next message.
    static func latest(root: URL, gitDir: URL?) -> AgentSession? {
        guard let gitDir, let files = try? FileManager.default.contentsOfDirectory(at: folder(gitDir: gitDir), includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "json" }.max { a, b in
            ((try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        guard let newest, let saved = FolmiShared.read(Saved.self, from: newest) else { return nil }
        let session = AgentSession(agent: saved.agent, root: root, gitDir: gitDir, started: saved.started)
        session.transcript = saved.transcript
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
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        ensureAgentSession()
    }

    func ensureAgentSession() {
        guard let root = repositoryURL else { return }
        if let session = agentSession, session.root == root { return }
        agentSession?.close()
        let session = AgentSession.latest(root: root, gitDir: aiGitDir)
            ?? AgentSession(agent: AgentKind(rawValue: aiSettings.defaultAgent) ?? .claude, root: root, gitDir: aiGitDir)
        wire(session)
        agentSession = session
    }

    func newAgentSession(_ agent: AgentKind? = nil) {
        guard let root = repositoryURL else { return }
        agentSession?.close()
        let kind = agent ?? agentSession?.agent ?? AgentKind(rawValue: aiSettings.defaultAgent) ?? .claude
        if aiSettings.defaultAgent != kind.rawValue { aiSettings.defaultAgent = kind.rawValue }
        let session = AgentSession(agent: kind, root: root, gitDir: aiGitDir)
        wire(session)
        agentSession = session
    }

    private func wire(_ session: AgentSession) {
        session.onTurnEnded = { [weak self] in self?.refreshInBackground() }
    }

    func connectAgent() {
        ensureAgentSession()
        if let session = agentSession, session.restored { newAgentSession(session.agent) }
        guard let session = agentSession else { return }
        session.start(command: agentCommand(session.agent))
    }

    func sendToAgent() {
        ensureAgentSession()
        guard let session = agentSession else { return }
        if session.restored { newAgentSession(session.agent) }
        guard let live = agentSession else { return }
        let text = agentDraft, context = agentContext
        if let finding = SecretScan.findings(in: text + context.map(\.text).joined()).first {
            preferencesStatus = "内容疑似含密钥（\(finding)），没有发给 agent"; NSSound.beep(); return
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
        openAgentTab()
    }

    func askAgent(_ text: String) {
        agentDraft = text
        openAgentTab()
    }
}

/// The AI tab of the terminal card: the conversation with Claude or Codex.
struct AgentPane: View {
    @Bindable var model: FolmiModel
    @FocusState private var composing: Bool
    @State private var availability: [AgentKind: AgentAvailability]?
    @State private var availabilityRevision = 0
    @State private var checking = false
    /// Said under the issues after a manual re-check, so pressing it visibly did something.
    @State private var checkNote: String?

    private struct AvailabilityRequest: Equatable {
        var root: URL?
        var commands: [String: String]
        var revision: Int
    }

    private var availableAgents: [AgentKind] {
        AgentKind.allCases.filter { availability?[$0]?.isAvailable == true }
    }

    private var canSend: Bool {
        guard let session = model.agentSession else { return false }
        if session.state == .ready || session.isBusy { return true }
        return availability?[session.agent]?.isAvailable == true
    }

    var body: some View {
        let _ = PerfLog.body("AgentPane")
        VStack(spacing: 0) {
            header
            Divider()
            if let session = model.agentSession, let current = session.currentModelID {
                HStack(spacing: 8) {
                    if !session.availableModels.isEmpty {
                        Picker("模型", selection: Binding(get: { session.currentModelID ?? current }, set: { session.selectModel($0) })) {
                            if !session.availableModels.contains(where: { $0.id == current }) {
                                Text("\(current)（当前配置）").tag(current)
                            }
                            ForEach(session.availableModels) { Text($0.name).tag($0.id) }
                        }
                        .disabled(session.isBusy || !session.isConnected)
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
            composer
        }
        .onAppear { model.ensureAgentSession(); composing = true }
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

    private var header: some View {
        HStack(spacing: 8) {
            if !availableAgents.isEmpty {
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
                .help("可启动 ACP 适配器；发送时确认登录。换 agent 会开一个新会话")
            }
            Text(statusText).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.agentSession?.state == .running {
                Button("停止") { model.agentSession?.cancel() }.controlSize(.small).keyboardShortcut(".", modifiers: .command)
            }
            if model.agentSession?.isConnected != true {
                Button("连接", action: model.connectAgent)
                    .controlSize(.small).disabled(!canSend || model.agentSession?.isBusy == true)
                    .help("先连接并查看模型，再发送第一条消息")
            }
            Button("新会话") { model.newAgentSession(canSend ? nil : availableAgents.first) }
                .controlSize(.small).disabled(model.agentSession?.isBusy == true || availableAgents.isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var statusText: String {
        if availability == nil { return "正在检测本机 ACP 适配器…" }
        guard let session = model.agentSession else { return "" }
        if session.restored { return "上次的会话 · 发消息会开新会话" }
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
