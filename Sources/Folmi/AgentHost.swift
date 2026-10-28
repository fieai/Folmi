import AppKit
import Foundation
import FolmiCore

/// One adapter process per agent and project, shared by every conversation open in it: ACP runs many sessions over
/// one connection, and each codex-acp process carries its own Node and Codex runtime. Messages from the adapter are
/// routed to the conversation they name by `sessionId`.
@MainActor
@Observable
final class AgentHost {
    let agent: AgentKind
    let root: URL
    @ObservationIgnored private(set) var connection: ACPConnection?
    /// Bumped on each launch: a session id from an earlier process means nothing to the new one.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private(set) var embeddedContext = false
    private(set) var supportsList: Bool?
    private(set) var supportsLoad: Bool?
    @ObservationIgnored private(set) var supportsClose = false

    @ObservationIgnored private var launching: Task<ACPConnection, Error>?
    @ObservationIgnored private var sessions: [String: Weak] = [:]
    private struct Weak { weak var session: AgentSession? }

    init(agent: AgentKind, root: URL) {
        self.agent = agent; self.root = root
    }

    var isRunning: Bool { connection?.isRunning == true }

    /// The running adapter, launched and greeted on first use. Callers arriving during a launch share it.
    func connect(_ command: String) async throws -> ACPConnection {
        if let connection, connection.isRunning { return connection }
        if let launching { return try await launching.value }
        let task = Task { try await launch(command) }
        launching = task
        do {
            let connection = try await task.value
            launching = nil
            return connection
        } catch {
            launching = nil
            throw error
        }
    }

    private func launch(_ command: String) async throws -> ACPConnection {
        connection?.close()
        let words = AgentSession.words(command), root = self.root
        let availability = await Task.detached { AgentAvailability.check(command: command, root: root) }.value
        guard let executable = availability.executable, availability.isAvailable else {
            throw ACPError(code: -1, message: availability.issue ?? "agent 无法启动：请检查 AI 设置。")
        }
        generation += 1
        let generation = self.generation
        let connection = try ACPConnection.launch(
            executable: URL(fileURLWithPath: executable), arguments: Array(words.dropFirst()), directory: root,
            environment: LocalCLI.environment(for: executable),
            requests: { [weak self] method, params in
                guard let id = params["sessionId"]?.string,
                      let session = await MainActor.run(body: { self?.session(id, generation: generation) }) else {
                    return .failure(ACPError(code: -32603, message: "会话已关闭"))
                }
                return await session.answer(method, params)
            },
            notifications: { [weak self] method, params in
                guard method == "session/update", let id = params["sessionId"]?.string, let update = params["update"] else { return }
                // FIFO onto the main thread: chunks must arrive in order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.session(id, generation: generation)?.receive(update) }
                }
            })
        connection.onClose = { [weak self] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.connection === connection else { return }
                    for session in self.sessions.values.compactMap(\.session) { session.connectionLost(reason) }
                    self.sessions = [:]
                }
            }
        }
        self.connection = connection
        do {
            let hello = try await connection.request("initialize", AgentSession.initializeParams)
            let capabilities = hello["agentCapabilities"]
            embeddedContext = capabilities?["promptCapabilities"]?["embeddedContext"]?.bool ?? false
            supportsList = capabilities?["sessionCapabilities"]?["list"] != nil
            supportsLoad = capabilities?["loadSession"]?.bool ?? false
            supportsClose = capabilities?["sessionCapabilities"]?["close"] != nil
        } catch {
            connection.close()
            if self.connection === connection { self.connection = nil }
            throw error
        }
        return connection
    }

    private func session(_ id: String, generation: Int) -> AgentSession? {
        guard generation == self.generation else { return nil }
        return sessions[id]?.session
    }

    /// Before `session/load` too, so the history it replays reaches the conversation.
    func register(_ session: AgentSession, id: String) {
        sessions[id] = Weak(session: session)
    }

    /// The conversation is no longer shown here; the adapter may free it (best effort, the reply is not awaited).
    func unregister(id: String) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        if supportsClose, let connection, connection.isRunning {
            Task { _ = try? await connection.request("session/close", .object(["sessionId": .string(id)])) }
        }
    }

    func close() {
        launching?.cancel(); launching = nil
        sessions = [:]
        connection?.close(); connection = nil
    }
}
