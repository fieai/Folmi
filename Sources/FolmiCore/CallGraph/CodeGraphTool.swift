import Foundation

/// CodeGraph (github.com/colbymchenry/codegraph), when the user has installed it and indexed the project with
/// `codegraph init` (`.codegraph/codegraph.db`): who calls a function, and what it calls, in the languages the call
/// map does not read (Go, Swift, Java, Rust…). Folmi never installs it, indexes a project or touches its files; it
/// only asks, read-only, with telemetry off.
public enum CodeGraphTool {
    public struct Node: Sendable, Hashable, Identifiable {
        public let name: String
        public let kind: String
        /// Relative to the repository root.
        public let path: String
        public let line: Int
        /// `calls`, `references`, `instantiates`…
        public let relationships: [String]
        public var id: String { "\(path):\(line):\(name)" }
        public var fileName: String { (path as NSString).lastPathComponent }
    }
    public struct Calls: Sendable, Equatable {
        public let target: Node
        public let callers: [Node]?
        public let callees: [Node]?
        /// Several definitions share the name and the lists are their union.
        public let ambiguous: Bool
        public let truncated: Bool
    }
    public enum Direction: String, Sendable { case callers, callees }

    static let limit = 100

    public static func isIndexed(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".codegraph/codegraph.db").path)
    }

    /// Where `codegraph` is installed: its own installer's folder, npm's usual places, then the login shell.
    /// Blocking: call off the main thread.
    public static func locate() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.codegraph/bin/codegraph", "\(home)/.local/bin/codegraph", "/opt/homebrew/bin/codegraph",
                          "/usr/local/bin/codegraph", "\(home)/.npm-global/bin/codegraph", "\(home)/.volta/bin/codegraph"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/codegraph" }
        }
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        guard let result = try? ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v codegraph"],
                                                    directory: URL(fileURLWithPath: home), environment: ProcessInfo.processInfo.environment,
                                                    timeout: 5) else { return nil }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// `codegraph callers|callees <name> --json` for the project at `root`; nil when it knows no such symbol.
    public static func calls(_ direction: Direction, of name: String, file: String? = nil, root: URL, executable: String) throws -> Calls? {
        var environment = ProcessInfo.processInfo.environment
        let folder = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = ([folder, "/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":"))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        environment["DO_NOT_TRACK"] = "1"
        let result = try ProcessExecutor.run(executable: URL(fileURLWithPath: executable),
                                             arguments: [direction.rawValue, name, "--json", "-p", root.path, "-l", String(limit)]
                                                + (file.map { ["-f", $0] } ?? []),
                                             directory: root, environment: environment, timeout: 20)
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodeGraphError(message: message.isEmpty ? "codegraph 退出码 \(result.status)" : message)
        }
        return parse(result.stdout, direction: direction, root: root)
    }

    public struct CodeGraphError: LocalizedError { public let message: String; public var errorDescription: String? { message } }

    /// The JSON `callers` / `callees` print. Not JSON (its "not found" line goes to stdout as text) or no target: nil.
    static func parse(_ data: Data, direction: Direction, root: URL) -> Calls? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let target = (object["targets"] as? [[String: Any]])?.first.flatMap({ node($0, root: root) }) else { return nil }
        let list = (object[direction.rawValue] as? [[String: Any]] ?? []).compactMap { node($0, root: root) }
        return Calls(target: target, callers: direction == .callers ? list : nil, callees: direction == .callees ? list : nil,
                     ambiguous: object["ambiguous"] as? Bool ?? false, truncated: object["truncated"] as? Bool ?? false)
    }

    private static func node(_ row: [String: Any], root: URL) -> Node? {
        guard let name = row["name"] as? String, var path = row["filePath"] as? String else { return nil }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        return Node(name: name, kind: row["kind"] as? String ?? "function", path: path, line: row["startLine"] as? Int ?? 1,
                    relationships: row["relationships"] as? [String] ?? [])
    }
}
