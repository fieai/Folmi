import Foundation

/// Merging another local branch into the current one, and folding the latest unpushed commits into one. Both are read
/// as a plan first (what comes in, whether it will conflict, why it cannot run) and return what undoes them; neither
/// ever pushes.
extension GitRepository {
    // MARK: Merge a branch

    /// What merging `source` into the current branch would do, read before anything runs.
    public struct MergePlan: Sendable, Equatable, Identifiable {
        /// The branch being merged in (short name).
        public let source: String
        public let sourceCommit: String
        /// The current branch (short name).
        public let branch: String
        public let head: String
        /// Commits on `source` that the current branch does not have.
        public let incoming: Int
        /// The current branch has nothing of its own, so it just moves forward to `source`.
        public let fastForward: Bool
        /// Files a real merge would stop on, worked out with `git merge-tree` without touching anything.
        public let conflicts: [String]
        public let fingerprint: String
        public let hasTrackedChanges: Bool
        public var id: String { head + sourceCommit }

        /// Why the merge cannot run, or nil when it can.
        public var blocked: String? {
            if incoming == 0 { return "「\(source)」的提交都已经在当前分支上了，没有要合并的。" }
            if !fastForward && hasTrackedChanges { return "工作区或暂存区有改动。先提交或暂放改动，合并遇到冲突时才能完整恢复。" }
            return nil
        }
    }

    public func mergePlan(_ source: String) async throws -> MergePlan {
        let current = try state(), git = try runner()
        guard let head = current.head else { throw FolmiError.unsupported("项目还没有提交。") }
        guard current.branch != "(detached)", current.branch != "HEAD" else { throw FolmiError.unsupported("当前不在分支上（游离的 HEAD），无法合并。") }
        guard source != current.branch else { throw FolmiError.unsupported("不能把分支合并进它自己。") }
        guard try operationInProgress(git) == nil else { throw FolmiError.unsupported("还有没完成的变基或合并，先继续或放弃它。") }
        let resolved = try git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(source)^{commit}"], allowFailure: true)
        guard resolved.status == 0, !source.hasPrefix("-") else { throw FolmiError.unsupported("找不到本地分支「\(source)」。") }
        let commit = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = Int(try git.run(["rev-list", "--count", "HEAD..\(commit)"]).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let fastForward = try git.run(["merge-base", "--is-ancestor", "HEAD", commit], allowFailure: true).status == 0
        var conflicts: [String] = []
        if incoming > 0, !fastForward {
            let merged = try git.run(["merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", commit], allowFailure: true)
            if merged.status == 1 { conflicts = Array(Set(merged.text.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty })).sorted() }
        }
        return MergePlan(source: source, sourceCommit: commit, branch: current.branch, head: head, incoming: incoming,
                         fastForward: fastForward, conflicts: conflicts, fingerprint: current.fingerprint,
                         hasTrackedChanges: current.files.contains { !$0.isUntracked })
    }

    /// Runs the planned merge after checking nothing moved since the plan was read. A conflict stops half way, the
    /// same as a pull by merge: resolve, stage, and commit to finish, or abort to go back.
    public func merge(_ plan: MergePlan) async throws -> PullOutcome {
        let current = try require(plan.fingerprint), git = try runner()
        let source = try git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(plan.source)^{commit}"], allowFailure: true).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.head == plan.head, current.branch == plan.branch, source == plan.sourceCommit else { throw FolmiError.staleSnapshot }
        if let reason = plan.blocked { throw FolmiError.unsupported(reason) }
        let result = try editorless().run(["merge", "--no-edit", "--quiet", "refs/heads/\(plan.source)"], allowFailure: true)
        if result.status != 0 {
            if try operationInProgress(git) == .merge { return .conflict(.merge, files: try conflictedFiles(git)) }
            let message = String(decoding: result.stderr, as: UTF8.self)
            if message.contains("would be overwritten") {
                throw FolmiError.unsupported("「\(plan.source)」的改动会覆盖你没提交的改动或新文件，没有合并。先提交或暂放这些改动再合并。")
            }
            throw FolmiError.git(exitCode: result.status, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .done(before: plan.head, after: try await currentHead() ?? plan.head)
    }

    // MARK: Fold commits into one

    /// Folding the commits from `oldest` up to HEAD into one commit, read before asking for the message.
    public struct SquashPlan: Sendable, Equatable, Identifiable {
        /// The commit the new one sits on; nil when `oldest` is the first commit of the project.
        public let base: String?
        public let oldest: String
        public let head: String
        /// Full ref of the current branch.
        public let branch: String
        public let count: Int
        /// git's raw author line pieces of `oldest`, kept on the new commit (as `git rebase` squash does).
        public let authorName: String
        public let authorEmail: String
        public let authorDate: String
        public let suggestedMessage: String
        public var id: String { head + oldest }
    }

    public func squashPlan(from id: String) async throws -> SquashPlan {
        let git = try runner()
        let oldest = try verifiedCommit(id, git: git)
        guard let head = try await currentHead() else { throw FolmiError.unsupported("还没有任何提交。") }
        guard let branch = try Self.branchRef(git) else { throw FolmiError.unsupported("当前不在分支上（游离的 HEAD），无法合并提交。") }
        guard try operationInProgress(git) == nil else { throw FolmiError.unsupported("还有没完成的变基或合并，先继续或放弃它。") }
        guard oldest != head else { throw FolmiError.unsupported("选中的已经是最新的提交；选更早的一个，从它到最新的提交会合并成一个。") }
        guard try git.run(["merge-base", "--is-ancestor", oldest, head], allowFailure: true).status == 0 else {
            throw FolmiError.unsupported("只能合并当前分支上的提交。")
        }
        let parent = try git.run(["rev-parse", "--verify", "--quiet", oldest + "^1"], allowFailure: true)
        let base = parent.status == 0 ? parent.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let range = base.map { [$0 + ".." + head] } ?? [head]
        func count(_ extra: [String]) throws -> Int {
            Int(try git.run(["rev-list", "--count"] + extra + range).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        guard try count(["--merges"]) == 0 else { throw FolmiError.unsupported("这些提交里有合并提交，没法直接合成一个。") }
        let total = try count([])
        let local = Int(try git.run(["rev-list", "--count"] + range + ["--not", "--remotes"]).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard local == total else {
            throw FolmiError.unsupported("其中 \(total - local) 个提交已经推送到远端，合并后会和远端分叉，没有合并。只能合并还没推送的提交。")
        }
        let log = try git.run(["log", "--reverse", "--format=%B%x01"] + range).text
        let messages = log.components(separatedBy: "\u{1}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let author = try git.run(["show", "-s", "--date=raw", "--format=%an%x00%ae%x00%ad", oldest]).text
            .trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard author.count == 3 else { throw FolmiError.unsupported("无法读取提交的作者。") }
        return SquashPlan(base: base, oldest: oldest, head: head, branch: branch, count: total,
                          authorName: author[0], authorEmail: author[1], authorDate: author[2],
                          suggestedMessage: Self.squashMessage(messages))
    }

    /// Writes one commit with HEAD's tree on top of `plan.base` and points the branch at it. The work tree and the
    /// staging area are not touched, so uncommitted changes stay exactly where they are.
    public func squash(_ plan: SquashPlan, message: String, expectedFingerprint: String) async throws -> UndoStep {
        _ = try require(expectedFingerprint)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FolmiError.unsupported("提交说明不能为空。") }
        let git = try runner()
        guard try await currentHead() == plan.head, try Self.branchRef(git) == plan.branch else { throw FolmiError.staleSnapshot }
        let tree = try git.run(["rev-parse", "HEAD^{tree}"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["commit-tree", tree]
        if let base = plan.base { args += ["-p", base] }
        // commit-tree does not read commit.gpgSign itself; a project that signs its commits gets a signed one here too.
        if try git.run(["config", "--bool", "--get", "commit.gpgsign"], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            args.append("-S")
        }
        args += ["-F", "-"]
        var env = git.environment
        env["GIT_AUTHOR_NAME"] = plan.authorName; env["GIT_AUTHOR_EMAIL"] = plan.authorEmail; env["GIT_AUTHOR_DATE"] = plan.authorDate
        let commit = try GitProcess(directory: git.directory, environment: env).run(args, input: Data((text + "\n").utf8))
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git.run(["update-ref", "-m", "Folmi：合并 \(plan.count) 个提交", plan.branch, commit, plan.head])
        return .head(restore: plan.head, current: commit, branch: plan.branch)
    }

    /// The oldest commit's message, the later ones' subjects as a list, and the trailers kept once at the end. Only the
    /// oldest commit's Change-Id survives: Gerrit treats the folded commit as that change.
    static func squashMessage(_ messages: [String]) -> String {
        func split(_ message: String) -> (body: String, trailers: [String]) {
            let paragraphs = message.components(separatedBy: "\n\n")
            guard paragraphs.count > 1, let last = paragraphs.last else { return (message, []) }
            let lines = last.components(separatedBy: "\n").filter { !$0.isEmpty }
            let isTrailer = { (line: String) in line.range(of: #"^[A-Za-z0-9-]+: \S"#, options: .regularExpression) != nil }
            guard !lines.isEmpty, lines.allSatisfy(isTrailer) else { return (message, []) }
            return (paragraphs.dropLast().joined(separator: "\n\n"), lines)
        }
        guard let first = messages.first else { return "" }
        let (body, firstTrailers) = split(first)
        var trailers = firstTrailers
        var subjects: [String] = []
        for message in messages.dropFirst() {
            let (rest, own) = split(message)
            if let subject = rest.components(separatedBy: "\n").first, !subject.isEmpty { subjects.append("- " + subject) }
            for trailer in own where !trailer.hasPrefix("Change-Id:") && !trailers.contains(trailer) { trailers.append(trailer) }
        }
        var parts = [body]
        if !subjects.isEmpty { parts.append(subjects.joined(separator: "\n")) }
        if !trailers.isEmpty { parts.append(trailers.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n") + "\n"
    }
}
