import Foundation

/// Putting all changes aside and bringing them back. Stashes are addressed by their commit object, never by
/// position (`stash@{n}` shifts as entries come and go), and are looked up again right before each action.
public struct StashEntry: Identifiable, Sendable, Equatable {
    /// The stash commit; stable while the entry exists.
    public let id: String
    /// Position in `git stash list` when it was read (stash@{index}).
    public let index: Int
    public let date: Date
    /// The branch it was made on, from git's "On main:" / "WIP on main:".
    public let branch: String
    public let message: String
    public init(id: String, index: Int, date: Date, branch: String, message: String) {
        self.id = id; self.index = index; self.date = date; self.branch = branch; self.message = message
    }
}

/// How to undo a stash action; `GitRepository.undo` runs it and returns the opposite.
public enum StashUndo: Sendable, Equatable {
    /// Bring this stash back into the work tree and index, and take it off the list.
    case pop(object: String)
    /// Put every change (untracked included) aside again under this message.
    case push(message: String, expectedFingerprint: String? = nil)
    /// Put this commit back on the stash list (after a drop).
    case store(object: String, message: String)
    /// Take this commit off the stash list again.
    case drop(object: String, message: String)
}

public struct StashedFile: Identifiable, Sendable, Equatable {
    public let change: CommitFileChange
    public var id: String { change.path }
    let base: String
    let target: String
}

public struct StashRestorePlan: Sendable {
    public let files: [StashedFile]
    public let conflicts: [String]
    public let blocker: String?
    fileprivate let paths: Set<String>
    fileprivate var worktree: StashTreeChange?
    fileprivate var index: StashTreeChange?
    fileprivate var untracked: StashTreeChange?
}

private struct StashTreeChange: Sendable {
    let tree: String
    let paths: [String]

    func restore(to area: String, git: GitProcess) throws {
        guard !paths.isEmpty else { return }
        _ = try git.run(["restore", "--source=" + tree, area, "--no-recurse-submodules",
                         "--pathspec-from-file=-", "--pathspec-file-nul"], input: GitRepository.pathspecs(paths))
    }
}

extension GitRepository {
    public func stashes() async throws -> [StashEntry] {
        try stashList(try runner())
    }

    func stashList(_ git: GitProcess) throws -> [StashEntry] {
        Self.parseStashList(try git.run(Self.stashListArguments, allowFailure: true).text)
    }
    static let stashListArguments = ["stash", "list", "-z", "--format=%H%x01%ct%x01%gs"]
    static func parseStashList(_ text: String) -> [StashEntry] {
        text.components(separatedBy: "\0").filter { !$0.isEmpty }.enumerated().compactMap { index, record in
            let fields = record.components(separatedBy: "\u{1}")
            guard fields.count == 3 else { return nil }
            let (branch, message) = Self.splitStashSubject(fields[2])
            return StashEntry(id: fields[0].trimmingCharacters(in: .whitespacesAndNewlines), index: index,
                              date: Date(timeIntervalSince1970: TimeInterval(fields[1]) ?? 0), branch: branch, message: message)
        }
    }

    /// "On main: message" / "WIP on main: abc123 subject" → ("main", "message").
    static func splitStashSubject(_ subject: String) -> (branch: String, message: String) {
        for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { break }
            let message = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (String(rest[..<colon]), message)
        }
        return ("", subject)
    }

    /// Puts every change aside, untracked files included, and leaves the work tree and index at HEAD.
    /// Returns the new stash entry.
    @discardableResult
    public func stashAll(message: String, expectedFingerprint: String) async throws -> StashEntry {
        try stash(message: message, workingOnly: false, expectedFingerprint: expectedFingerprint)
    }

    public func stashWorking(message: String, expectedFingerprint: String) async throws -> StashEntry {
        try stash(message: message, workingOnly: true, expectedFingerprint: expectedFingerprint)
    }

    private func stash(message: String, workingOnly: Bool, expectedFingerprint: String) throws -> StashEntry {
        let current = try require(expectedFingerprint)
        let git = try runner()
        guard current.head != nil else { throw FolmiError.unsupported("项目还没有提交，不能暂放改动。") }
        guard current.files.contains(where: { !workingOnly || $0.hasWorking }) else { throw FolmiError.unsupported("没有可以暂放的改动。") }
        guard !current.files.contains(where: \.isConflict) else { throw FolmiError.unsupported("有冲突没解决，先解决冲突再暂放。") }
        guard try operationInProgress(git) == nil else { throw FolmiError.unsupported("变基或合并还没完成，先继续或放弃它。") }
        let entry = try pushStash(message: message, keepingIndex: workingOnly)
        guard workingOnly, current.files.contains(where: \.hasStaged) else { return entry }

        // --keep-index protects the real index, but still records its contents relative to HEAD. Make the
        // saved index tree the base of a standard stash so its diff contains only the work-tree changes.
        do {
            let base = try git.run(["rev-parse", entry.id + "^2"]).text.trimmingCharacters(in: .newlines)
            let index = try stashCommit(tree: base + "^{tree}", parents: [base], message: "Folmi index", git: git)
            let untracked = try refObject(entry.id + "^3", git: git)
            let subject = Self.storedMessage(entry)
            let object = try stashCommit(tree: entry.id + "^{tree}", parents: [base, index] + [untracked].compactMap { $0 },
                                         message: subject, git: git)
            _ = try git.run(["stash", "store", "--message", subject, object])
            try drop(entry.id, git: git)
            guard let saved = try stashList(git).first(where: { $0.id == object }) else { throw FolmiError.staleSnapshot }
            return saved
        } catch {
            throw FolmiError.unsupported("改动已存进「\(entry.message)」。生成只含工作区的记录时失败：\(error.localizedDescription)")
        }
    }

    private func stashCommit(tree: String, parents: [String], message: String, git: GitProcess) throws -> String {
        let args = ["-c", "user.name=Folmi", "-c", "user.email=folmi@localhost", "commit-tree", tree, "--no-gpg-sign"]
        return try git.run(args + parents.flatMap { ["-p", $0] } + ["-F", "-"], input: Data((message + "\n").utf8))
            .text.trimmingCharacters(in: .newlines)
    }

    private func pushStash(message: String, keepingIndex: Bool = false) throws -> StashEntry {
        let git = try runner()
        let before = try stashList(git).first?.id
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = ["stash", "push", "--include-untracked", "--quiet", "--message", text.isEmpty ? "Folmi" : text]
        _ = try git.run(args + (keepingIndex ? ["--keep-index"] : []), literalPathspecs: false)
        guard let entry = try stashList(git).first, entry.id != before else { throw FolmiError.unsupported("没有可以暂放的改动。") }
        return entry
    }

    /// Brings a stash back and removes it from the list. Undo puts the same stash object back.
    @discardableResult
    public func popStash(_ id: String, expectedFingerprint: String) async throws -> UndoStep {
        let current = try require(expectedFingerprint)
        let git = try runner()
        guard let entry = try stashList(git).first(where: { $0.id == id }) else {
            throw FolmiError.unsupported("这份暂放的改动已经不在了。")
        }
        let plan = try stashPlan(entry.id, current: current, git: git, indexTree: stashIndexTree(current, git: git))
        if let blocker = plan.blocker { throw FolmiError.unsupported(blocker) }
        let hasTrackedChanges = current.files.contains { !$0.isUntracked }
        let paths = plan.paths.sorted()
        let before: UndoStep?
        do {
            before = .group([.stash(.store(object: id, message: Self.storedMessage(entry))),
                             try await captureIndex(paths), try await captureWorktree(paths, allowLargeFiles: true)])
        } catch {
            guard !hasTrackedChanges else { throw error }
            before = nil
        }
        _ = try require(expectedFingerprint)
        do {
            if hasTrackedChanges {
                guard let worktree = plan.worktree else { throw FolmiError.staleSnapshot }
                // stash apply can refresh unrelated index entries, then refuse their unstaged edits.
                // Use the same three-way tree result and update only the files that changed.
                try worktree.restore(to: "--worktree", git: git)
                try plan.index?.restore(to: "--staged", git: git)
                try plan.untracked?.restore(to: "--worktree", git: git)
                try drop(id, git: git)
            } else {
                try restoreStash(id, git: git)
            }
            if let before {
                do {
                    _ = try await recapture(before)
                    return before
                } catch {
                    if hasTrackedChanges { throw error }
                }
            }
            return try .stash(.push(message: entry.message, expectedFingerprint: state().fingerprint))
        } catch {
            // A failed apply can leave some entries behind. When other tracked changes are present, roll
            // back only the stash's paths, never reset the whole work tree.
            let hasConflicts = (try? state().files.contains(where: \.isConflict)) == true
            if (hasTrackedChanges || !hasConflicts), case .group(let steps)? = before,
               case .index(let entries) = steps[1], case .worktree(let files) = steps[2] {
                try restoreIndex(entries)
                for file in files { try Self.writeWorktreeFile(file, root: git.directory) }
                if !(try stashList(git).contains { $0.id == id }) {
                    _ = try git.run(["stash", "store", "--message", Self.storedMessage(entry), id])
                }
            }
            throw error
        }
    }

    private func restoreStash(_ id: String, git: GitProcess) throws {
        let before = try state().fingerprint
        var result = try git.run(["stash", "apply", "--index", "--quiet", id], allowFailure: true, literalPathspecs: false)
        if result.status != 0, try state().fingerprint == before {
            // The index part could not be put back as it was (HEAD moved on); bring the changes back unstaged.
            result = try git.run(["stash", "apply", "--quiet", id], allowFailure: true, literalPathspecs: false)
        }
        guard result.status == 0 else {
            let conflicts = try git.run(["diff", "--name-only", "--diff-filter=U", "-z"]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
            if !conflicts.isEmpty {
                throw FolmiError.unsupported("拿回时这些文件和当前提交有冲突，已带冲突标记写入，暂放的改动仍留在列表里：\n" + conflicts.joined(separator: "\n"))
            }
            throw FolmiError.git(exitCode: result.status, message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try drop(id, git: git)
    }

    /// Takes back the paths a conflicted apply touched. Edits made elsewhere while resolving it stay in place.
    public func undoConflictedRestore(stash id: String?) async throws {
        let git = try runner()
        guard try operationInProgress(git) == nil else { throw FolmiError.unsupported("有进行中的变基或合并，用它自己的「放弃」。") }
        let current = try state()
        guard let id, let head = current.head, try stashList(git).contains(where: { $0.id == id }) else {
            throw FolmiError.unsupported("找不到产生冲突的暂放记录，无法安全撤销拿回。")
        }
        let plan = try stashPlan(id, current: current, git: git, indexTree: head)
        let tracked = current.files.filter { !$0.isUntracked }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        let paths = Set(tracked).intersection(plan.paths).sorted()
        if !paths.isEmpty {
            _ = try git.run(["restore", "--source=" + head, "--staged", "--worktree", "--no-recurse-submodules",
                             "--pathspec-from-file=-", "--pathspec-file-nul"], input: Self.pathspecs(paths))
        }
        if try refObject(id + "^3", git: git) != nil {
            let listed = try git.run(["ls-tree", "-r", "-z", "\(id)^3"]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
            let untracked = Set(try git.run(["ls-files", "--others", "--exclude-standard", "-z"]).text.components(separatedBy: "\0").filter { !$0.isEmpty })
            for line in listed {
                // "<mode> blob <sha>\t<path>"
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let path = String(line[line.index(after: tab)...]), blob = line[..<tab].split(separator: " ").last.map(String.init)
                guard untracked.contains(path), let blob,
                      try git.run(["hash-object", "--", path]).text.trimmingCharacters(in: .whitespacesAndNewlines) == blob else { continue }
                try FileManager.default.removeItem(at: git.directory.appendingPathComponent(path))
            }
        }
    }

    /// Removes a stash from the list; the returned step puts it back.
    public func dropStash(_ id: String) async throws -> UndoStep {
        let git = try runner()
        guard let entry = try stashList(git).first(where: { $0.id == id }) else { throw FolmiError.unsupported("这份暂放的改动已经不在了。") }
        try drop(id, git: git)
        return .stash(.store(object: id, message: Self.storedMessage(entry)))
    }

    private func drop(_ id: String, git: GitProcess) throws {
        // Looked up again right before dropping: positions shift when entries come and go.
        guard let entry = try stashList(git).first(where: { $0.id == id }) else { return }
        _ = try git.run(["stash", "drop", "--quiet", "stash@{\(entry.index)}"])
    }

    static func storedMessage(_ entry: StashEntry) -> String {
        entry.branch.isEmpty ? entry.message : "On \(entry.branch): \(entry.message)"
    }

    /// Files a stash holds (tracked changes plus its untracked files), for the list.
    public func stashFiles(_ id: String) async throws -> [String] {
        try stashedFiles(id, git: runner()).map(\.id)
    }

    public func stashDiff(_ file: StashedFile) async throws -> FileDiff {
        try Self.readOnlyDiff(base: file.base, target: file.target, file: file.change, git: runner())
    }

    private func stashedFiles(_ id: String, git: GitProcess) throws -> [StashedFile] {
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else { throw FolmiError.unsupported("无效的提交编号。") }
        let base = id + "^1", index = id + "^2"
        var files: [String: StashedFile] = [:]
        for target in [index, id] {
            for change in try Self.commitFiles(base: base, target: target, git: git) {
                files[change.path] = StashedFile(change: change, base: base, target: target)
            }
        }
        if let untracked = try refObject(id + "^3", git: git) {
            let empty = try parentOrEmptyTree(untracked, git: git)
            for change in try Self.commitFiles(base: empty, target: untracked, git: git) {
                files[change.path] = StashedFile(change: change, base: empty, target: untracked)
            }
        }
        return files.values.sorted { $0.id < $1.id }
    }

    /// Shows where bringing a stash back would conflict with the current index or overlap uncommitted files.
    public func stashConflicts(_ id: String) async throws -> [String] {
        try await stashRestorePlans([id])[id]?.conflicts ?? []
    }

    public func stashRestorePlans(_ ids: [String]) async throws -> [String: StashRestorePlan] {
        guard !ids.isEmpty else { return [:] }
        let git = try runner()
        let current = try state()
        let indexTree = try stashIndexTree(current, git: git)
        var plans: [String: StashRestorePlan] = [:]
        for id in Set(ids) {
            plans[id] = try stashPlan(id, current: current, git: git, indexTree: indexTree)
        }
        return plans
    }

    private func stashIndexTree(_ current: State, git: GitProcess) throws -> String? {
        guard try operationInProgress(git) == nil, !current.files.contains(where: \.isConflict), let head = current.head else { return nil }
        guard current.files.contains(where: \.hasStaged) else { return head }
        // write-tree can rewrite the cache-tree extension. Preview against a copy to keep the snapshot valid.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-stash-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: gitPaths(git).index, to: temporary)
        let preview = GitProcess(directory: git.directory, environment: git.environment.merging(["GIT_INDEX_FILE": temporary.path]) { _, new in new })
        return try preview.run(["write-tree"]).text.trimmingCharacters(in: .newlines)
    }

    private func stashPlan(_ id: String, current: State, git: GitProcess, indexTree: String?) throws -> StashRestorePlan {
        let files = try stashedFiles(id, git: git)
        var affected = Set(files.map(\.id))
        guard let indexTree else {
            return StashRestorePlan(files: files, conflicts: [], blocker: current.head == nil
                ? "当前分支还没有提交。" : "先完成当前的冲突处理，再拿回改动。", paths: affected)
        }
        let merge = try git.run(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "--merge-base=\(id)^1", indexTree, id],
                                allowFailure: true)
        let output = merge.text.split(separator: "\0").map(String.init)
        guard merge.status == 0 || merge.status == 1, let tree = output.first?.trimmingCharacters(in: .newlines),
              !tree.isEmpty, tree.allSatisfy(\.isHexDigit) else {
            return StashRestorePlan(files: files, conflicts: [], blocker: "无法确认是否能拿回：" + String(decoding: merge.stderr, as: UTF8.self),
                                    paths: affected)
        }
        let conflicts = Set(output.dropFirst())
        let worktreePaths = try Self.commitFiles(base: indexTree, target: tree, git: git).map(\.path)
        let worktree = StashTreeChange(tree: tree, paths: worktreePaths)
        affected.formUnion(conflicts)
        affected.formUnion(worktreePaths)

        var index: StashTreeChange?
        if conflicts.isEmpty, current.files.contains(where: { !$0.isUntracked }) {
            let mergeIndex = try git.run(["merge-tree", "--write-tree", "--no-messages", "--merge-base=\(id)^1", indexTree, id + "^2"],
                                         allowFailure: true)
            if mergeIndex.status == 0 {
                let stagedTree = mergeIndex.text.trimmingCharacters(in: .newlines)
                let stagedPaths = try Self.commitFiles(base: indexTree, target: stagedTree, git: git).map(\.path)
                affected.formUnion(stagedPaths)
                index = StashTreeChange(tree: stagedTree, paths: stagedPaths)
            }
        }

        let working = Set(current.files.filter(\.hasWorking).flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        var overlap = Self.overlappingPaths(working, with: affected)
        if current.files.contains(where: \.hasStaged) {
            let staged = Set(current.files.filter(\.hasStaged).flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
            let different = Set(try Self.commitFiles(base: id + "^1", target: indexTree, git: git).map(\.path))
            overlap.formUnion(Self.overlappingPaths(staged.intersection(different), with: affected))
        }
        var untracked: StashTreeChange?
        if let object = try refObject(id + "^3", git: git) {
            let names = try git.run(["ls-tree", "-r", "--name-only", "-z", object]).text.split(separator: "\0").map(String.init)
            untracked = StashTreeChange(tree: object, paths: names)
            for path in names {
                if (try? FileManager.default.attributesOfItem(atPath: git.directory.appendingPathComponent(path).path)) != nil {
                    overlap.insert(path)
                }
            }
        }
        let blocker: String?
        if !overlap.isEmpty {
            blocker = "这些文件已有本机改动或同名文件，先处理后再拿回：" + overlap.sorted().prefix(4).joined(separator: "、")
        } else if !conflicts.isEmpty, current.files.contains(where: { !$0.isUntracked }) {
            blocker = "这批改动会有冲突。请先提交或暂放手上的改动，再拿回这批。"
        } else {
            blocker = nil
        }
        return StashRestorePlan(files: files, conflicts: conflicts.sorted(), blocker: blocker, paths: affected,
                                worktree: worktree, index: index, untracked: untracked)
    }

    func undoStash(_ change: StashUndo) async throws -> UndoStep {
        let git = try runner()
        switch change {
        case .pop(let object):
            guard let entry = try stashList(git).first(where: { $0.id == object }) else { throw FolmiError.unsupported("这份暂放的改动已经不在了，无法拿回。") }
            let current = try state()
            let inverse = try await popStash(object, expectedFingerprint: current.fingerprint)
            if current.files.isEmpty {
                return try .stash(.push(message: entry.message, expectedFingerprint: state().fingerprint))
            }
            return inverse
        case let .push(message, expected):
            let current = try state()
            if let expected, expected != current.fingerprint { throw FolmiError.staleSnapshot }
            guard !current.files.isEmpty else { throw FolmiError.unsupported("没有可以暂放的改动。") }
            return .stash(.pop(object: try pushStash(message: message).id))
        case let .store(object, message):
            guard object.allSatisfy(\.isHexDigit) else { throw FolmiError.unsupported("无效的提交编号。") }
            _ = try git.run(["stash", "store", "--message", message, object])
            return .stash(.drop(object: object, message: message))
        case let .drop(object, message):
            try drop(object, git: git)
            return .stash(.store(object: object, message: message))
        }
    }
}
