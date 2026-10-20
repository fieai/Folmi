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

extension GitRepository {
    public func worktrees() async throws -> [WorktreeInfo] {
        let result = try runner().run(["worktree", "list", "--porcelain"], allowFailure: true)
        guard result.status == 0 else { return [] }
        return WorktreeInfo.parse(result.text)
    }
}
