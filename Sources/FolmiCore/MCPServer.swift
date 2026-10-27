import Foundation

/// `folmi-hook mcp`: an MCP server on stdio (one JSON-RPC message per line) that lets Claude Code, the Claude app
/// or Codex read what the user decided in Folmi. It can read review notes and status, mark a note as dealt with,
/// ask the app to show a place, and read the call map (who calls a function, what a change breaks). It cannot
/// stage, discard, commit or push: the review stays the user's.
public final class MCPServer {
    public static let name = "folmi"
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Where the app keeps `app.json` (the installed helper sits in `<settings>/bin/`).
    let settingsDirectory: URL?
    let workingDirectory: URL
    /// Opens a `folmi://` link in the app; returns an error message or nil.
    let openLink: (URL, SharedAppState?) -> String?
    let now: () -> Date
    /// Outlines of the files read for the call map, so a later tool call rereads only what changed.
    var callCache = CallGraphCache()
    var callCacheRoot: String?
    /// Where `codegraph` is; tests point it at a stand-in.
    var locateCodeGraph: () -> String? = CodeGraphTool.locate

    public init(settingsDirectory: URL?, workingDirectory: URL, now: @escaping () -> Date = Date.init,
                openLink: @escaping (URL, SharedAppState?) -> String? = MCPServer.openWithSystem) {
        self.settingsDirectory = settingsDirectory; self.workingDirectory = workingDirectory
        self.openLink = openLink; self.now = now
    }

    /// Reads requests from stdin until it closes.
    public static func runStdio(settingsDirectory: URL?) {
        let server = MCPServer(settingsDirectory: settingsDirectory,
                               workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let reply = server.handle(Data(line.utf8)) else { continue }
            FileHandle.standardOutput.write(reply + Data([10]))
        }
    }

    // MARK: JSON-RPC

    /// One message in, at most one message out (notifications get no reply).
    public func handle(_ data: Data) -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.name, "version": "1"],
                "instructions": "Folmi is where the user reviews your changes. Read their review comments with list_review_comments, fix them, then call mark_comment_addressed for each. Before renaming, deleting or changing the parameters of a JavaScript, TypeScript or Python function, see who calls it with callers; when you are done, run change_impact to find calls your changes left broken. You cannot stage, commit or push from here: the user decides in the app.",
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try call(name, arguments)
                return result(id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch let failure as Failure {
                return result(id, ["content": [["type": "text", "text": failure.message]], "isError": true])
            } catch {
                return result(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func result(_ id: Any, _ value: [String: Any]) -> Data? { encode(["jsonrpc": "2.0", "id": id, "result": value]) }
    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    struct Failure: Error { let message: String }

    // MARK: Tools

    static var tools: [[String: Any]] {
        let repo: [String: Any] = ["type": "string", "description": "Repository path. Optional: defaults to the current directory, else the project open in Folmi."]
        // Only reading tools say so: clients such as Codex run those without asking, and ask before the others.
        let writes: Set<String> = ["mark_comment_addressed", "show_in_folmi"]
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var props = properties; props["repo"] = repo
            return ["name": name, "description": description,
                    "inputSchema": ["type": "object", "properties": props, "required": required],
                    "annotations": ["readOnlyHint": !writes.contains(name), "destructiveHint": false, "openWorldHint": false]]
        }
        let callArguments: [String: Any] = [
            "function": ["type": "string", "description": "Function name, or Class.method."],
            "file": ["type": "string", "description": "File that defines it, relative to the repository root. Needed only when several functions share the name."],
        ]
        return [
            tool("list_review_comments",
                 "The user's review comments on the current changes: file, lines, the diff lines they refer to, and what to change. Fix them, then call mark_comment_addressed for each.",
                 ["include_outdated": ["type": "boolean", "description": "Also list notes whose lines changed since (default false)."]]),
            tool("mark_comment_addressed",
                 "Tell the user you dealt with a review comment. It shows as \"AI 说已处理\" with your note; the user confirms it.",
                 ["id": ["type": "string", "description": "The comment id from list_review_comments."],
                  "note": ["type": "string", "description": "One short sentence: what you changed."]], required: ["id", "note"]),
            tool("review_status",
                 "What is waiting for the user's review: changed files (staged / not staged), hunks not looked at yet, and the latest AI turn."),
            tool("recent_decisions",
                 "The user's latest review decisions: which changes they accepted or rejected, with the reason when they gave one. Use it to learn what they do not want.",
                 ["limit": ["type": "integer", "description": "How many, newest last (default 20, at most 200)."]]),
            tool("show_in_folmi",
                 "Open a file's change in Folmi at a line, so the user can look at it.",
                 ["path": ["type": "string", "description": "File path relative to the repository root."],
                  "line": ["type": "integer", "description": "Line number (optional)."]], required: ["path"]),
            tool("callers",
                 "Who calls a function in this repository: each calling function with file and lines. JavaScript, TypeScript and Python are read by Folmi (names followed through imports, re-exports, aliases and `this` / `self` members; `certain: false` means matched by method name only); other languages come from CodeGraph when the project has a CodeGraph index.",
                 callArguments, required: ["function"]),
            tool("callees",
                 "What a function calls: functions in this repository (with where they are defined) and outside packages. Other languages than JavaScript, TypeScript and Python come from CodeGraph when the project has a CodeGraph index.",
                 callArguments, required: ["function"]),
            tool("endpoints",
                 "The back end's routes (Express, Koa, NestJS, Next.js, FastAPI, Flask, Django) with the front-end requests (fetch, axios, wrappers like api.get) that reach each, and requests no route matched. `certain: false` means only the end of the path matched (a base URL or a mount prefix in between).",
                 ["filter": ["type": "string", "description": "Only endpoints whose method and path contain this text (optional)."]]),
            tool("change_impact",
                 "What the uncommitted changes (staged and not, against HEAD) do to calls in JavaScript, TypeScript and Python: removed or renamed functions still called by the old name, functions whose new parameters some calls do not fit, who calls each changed function, and for a changed route handler (Express, NestJS, Next.js, FastAPI, Flask, Django) which front-end requests reach it. Run it before you finish.",
                 ["paths": ["type": "array", "items": ["type": "string"], "description": "Only these files (relative to the repository root). Optional: all changed files."]]),
        ]
    }

    func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        switch name {
        case "list_review_comments": return try listComments(arguments)
        case "mark_comment_addressed": return try markAddressed(arguments)
        case "review_status": return try reviewStatus(arguments)
        case "recent_decisions": return try recentDecisions(arguments)
        case "show_in_folmi": return try show(arguments)
        case "callers": return try callers(arguments)
        case "callees": return try callees(arguments)
        case "change_impact": return try changeImpact(arguments)
        case "endpoints": return try endpoints(arguments)
        default: throw Failure(message: "Unknown tool: \(name)")
        }
    }

    var appState: SharedAppState? {
        settingsDirectory.flatMap { FolmiShared.read(SharedAppState.self, from: FolmiShared.appState(settingsDirectory: $0)) }
    }

    /// The `repo` argument, else the directory the client started us in, else the project open in the app.
    func repository(_ arguments: [String: Any]) throws -> (root: URL, gitDir: URL) {
        if let path = arguments["repo"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: workingDirectory)
            guard let found = AIEventStore.locate(from: url) else { throw Failure(message: "Not a Git repository: \(path)") }
            return found
        }
        if workingDirectory.path != "/", let found = AIEventStore.locate(from: workingDirectory) { return found }
        if let open = appState?.repository, let found = AIEventStore.locate(from: URL(fileURLWithPath: open)) { return found }
        throw Failure(message: "No repository: pass `repo`, or open the project in Folmi.")
    }

    private func listComments(_ arguments: [String: Any]) throws -> String {
        let repo = try repository(arguments)
        let all = FolmiShared.read([SharedComment].self, from: FolmiShared.comments(gitDir: repo.gitDir)) ?? []
        let replies = Dictionary(FolmiShared.lines(CommentReply.self, from: FolmiShared.replies(gitDir: repo.gitDir)).map { ($0.id, $0.note) },
                                 uniquingKeysWith: { _, last in last })
        let includeOutdated = arguments["include_outdated"] as? Bool ?? false
        let shown = all.filter { includeOutdated || !$0.outdated }
        guard !shown.isEmpty else { return all.isEmpty ? "No review comments." : "No current review comments (\(all.count) outdated)." }
        let rows: [[String: Any]] = shown.map { comment in
            var row: [String: Any] = ["id": comment.id, "file": comment.path,
                                      "lines": comment.firstLine == comment.lastLine ? "\(comment.firstLine)" : "\(comment.firstLine)-\(comment.lastLine)",
                                      "diff": comment.excerpt.joined(separator: "\n"), "comment": comment.body]
            if comment.outdated { row["outdated"] = true }
            if let note = replies[comment.id] { row["addressed"] = note }
            return row
        }
        return try json(["repository": repo.root.path, "comments": rows])
    }

    private func markAddressed(_ arguments: [String: Any]) throws -> String {
        let repo = try repository(arguments)
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw Failure(message: "`id` is required.") }
        let note = (arguments["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw Failure(message: "`note` is required: say in one sentence what you changed.") }
        let all = FolmiShared.read([SharedComment].self, from: FolmiShared.comments(gitDir: repo.gitDir)) ?? []
        guard all.contains(where: { $0.id == id }) else { throw Failure(message: "No review comment with id \(id).") }
        try FolmiShared.append(CommentReply(id: id, note: String(note.prefix(500)), t: now().timeIntervalSince1970),
                                   to: FolmiShared.replies(gitDir: repo.gitDir))
        return "Recorded. The user will confirm it in Folmi."
    }

    private func reviewStatus(_ arguments: [String: Any]) throws -> String {
        let repo = try repository(arguments)
        let url = FolmiShared.status(gitDir: repo.gitDir)
        guard let status = FolmiShared.read(SharedReviewStatus.self, from: url) else {
            return "Folmi has not opened this repository yet, so there is no review status."
        }
        let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var object: [String: Any] = ["repository": repo.root.path,
                                     "files": status.files.map { file -> [String: Any] in
                                         ["path": file.path, "staged": file.staged, "notStaged": file.working, "untracked": file.untracked]
                                     }]
        if let branch = status.branch { object["branch"] = branch }
        if let remaining = status.remaining { object["hunksNotReviewed"] = remaining }
        if let batch = status.latestBatch {
            var row: [String: Any] = ["paths": batch.paths, "finished": batch.finished]
            if let prompt = batch.prompt { row["prompt"] = prompt }
            object["latestAITurn"] = row
        }
        if let updated { object["updated"] = ISO8601DateFormatter().string(from: updated) }
        return try json(object)
    }

    private func recentDecisions(_ arguments: [String: Any]) throws -> String {
        let repo = try repository(arguments)
        let limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 200)
        let rows = FolmiShared.lines(ReviewDecision.self, from: FolmiShared.decisions(gitDir: repo.gitDir), limit: limit)
        guard !rows.isEmpty else { return "No review decisions recorded yet." }
        let reasons = Dictionary(FolmiShared.lines(DecisionReason.self, from: FolmiShared.reasons(gitDir: repo.gitDir), limit: 2_000)
            .map { ($0.key, $0.reason) }, uniquingKeysWith: { _, last in last })
        let formatter = ISO8601DateFormatter()
        return try json(["decisions": rows.map { row -> [String: Any] in
            var object: [String: Any] = ["time": formatter.string(from: Date(timeIntervalSince1970: row.t)), "file": row.path,
                                         "action": row.action == .accept ? "accepted" : "rejected", "scope": row.scope.rawValue,
                                         "added": row.added, "removed": row.removed, "preview": row.preview.joined(separator: "\n")]
            if row.commentOnly { object["commentOnly"] = true }
            if let reason = reasons[DecisionReason(t: row.t, path: row.path, reason: "").key] { object["reason"] = reason }
            return object
        }])
    }

    private func show(_ arguments: [String: Any]) throws -> String {
        let repo = try repository(arguments)
        guard let path = arguments["path"] as? String, !path.isEmpty else { throw Failure(message: "`path` is required.") }
        let line = arguments["line"] as? Int
        guard let link = Self.link(repository: repo.root.path, path: path, line: line) else { throw Failure(message: "Bad path: \(path)") }
        if let problem = openLink(link, appState) { throw Failure(message: problem) }
        return "Opened \(path)\(line.map { ":\($0)" } ?? "") in Folmi."
    }

    func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Links

    public static let scheme = "folmi"

    /// `folmi://open?repo=…&path=…&line=…`
    public static func link(repository: String, path: String, line: Int?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme; components.host = "open"
        components.queryItems = [URLQueryItem(name: "repo", value: repository), URLQueryItem(name: "path", value: path)]
            + (line.map { [URLQueryItem(name: "line", value: String($0))] } ?? [])
        return components.url
    }
    public struct Link: Equatable, Sendable { public let repository: String; public let path: String?; public let line: Int? }
    public static func parse(_ url: URL) -> Link? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let repository = items.first(where: { $0.name == "repo" })?.value, repository.hasPrefix("/") else { return nil }
        let path = items.first { $0.name == "path" }?.value.flatMap { $0.isEmpty || $0.hasPrefix("/") || $0.contains("..") ? nil : $0 }
        return Link(repository: repository, path: path, line: items.first { $0.name == "line" }?.value.flatMap { Int($0) })
    }

    /// `open -b <app>` (the app that wrote app.json), else whichever app claims the scheme.
    public static func openWithSystem(_ link: URL, _ state: SharedAppState?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (state?.bundleID.map { ["-b", $0] } ?? []) + [link.absoluteString]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "Could not open Folmi: \(error.localizedDescription)" }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : "Could not open Folmi (is it installed?)."
    }
}
