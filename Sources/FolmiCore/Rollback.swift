import Foundation

/// Going back in history: moving the current branch back to an earlier commit, and putting one file back to how a
/// commit left it (or found it). Both return the step that undoes them; neither ever pushes.
extension GitRepository {
    public enum RollbackMode: Sendable { case keepChanges, discardChanges }

    /// What a rollback to `target` would drop, read before asking the user.
    public struct RollbackPlan: Sendable, Equatable, Identifiable {
        public let target: String
        public let head: String
        /// Full ref of the branch that moves; nil on a detached HEAD.
        public let branch: String?
        /// Commits between `target` and HEAD that go away from the branch.
        public let commits: Int
        /// How many of them are already on a remote branch; rolling those back needs a force push to publish.
        public let pushed: Int
        public var id: String { head + target }
    }

    public func rollbackPlan(to id: String) async throws -> RollbackPlan {
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        guard let head = try await currentHead() else { throw FolmiError.unsupported("还没有任何提交。") }
        guard object != head else { throw FolmiError.unsupported("已经在这个提交上了。") }
        guard try git.run(["merge-base", "--is-ancestor", object, head], allowFailure: true).status == 0 else {
            throw FolmiError.unsupported("只能回滚到当前分支上更早的提交。")
        }
        func count(_ args: [String]) throws -> Int {
            Int(try git.run(["rev-list", "--count"] + args).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let commits = try count([object + ".." + head])
        let local = try count([object + ".." + head, "--not", "--remotes"])
        return RollbackPlan(target: object, head: head, branch: try Self.branchRef(git), commits: commits, pushed: commits - local)
    }

    /// Points the branch at `plan.target`. `keepChanges` leaves the dropped commits' changes staged (like
    /// `reset --soft`); `discardChanges` also puts the files back, carrying uncommitted changes along and refusing,
    /// before anything is written, where they would be overwritten.
    public func rollback(_ plan: RollbackPlan, mode: RollbackMode, expectedFingerprint: String) async throws -> UndoStep {
        _ = try require(expectedFingerprint)
        let git = try runner()
        let ref = try Self.refToMove(plan.branch, git)
        guard try await currentHead() == plan.head else { throw FolmiError.staleSnapshot }
        switch mode {
        case .keepChanges:
            _ = try git.run(["update-ref", "-m", "Folmi：回滚", ref, plan.target, plan.head])
            return .head(restore: plan.head, current: plan.target, branch: plan.branch)
        case .discardChanges:
            let result = try git.run(["read-tree", "-m", "-u", plan.head, plan.target], allowFailure: true)
            guard result.status == 0 else {
                throw FolmiError.unsupported("没提交的改动和要回滚的文件有重叠，回滚会覆盖它们，所以没有执行。先提交或收起改动，或者选「改动留在暂存区」。")
            }
            _ = try git.run(["update-ref", "-m", "Folmi：回滚", ref, plan.target, plan.head])
            return .reset(restore: plan.head, current: plan.target, branch: plan.branch)
        }
    }

    public enum RestoreSide: Sendable { case after, before }

    /// Writes `path` into the work tree as it was after `commit` (or before it, from its first parent). A file that
    /// did not exist there is removed. Only the work tree changes, so the result shows up as an ordinary change.
    public func restoreFile(_ path: String, from commit: String, side: RestoreSide) async throws {
        let git = try runner()
        let object = try verifiedCommit(commit, git: git)
        let root = git.directory
        var revision = object
        if side == .before {
            let parents = try git.run(["rev-list", "--parents", "-n", "1", object]).text.split(separator: " ")
            guard parents.count > 1 else {
                // The first commit: before it, nothing existed.
                try Self.writeWorktreeFile(WorktreeFile(path: path, data: nil, permissions: nil), root: root)
                return
            }
            revision = String(parents[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let entry = try git.run(["ls-tree", "-z", revision, "--", path]).text
        guard let tab = entry.firstIndex(of: "\t"), entry[entry.index(after: tab)...].trimmingCharacters(in: CharacterSet(charactersIn: "\0")) == path else {
            try Self.writeWorktreeFile(WorktreeFile(path: path, data: nil, permissions: nil), root: root)
            return
        }
        let fields = entry[..<tab].split(separator: " ")
        guard fields.count == 3, fields[1] == "blob" else { throw FolmiError.unsupported("\(path) 不是普通文件，无法恢复。") }
        // --filters gives the bytes checkout would write (line endings, smudge filters).
        let data = try git.run(["cat-file", "--filters", revision + ":" + path]).stdout
        let existing = try? Self.readWorktreeFile(path, root: root)
        let base = existing?.permissions ?? 0o644
        let permissions = fields[0] == "100755" ? base | 0o111 : base & ~0o111
        try Self.writeWorktreeFile(WorktreeFile(path: path, data: data, permissions: permissions), root: root)
    }
}
