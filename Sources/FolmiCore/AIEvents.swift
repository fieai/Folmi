import Foundation

/// What an AI agent did in a repository, as written by `folmi-hook` from Claude Code or Codex hooks into
/// `<git dir>/folmi/`. One JSON object per line in `events.jsonl`; a file's content before the agent first
/// touched it in a turn ("batch") is kept under `batches/<batch>/pre/<path>` (or in sibling `pre-missing/<path>` when absent),
/// and what those files held when the turn stopped under `batches/<batch>/post/` the same way.
public struct AIEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case start, edit, stop }
    public let t: Double
    public let kind: Kind
    public let session: String
    public let batch: String
    public let path: String?
    public let tool: String?
    /// The first words of the prompt that started the batch (only on `start`).
    public let prompt: String?
    /// Missing for events written by older Claude helpers.
    public let agent: String?
    public init(t: Double, kind: Kind, session: String, batch: String, path: String? = nil, tool: String? = nil, prompt: String? = nil, agent: String? = nil) {
        self.t = t; self.kind = kind; self.session = session; self.batch = batch; self.path = path; self.tool = tool; self.prompt = prompt; self.agent = agent
    }
}

public enum AIEventStore {
    public static let directoryName = "folmi"
    public static func directory(gitDir: URL) -> URL { gitDir.appendingPathComponent(directoryName, isDirectory: true) }
    public static func events(gitDir: URL) -> URL { directory(gitDir: gitDir).appendingPathComponent("events.jsonl") }
    /// One line per thing the hook could not do (a copy it could not keep, a file it could not write).
    public static func errorLog(gitDir: URL) -> URL { directory(gitDir: gitDir).appendingPathComponent("hook-errors.log") }
    public static func batch(_ id: String, gitDir: URL) -> URL {
        directory(gitDir: gitDir).appendingPathComponent("batches", isDirectory: true).appendingPathComponent(safe(id), isDirectory: true)
    }
    public static func preImage(_ path: String, batch: String, gitDir: URL) -> URL {
        Self.batch(batch, gitDir: gitDir).appendingPathComponent("pre", isDirectory: true).appendingPathComponent(path)
    }
    public static func absentMarker(_ path: String, batch: String, gitDir: URL) -> URL {
        snapshotAbsentMarker(path, in: Self.batch(batch, gitDir: gitDir).appendingPathComponent("pre", isDirectory: true))
    }
    /// The files as the turn left them, written by the stop hook. The folder appears whole (renamed into place) or not at all.
    public static func post(batch: String, gitDir: URL) -> URL {
        Self.batch(batch, gitDir: gitDir).appendingPathComponent("post", isDirectory: true)
    }

    private static func missingDirectory(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-missing", isDirectory: true)
    }
    private static func formatFile(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "-format")
    }
    private static func isCurrentFormat(_ folder: URL) -> Bool {
        (try? String(contentsOf: formatFile(folder), encoding: .utf8)) == "2"
    }
    /// V2 keeps missing-file markers outside the content tree, so `foo.absent` is an ordinary filename.
    public static func snapshotAbsentMarker(_ path: String, in folder: URL) -> URL {
        missingDirectory(folder).appendingPathComponent(path)
    }
    public static func isAbsent(_ path: String, in folder: URL) -> Bool {
        isCurrentFormat(folder) && FileManager.default.fileExists(atPath: snapshotAbsentMarker(path, in: folder).path)
    }
    /// Every `.absent` file in V1 is ambiguous: it may be a marker or an actual file. Never guess which.
    public static func hasAmbiguousLegacySnapshot(_ folder: URL) -> Bool {
        !isCurrentFormat(folder) && regularPaths(folder).contains { $0.hasSuffix(".absent") }
    }
    /// Call before writing a new snapshot. Refuse to relabel an existing legacy snapshot as V2.
    public static func prepareSnapshot(in folder: URL) throws {
        let manager = FileManager.default
        if !isCurrentFormat(folder) {
            guard !manager.fileExists(atPath: formatFile(folder).path), regularPaths(folder).isEmpty,
                  regularPaths(missingDirectory(folder)).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.createDirectory(at: missingDirectory(folder), withIntermediateDirectories: true)
        if !isCurrentFormat(folder) { try "2".write(to: formatFile(folder), atomically: true, encoding: .utf8) }
    }
    /// Copies the turn's touched files as they are now; absent paths go to a separate marker tree.
    public static func snapshotTouched(batch: String, root: URL, gitDir: URL, into folder: URL) throws {
        let manager = FileManager.default
        let pre = Self.batch(batch, gitDir: gitDir).appendingPathComponent("pre", isDirectory: true)
        guard !hasAmbiguousLegacySnapshot(pre) else { throw CocoaError(.fileReadCorruptFile) }
        try prepareSnapshot(in: folder)
        for path in keptPaths(pre) {
            guard let safe = safeRelativePath(path, cwd: root, root: root), safe == path else {
                throw CocoaError(.fileReadNoPermission)
            }
            let source = root.appendingPathComponent(path), target = folder.appendingPathComponent(path)
            if manager.fileExists(atPath: source.path) {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: target)
            } else {
                let absent = snapshotAbsentMarker(path, in: folder)
                try manager.createDirectory(at: absent.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard manager.createFile(atPath: absent.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
    /// Publish metadata first and the content directory last: seeing `post/` guarantees all metadata is ready.
    public static func publishSnapshot(from staging: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard isCurrentFormat(staging), !manager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try? manager.removeItem(at: missingDirectory(destination))
        try? manager.removeItem(at: formatFile(destination))
        do {
            try manager.moveItem(at: missingDirectory(staging), to: missingDirectory(destination))
            try manager.moveItem(at: formatFile(staging), to: formatFile(destination))
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: missingDirectory(destination))
            try? manager.removeItem(at: formatFile(destination))
            throw error
        }
    }
    public static func removeSnapshot(_ folder: URL) {
        for url in [folder, missingDirectory(folder), formatFile(folder)] { try? FileManager.default.removeItem(at: url) }
    }
    /// Paths kept in a snapshot. Ambiguous legacy snapshots yield no restorable paths.
    public static func keptPaths(_ folder: URL) -> Set<String> {
        guard !hasAmbiguousLegacySnapshot(folder) else { return [] }
        let files = regularPaths(folder)
        return isCurrentFormat(folder) ? files.union(regularPaths(missingDirectory(folder))) : files
    }
    private static func regularPaths(_ folder: URL) -> Set<String> {
        // URL enumeration may canonicalize /var to /private/var. Relative String enumeration avoids mixing
        // a canonicalized entry URL with the caller's lexical root when deriving repository paths.
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: folder.path) else { return [] }
        var result = Set<String>()
        for case let path as String in enumerator {
            let url = folder.appendingPathComponent(path)
            if (try? manager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular {
                result.insert(path)
            }
        }
        return result
    }

    /// Paths from all file sections of one Codex apply_patch call, including both sides of a move.
    public static func patchPaths(_ patch: String) -> [String] {
        let prefixes = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
        var paths: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line).trimmingCharacters(in: .newlines)
            for prefix in prefixes where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count))
                if !path.isEmpty && !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    /// Restricts hook reads to ordinary repository files. Reject every symlink component, including dangling
    /// links, and all .git components; merely standardizing `../` is not enough to prevent following links.
    public static func safeRelativePath(_ path: String, cwd: URL, root: URL) -> String? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let root = root.absoluteURL.standardized
        let url = URL(fileURLWithPath: path, relativeTo: cwd).absoluteURL.standardized
        let base = root.path + "/"
        guard url.path.hasPrefix(base) else { return nil }
        let relative = String(url.path.dropFirst(base.count))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.contains(".git"), !components.isEmpty else { return nil }
        var current = root
        for component in components {
            current.appendPathComponent(component)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path) {
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
                if current != url && attrs[.type] as? FileAttributeType != .typeDirectory { return nil }
            }
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           attrs[.type] as? FileAttributeType != .typeRegular { return nil }
        return relative
    }

    /// File-name-safe form of a session or batch id.
    public static func safe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(120))
    }

    /// Work-tree root and git directory for a path inside a repository, found without running git: the nearest
    /// `.git` folder, or a `.git` file of a linked worktree pointing at its git directory.
    public static func locate(from start: URL) -> (root: URL, gitDir: URL)? {
        var directory = start.absoluteURL.standardized
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            directory = directory.deletingLastPathComponent()
        }
        while directory.path != "/" {
            let dotGit = directory.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (directory, dotGit) }
                if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
                    let raw = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitDir = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : directory.appendingPathComponent(raw)
                    return (directory, gitDir.absoluteURL.standardized)
                }
                return nil
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// Parses complete lines from `data`; returns events and how many bytes were consumed.
    public static func parse(_ data: Data) -> (events: [AIEvent], consumed: Int) {
        guard let end = data.lastIndex(of: 10) else { return ([], 0) }
        let decoder = JSONDecoder()
        var events: [AIEvent] = []
        for line in data[data.startIndex...end].split(separator: 10) {
            if let event = try? decoder.decode(AIEvent.self, from: Data(line)) { events.append(event) }
        }
        return (events, end - data.startIndex + 1)
    }
}
