import Foundation

/// What the history page can do with a commit. Every action keeps the user's work safe: revert and cherry-pick land
/// in the staging area (to be read and committed like any other change) and only on a clean work tree, so a conflict
/// can be rolled back without touching anything of theirs; rewording is limited to the latest, unpushed commit.
extension GitRepository {
    public struct CommitAbilities: Sendable, Equatable {
        /// Already part of the current branch (cherry-pick would do nothing useful).
        public let onCurrentBranch: Bool
        /// Some remote branch contains it, so rewriting it would diverge from what others have.
        public let pushed: Bool
        public let isHead: Bool
        public let isMerge: Bool
    }

    public func abilities(of id: String) async throws -> CommitAbilities {
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        let head = try git.run(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let onBranch = head.isEmpty ? false : try git.run(["merge-base", "--is-ancestor", object, "HEAD"], allowFailure: true).status == 0
        let remotes = try git.run(["branch", "-r", "--contains", object], allowFailure: true).text
        let parents = try git.run(["rev-list", "--parents", "-n", "1", object]).text.split(separator: " ").count - 1
        return CommitAbilities(onCurrentBranch: onBranch, pushed: !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               isHead: object == head, isMerge: parents > 1)
    }

    /// Changes the latest commit's message only; staged changes stay staged and out of the commit.
    public func reword(_ id: String, message: String, expectedFingerprint: String) async throws -> String {
        _ = try require(expectedFingerprint)
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolmiError.unsupported("提交说明不能为空。") }
        let ability = try await abilities(of: id)
        guard ability.isHead else { throw FolmiError.unsupported("只能修改当前分支最新一个提交的说明。") }
        guard !ability.pushed else { throw FolmiError.unsupported("这个提交已经推送到远端，修改说明会和远端分叉，没有修改。") }
        let git = try runner()
        _ = try git.run(["commit", "--amend", "--only", "--allow-empty", "--cleanup=verbatim", "--file=-"], input: Data(message.utf8))
        return try git.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum ApplyKind: Sendable { case revert, cherryPick }

    /// Applies the commit's change (or its inverse) to the work tree and index without committing. Needs a clean
    /// work tree; on a conflict everything is put back as it was and the error says so.
    /// `intoWorkTree` leaves the result unstaged, to be reviewed and accepted like any other change; otherwise it is
    /// staged, as `git revert --no-commit` leaves it. Returns the paths it changed.
    public func applyCommit(_ id: String, kind: ApplyKind, expectedFingerprint: String, intoWorkTree: Bool = false) async throws -> [String] {
        let current = try require(expectedFingerprint)
        guard current.files.isEmpty else { throw FolmiError.unsupported("工作区和暂存区要先清空（提交或丢弃现有改动），才能\(kind == .revert ? "撤回" : "挑选")提交。") }
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        let ability = try await abilities(of: object)
        if kind == .cherryPick, ability.onCurrentBranch { throw FolmiError.unsupported("这个提交已经在当前分支上了。") }
        if kind == .revert, !ability.onCurrentBranch { throw FolmiError.unsupported("只能撤回当前分支上的提交。") }
        var args = [kind == .revert ? "revert" : "cherry-pick", "--no-commit"]
        if ability.isMerge { args += ["-m", "1"] }
        args.append(object)
        let result = try git.run(args, allowFailure: true)
        if result.status != 0 {
            // The tree was clean, so going back to HEAD loses nothing.
            _ = try? git.run([kind == .revert ? "revert" : "cherry-pick", "--quit"], allowFailure: true)
            _ = try git.run(["reset", "--hard", "--quiet", "HEAD"])
            throw FolmiError.unsupported("\(kind == .revert ? "撤回" : "挑选")时有冲突，已恢复原样，没有改动。")
        }
        // Without committing, git still leaves its sequencer note behind; drop it so the next commit is a plain one.
        _ = try? git.run([kind == .revert ? "revert" : "cherry-pick", "--quit"], allowFailure: true)
        for ref in ["REVERT_HEAD", "CHERRY_PICK_HEAD"] { _ = try? git.run(["update-ref", "-d", ref], allowFailure: true) }
        let paths = try git.run(["diff", "--cached", "--name-only", "-z"]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
        // The tree was clean before, so the index can go back to HEAD as a whole: the result stays in the files only
        // (a file the commit added shows as new, one it removed as deleted).
        if intoWorkTree { _ = try git.run(["reset", "--quiet"]) }
        return paths
    }

    /// The message git would write for a revert or a cherry-pick, to prefill the commit box.
    public func suggestedMessage(for id: String, kind: ApplyKind) async throws -> String {
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        let body = try git.run(["show", "-s", "--format=%B", object]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .cherryPick: return body + "\n\n(cherry picked from commit \(object))\n"
        case .revert:
            let subject = body.components(separatedBy: "\n").first ?? ""
            return "Revert \"\(subject)\"\n\nThis reverts commit \(object).\n"
        }
    }

    public func createBranch(_ name: String, at id: String) async throws {
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        let check = try git.run(["check-ref-format", "--branch", name], allowFailure: true)
        guard check.status == 0, !name.hasPrefix("-") else { throw FolmiError.unsupported("「\(name)」不是有效的分支名。") }
        let exists = try git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" + name], allowFailure: true).status == 0
        guard !exists else { throw FolmiError.unsupported("分支「\(name)」已经存在。") }
        _ = try git.run(["branch", "--", name, object])
    }

    /// Files that differ between two commits (base → target), for comparing any two points in history.
    public func compareDetail(base: String, target: String) async throws -> CommitDetail {
        let git = try runner()
        let from = try verifiedCommit(base, git: git), to = try verifiedCommit(target, git: git)
        let records = try git.run(["diff-tree", "-r", "-z", "--no-renames", "--name-status", from, to]).text.components(separatedBy: "\0")
        var files: [CommitFileChange] = []
        var index = 0
        while index + 1 < records.count {
            let status = records[index]
            if !status.isEmpty { files.append(CommitFileChange(path: records[index + 1], status: String(status.prefix(1)))) }
            index += 2
        }
        let meta = try git.run(["show", "-s", "--format=%cn%x00%ct", to]).text.split(separator: "\0").map(String.init)
        return CommitDetail(id: to, message: "", committer: meta.first ?? "",
                            committerDate: Date(timeIntervalSince1970: TimeInterval(meta.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0),
                            files: files)
    }

    /// One file's change between two commits. Read only.
    public func compareDiff(base: String, target: String, file: CommitFileChange) async throws -> FileDiff {
        let git = try runner()
        let from = try verifiedCommit(base, git: git), to = try verifiedCommit(target, git: git)
        let bytes = try git.run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--full-index",
                                 "--unified=3", from, to, "--", file.path]).stdout
        let change = FileChange(path: file.path, indexCode: file.status, worktreeCode: ".")
        guard let raw = UTF8Text.decode(bytes) else {
            return FileDiff(file: change, area: .staged, rawPatch: "", hunks: [], fingerprint: from + to + file.path,
                            isPartialSupported: false, notice: "差异包含非 UTF-8 文本，无法显示。")
        }
        let hunks = Patch.hunks(raw)
        let notice: String? = raw.contains("Binary files ") || raw.contains("GIT binary patch") ? "二进制文件，无法显示文本差异。"
            : (hunks.isEmpty ? "没有文本差异（可能只是文件模式变化）。" : nil)
        return FileDiff(file: change, area: .staged, rawPatch: raw, hunks: hunks, fingerprint: from + "\0" + to + "\0" + file.path,
                        isPartialSupported: false, notice: notice,
                        versions: FileVersions(old: .object(from + ":" + file.path), new: .object(to + ":" + file.path)))
    }
}
