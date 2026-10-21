import Foundation

/// Bringing the remote's commits in. Fetching only moves remote-tracking refs and never touches the user's files;
/// pulling is fast-forward by default, and rebase or merge (for a diverged branch) need a clean work tree so that
/// aborting a conflict puts everything back exactly as it was.
extension GitRepository {
    /// Fetches every remote quietly: no prompts (terminal, SSH passphrase), a time limit, no auto gc. Runs outside the
    /// actor so a slow network never holds up reading the status. Returns false when the project has no remote.
    public static func fetch(root: URL, environment: [String: String] = [:], timeout: TimeInterval = 90) throws -> Bool {
        var env = environment
        let probe = GitProcess(directory: root, environment: env)
        let remotes = try probe.run(["remote"]).text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !remotes.isEmpty else { return false }
        // Batch mode makes ssh fail instead of asking for a passphrase; a configured ssh command is left alone.
        let configured = try probe.run(["config", "--get", "core.sshCommand"], allowFailure: true).text
        if env["GIT_SSH_COMMAND"] == nil, ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil,
           configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        }
        env["GIT_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS"] = "/usr/bin/false"
        _ = try GitProcess(directory: root, environment: env)
            .run(["-c", "gc.auto=0", "-c", "credential.interactive=never", "fetch", "--all", "--prune", "--quiet"], timeout: timeout)
        return true
    }

    public enum PullKind: String, Sendable, CaseIterable { case fastForward, rebase, merge }

    /// What a pull would do right now, read before anything runs.
    public struct PullPlan: Sendable, Equatable {
        public let branch: String
        /// The upstream's short name, e.g. origin/main.
        public let upstream: String
        public let head: String
        /// The upstream commit the pull will bring in; a fetch that moves it in between makes the plan stale.
        public let target: String
        public let ahead: Int
        public let behind: Int
        public let fingerprint: String
        /// Tracked files have changes; only a fast-forward that git can carry them through is possible.
        public let hasTrackedChanges: Bool
        public var upToDate: Bool { behind == 0 }
        public var diverged: Bool { ahead > 0 && behind > 0 }

        /// The command each way runs, as shown in the preview.
        public func command(_ kind: PullKind) -> String {
            switch kind {
            case .fastForward: return "git merge --ff-only \(upstream)"
            case .rebase: return "git rebase \(upstream)"
            case .merge: return "git merge --no-edit \(upstream)"
            }
        }
        /// Why this way cannot run, or nil when it can.
        public func blocked(_ kind: PullKind) -> String? {
            if upToDate { return "已经是最新的，没有可拉取的提交。" }
            switch kind {
            case .fastForward: return ahead > 0 ? "本地有 \(ahead) 个提交远端没有，不能直接快进；选择变基或合并。" : nil
            case .rebase, .merge:
                return hasTrackedChanges ? "工作区或暂存区有改动。先提交或暂放改动，\(kind == .rebase ? "变基" : "合并")遇到冲突时才能完整恢复。" : nil
            }
        }
    }

    public func pullPlan() async throws -> PullPlan {
        let current = try state(), git = try runner()
        guard let head = current.head else { throw FolmiError.unsupported("项目还没有提交。") }
        guard current.branch != "(detached)", current.branch != "HEAD" else { throw FolmiError.unsupported("当前不在分支上（游离的 HEAD），无法拉取。") }
        guard let upstream = current.upstream else {
            throw FolmiError.unsupported("分支「\(current.branch)」没有设置上游分支，不知道从哪里拉取。可以在终端里运行 git branch --set-upstream-to=origin/\(current.branch)。")
        }
        guard try operationInProgress(git) == nil else { throw FolmiError.unsupported("还有没完成的变基或合并，先继续或放弃它。") }
        let target = try git.run(["rev-parse", "--verify", "--quiet", "@{upstream}^{commit}"], allowFailure: true)
        guard target.status == 0 else { throw FolmiError.unsupported("上游分支 \(upstream) 还没有取回到本地，先取回一次。") }
        let counts = try git.run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]).text.split(whereSeparator: \.isWhitespace)
        return PullPlan(branch: current.branch, upstream: upstream, head: head, target: target.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        ahead: counts.first.flatMap { Int($0) } ?? 0, behind: counts.dropFirst().first.flatMap { Int($0) } ?? 0,
                        fingerprint: current.fingerprint, hasTrackedChanges: current.files.contains { !$0.isUntracked })
    }

    public enum PullOutcome: Sendable, Equatable {
        /// HEAD moved from `before` to `after`.
        case done(before: String, after: String)
        /// Stopped on a conflict; the operation is still in progress for the user to finish or abort.
        case conflict(RepositoryOperation, files: [String])
    }

    /// Runs the planned pull after checking nothing moved since the plan was read (files, HEAD, the upstream).
    public func pull(_ kind: PullKind, plan: PullPlan) async throws -> PullOutcome {
        let current = try require(plan.fingerprint), git = try runner()
        let target = try git.run(["rev-parse", "--verify", "--quiet", "@{upstream}^{commit}"], allowFailure: true).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.head == plan.head, current.branch == plan.branch, target == plan.target else { throw FolmiError.staleSnapshot }
        let fresh = try await pullPlan()
        if let reason = fresh.blocked(kind) { throw FolmiError.unsupported(reason) }
        switch kind {
        case .fastForward:
            let result = try git.run(["merge", "--ff-only", "--quiet", plan.target], allowFailure: true)
            guard result.status == 0 else {
                // git checks before writing anything, so nothing changed.
                let message = String(decoding: result.stderr, as: UTF8.self)
                if message.contains("would be overwritten") {
                    throw FolmiError.unsupported("远端改动和你没提交的改动碰到了同一些文件，没有拉取。先提交或暂放这些改动再拉取。")
                }
                throw FolmiError.git(exitCode: result.status, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .rebase:
            let result = try editorless().run(["rebase", "--quiet", plan.target], allowFailure: true)
            if result.status != 0 {
                if try operationInProgress(git) == .rebase { return .conflict(.rebase, files: try conflictedFiles(git)) }
                throw FolmiError.git(exitCode: result.status, message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .merge:
            let message = "Merge remote-tracking branch '\(plan.upstream)' into \(plan.branch)"
            let result = try editorless().run(["merge", "--no-edit", "--quiet", "-m", message, plan.target], allowFailure: true)
            if result.status != 0 {
                if try operationInProgress(git) == .merge { return .conflict(.merge, files: try conflictedFiles(git)) }
                throw FolmiError.git(exitCode: result.status, message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return .done(before: plan.head, after: try await currentHead() ?? plan.head)
    }

    /// Rebases the current commits onto `target`, a commit already fetched (the delivery target's latest), so a push or
    /// a Gerrit review sits on top of what the remote has now. Same rules as a pull by rebase: nothing moved since the
    /// plan was read, a clean work tree, and a conflict stops half way for the user to finish or abort.
    public func rebase(onto target: String, expectedFingerprint: String, expectedHead: String) async throws -> PullOutcome {
        let current = try require(expectedFingerprint), git = try runner()
        guard current.head == expectedHead else { throw FolmiError.staleSnapshot }
        guard try operationInProgress(git) == nil else { throw FolmiError.unsupported("还有没完成的变基或合并，先继续或放弃它。") }
        guard !current.files.contains(where: { !$0.isUntracked }) else {
            throw FolmiError.unsupported("工作区或暂存区有改动。先提交或暂放改动，变基遇到冲突时才能完整恢复。")
        }
        let result = try editorless().run(["rebase", "--quiet", target], allowFailure: true)
        if result.status != 0 {
            if try operationInProgress(git) == .rebase { return .conflict(.rebase, files: try conflictedFiles(git)) }
            throw FolmiError.git(exitCode: result.status, message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .done(before: expectedHead, after: try await currentHead() ?? expectedHead)
    }

    /// Goes on with a rebase after the conflicts are resolved and staged; it may stop again on the next commit.
    /// A merge is finished by committing (the commit box makes the merge commit).
    public func continueRebase(expectedFingerprint: String) async throws -> PullOutcome? {
        let current = try require(expectedFingerprint), git = try runner()
        guard try operationInProgress(git) == .rebase else { throw FolmiError.unsupported("没有进行中的变基。") }
        guard !current.files.contains(where: \.isConflict) else { throw FolmiError.unsupported("还有冲突没解决：解决后暂存这些文件，再继续。") }
        let result = try editorless().run(["rebase", "--continue"], allowFailure: true)
        if try operationInProgress(git) == .rebase {
            if result.status == 0 { return nil }
            let files = try conflictedFiles(git)
            if files.isEmpty {
                throw FolmiError.git(exitCode: result.status, message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .conflict(.rebase, files: files)
        }
        guard result.status == 0 else {
            throw FolmiError.git(exitCode: result.status, message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Gives up the rebase or merge in progress: the branch and files go back to just before it started.
    public func abortOperation() async throws -> RepositoryOperation {
        let git = try runner()
        guard let operation = try operationInProgress(git) else { throw FolmiError.unsupported("没有进行中的变基或合并。") }
        _ = try git.run([operation == .rebase ? "rebase" : "merge", "--abort"])
        return operation
    }

    func operationInProgress(_ git: GitProcess) throws -> RepositoryOperation? {
        let known = try gitPaths(git)
        let paths = [known.rebaseMerge, known.rebaseApply, known.mergeHead]
        let manager = FileManager.default
        if paths.prefix(2).contains(where: { manager.fileExists(atPath: $0.path) }) { return .rebase }
        if let merge = paths.last, paths.count == 3, manager.fileExists(atPath: merge.path) { return .merge }
        return nil
    }

    private func conflictedFiles(_ git: GitProcess) throws -> [String] {
        try git.run(["diff", "--name-only", "--diff-filter=U", "-z"]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
    }

    /// Git commands that would open an editor (rebase --continue, merge messages) take the prepared text instead.
    private func editorless() throws -> GitProcess {
        let git = try runner()
        var env = git.environment
        env["GIT_EDITOR"] = "true"; env["GIT_SEQUENCE_EDITOR"] = "true"
        return GitProcess(directory: git.directory, environment: env)
    }
}
