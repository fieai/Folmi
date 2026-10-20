import Foundation

/// One working tree of a repository (`git worktree list`): the main checkout and the extra ones agents such as
/// Claude Code and Codex make to work on a branch in parallel.
public struct WorktreeInfo: Sendable, Equatable, Identifiable {
    public let path: String
    /// Short branch name; nil when HEAD is detached.
    public let branch: String?
    public let head: String?
    public let isMain: Bool
    public var id: String { path }
    public init(path: String, branch: String?, head: String?, isMain: Bool) {
        self.path = path; self.branch = branch; self.head = head; self.isMain = isMain
    }
    /// The branch, or the short commit for a detached HEAD.
    public var title: String { branch ?? head.map { String($0.prefix(7)) } ?? "（无提交）" }

    /// Parses `git worktree list --porcelain`. Bare and prunable (folder gone) entries are left out.
    public static func parse(_ text: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        for (number, record) in text.components(separatedBy: "\n\n").enumerated() {
            var path: String?, branch: String?, head: String?, skip = false
            for line in record.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst(7))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
                } else if line == "bare" || line.hasPrefix("prunable") { skip = true }
            }
            guard let path, !skip else { continue }
            result.append(WorktreeInfo(path: path, branch: branch, head: head, isMain: number == 0))
        }
        return result
    }

    /// For a linked worktree (its `.git` is a file pointing into `<main>/.git/worktrees/<name>`), the main checkout's
    /// folder; nil for a main checkout, a submodule, or anything else. Reads two small files, no git process.
    public static func mainRoot(of root: String) -> String? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        guard let link = try? String(contentsOf: dotGit, encoding: .utf8), link.hasPrefix("gitdir:") else { return nil }
        let target = link.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(fileURLWithPath: root).appendingPathComponent(target))
            .standardizedFileURL.path
        guard let range = gitDir.range(of: "/.git/worktrees/", options: .backwards) else { return nil }
        return String(gitDir[..<range.lowerBound])
    }
}

/// Which agent most likely made a worktree, read from where it lives.
public enum WorktreeAgent: String, Sendable {
    case codex, claudeCode
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
    public static func guess(path: String) -> WorktreeAgent? {
        if path.contains("/.codex/worktrees/") { return .codex }
        if path.contains("/.claude/worktrees/") { return .claudeCode }
        return nil
    }
}

/// A worktree and whether it holds work nobody has looked at: uncommitted files, or commits no other branch, tag or
/// remote branch has.
public struct WorktreeStatus: Sendable, Equatable, Identifiable {
    public let info: WorktreeInfo
    /// Files with uncommitted changes (untracked included).
    public var changes: Int
    /// Commits only this worktree's HEAD reaches; removing a detached worktree would leave them behind.
    public var ownCommits: Int
    /// Last time its index or HEAD moved.
    public var modified: Date?
    /// The status could not be read (folder unreadable, git failed).
    public var unreadable = false
    public init(info: WorktreeInfo, changes: Int, ownCommits: Int, modified: Date?, unreadable: Bool = false) {
        self.info = info; self.changes = changes; self.ownCommits = ownCommits; self.modified = modified; self.unreadable = unreadable
    }
    public var id: String { info.path }
    public var agent: WorktreeAgent? { WorktreeAgent.guess(path: info.path) }
    public var hasWork: Bool { changes > 0 || ownCommits > 0 }
    /// `git worktree remove` loses nothing: no uncommitted files, and its commits stay on a branch or elsewhere.
    public var canRemove: Bool { !info.isMain && !unreadable && changes == 0 && (ownCommits == 0 || info.branch != nil) }
    /// The folder's last two components (Codex keeps `<task id>/<repo>`), for telling worktrees apart.
    public var folder: String {
        let parts = URL(fileURLWithPath: info.path).pathComponents.filter { $0 != "/" }
        return parts.suffix(2).joined(separator: "/")
    }
}

extension GitRepository {
    public func worktrees() async throws -> [WorktreeInfo] {
        let result = try runner().run(["worktree", "list", "--porcelain"], allowFailure: true)
        guard result.status == 0 else { return [] }
        return WorktreeInfo.parse(result.text)
    }

    /// One `git status` per worktree plus one `rev-list` for its own commits; nothing is hashed.
    public func worktreeStatuses(_ list: [WorktreeInfo]) async -> [WorktreeStatus] {
        list.map { info in
            let git = GitProcess(directory: URL(fileURLWithPath: info.path), environment: environment)
            guard let status = try? git.run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], allowFailure: true),
                  status.status == 0 else {
                return WorktreeStatus(info: info, changes: 0, ownCommits: 0, modified: nil, unreadable: true)
            }
            // A rename record carries its old path as the next field, which starts with neither marker.
            let changes = status.text.split(separator: "\0").filter {
                $0.hasPrefix("1 ") || $0.hasPrefix("2 ") || $0.hasPrefix("u ") || $0.hasPrefix("? ")
            }.count
            var own = 0
            if let head = info.head {
                // Every branch but its own, plus remote branches and tags; ref patterns keep the argument list short.
                let others = (info.branch.map { ["--exclude=" + $0] } ?? []) + ["--branches", "--remotes", "--tags"]
                let count = try? git.run(["rev-list", "--count", head, "--not"] + others, allowFailure: true)
                own = count?.status == 0 ? Int(count!.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
            }
            return WorktreeStatus(info: info, changes: changes, ownCommits: own, modified: Self.lastMoved(info.path))
        }
    }

    /// Removes a linked worktree's folder and its admin files; its branch stays. Refuses anything `canRemove` refuses,
    /// and git itself refuses a folder with changes (no `--force`).
    public func removeWorktree(_ status: WorktreeStatus) async throws {
        guard status.canRemove else { throw FolmiError.unsupported("这个工作树还有没提交的改动或只在这里的提交，不能清理。") }
        _ = try runner().run(["worktree", "remove", "--", status.info.path])
    }

    /// The newer of the worktree's index and HEAD modification times.
    static func lastMoved(_ root: String) -> Date? {
        let rootURL = URL(fileURLWithPath: root)
        var gitDir = rootURL.appendingPathComponent(".git")
        if let link = try? String(contentsOf: gitDir, encoding: .utf8), link.hasPrefix("gitdir:") {
            let target = link.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : rootURL.appendingPathComponent(target)
        }
        return ["index", "HEAD"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: gitDir.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }.max()
    }
}
