import Foundation

/// Files the app and `folmi-hook mcp` share, next to the hook events in `<git dir>/folmi/`. The app writes
/// the review state; the MCP server reads it and only appends replies. Nothing here can change what Git holds.
public enum FolmiShared {
    public static func comments(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("comments.json") }
    public static func replies(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("comment-replies.jsonl") }
    public static func status(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("review-status.json") }
    public static func decisions(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("decisions.jsonl") }
    /// Why a rejection was made, added after it (decisions.jsonl stays append-only).
    public static func reasons(gitDir: URL) -> URL { AIEventStore.directory(gitDir: gitDir).appendingPathComponent("decision-reasons.jsonl") }
    /// Written by the app: its own writes must not wake its file watcher.
    public static let appWrittenFiles: Set<String> = ["comments.json", "review-status.json", "decisions.jsonl", "decision-reasons.jsonl", "note-log.jsonl",
                                                         "learning.json"]

    /// `<settings dir>/app.json`: which app to open links in and which project is in front.
    public static func appState(settingsDirectory: URL) -> URL { settingsDirectory.appendingPathComponent("app.json") }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    /// Writes only when the bytes differ; returns whether it wrote.
    @discardableResult
    public static func write<T: Encodable>(_ value: T, to url: URL) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        if (try? Data(contentsOf: url)) == data { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }
    /// One JSON line at the end (O_APPEND: several writers at once each land whole).
    public static func append<T: Encodable>(_ value: T, to url: URL) throws {
        var line = try JSONEncoder().encode(value)
        line.append(10)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }
    /// Every complete line that decodes, oldest first; the last `limit` when given.
    public static func lines<T: Decodable>(_ type: T.Type, from url: URL, limit: Int? = nil) -> [T] {
        guard let data = try? Data(contentsOf: url), let end = data.lastIndex(of: 10) else { return [] }
        let decoder = JSONDecoder()
        var rows = data[data.startIndex...end].split(separator: 10)
        if let limit, rows.count > limit { rows = Array(rows.suffix(limit)) }
        return rows.compactMap { try? decoder.decode(type, from: Data($0)) }
    }
}

/// A review note as the agent sees it.
public struct SharedComment: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var firstLine: Int
    public var lastLine: Int
    /// The commented diff lines with their +/-/space prefix.
    public var excerpt: [String]
    public var body: String
    /// The lines moved away or changed since the note was written.
    public var outdated: Bool
    public init(id: String, path: String, firstLine: Int, lastLine: Int, excerpt: [String], body: String, outdated: Bool) {
        self.id = id; self.path = path; self.firstLine = firstLine; self.lastLine = lastLine
        self.excerpt = excerpt; self.body = body; self.outdated = outdated
    }
}

/// "I dealt with this note", from the agent. The user still confirms it in the app.
public struct CommentReply: Codable, Equatable, Sendable {
    public var id: String
    public var note: String
    public var t: Double
    public init(id: String, note: String, t: Double) { self.id = id; self.note = note; self.t = t }
}

/// What is waiting for review, as of the app's last refresh.
public struct SharedReviewStatus: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var staged: Bool
        public var working: Bool
        public var untracked: Bool
        public init(path: String, staged: Bool, working: Bool, untracked: Bool) {
            self.path = path; self.staged = staged; self.working = working; self.untracked = untracked
        }
    }
    public struct Batch: Codable, Equatable, Sendable {
        public var id: String
        public var prompt: String?
        public var paths: [String]
        public var finished: Bool
        public init(id: String, prompt: String?, paths: [String], finished: Bool) {
            self.id = id; self.prompt = prompt; self.paths = paths; self.finished = finished
        }
    }
    public var branch: String?
    public var files: [File]
    /// Hunks not looked at yet; nil when the app has not read every diff (a large change set).
    public var remaining: Int?
    public var latestBatch: Batch?
    public init(branch: String?, files: [File], remaining: Int?, latestBatch: Batch?) {
        self.branch = branch; self.files = files; self.remaining = remaining; self.latestBatch = latestBatch
    }
}

/// One accept or reject in the review, for spotting what the user keeps turning down.
public struct ReviewDecision: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case accept, reject }
    public enum Scope: String, Codable, Sendable { case hunk, lines, file }
    public var t: Double
    public var path: String
    public var action: Action
    public var scope: Scope
    public var added: Int
    public var removed: Int
    /// Every changed line is a comment (or blank).
    public var commentOnly: Bool
    /// The first few changed lines with their +/- prefix.
    public var preview: [String]
    /// The AI turn that last touched the file, when known.
    public var batch: String?
    public init(t: Double, path: String, action: Action, scope: Scope, added: Int, removed: Int, commentOnly: Bool,
                preview: [String], batch: String?) {
        self.t = t; self.path = path; self.action = action; self.scope = scope; self.added = added; self.removed = removed
        self.commentOnly = commentOnly; self.preview = preview; self.batch = batch
    }
}

/// The running app, for `show_in_folmi` and for an MCP client that is not started inside the repository.
public struct SharedAppState: Codable, Equatable, Sendable {
    public var bundleID: String?
    public var appPath: String?
    public var repository: String?
    public init(bundleID: String?, appPath: String?, repository: String?) {
        self.bundleID = bundleID; self.appPath = appPath; self.repository = repository
    }
}

/// The user's one line on why they turned a change down, matched to its decision by time and path.
public struct DecisionReason: Codable, Equatable, Sendable {
    /// The `t` of the decision it explains.
    public var t: Double
    public var path: String
    public var reason: String
    public init(t: Double, path: String, reason: String) { self.t = t; self.path = path; self.reason = reason }
    public var key: String { "\(t)|\(path)" }
}
