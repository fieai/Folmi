import Foundation

public enum ChangeArea: String, CaseIterable, Sendable, Codable { case working, staged }

public struct FileChange: Identifiable, Hashable, Sendable, Codable {
    public let path: String
    public let originalPath: String?
    public let indexCode: String
    public let worktreeCode: String
    public var id: String { path }
    public var hasStaged: Bool { ![".", " ", "?"].contains(indexCode) }
    public var hasWorking: Bool { isUntracked || ![".", " "].contains(worktreeCode) }
    public var isUntracked: Bool { indexCode == "?" }
    public var isConflict: Bool { indexCode == "U" || worktreeCode == "U" || ["AA", "DD"].contains(indexCode + worktreeCode) }
    public init(path: String, originalPath: String? = nil, indexCode: String, worktreeCode: String) {
        self.path = path; self.originalPath = originalPath; self.indexCode = indexCode; self.worktreeCode = worktreeCode
    }
}

/// Paths `.gitignore` covers, relative to the scanned folder: whole folders, and single files in folders that are not.
public struct IgnoredPaths: Sendable, Equatable {
    public var directories: Set<String> = []
    public var files: Set<String> = []
    public init(directories: Set<String> = [], files: Set<String> = []) { self.directories = directories; self.files = files }
}

/// A file's diffstat: lines added and removed.
public struct LineCount: Sendable, Equatable {
    public let added: Int
    public let removed: Int
    public init(added: Int, removed: Int) { self.added = added; self.removed = removed }

    /// `git diff --numstat -z`: `added\tremoved\tpath\0`, or for a rename `added\tremoved\t\0old\0new\0`.
    /// Binary files (`-\t-`) are skipped; a rename is keyed by its new path.
    public static func parseNumstat(_ output: String) -> [(String, LineCount)] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        var result: [(String, LineCount)] = []
        while let head = fields.popFirst() {
            let parts = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {
                // Rename: the old and new paths follow as their own fields.
                _ = fields.popFirst()
                path = fields.popFirst() ?? ""
            }
            guard !path.isEmpty, let added = Int(parts[0]), let removed = Int(parts[1]) else { continue }
            result.append((path, LineCount(added: added, removed: removed)))
        }
        return result
    }
}

public struct CommitSummary: Identifiable, Sendable, Codable {
    public let id: String
    public let shortID: String
    public let subject: String
    /// Author date; nil in snapshots saved before it was recorded.
    public let date: Date?
    public init(id: String, shortID: String, subject: String, date: Date? = nil) {
        self.id = id; self.shortID = shortID; self.subject = subject; self.date = date
    }
}

public struct RepositorySnapshot: Sendable, Codable {
    public let root: URL
    public let branch: String
    public let head: String?
    public let files: [FileChange]
    public let commits: [CommitSummary]
    public let branches: [String]
    public let remotes: [String]
    public let fingerprint: String
    /// The branch's upstream and how far ahead / behind it is; nil without an upstream.
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?
    /// Commits a push would send: `ahead` with an upstream, otherwise the commits no remote has yet. Nil without a
    /// remote (nothing to push to) or without a commit.
    public let unpushed: Int?
    /// A rebase or merge stopped half way (usually on a conflict); nil when none is in progress.
    public let operation: RepositoryOperation?
    /// How many stashes (临时收起的改动) the repository holds; nil in snapshots saved before it was recorded.
    public let stashCount: Int?
    public init(root: URL, branch: String, head: String?, files: [FileChange], commits: [CommitSummary], branches: [String], remotes: [String], fingerprint: String,
                upstream: String? = nil, ahead: Int? = nil, behind: Int? = nil, unpushed: Int? = nil, operation: RepositoryOperation? = nil, stashCount: Int? = nil) {
        self.root = root; self.branch = branch; self.head = head; self.files = files; self.commits = commits; self.branches = branches; self.remotes = remotes; self.fingerprint = fingerprint
        self.upstream = upstream; self.ahead = ahead; self.behind = behind; self.unpushed = unpushed ?? ahead; self.operation = operation; self.stashCount = stashCount
    }
}

/// A multi-step Git operation left in progress in the repository.
public enum RepositoryOperation: String, Sendable, Codable {
    case rebase, merge
    public var title: String { self == .rebase ? "变基" : "合并" }
}

public enum DiffLineKind: String, Hashable, Sendable { case context, addition, deletion, meta }
public struct DiffLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public let text: String
    public let kind: DiffLineKind
    public init(id: Int, text: String, kind: DiffLineKind) { self.id = id; self.text = text; self.kind = kind }
}
public struct DiffHunk: Identifiable, Hashable, Sendable {
    public let id: String
    public let header: String
    public let lines: [DiffLine]
    public init(id: String, header: String, lines: [DiffLine]) { self.id = id; self.header = header; self.lines = lines }
}
public struct FileDiff: Sendable {
    public let file: FileChange
    public let area: ChangeArea
    public let rawPatch: String
    public let hunks: [DiffHunk]
    public let fingerprint: String
    public let isPartialSupported: Bool
    public let notice: String?
    /// Where the whole file before and after the change can be read, so a picture or a Word file with no text diff
    /// can be shown as itself.
    public var versions: FileVersions?
    public init(file: FileChange, area: ChangeArea, rawPatch: String, hunks: [DiffHunk], fingerprint: String, isPartialSupported: Bool,
                notice: String?, versions: FileVersions? = nil) {
        self.file = file; self.area = area; self.rawPatch = rawPatch; self.hunks = hunks; self.fingerprint = fingerprint; self.isPartialSupported = isPartialSupported; self.notice = notice
        self.versions = versions
    }
    /// Git found no text to compare: a binary file, or a new file that is not UTF-8 text.
    public var isBinary: Bool {
        rawPatch.contains("Binary files ") || rawPatch.contains("GIT binary patch") || notice?.contains("二进制") == true
    }
}

/// One side of a change, read whole.
public enum FileVersion: Sendable, Equatable {
    /// The file in the working tree, by its path in the repository.
    case worktree(String)
    /// A Git object name: `:path` (the index), `HEAD:path`, `<commit>:path`.
    case object(String)
    /// Bytes kept elsewhere, such as the copy saved before a Claude turn.
    case bytes(Data)
}

/// The two sides of a change; nil where the file did not exist (added) or no longer does (deleted).
public struct FileVersions: Sendable, Equatable {
    public let old: FileVersion?
    public let new: FileVersion?
    public init(old: FileVersion?, new: FileVersion?) { self.old = old; self.new = new }
}

public enum FolmiError: LocalizedError, Sendable {
    case git(exitCode: Int32, message: String)
    case staleSnapshot
    case unsupported(String)
    case invalidSelection
    case outputLimit
    case timedOut
    case projectDirectoryUnavailable(path: String, message: String)
    case processLaunch(executable: String, message: String)
    case processIO(String)
    public var errorDescription: String? {
        switch self {
        case let .projectDirectoryUnavailable(path, message): return "无法打开项目目录：\(path)\n\(message) 请重新定位项目文件夹，或将它从项目列表中移除。"
        case let .processLaunch(executable, message): return "未能启动 Git（\(executable)）：\(message)。Git 命令尚未执行。"
        case let .git(code, message): return "Git 执行失败（退出码 \(code)）：\(message)"
        case .staleSnapshot: return "仓库或文件已变化，请刷新后重试。"
        case let .unsupported(message): return message
        case .invalidSelection: return "请在当前块中选择至少一行新增或删除内容。"
        case .outputLimit: return "Git 输出超过安全显示上限，请使用命令行处理此大文件或大仓库。"
        case .timedOut: return "Git 命令超时，请检查进程、钩子或签名提示。"
        case let .processIO(message): return "Git 进程通信异常：\(message)。操作可能已经完成，请刷新仓库确认。"
        }
    }
}
