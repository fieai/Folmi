import Foundation

/// A JSON value that can cross threads: ACP messages are free-form objects.
public enum JSON: Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    public init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let value as NSNumber: self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map { JSON($0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSON($0) })
        default: self = .null
        }
    }
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }
    public subscript(key: String) -> JSON? { if case .object(let object) = self { return object[key] } else { return nil } }
    public var string: String? { if case .string(let value) = self { return value } else { return nil } }
    public var array: [JSON]? { if case .array(let value) = self { return value } else { return nil } }
    public var int: Int? { if case .number(let value) = self { return Int(value) } else { return nil } }
    public var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public static func parse(_ data: Data) -> JSON? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).map { JSON($0) }
    }
    public func data() -> Data { (try? JSONSerialization.data(withJSONObject: any, options: [.withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("null".utf8) }
}

public struct ACPError: Error, LocalizedError, Sendable, Equatable {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// The client end of the Agent Client Protocol: JSON-RPC 2.0, one message per line, over an agent process's
/// stdin / stdout. Requests from the agent (permission, file reads) go to `handleRequest`; `session/update`
/// notifications go to `handleNotification`. Both callbacks run on the connection's reading thread.
public final class ACPConnection: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSON) async -> Result<JSON, ACPError>
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSON) -> Void

    private let input: FileHandle
    private let output: FileHandle
    private let process: Process?
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var closed = false
    private var errorTail = Data()
    private let handleRequest: RequestHandler
    private let handleNotification: NotificationHandler
    /// Called once when the agent's output ends (it quit or crashed), with the last of its stderr.
    public var onClose: (@Sendable (String) -> Void)?

    /// Over existing handles (tests, or a process started elsewhere). `input` is what the agent writes.
    public init(reading input: FileHandle, writing output: FileHandle, process: Process? = nil,
                requests: @escaping RequestHandler, notifications: @escaping NotificationHandler) {
        self.input = input; self.output = output; self.process = process
        self.handleRequest = requests; self.handleNotification = notifications
    }

    /// Starts `executable arguments…` in `directory` and connects to it.
    public static func launch(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                              requests: @escaping RequestHandler, notifications: @escaping NotificationHandler) throws -> ACPConnection {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let connection = ACPConnection(reading: stdout.fileHandleForReading, writing: stdin.fileHandleForWriting, process: process,
                                       requests: requests, notifications: notifications)
        stderr.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let data = handle.availableData
            guard let connection, !data.isEmpty else { handle.readabilityHandler = nil; return }
            connection.lock.lock()
            connection.errorTail.append(data)
            if connection.errorTail.count > 4_000 { connection.errorTail = connection.errorTail.suffix(4_000) }
            connection.lock.unlock()
        }
        try process.run()
        connection.start()
        return connection
    }

    /// Begins reading the agent's messages on a background thread.
    public func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "acp-read"
        thread.start()
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

    public func request(_ method: String, _ params: JSON) async throws -> JSON {
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            let id = nextID; nextID += 1; return id
        }()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: ACPError(code: -32000, message: "agent 已经退出：\(stderrTail)")); return
            }
            waiting[id] = continuation
            lock.unlock()
            send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
        }
    }

    public func notify(_ method: String, _ params: JSON) {
        send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    /// Ends the agent process (and fails anything still waiting).
    public func close() {
        process?.terminate()
        try? output.close()
        finish()
    }

    public var stderrTail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errorTail.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ message: JSON) {
        var data = message.data()
        data.append(10)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        do { try output.write(contentsOf: data) } catch { closed = true }
    }

    private func readLoop() {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty, let message = JSON.parse(Data(line)) { dispatch(message) }
            }
        }
        finish()
    }

    private func finish() {
        lock.lock()
        let pending = waiting; waiting = [:]
        let wasClosed = closed; closed = true
        lock.unlock()
        let reason = stderrTail
        for continuation in pending.values { continuation.resume(throwing: ACPError(code: -32000, message: reason.isEmpty ? "agent 已经退出" : "agent 已经退出：\(reason)")) }
        if !wasClosed || !pending.isEmpty { onClose?(reason) }
    }

    private func dispatch(_ message: JSON) {
        let method = message["method"]?.string
        if let method, let id = message["id"] {
            // A request from the agent: answered when the handler is done (a permission waits for the user).
            let params = message["params"] ?? .null
            Task { [self] in
                let result = await handleRequest(method, params)
                switch result {
                case .success(let value):
                    send(.object(["jsonrpc": .string("2.0"), "id": id, "result": value]))
                case .failure(let error):
                    send(.object(["jsonrpc": .string("2.0"), "id": id,
                                  "error": .object(["code": .number(Double(error.code)), "message": .string(error.message)])]))
                }
            }
        } else if let method {
            handleNotification(method, message["params"] ?? .null)
        } else if let id = message["id"]?.int {
            lock.lock()
            let continuation = waiting.removeValue(forKey: id)
            lock.unlock()
            if let error = message["error"] {
                continuation?.resume(throwing: ACPError(code: error["code"]?.int ?? -32000, message: error["message"]?.string ?? "agent 返回错误"))
            } else {
                continuation?.resume(returning: message["result"] ?? .null)
            }
        }
    }
}

/// What a session shows, rebuilt from the agent's `session/update` notifications. Pure, so it can be tested and
/// saved; the app keeps one per conversation.
public struct ACPTranscript: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, agent, thought, tool, plan, permission, notice }
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: Kind
        public var text: String
        /// Tool calls: pending / in_progress / completed / failed. Permissions: the chosen option's name once answered.
        public var status: String?
        /// Tool calls: read / edit / delete / move / search / execute / think / fetch / other.
        public var toolKind: String?
        /// Files a tool call touched or a permission is about.
        public var paths: [String] = []
        /// Permission choices: id and label, plus the ACP kind (allow_once, allow_always, reject_once, reject_always).
        public var options: [Option] = []
        public init(id: String, kind: Kind, text: String, status: String? = nil, toolKind: String? = nil, paths: [String] = [], options: [Option] = []) {
            self.id = id; self.kind = kind; self.text = text; self.status = status; self.toolKind = toolKind; self.paths = paths; self.options = options
        }
    }
    public struct Option: Codable, Equatable, Sendable {
        public var id: String; public var name: String; public var kind: String
        public init(id: String, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
    }

    public var entries: [Entry] = []
    public init() {}

    public mutating func append(_ entry: Entry) { entries.append(entry) }

    /// Applies one `session/update` (its `update` object).
    public mutating func apply(_ update: JSON) {
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk": appendText(.agent, update["content"])
        case "agent_thought_chunk": appendText(.thought, update["content"])
        case "user_message_chunk": appendText(.user, update["content"])
        case "tool_call":
            let id = update["toolCallId"]?.string ?? UUID().uuidString
            var entry = Entry(id: "tool-" + id, kind: .tool, text: update["title"]?.string ?? "工具", status: update["status"]?.string ?? "pending",
                              toolKind: update["kind"]?.string, paths: Self.paths(update))
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entry.paths = Array(Set(entries[index].paths + entry.paths)).sorted(); entries[index] = entry }
            else { entries.append(entry) }
        case "tool_call_update":
            guard let id = update["toolCallId"]?.string, let index = entries.firstIndex(where: { $0.id == "tool-" + id }) else { return }
            if let status = update["status"]?.string { entries[index].status = status }
            if let title = update["title"]?.string { entries[index].text = title }
            if let kind = update["kind"]?.string { entries[index].toolKind = kind }
            let more = Self.paths(update)
            if !more.isEmpty { entries[index].paths = Array(Set(entries[index].paths + more)).sorted() }
        case "plan":
            let lines = (update["entries"]?.array ?? []).map { item -> String in
                let mark = item["status"]?.string == "completed" ? "✓" : item["status"]?.string == "in_progress" ? "→" : "·"
                return "\(mark) \(item["content"]?.string ?? "")"
            }
            if let index = entries.lastIndex(where: { $0.kind == .plan }), index == entries.indices.last { entries[index].text = lines.joined(separator: "\n") }
            else { entries.append(Entry(id: "plan-\(entries.count)", kind: .plan, text: lines.joined(separator: "\n"))) }
        default:
            break
        }
    }

    /// Consecutive chunks of the same kind grow one entry.
    private mutating func appendText(_ kind: Kind, _ content: JSON?) {
        guard let content else { return }
        let text: String
        switch content["type"]?.string {
        case "text": text = content["text"]?.string ?? ""
        case "resource_link": text = "[\(content["name"]?.string ?? content["uri"]?.string ?? "链接")]"
        default: text = ""
        }
        guard !text.isEmpty else { return }
        if let last = entries.indices.last, entries[last].kind == kind { entries[last].text += text }
        else { entries.append(Entry(id: "\(kind.rawValue)-\(entries.count)", kind: kind, text: text)) }
    }

    /// `locations[].path` and diff content paths.
    public static func paths(_ update: JSON) -> [String] {
        let located = (update["locations"]?.array ?? []).compactMap { $0["path"]?.string }
        let diffs = (update["content"]?.array ?? []).compactMap { $0["type"]?.string == "diff" ? $0["path"]?.string : nil }
        return Array(Set(located + diffs)).sorted()
    }
}
