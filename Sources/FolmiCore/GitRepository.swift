import Foundation
import CryptoKit

public actor GitRepository {
    private let initialURL: URL
    private let environment: [String: String]
    private var root: URL?
    private var knownPaths: GitPaths?
    /// See `GitProcess.largeRepository`; set per project by the app.
    private var largeRepository: Bool
    public func setLargeRepository(_ on: Bool) { largeRepository = on }
    /// How long the last `git status` took, so the app can offer 大仓库模式 when it is slow.
    public private(set) var lastStatusDuration: TimeInterval = 0
    public init(url: URL, environment: [String: String] = [:], largeRepository: Bool = false) {
        initialURL = url.standardizedFileURL; self.environment = environment; self.largeRepository = largeRepository
    }

    /// Files inside the Git directory that status and in-progress checks look at. Where they live never changes for
    /// a repository, so one `rev-parse` answers for its whole life instead of one per refresh.
    struct GitPaths { let index, rebaseMerge, rebaseApply, mergeHead: URL }
    func gitPaths(_ git: GitProcess) throws -> GitPaths {
        if let knownPaths { return knownPaths }
        let names = ["index", "rebase-merge", "rebase-apply", "MERGE_HEAD"]
        let lines = try git.run(["rev-parse"] + names.flatMap { ["--git-path", $0] }).text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count == names.count else { throw FolmiError.unsupported("无法读取 Git 目录位置。") }
        let urls = lines.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : git.directory.appendingPathComponent($0) }
        let paths = GitPaths(index: urls[0], rebaseMerge: urls[1], rebaseApply: urls[2], mergeHead: urls[3])
        knownPaths = paths
        return paths
    }

    func runner() throws -> GitProcess {
        if root == nil {
            var path = try GitProcess(directory: initialURL, environment: environment).run(["rev-parse", "--show-toplevel"]).text
            if path.hasSuffix("\n") { path.removeLast() }
            root = URL(fileURLWithPath: path, isDirectory: true)
        }
        var process = GitProcess(directory: root!, environment: environment)
        process.largeRepository = largeRepository
        return process
    }

    struct State {
        let branch: String
        let head: String?
        let files: [FileChange]
        let fingerprint: String
        var upstream: String? = nil
        var ahead: Int? = nil
        var behind: Int? = nil
    }

    func state() throws -> State {
        let git = try runner()
        let started = Date()
        let status = try git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]).stdout
        lastStatusDuration = Date().timeIntervalSince(started)
        guard let text = String(data: status, encoding: .utf8) else { throw FolmiError.unsupported("仓库包含非 UTF-8 文件名，当前版本无法安全显示。") }
        let records = text.components(separatedBy: "\0")
        var files: [FileChange] = [], branch = "HEAD", head: String?, i = 0
        var upstream: String?, ahead: Int?, behind: Int?
        while i < records.count {
            let record = records[i]; i += 1
            if record.hasPrefix("# branch.head ") { branch = String(record.dropFirst(14)) }
            else if record.hasPrefix("# branch.upstream ") { upstream = String(record.dropFirst(18)) }
            else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst(12).split(separator: " ")
                if parts.count == 2 { ahead = Int(parts[0].dropFirst()); behind = Int(parts[1].dropFirst()) }
            }
            else if record.hasPrefix("# branch.oid ") {
                let value = String(record.dropFirst(13)); head = value == "(initial)" ? nil : value
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") || record.hasPrefix("u ") {
                let isRename = record.hasPrefix("2 "), conflict = record.hasPrefix("u ")
                let count = conflict ? 10 : (isRename ? 9 : 8)
                let fields = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
                guard fields.count == count + 1, fields[1].count == 2 else { throw FolmiError.unsupported("无法安全解析 Git 状态。") }
                let codes = Array(fields[1]); var original: String?
                if isRename {
                    guard i < records.count else { throw FolmiError.unsupported("重命名状态缺少原文件名。") }
                    original = records[i]; i += 1
                }
                files.append(FileChange(path: String(fields[count]), originalPath: original, indexCode: String(codes[0]), worktreeCode: String(codes[1])))
            } else if record.hasPrefix("? ") { files.append(FileChange(path: String(record.dropFirst(2)), indexCode: "?", worktreeCode: "?")) }
        }
        var hash = SHA256()
        hash.update(data: status)
        // In 大仓库模式 status itself rewrites the index (monitor token, untracked cache), so its bytes would change
        // on every read. The porcelain v2 lines already carry each changed entry's index object, which is what
        // staging changes; the raw index only adds stat data there.
        if !largeRepository {
            let indexURL = try gitPaths(git).index
            if FileManager.default.fileExists(atPath: indexURL.path) { try addFile(indexURL, to: &hash) }
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(file.path.utf8)); hash.update(data: Data([0]))
            try addFile(git.directory.appendingPathComponent(file.path), to: &hash)
            if let original = file.originalPath { try addFile(git.directory.appendingPathComponent(original), to: &hash) }
        }
        return State(branch: branch, head: head, files: files, fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                     upstream: upstream, ahead: ahead, behind: behind)
    }

    private func addFile(_ url: URL, to hash: inout SHA256) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { hash.update(data: Data("<missing>".utf8)); return }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)); return
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { hash.update(data: Data("<directory>".utf8)); return }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        while let data = try handle.read(upToCount: 128 * 1024), !data.isEmpty { hash.update(data: data) }
    }

    /// The work tree plus the Git directories that hold its index and refs; a linked worktree keeps them outside the work tree.
    /// Untracked paths `.gitignore` covers, relative to `directory`. A folder that is ignored as a whole comes back
    /// once (in `directories`) instead of file by file, so `node_modules` costs one entry.
    public func ignoredPaths(in directory: URL) async throws -> IgnoredPaths {
        let git = GitProcess(directory: directory, environment: environment)
        let output = try git.run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        var result = IgnoredPaths()
        for record in output.text.split(separator: "\0") where !record.isEmpty {
            if record.hasSuffix("/") { result.directories.insert(String(record.dropLast())) }
            else { result.files.insert(String(record)) }
        }
        return result
    }

    public func watchedDirectories() async throws -> [URL] {
        let git = try runner()
        let lines = try git.run(["rev-parse", "--absolute-git-dir", "--git-common-dir"]).text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let gitDirectories = lines.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : git.directory.appendingPathComponent($0) }
        let rootPath = git.directory.standardizedFileURL.path + "/"
        return [git.directory] + gitDirectories.map(\.standardizedFileURL).filter { !($0.path + "/").hasPrefix(rootPath) }
    }

    /// Status plus branches, recent commits, remotes and stashes. With `previous`, when only work tree files changed
    /// (nothing under the Git directory), the ref-derived parts are kept if HEAD, branch and upstream still match,
    /// so a refresh is one `git status`. Otherwise the ref reads run side by side: each is mostly process start-up.
    public func load(reusing previous: RepositorySnapshot? = nil) async throws -> RepositorySnapshot {
        let current = try state(), git = try runner()
        if let previous, previous.root == git.directory, previous.head == current.head, previous.branch == current.branch,
           previous.upstream == current.upstream, previous.ahead == current.ahead, previous.behind == current.behind {
            return RepositorySnapshot(root: git.directory, branch: current.branch, head: current.head, files: current.files, commits: previous.commits,
                                      branches: previous.branches, remotes: previous.remotes, fingerprint: current.fingerprint,
                                      upstream: current.upstream, ahead: current.ahead, behind: current.behind, unpushed: previous.unpushed,
                                      operation: try operationInProgress(git), stashCount: previous.stashCount)
        }
        let countUnpushed = current.upstream == nil && current.head != nil
        var jobs: [(arguments: [String], allowFailure: Bool)] = [
            (["for-each-ref", "--format=%(refname:short)", "refs/heads/"], false),
            (["remote"], false),
            (Self.stashListArguments, true)
        ]
        if current.head != nil { jobs.append((["log", "-40", "--format=%H%x00%h%x00%at%x00%s%x00"], false)) }
        if countUnpushed { jobs.append((["rev-list", "--count", "HEAD", "--not", "--remotes"], false)) }
        let outputs = try Self.runSideBySide(git, jobs)
        let branches = outputs[0].components(separatedBy: .newlines).filter { !$0.isEmpty }
        let remotes = outputs[1].components(separatedBy: .newlines).filter { !$0.isEmpty }
        let stashCount = Self.parseStashList(outputs[2]).count
        var commits: [CommitSummary] = []
        if current.head != nil {
            let log = outputs[3].components(separatedBy: "\0")
            var i = 0
            while i + 3 < log.count {
                let id = log[i].trimmingCharacters(in: .newlines)
                let date = TimeInterval(log[i + 2]).map { Date(timeIntervalSince1970: $0) }
                if !id.isEmpty { commits.append(CommitSummary(id: id, shortID: log[i + 1], subject: log[i + 3], date: date)) }
                i += 4
            }
        }
        var unpushed = current.ahead
        if countUnpushed, !remotes.isEmpty, let text = outputs.last { unpushed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return RepositorySnapshot(root: git.directory, branch: current.branch, head: current.head, files: current.files, commits: commits, branches: branches, remotes: remotes, fingerprint: current.fingerprint,
                                  upstream: current.upstream, ahead: current.ahead, behind: current.behind, unpushed: unpushed,
                                  operation: try operationInProgress(git), stashCount: stashCount)
    }

    /// Runs read-only Git commands at the same time and returns their output in order; the first failure is thrown.
    static func runSideBySide(_ git: GitProcess, _ jobs: [(arguments: [String], allowFailure: Bool)]) throws -> [String] {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var texts: [String]
            var error: Error?
            init(_ count: Int) { texts = Array(repeating: "", count: count) }
        }
        let results = Results(jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            do {
                let text = try git.run(jobs[index].arguments, allowFailure: jobs[index].allowFailure).text
                results.lock.lock(); results.texts[index] = text; results.lock.unlock()
            } catch {
                results.lock.lock(); if results.error == nil { results.error = error }; results.lock.unlock()
            }
        }
        if let error = results.error { throw error }
        return results.texts
    }

    public func diff(for file: FileChange, area: ChangeArea) async throws -> FileDiff {
        try makeDiff(for: file, area: area)
    }

    /// For showing a diff: trusts the snapshot the file came from instead of re-reading the whole status around the
    /// `git diff`. The result carries the snapshot's fingerprint, so staging from it still re-checks everything (a
    /// stale view is refused by `apply`).
    public func diff(for file: FileChange, area: ChangeArea, snapshotFingerprint: String) async throws -> FileDiff {
        try makeDiff(for: file, area: area, known: snapshotFingerprint)
    }

    func makeDiff(for file: FileChange, area: ChangeArea, known: String? = nil) throws -> FileDiff {
        let git = try runner()
        let before: State
        if let known { before = State(branch: "", head: nil, files: [file], fingerprint: known) } else { before = try state() }
        guard let actual = before.files.first(where: { $0.path == file.path }) else { throw FolmiError.staleSnapshot }
        var raw = "", notice: String?
        if actual.isUntracked {
            let url = git.directory.appendingPathComponent(actual.path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 1024 * 1024 {
                let data = try Data(contentsOf: url)
                if !data.contains(0), let value = UTF8Text.decode(data) { raw = value }
                else { notice = "二进制或非 UTF-8 文件，请按整个文件暂存。" }
            }
            notice = notice ?? "新文件请先按整个文件暂存。"
        } else {
            var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--full-index", "--unified=3"]
            if area == .staged { args.append("--cached") }
            args += ["--", actual.path]
            let bytes = try git.run(args).stdout
            guard let value = UTF8Text.decode(bytes) else { throw FolmiError.unsupported("差异包含非 UTF-8 文本，请使用整个文件暂存。") }
            raw = value
        }
        let hunks = actual.isUntracked ? [] : Patch.hunks(raw)
        if actual.isConflict { notice = "冲突文件暂不支持部分暂存，请先在编辑器中解决冲突。" }
        else if actual.originalPath != nil { notice = "重命名请使用整个文件操作。" }
        else if raw.components(separatedBy: "\n").contains(where: { $0.hasPrefix("index ") && $0.hasSuffix(" 160000") }) { notice = "子模块请使用整个文件操作。" }
        else if raw.contains("Binary files ") || raw.contains("GIT binary patch") { notice = "二进制文件仅支持整个文件操作。" }
        else if raw.contains("\nnew file mode ") || raw.contains("\ndeleted file mode ") || raw.contains("\nold mode ") || raw.contains("\nnew mode ") { notice = "新增、删除或文件模式变化请使用整个文件操作。" }
        else if hunks.isEmpty, notice == nil { notice = "当前区域没有可操作的文本差异。" }
        if known == nil {
            let after = try state()
            guard before.fingerprint == after.fingerprint else { throw FolmiError.staleSnapshot }
        }
        let fingerprint = SHA256.hash(data: Data((before.fingerprint + "\0" + area.rawValue + "\0" + actual.path + "\0" + raw).utf8)).map { String(format: "%02x", $0) }.joined()
        return FileDiff(file: actual, area: area, rawPatch: raw, hunks: hunks, fingerprint: fingerprint, isPartialSupported: notice == nil,
                        notice: notice, versions: Self.versions(of: actual, area: area))
    }

    /// Working area: the index against the file on disk. Staged: HEAD against the index.
    static func versions(of file: FileChange, area: ChangeArea) -> FileVersions {
        let oldPath = file.originalPath ?? file.path
        if area == .working {
            return FileVersions(old: file.isUntracked ? nil : .object(":" + oldPath),
                                new: file.worktreeCode == "D" ? nil : .worktree(file.path))
        }
        return FileVersions(old: file.indexCode == "A" ? nil : .object("HEAD:" + oldPath),
                            new: file.indexCode == "D" ? nil : .object(":" + file.path))
    }

    /// Lines added and removed per changed file, keyed `"<area>:<path>"` (`ChangeArea.rawValue`). Binary files are left
    /// out; an untracked file counts its own lines when it is at most `untrackedLimit` bytes.
    public func lineCounts(untracked: [String], untrackedLimit: Int = 512 * 1_024) async throws -> [String: LineCount] {
        let git = try runner()
        var counts: [String: LineCount] = [:]
        for area in ChangeArea.allCases {
            let arguments = ["diff", "--numstat", "-z", "--no-color", "--no-ext-diff", "--no-textconv"] + (area == .staged ? ["--cached"] : [])
            for (path, count) in LineCount.parseNumstat(try git.run(arguments, allowFailure: true).text) {
                counts[area.rawValue + ":" + path] = count
            }
        }
        for path in untracked {
            guard let url = try workingFileURL(path),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= untrackedLimit,
                  let data = try? Data(contentsOf: url), !data.prefix(8_000).contains(0) else { continue }
            let newlines = data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            counts[ChangeArea.working.rawValue + ":" + path] = LineCount(added: newlines + (data.last == 10 || data.isEmpty ? 0 : 1), removed: 0)
        }
        return counts
    }

    /// A regular file in the working tree at `path`, without reading it; nil when it is not there or the path (or a link
    /// on the way) leads outside the repository.
    public func workingFileURL(_ path: String) throws -> URL? {
        let git = try runner()
        let root = git.directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let url = git.directory.appendingPathComponent(path)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    /// A version's bytes, or nil when it does not exist there. Bigger than `limit` throws `outputLimit`.
    public func bytes(of version: FileVersion, limit: Int = 64 * 1_024 * 1_024) async throws -> Data? {
        switch version {
        case .bytes(let data):
            return data
        case .worktree(let path):
            guard let url = try workingFileURL(path) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= limit else { throw FolmiError.outputLimit }
            return try Data(contentsOf: url)
        case .object(let name):
            let git = try runner()
            // A name with no ':' or starting with '-' is not one of ours.
            guard name.contains(":"), !name.hasPrefix("-") else { return nil }
            let size = try git.run(["cat-file", "-s", name], allowFailure: true)
            guard size.status == 0 else { return nil }
            guard let count = Int(size.text.trimmingCharacters(in: .whitespacesAndNewlines)), count <= limit else {
                throw FolmiError.outputLimit
            }
            return try git.run(["cat-file", "blob", name], stdoutLimit: limit + 1).stdout
        }
    }

    func require(_ fingerprint: String) throws -> State {
        let current = try state()
        guard current.fingerprint == fingerprint else { throw FolmiError.staleSnapshot }
        return current
    }

    public func stage(_ file: FileChange, expectedFingerprint: String) async throws {
        try await stage([file], expectedFingerprint: expectedFingerprint)
    }

    /// Stages several files in one `git add`; the paths go in on stdin, so any number of them fits.
    public func stage(_ files: [FileChange], expectedFingerprint: String) async throws {
        let current = try require(expectedFingerprint)
        let git = try runner()
        var paths: [String] = []
        for file in files {
            guard let actual = current.files.first(where: { $0.path == file.path }) else { throw FolmiError.staleSnapshot }
            if let original = actual.originalPath {
                let tracked = try git.run(["ls-files", "--error-unmatch", "--", original], allowFailure: true).status == 0
                if tracked || FileManager.default.fileExists(atPath: git.directory.appendingPathComponent(original).path) { paths.append(original) }
            }
            paths.append(actual.path)
        }
        guard !paths.isEmpty else { return }
        _ = try git.run(["--literal-pathspecs", "add", "--pathspec-from-file=-", "--pathspec-file-nul"], input: Self.pathspecs(paths))
    }

    public func unstage(_ file: FileChange, expectedFingerprint: String) async throws {
        try await unstage([file], expectedFingerprint: expectedFingerprint)
    }

    public func unstage(_ files: [FileChange], expectedFingerprint: String) async throws {
        let current = try require(expectedFingerprint)
        var paths: [String] = []
        for file in files {
            guard let actual = current.files.first(where: { $0.path == file.path }), actual.hasStaged else { throw FolmiError.staleSnapshot }
            paths += actual.originalPath.map { [$0, actual.path] } ?? [actual.path]
        }
        guard !paths.isEmpty else { return }
        let git = try runner()
        if current.head == nil {
            let format = try git.run(["rev-parse", "--show-object-format"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let zero = String(repeating: "0", count: format == "sha256" ? 64 : 40)
            let removal = paths.map { "0 \(zero)\t\($0)\0" }.joined()
            _ = try git.run(["update-index", "-z", "--index-info"], input: Data(removal.utf8))
        }
        else { _ = try git.run(["--literal-pathspecs", "restore", "--staged", "--pathspec-from-file=-", "--pathspec-file-nul"], input: Self.pathspecs(paths)) }
    }

    /// NUL-separated paths for `--pathspec-from-file`; `--literal-pathspecs` keeps a name with `*` or `?` from
    /// matching other files.
    static func pathspecs(_ paths: [String]) -> Data {
        Data(paths.map { $0 + "\0" }.joined().utf8)
    }

    /// Stages or unstages part of a hunk by rewriting the file's index entry: read the index blob, apply the chosen
    /// lines to that text, write the result as a new blob and point the index at it. No patch is built, so there is
    /// no context matching or fuzz; any mismatch with the index is reported as a stale view.
    public func apply(diff: FileDiff, hunkID: String, selectedLineIDs: Set<Int>? = nil) async throws {
        guard diff.isPartialSupported else { throw FolmiError.unsupported(diff.notice ?? "此文件暂不支持部分操作。") }
        let fresh = try makeDiff(for: diff.file, area: diff.area)
        guard fresh.fingerprint == diff.fingerprint, fresh.rawPatch == diff.rawPatch else { throw FolmiError.staleSnapshot }
        guard let hunk = fresh.hunks.first(where: { $0.id == hunkID }) else { throw FolmiError.invalidSelection }
        let git = try runner()
        let entry = try indexEntry(for: fresh.file.path, git: git)
        let blob = try git.run(["cat-file", "blob", entry.object]).stdout
        guard let indexText = UTF8Text.decode(blob) else { throw FolmiError.unsupported("暂存区内容不是 UTF-8 文本，请按整个文件操作。") }
        let updated = try Patch.indexContent(indexText, diff: fresh, hunk: hunk, selection: selectedLineIDs)
        // Blob form already: the diff shows clean-filtered text, so skip filters when writing it back.
        let object = try git.run(["hash-object", "-w", "--no-filters", "--stdin"], input: Data(updated.utf8)).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-check just before the write; Git takes its own index lock for update-index.
        guard try indexEntry(for: fresh.file.path, git: git) == entry,
              try makeDiff(for: diff.file, area: diff.area).fingerprint == fresh.fingerprint else { throw FolmiError.staleSnapshot }
        _ = try git.run(["update-index", "--cacheinfo", "\(entry.mode),\(object),\(fresh.file.path)"])
    }

    /// One file's stage-0 entry in the index with its blob bytes, for comparing the editor buffer against the index.
    public struct IndexFile: Sendable, Equatable {
        public let path: String
        public let mode: String
        public let object: String
        public let data: Data
        public init(path: String, mode: String, object: String, data: Data) { self.path = path; self.mode = mode; self.object = object; self.data = data }
    }

    /// The file's index content, or nil when it is not tracked as a regular file (untracked, conflicted, symlink, submodule).
    public func indexFile(path: String) async throws -> IndexFile? {
        let git = try runner()
        guard let entry = try? indexEntry(for: path, git: git) else { return nil }
        let data = try git.run(["cat-file", "blob", entry.object]).stdout
        return IndexFile(path: path, mode: entry.mode, object: entry.object, data: data)
    }

    /// Points the file's index entry at new content, keeping its mode. Refuses when the entry moved since `expectedObject`.
    public func replaceIndexFile(path: String, data: Data, expectedObject: String) async throws {
        let git = try runner()
        let entry = try indexEntry(for: path, git: git)
        guard entry.object == expectedObject else { throw FolmiError.staleSnapshot }
        let object = try git.run(["hash-object", "-w", "--no-filters", "--stdin"], input: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard try indexEntry(for: path, git: git) == entry else { throw FolmiError.staleSnapshot }
        _ = try git.run(["update-index", "--cacheinfo", "\(entry.mode),\(object),\(path)"])
    }

    struct IndexEntry: Equatable { let mode: String; let object: String }

    func indexEntry(for path: String, git: GitProcess) throws -> IndexEntry {
        let records = try git.run(["ls-files", "-s", "-z", "--", path]).text.split(separator: "\0").map(String.init)
        guard records.count == 1, let tab = records[0].firstIndex(of: "\t"), String(records[0][records[0].index(after: tab)...]) == path else {
            throw FolmiError.staleSnapshot
        }
        let fields = records[0][..<tab].split(separator: " ")
        guard fields.count == 3, fields[2] == "0", ["100644", "100755"].contains(fields[0]) else {
            throw FolmiError.unsupported("只能部分暂存普通文本文件。")
        }
        return IndexEntry(mode: String(fields[0]), object: String(fields[1]))
    }

    public func commit(message: String, amend: Bool, expectedFingerprint: String) async throws -> String {
        let current = try require(expectedFingerprint)
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolmiError.unsupported("提交信息不能为空。") }
        guard !current.files.contains(where: \.isConflict) else { throw FolmiError.unsupported("请先解决所有冲突后再提交。") }
        guard amend ? current.head != nil : current.files.contains(where: \.hasStaged) else { throw FolmiError.unsupported("没有可提交的暂存内容。") }
        var args = ["commit", "--cleanup=verbatim", "--file=-"]
        if amend { args.append("--amend") }
        _ = try runner().run(args, input: Data(message.utf8))
        return try runner().run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The staged change for writing a commit message: stat, then the patch cut at `limit` bytes.
    public func stagedPatch(limit: Int = 60_000) async throws -> (stat: String, patch: String, subjects: [String]) {
        let git = try runner()
        let stat = try git.run(["diff", "--cached", "--no-color", "--stat=120"]).text
        var patch = try git.run(["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--unified=2"]).text
        if patch.utf8.count > limit { patch = String(decoding: patch.utf8.prefix(limit), as: UTF8.self) + "\n…（diff 已截断）" }
        let subjects = try git.run(["log", "-20", "--format=%s"], allowFailure: true).text.components(separatedBy: "\n").filter { !$0.isEmpty }
        return (stat, patch, subjects)
    }

    public func latestCommitMessage() async throws -> String {
        try runner().run(["show", "-s", "--format=%B", "HEAD"]).text
    }

    public func checkout(branch: String, expectedFingerprint: String) async throws {
        _ = try require(expectedFingerprint)
        let git = try runner()
        let branches = try git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/"]).text.components(separatedBy: .newlines)
        guard branches.contains(branch), !branch.hasPrefix("-") else { throw FolmiError.unsupported("只能切换到现有本地分支。") }
        _ = try git.run(["switch", "--", branch])
    }

    // MARK: One file's history

    public struct FileRevision: Identifiable, Sendable, Equatable {
        public let id: String
        public let shortID: String
        public let date: Date
        public let subject: String
        public let author: String
        /// The file's path in that commit (it may have been renamed since).
        public let path: String
    }

    /// Commits that changed the file, newest first, following renames.
    public func fileHistory(path: String, limit: Int = 60) async throws -> [FileRevision] {
        let git = try runner()
        guard try git.run(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true).status == 0 else { return [] }
        let text = try git.run(["log", "--follow", "-n", String(limit), "--name-only", "-z",
                                "--format=%x01%H%x00%h%x00%at%x00%an%x00%s", "--", path]).text
        var result: [FileRevision] = []
        for record in text.components(separatedBy: "\u{1}") where !record.isEmpty {
            let fields = record.components(separatedBy: "\0").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
            guard fields.count >= 6 else { continue }
            result.append(FileRevision(id: fields[0], shortID: fields[1], date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                                       subject: fields[4], author: fields[3], path: fields[5]))
        }
        return result
    }

    /// The file's text in a commit; nil when it did not exist there or is not UTF-8.
    public func fileText(commit: String, path: String) async throws -> String? {
        let git = try runner()
        let object = try verifiedCommit(commit, git: git)
        let result = try git.run(["show", "\(object):\(path)"], allowFailure: true)
        guard result.status == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8)
    }
    /// The file as HEAD has it; nil on an unborn branch, when the file is not in HEAD, or when it is not UTF-8.
    public func headFileText(path: String) async throws -> String? {
        let git = try runner()
        let result = try git.run(["show", "HEAD:" + path], allowFailure: true)
        guard result.status == 0 else { return nil }
        return UTF8Text.decode(result.stdout)
    }
    /// The first parent of a commit, or nil for a root commit.
    public func parent(of commit: String) async throws -> String? {
        let git = try runner()
        let parents = try git.run(["rev-list", "--parents", "-n", "1", try verifiedCommit(commit, git: git)]).text
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        return parents.count > 1 ? String(parents[1]) : nil
    }

    // MARK: History

    /// Commits reachable from HEAD, local and remote branches and tags, newest first with children before parents.
    public func history(limit: Int = 500) async throws -> [CommitNode] {
        let git = try runner()
        guard try git.run(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true).status == 0 else { return [] }
        let text = try git.run(["log", "-z", "--topo-order", "--decorate=short", "-n", String(max(1, limit)),
                                "--format=%H%x00%P%x00%h%x00%an%x00%ae%x00%at%x00%D%x00%s",
                                "HEAD", "--branches", "--remotes", "--tags", "--"]).text
        return CommitNode.parse(text)
    }

    /// The commit's message and the files it changed against its first parent (renames shown as delete plus add).
    public func commitDetail(_ id: String) async throws -> CommitDetail {
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        let meta = try git.run(["show", "-s", "--format=%cn%x00%ct%x00%B", object]).text
        let parts = meta.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw FolmiError.unsupported("无法读取提交信息。") }
        let base = try parentOrEmptyTree(object, git: git)
        let records = try git.run(["diff-tree", "-r", "-z", "--no-renames", "--name-status", base, object]).text
            .components(separatedBy: "\0")
        var files: [CommitFileChange] = []
        var index = 0
        while index + 1 < records.count {
            let status = records[index]
            if !status.isEmpty { files.append(CommitFileChange(path: records[index + 1], status: String(status.prefix(1)))) }
            index += 2
        }
        return CommitDetail(id: object, message: parts[2].trimmingCharacters(in: .newlines), committer: parts[0],
                            committerDate: Date(timeIntervalSince1970: TimeInterval(parts[1]) ?? 0), files: files)
    }

    /// One file's change in a commit, against its first parent. Read only: `isPartialSupported` is always false.
    public func commitDiff(_ id: String, file: CommitFileChange) async throws -> FileDiff {
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        let base = try parentOrEmptyTree(object, git: git)
        let bytes = try git.run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--full-index",
                                 "--unified=3", base, object, "--", file.path]).stdout
        let change = FileChange(path: file.path, indexCode: file.status, worktreeCode: ".")
        guard let raw = UTF8Text.decode(bytes) else {
            return FileDiff(file: change, area: .staged, rawPatch: "", hunks: [], fingerprint: object + file.path,
                            isPartialSupported: false, notice: "差异包含非 UTF-8 文本，无法显示。")
        }
        let hunks = Patch.hunks(raw)
        let notice: String? = raw.contains("Binary files ") || raw.contains("GIT binary patch") ? "二进制文件，无法显示文本差异。"
            : (hunks.isEmpty ? "没有文本差异（可能只是文件模式变化）。" : nil)
        return FileDiff(file: change, area: .staged, rawPatch: raw, hunks: hunks, fingerprint: object + "\0" + file.path,
                        isPartialSupported: false, notice: notice,
                        versions: FileVersions(old: file.status == "A" ? nil : .object(base + ":" + file.path),
                                               new: file.status == "D" ? nil : .object(object + ":" + file.path)))
    }

    func verifiedCommit(_ id: String, git: GitProcess) throws -> String {
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else { throw FolmiError.unsupported("无效的提交编号。") }
        return try git.run(["rev-parse", "--verify", "--quiet", id + "^{commit}"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parentOrEmptyTree(_ object: String, git: GitProcess) throws -> String {
        let parents = try git.run(["rev-list", "--parents", "-n", "1", object]).text
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        if parents.count > 1 { return String(parents[1]) }
        return try git.run(["hash-object", "-t", "tree", "--stdin"], input: Data()).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
