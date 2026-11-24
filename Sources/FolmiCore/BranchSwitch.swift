import Foundation

public enum BranchSwitchTarget: Sendable, Equatable {
    case local(String)
    case new(String)
    case remote(RemoteBranch, name: String)

    public var name: String {
        switch self { case .local(let name), .new(let name), .remote(_, let name): return name }
    }
}

public struct BranchSwitchPlan: Sendable, Equatable {
    public let target: BranchSwitchTarget
    public let fingerprint: String
    public let blocker: String?
    public let canStash: Bool
    let object: String
}

public struct BranchPosition: Sendable, Equatable {
    let branch: String?
    let object: String?
}

public enum BranchSwitchUndo: Sendable, Equatable {
    case move(restore: BranchPosition, current: BranchPosition)
    case removeCreated(restore: BranchPosition, current: BranchPosition, upstream: RemoteBranch?)
    case recreate(restore: BranchPosition, current: BranchPosition, upstream: RemoteBranch?)
}

extension GitRepository {
    /// Git's two-way checkout check leaves the index and work tree alone.
    public func prepareBranchSwitch(_ target: BranchSwitchTarget, expectedFingerprint: String) async throws -> BranchSwitchPlan {
        let current = try require(expectedFingerprint)
        let git = try runner()
        let object = try switchObject(target, current: current, git: git)
        var blocker: String?
        var canStash = false
        if let head = current.head, head != object {
            let check = try git.run(["read-tree", "--dry-run", "-m", "-u", "--no-recurse-submodules", head, object], allowFailure: true)
            if check.status != 0 {
                let changed = try git.run(["diff", "--name-only", "--no-renames", "-z", head, object]).text
                let paths = Set(changed.split(separator: "\0").map(String.init))
                let dirty = Set(current.files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
                let overlap = Self.overlappingPaths(dirty, with: paths)
                canStash = !overlap.isEmpty && !current.files.contains { $0.isSubmodule && overlap.contains($0.path) }
                blocker = canStash
                    ? "切换分支会碰到这些没提交的改动：\n" + overlap.sorted().prefix(8).joined(separator: "\n")
                    : String(decoding: check.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return BranchSwitchPlan(target: target, fingerprint: current.fingerprint, blocker: blocker, canStash: canStash, object: object)
    }

    @discardableResult
    public func checkout(branch: String, expectedFingerprint: String) async throws -> UndoStep {
        let current = try require(expectedFingerprint)
        let target = BranchSwitchTarget.local(branch)
        let object = try switchObject(target, current: current, git: runner())
        let plan = BranchSwitchPlan(target: target, fingerprint: current.fingerprint, blocker: nil, canStash: false, object: object)
        return try await checkout(plan)
    }

    /// For a stash-then-switch, pass the fingerprint after stashing. The previewed target still has to match.
    public func checkout(_ plan: BranchSwitchPlan, afterStashing fingerprint: String? = nil) async throws -> UndoStep {
        if fingerprint == nil, let blocker = plan.blocker { throw FolmiError.unsupported(blocker) }
        let current = try require(fingerprint ?? plan.fingerprint)
        let git = try runner()
        let object = try switchObject(plan.target, current: current, git: git)
        guard object == plan.object else { throw FolmiError.staleSnapshot }
        let before = try BranchPosition(branch: Self.branchRef(git).map { String($0.dropFirst("refs/heads/".count)) }, object: current.head)
        let after = BranchPosition(branch: plan.target.name, object: object)
        switch plan.target {
        case .local:
            try switchTo(after, git: git)
            return .branchSwitch(.move(restore: before, current: after))
        case .new:
            try createAndSwitch(after, tracking: nil, git: git)
            return .branchSwitch(.removeCreated(restore: before, current: after, upstream: nil))
        case .remote(let remote, _):
            try createAndSwitch(after, tracking: remote, git: git)
            return .branchSwitch(.removeCreated(restore: before, current: after, upstream: remote))
        }
    }

    private func switchObject(_ target: BranchSwitchTarget, current: State, git: GitProcess) throws -> String {
        guard try operationInProgress(git) == nil, !current.files.contains(where: \.isConflict) else {
            throw FolmiError.unsupported("先完成当前的冲突处理，再切换分支。")
        }
        try validBranchName(target.name, git: git)
        let ref = "refs/heads/" + target.name
        if case .local = target {
            guard let object = try refObject(ref, git: git) else { throw FolmiError.unsupported("本地分支「\(target.name)」不存在。") }
            let trees = WorktreeInfo.parse(try git.run(["worktree", "list", "--porcelain"]).text)
            if current.branch != target.name, let holder = trees.first(where: { $0.branch == target.name }) {
                throw FolmiError.unsupported("分支「\(target.name)」正在另一个工作树使用：\n\(holder.path)")
            }
            return object
        }
        guard try refObject(ref, git: git) == nil else { throw FolmiError.unsupported("本地分支「\(target.name)」已经存在。") }
        if case .remote(let remote, _) = target {
            guard let object = try refObject(remote.ref, git: git) else { throw FolmiError.unsupported("远端分支「\(remote.id)」不存在。") }
            return object
        }
        guard let head = current.head else { throw FolmiError.unsupported("先完成第一次提交，再从当前提交新建分支。") }
        return head
    }

    // Both switch and its inverse use Git's overwrite checks, including ignored files and linked worktrees.
    private static let switchArguments = ["switch", "--no-guess", "--no-overwrite-ignore", "--no-recurse-submodules"]

    private func switchTo(_ position: BranchPosition, git: GitProcess) throws {
        if let branch = position.branch {
            guard try refObject("refs/heads/" + branch, git: git) == position.object else { throw FolmiError.staleSnapshot }
            let args = position.object == nil ? ["--orphan", branch] : ["--", branch]
            _ = try git.run(Self.switchArguments + args)
        } else if let object = position.object {
            _ = try git.run(Self.switchArguments + ["--detach", object])
        }
    }

    private func createAndSwitch(_ position: BranchPosition, tracking upstream: RemoteBranch?, git: GitProcess) throws {
        guard let branch = position.branch, let object = position.object,
              try refObject("refs/heads/" + branch, git: git) == nil else { throw FolmiError.staleSnapshot }
        if let upstream {
            guard try refObject(upstream.ref, git: git) == object else { throw FolmiError.staleSnapshot }
            _ = try git.run(Self.switchArguments + ["--track", "-c", branch, upstream.ref])
        } else {
            _ = try git.run(Self.switchArguments + ["--no-track", "-c", branch, object])
        }
    }

    func undoBranchSwitch(_ change: BranchSwitchUndo) throws -> UndoStep {
        let git = try runner()
        let state = try state()
        func verify(_ position: BranchPosition) throws {
            guard try operationInProgress(git) == nil,
                  try Self.branchRef(git) == position.branch.map({ "refs/heads/" + $0 }), state.head == position.object else {
                throw FolmiError.unsupported("分支或提交已经变了，无法撤销这次切换。")
            }
        }
        switch change {
        case .move(let restore, let current):
            try verify(current)
            try switchTo(restore, git: git)
            return .branchSwitch(.move(restore: current, current: restore))
        case .removeCreated(let restore, let current, let upstream):
            try verify(current)
            guard let branch = current.branch else { throw FolmiError.staleSnapshot }
            try switchTo(restore, git: git)
            do { _ = try git.run(["branch", "-D", "--", branch]) }
            catch { try? switchTo(current, git: git); throw error }
            return .branchSwitch(.recreate(restore: current, current: restore, upstream: upstream))
        case .recreate(let restore, let current, let upstream):
            try verify(current)
            try createAndSwitch(restore, tracking: upstream, git: git)
            return .branchSwitch(.removeCreated(restore: current, current: restore, upstream: upstream))
        }
    }

    /// Git also treats a changed file as overlapping with a directory that would replace it, and vice versa.
    static func overlappingPaths(_ paths: Set<String>, with others: Set<String>) -> Set<String> {
        func parents(of path: String) -> [String] {
            path.indices.filter { path[$0] == "/" }.map { String(path[..<$0]) }
        }
        let directories = Set(others.flatMap { parents(of: $0) })
        return paths.filter { others.contains($0) || directories.contains($0) || parents(of: $0).contains(where: others.contains) }
    }
}
