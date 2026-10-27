import Foundation

/// A remote as the 远端 sheet shows it: where fetches come from and, when set apart, where pushes go.
public struct GitRemote: Sendable, Equatable, Identifiable {
    public let name: String
    public let fetchURL: String
    /// Only when `remote.<name>.pushurl` is set; otherwise pushes go to `fetchURL`.
    public let pushURL: String?
    public var id: String { name }
    public init(name: String, fetchURL: String, pushURL: String?) { self.name = name; self.fetchURL = fetchURL; self.pushURL = pushURL }

    /// The URL with any password in it hidden (`https://me:•••@host/x.git`); tokens pasted into URLs are common.
    public static func displayURL(_ url: String) -> String {
        guard let scheme = url.range(of: "://"), let at = url[scheme.upperBound...].firstIndex(of: "@") else { return url }
        let credentials = url[scheme.upperBound..<at]
        guard !credentials.contains("/"), let colon = credentials.firstIndex(of: ":") else { return url }
        return String(url[..<url.index(after: colon)]) + "•••" + String(url[at...])
    }
}

/// Everything `git remote remove` throws away for one remote, so undo can put it back: its config section, its
/// remote-tracking refs, and the upstream settings of local branches that tracked it.
public struct RemoteRecord: Sendable, Equatable {
    public struct Entry: Sendable, Equatable { public let key: String; public let value: String }
    public struct Ref: Sendable, Equatable {
        public let name: String
        public let object: String
        /// `refs/remotes/origin/HEAD` points at another ref, not a commit.
        public let symbolic: String?
    }
    public let name: String
    public let config: [Entry]
    public let refs: [Ref]
    public let upstreams: [Entry]
    /// Local branches whose upstream is on this remote.
    public var trackingBranches: [String] {
        upstreams.filter { $0.key.hasSuffix(".remote") }.map { String($0.key.dropFirst("branch.".count).dropLast(".remote".count)) }
    }
}

extension GitRepository {
    /// The project's remotes in config order. URLs come straight from the config (no `insteadOf` rewriting).
    public func remotes() async throws -> [GitRemote] {
        let entries = try Self.localConfig(try runner())
        var names: [String] = [], fetch: [String: String] = [:], push: [String: String] = [:]
        for entry in entries where entry.key.hasPrefix("remote.") {
            let rest = entry.key.dropFirst("remote.".count)
            guard let dot = rest.lastIndex(of: ".") else { continue }
            let name = String(rest[..<dot]), variable = rest[rest.index(after: dot)...]
            if variable == "url", fetch[name] == nil { fetch[name] = entry.value; names.append(name) }
            if variable == "pushurl", push[name] == nil { push[name] = entry.value }
        }
        return names.map { GitRemote(name: $0, fetchURL: fetch[$0] ?? "", pushURL: push[$0]) }
    }

    /// Why `name` / `url` cannot be added, said before the button is pressed; nil when they can.
    public static func remoteProblem(name: String, url: String, existing: [String]) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "填一个名字，常用 origin 或 upstream" }
        if existing.contains(name) { return "已经有叫 \(name) 的远端了" }
        // The rules git checks with `check-ref-format refs/remotes/<name>/x`, said in words.
        if name.hasPrefix("-") || name.hasPrefix(".") || name.hasPrefix("/") || name.hasSuffix("/") || name.hasSuffix(".")
            || name.hasSuffix(".lock") || name.contains("..") || name.contains("//") || name.contains("@{")
            || name.contains(where: { $0.isWhitespace || "~^:?*[\\".contains($0) || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) {
            return "名字里不能有空格和 ~ ^ : ? * [ \\ 这些符号"
        }
        if url.isEmpty { return "填远端地址，例如 git@github.com:me/app.git" }
        if url.hasPrefix("-") || url.contains(where: \.isNewline) { return "地址不对" }
        return nil
    }

    /// `git remote add`; nothing is fetched here (the caller starts a quiet fetch). Undo removes it again.
    public func addRemote(_ name: String, url: String) async throws -> UndoStep {
        let git = try runner()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await remotes().map(\.name)
        if let problem = Self.remoteProblem(name: name, url: url, existing: existing) { throw FolmiError.unsupported(problem + "。") }
        let result = try git.run(["remote", "add", "--", name, url], allowFailure: true)
        guard result.status == 0 else { throw FolmiError.unsupported("「\(name)」不是有效的远端名。") }
        return .remote(restore: nil, current: try captureRemote(name, git: git))
    }

    /// What removing `name` would take away, for the confirmation.
    public func remoteRecord(_ name: String) async throws -> RemoteRecord {
        let git = try runner()
        guard try await remotes().contains(where: { $0.name == name }) else { throw FolmiError.unsupported("远端「\(name)」不存在。") }
        return try captureRemote(name, git: git)
    }

    /// `git remote remove`: drops its settings and remote-tracking branches; nothing on the server changes. Undo
    /// puts all of it back.
    public func removeRemote(_ name: String) async throws -> UndoStep {
        let record = try await remoteRecord(name)
        _ = try runner().run(["remote", "remove", "--", name])
        return .remote(restore: record, current: nil)
    }

    func undoRemote(restore: RemoteRecord?, current: RemoteRecord?) throws -> UndoStep {
        let git = try runner()
        let names = Set(try Self.localConfig(git).compactMap { $0.key.hasPrefix("remote.") && $0.key.hasSuffix(".url") ? String($0.key.dropFirst(7).dropLast(4)) : nil })
        var now: RemoteRecord?
        if let current {
            guard names.contains(current.name) else { throw FolmiError.unsupported("远端「\(current.name)」已经不在了。") }
            now = try captureRemote(current.name, git: git)
            _ = try git.run(["remote", "remove", "--", current.name])
        }
        if let restore {
            guard !names.contains(restore.name) || current?.name == restore.name else {
                throw FolmiError.unsupported("现在又有了叫 \(restore.name) 的远端，先删掉它再撤销。")
            }
            for entry in restore.config { _ = try git.run(["config", "--local", "--add", entry.key, entry.value]) }
            for entry in restore.upstreams { _ = try git.run(["config", "--local", "--replace-all", entry.key, entry.value]) }
            for ref in restore.refs where ref.symbolic == nil {
                _ = try git.run(["update-ref", "-m", "Folmi：撤销", ref.name, ref.object, ""], allowFailure: true)
            }
            for ref in restore.refs { if let target = ref.symbolic { _ = try git.run(["symbolic-ref", ref.name, target], allowFailure: true) } }
        }
        return .remote(restore: now, current: restore)
    }

    func captureRemote(_ name: String, git: GitProcess) throws -> RemoteRecord {
        let entries = try Self.localConfig(git)
        let config = entries.filter { $0.key.hasPrefix("remote.\(name).") && !$0.key.dropFirst("remote.\(name).".count).contains(".") }
        let tracking = entries.filter { $0.key.hasPrefix("branch.") && ($0.key.hasSuffix(".remote") || $0.key.hasSuffix(".pushremote")) && $0.value == name }
            .map { String($0.key[..<$0.key.lastIndex(of: ".")!]) }
        let upstreams = entries.filter { entry in
            tracking.contains { entry.key == $0 + ".remote" || entry.key == $0 + ".merge" || entry.key == $0 + ".pushremote" }
        }
        let refs = try git.run(["for-each-ref", "--format=%(objectname) %(refname) %(symref)", "refs/remotes/\(name)/"]).text
            .components(separatedBy: .newlines).compactMap { line -> RemoteRecord.Ref? in
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { return nil }
                return RemoteRecord.Ref(name: String(fields[1]), object: String(fields[0]), symbolic: fields[2].isEmpty ? nil : String(fields[2]))
            }
        return RemoteRecord(name: name, config: config, refs: refs, upstreams: upstreams)
    }

    /// The repository's own config (`.git/config`), in file order.
    static func localConfig(_ git: GitProcess) throws -> [RemoteRecord.Entry] {
        try git.run(["config", "--local", "--null", "--list"]).text.split(separator: "\0").map { item in
            guard let newline = item.firstIndex(of: "\n") else { return RemoteRecord.Entry(key: String(item), value: "") }
            return RemoteRecord.Entry(key: String(item[..<newline]), value: String(item[item.index(after: newline)...]))
        }
    }
}
