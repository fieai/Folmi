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
    case push(message: String)
    /// Put this commit back on the stash list (after a drop).
    case store(object: String, message: String)
    /// Take this commit off the stash list again.
    case drop(object: String, message: String)
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
        let current = try require(expectedFingerprint)
        guard current.head != nil else { throw FolmiError.unsupported("项目还没有提交，不能收起改动。") }
        guard !current.files.isEmpty else { throw FolmiError.unsupported("没有可以收起的改动。") }
        guard !current.files.contains(where: \.isConflict) else { throw FolmiError.unsupported("有冲突没解决，先解决冲突再收起。") }
        guard try operationInProgress(try runner()) == nil else { throw FolmiError.unsupported("变基或合并还没完成，先继续或放弃它。") }
        return try pushStash(message: message)
    }

    private func pushStash(message: String) throws -> StashEntry {
        let git = try runner()
        let before = try stashList(git).first?.id
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git.run(["stash", "push", "--include-untracked", "--quiet", "--message", text.isEmpty ? "Folmi" : text], literalPathspecs: false)
        guard let entry = try stashList(git).first, entry.id != before else { throw FolmiError.unsupported("没有可以收起的改动。") }
        return entry
    }

    /// Brings a stash back (staged parts staged again) and takes it off the list. Needs no changes to tracked files,
    /// so a conflict can only touch the stash's own changes: then the stash stays on the list and the error says so.
    public func popStash(_ id: String, expectedFingerprint: String) async throws {
        let current = try require(expectedFingerprint)
        guard !current.files.contains(where: { !$0.isUntracked }) else {
            throw FolmiError.unsupported("工作区或暂存区还有改动。先提交或收起它们，再恢复这份收起的改动。")
        }
        try restoreStash(id)
    }

    private func restoreStash(_ id: String) throws {
        let git = try runner()
        guard let entry = try stashList(git).first(where: { $0.id == id }) else { throw FolmiError.unsupported("这份收起的改动已经不在了。") }
        let ref = "stash@{\(entry.index)}"
        let before = try state().fingerprint
        var result = try git.run(["stash", "apply", "--index", "--quiet", ref], allowFailure: true, literalPathspecs: false)
        if result.status != 0, try state().fingerprint == before {
            // The index part could not be put back as it was (HEAD moved on); bring the changes back unstaged.
            result = try git.run(["stash", "apply", "--quiet", ref], allowFailure: true, literalPathspecs: false)
        }
        guard result.status == 0 else {
            let conflicts = try git.run(["diff", "--name-only", "--diff-filter=U", "-z"]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
            if !conflicts.isEmpty {
                throw FolmiError.unsupported("恢复时这些文件和当前提交有冲突，已带冲突标记写入，收起的改动仍留在列表里：\n" + conflicts.joined(separator: "\n"))
            }
            throw FolmiError.git(exitCode: result.status, message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try drop(id, git: git)
    }

    /// Removes a stash from the list; the returned step puts it back.
    public func dropStash(_ id: String) async throws -> UndoStep {
        let git = try runner()
        guard let entry = try stashList(git).first(where: { $0.id == id }) else { throw FolmiError.unsupported("这份收起的改动已经不在了。") }
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
        let git = try runner()
        guard id.allSatisfy(\.isHexDigit) else { throw FolmiError.unsupported("无效的提交编号。") }
        var files = try git.run(["diff", "--name-only", "-z", id + "^1", id]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
        let untracked = try git.run(["rev-parse", "--verify", "--quiet", id + "^3"], allowFailure: true)
        if untracked.status == 0 {
            files += try git.run(["ls-tree", "-r", "--name-only", "-z", id + "^3"]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
        }
        return Array(Set(files)).sorted()
    }

    func undoStash(_ change: StashUndo) throws -> UndoStep {
        let git = try runner()
        switch change {
        case .pop(let object):
            guard let entry = try stashList(git).first(where: { $0.id == object }) else { throw FolmiError.unsupported("这份收起的改动已经不在了，无法恢复。") }
            guard !(try state().files.contains { !$0.isUntracked }) else {
                throw FolmiError.unsupported("之后工作区又有了改动，撤销会和它们混在一起，所以没有执行。")
            }
            try restoreStash(object)
            return .stash(.push(message: entry.message))
        case .push(let message):
            let current = try state()
            guard !current.files.isEmpty else { throw FolmiError.unsupported("没有可以收起的改动。") }
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
