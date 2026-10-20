import Foundation

/// What one undoable action changed, recorded before it ran. Undoing a step restores what it holds and returns the
/// step that redoes it, so undo and redo are the same operation.
public enum UndoStep: Sendable, Equatable {
    /// Work-tree files as they were; `data == nil` means the file did not exist.
    case worktree([WorktreeFile])
    /// Index entries as they were; `entry == nil` means the path was not in the index.
    case index([IndexSnapshot])
    /// Undo points `branch` (a full ref like `refs/heads/main`; nil: detached HEAD) at `restore` (nil: no commit
    /// yet), if HEAD is still on that branch and it still points at `current`. Index and work tree are left alone,
    /// like `git reset --soft`.
    case head(restore: String?, current: String?, branch: String?)
    /// Undo moves `branch` and the files back to `restore`, if HEAD is still on that branch at `current`: uncommitted
    /// changes (staged or not) are carried along, and git refuses, changing nothing, where they would be lost.
    case reset(restore: String, current: String, branch: String?)
    /// Undo points `ref` (a full ref such as `refs/heads/x` or `refs/tags/v1`) at `restore` (nil: deletes it), if it
    /// still points at `current` (nil: must not exist). Used for branches and tags made or removed.
    case ref(ref: String, restore: String?, current: String?)
    /// Undo renames branch `to` back to `from` (short names).
    case renameBranch(from: String, to: String)
    /// A stash action to take back (see `StashUndo`).
    case stash(StashUndo)
    /// Several steps that undo together, newest last.
    case group([UndoStep])

    public var paths: [String] {
        switch self {
        case .worktree(let files): return files.map(\.path)
        case .index(let entries): return entries.map(\.path)
        case .head, .reset, .stash, .ref, .renameBranch: return []
        case .group(let steps): return steps.flatMap(\.paths)
        }
    }
}

public struct WorktreeFile: Sendable, Equatable, Codable {
    public let path: String
    public let data: Data?
    public let permissions: Int?
    public init(path: String, data: Data?, permissions: Int?) { self.path = path; self.data = data; self.permissions = permissions }
}

public struct IndexSnapshot: Sendable, Equatable {
    public let path: String
    public let mode: String?
    public let object: String?
    public init(path: String, mode: String?, object: String?) { self.path = path; self.mode = mode; self.object = object }
}

extension GitRepository {
    // MARK: Capture

    /// The listed work-tree files as they are now. Files over 32 MiB are refused: undo keeps them in memory.
    public func captureWorktree(_ paths: [String]) async throws -> UndoStep {
        let root = try runner().directory
        return .worktree(try Set(paths).sorted().map { try Self.readWorktreeFile($0, root: root) })
    }

    static func readWorktreeFile(_ path: String, root: URL) throws -> WorktreeFile {
        let url = try contained(path, root: root)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Only a file that is really not there is recorded as absent: undoing then removes it.
            return WorktreeFile(path: path, data: nil, permissions: nil)
        }
        // Anything else (no permission, an unreadable folder) is not "absent"; recording it so would delete it on undo.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw FolmiError.unsupported("\(path) 不是普通文件，无法撤销。")
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 32 * 1024 * 1024 else {
            throw FolmiError.unsupported("\(path) 超过 32 MiB，无法记录撤销。")
        }
        return WorktreeFile(path: path, data: try Data(contentsOf: url), permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    /// The index entries of the listed paths as they are now. Conflicted paths (several stages) are refused.
    public func captureIndex(_ paths: [String]) async throws -> UndoStep {
        let git = try runner()
        var result: [IndexSnapshot] = []
        for path in Set(paths).sorted() {
            let records = try git.run(["ls-files", "-s", "-z", "--", path]).text.split(separator: "\0").map(String.init)
                .filter { record in record.firstIndex(of: "\t").map { String(record[record.index(after: $0)...]) == path } ?? false }
            if records.isEmpty { result.append(IndexSnapshot(path: path, mode: nil, object: nil)); continue }
            guard records.count == 1, let tab = records[0].firstIndex(of: "\t") else {
                throw FolmiError.unsupported("\(path) 处于冲突状态，无法记录撤销。")
            }
            let fields = records[0][..<tab].split(separator: " ")
            guard fields.count == 3, fields[2] == "0" else { throw FolmiError.unsupported("\(path) 处于冲突状态，无法记录撤销。") }
            result.append(IndexSnapshot(path: path, mode: String(fields[0]), object: String(fields[1])))
        }
        return .index(result)
    }

    /// The same paths captured again now, to tell whether anything touched them since a step was recorded.
    public func recapture(_ step: UndoStep) async throws -> UndoStep {
        switch step {
        case .worktree(let files): return try await captureWorktree(files.map(\.path))
        case .index(let entries): return try await captureIndex(entries.map(\.path))
        case .head, .reset, .stash, .ref, .renameBranch: return step
        case .group(let steps):
            var result: [UndoStep] = []
            for step in steps { result.append(try await recapture(step)) }
            return .group(result)
        }
    }

    /// The branch HEAD is on, as a full ref (`refs/heads/main`), also before its first commit; nil when detached.
    public func currentBranchRef() async throws -> String? {
        try Self.branchRef(try runner())
    }

    static func branchRef(_ git: GitProcess) throws -> String? {
        let result = try git.run(["symbolic-ref", "-q", "HEAD"], allowFailure: true)
        guard result.status == 0 else { return nil }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The ref an undo recorded on `branch` may move: refused when HEAD is now on another branch, even one at the
    /// same commit, since the step belongs to the branch it was recorded on.
    static func refToMove(_ branch: String?, _ git: GitProcess) throws -> String {
        let now = try branchRef(git)
        guard now == branch else {
            func name(_ ref: String?) -> String { ref.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } ?? "游离 HEAD" }
            throw FolmiError.unsupported("这一步记录在「\(name(branch))」上，现在在「\(name(now))」。切回「\(name(branch))」再撤销，免得改错分支。")
        }
        return branch ?? "HEAD"
    }

    public func currentHead() async throws -> String? {
        let result = try runner().run(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true)
        guard result.status == 0 else { return nil }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Undo

    /// Restores what `step` recorded and returns the step that puts back what was there just before.
    public func undo(_ step: UndoStep) async throws -> UndoStep {
        switch step {
        case .worktree(let files):
            let root = try runner().directory
            let current = try files.map { try Self.readWorktreeFile($0.path, root: root) }
            for file in files { try Self.writeWorktreeFile(file, root: root) }
            return .worktree(current)
        case .index(let entries):
            guard case .index(let current) = try await captureIndex(entries.map(\.path)) else { return .index([]) }
            let git = try runner()
            for entry in entries {
                if let mode = entry.mode, let object = entry.object {
                    _ = try git.run(["update-index", "--add", "--cacheinfo", "\(mode),\(object),\(entry.path)"])
                } else {
                    _ = try git.run(["update-index", "--force-remove", "--", entry.path])
                }
            }
            return .index(current)
        case let .head(restore, current, branch):
            // update-ref checks the old value atomically; an empty old value means "must not exist yet".
            let git = try runner()
            let ref = try Self.refToMove(branch, git)
            if let restore { _ = try git.run(["update-ref", "-m", "Folmi：撤销", ref, restore, current ?? ""]) }
            else if let current { _ = try git.run(["update-ref", "-d", ref, current]) }
            return .head(restore: current, current: restore, branch: branch)
        case let .reset(restore, current, branch):
            let git = try runner()
            let ref = try Self.refToMove(branch, git)
            let head = try git.run(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == current else { throw FolmiError.unsupported("之后又有了新的提交或切换，撤销会丢掉它们，所以没有执行。") }
            // The two-way merge a fast-forward does, backwards: files that differ between the commits are updated,
            // staged and unstaged changes elsewhere stay as they are, and any overlap is refused before writing.
            let result = try git.run(["read-tree", "-m", "-u", current, restore], allowFailure: true)
            guard result.status == 0 else {
                throw FolmiError.unsupported("没提交的改动和要恢复的文件有重叠，撤销会覆盖它们，所以没有执行。先提交或临时收起改动。")
            }
            _ = try git.run(["update-ref", "-m", "Folmi：撤销", ref, restore, current])
            return .reset(restore: current, current: restore, branch: branch)
        case let .ref(ref, restore, current):
            let git = try runner()
            if let restore { _ = try git.run(["update-ref", "-m", "Folmi：撤销", ref, restore, current ?? ""]) }
            else if let current { _ = try git.run(["update-ref", "-d", ref, current]) }
            return .ref(ref: ref, restore: current, current: restore)
        case let .renameBranch(from, to):
            _ = try runner().run(["branch", "-m", "--", to, from])
            return .renameBranch(from: to, to: from)
        case .stash(let change):
            return try undoStash(change)
        case .group(let steps):
            var inverses: [UndoStep] = []
            for step in steps.reversed() { inverses.append(try await undo(step)) }
            return .group(inverses)
        }
    }

    static func writeWorktreeFile(_ file: WorktreeFile, root: URL) throws {
        let url = try contained(file.path, root: root)
        let manager = FileManager.default
        guard let data = file.data else {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let permissions = file.permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    /// A path inside the work tree, never through `..` or an absolute path.
    static func contained(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw FolmiError.unsupported("路径不在项目内：\(path)")
        }
        return root.appendingPathComponent(path)
    }

    // MARK: Discard

    /// Takes one work-tree hunk (or the chosen lines of it) out of the file, after checking the view is current.
    /// Returns the step that brings it back.
    public func discard(diff: FileDiff, hunkID: String, selectedLineIDs: Set<Int>? = nil) async throws -> UndoStep {
        guard diff.area == .working, !diff.file.isUntracked else { throw FolmiError.unsupported("只能丢弃工作区里已跟踪文件的改动块。") }
        guard diff.isPartialSupported else { throw FolmiError.unsupported(diff.notice ?? "此文件暂不支持按块丢弃。") }
        let fresh = try makeDiff(for: diff.file, area: .working)
        guard fresh.fingerprint == diff.fingerprint, fresh.rawPatch == diff.rawPatch else { throw FolmiError.staleSnapshot }
        guard let hunk = fresh.hunks.first(where: { $0.id == hunkID }) else { throw FolmiError.invalidSelection }
        let root = try runner().directory
        let before = try Self.readWorktreeFile(diff.file.path, root: root)
        guard let data = before.data, let text = UTF8Text.decode(data) else {
            throw FolmiError.unsupported("文件不是 UTF-8 文本，无法按块丢弃。")
        }
        let reverted: String
        do { reverted = try Patch.revertedWorktree(text, hunk: hunk, selection: selectedLineIDs) }
        catch FolmiError.staleSnapshot {
            // The diff shows clean-filtered text (line endings, filters); the file on disk differs from it.
            throw FolmiError.unsupported("文件经过换行或过滤器转换，无法安全按块丢弃；请在编辑器里修改。")
        }
        guard try Self.readWorktreeFile(diff.file.path, root: root) == before else { throw FolmiError.staleSnapshot }
        try Self.writeWorktreeFile(WorktreeFile(path: diff.file.path, data: Data(reverted.utf8), permissions: before.permissions), root: root)
        return .worktree([before])
    }
}
