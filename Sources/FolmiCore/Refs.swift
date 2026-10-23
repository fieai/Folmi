import Foundation

/// Branch and tag housekeeping. Each change returns the step that undoes it.
extension GitRepository {
    func validBranchName(_ name: String, git: GitProcess) throws {
        let check = try git.run(["check-ref-format", "--branch", name], allowFailure: true)
        guard check.status == 0, !name.hasPrefix("-") else { throw FolmiError.unsupported("「\(name)」不是有效的分支名。") }
    }

    func refObject(_ ref: String, git: GitProcess) throws -> String? {
        let result = try git.run(["rev-parse", "--verify", "--quiet", ref], allowFailure: true)
        guard result.status == 0 else { return nil }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `branch` has commits that no other branch, tag or remote branch has; deleting it would lose them.
    public func branchHasOwnCommits(_ branch: String) async throws -> Bool {
        let git = try runner()
        guard let object = try refObject("refs/heads/" + branch, git: git) else { throw FolmiError.unsupported("分支「\(branch)」不存在。") }
        let others = try git.run(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"]).text
            .components(separatedBy: .newlines).filter { !$0.isEmpty && $0 != "refs/heads/" + branch && !$0.hasSuffix("/HEAD") }
        let unique = try git.run(["rev-list", "--count", object, "--not"] + others).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(unique) ?? 0) > 0
    }

    public func deleteBranch(_ branch: String) async throws -> UndoStep {
        let git = try runner()
        guard let object = try refObject("refs/heads/" + branch, git: git) else { throw FolmiError.unsupported("分支「\(branch)」不存在。") }
        guard try Self.branchRef(git) != "refs/heads/" + branch else { throw FolmiError.unsupported("不能删除当前所在的分支，先切换到别的分支。") }
        let worktrees = try await worktrees()
        if let tree = worktrees.first(where: { $0.branch == branch }) {
            throw FolmiError.unsupported("分支「\(branch)」正被工作树 \(tree.path) 使用，不能删除。")
        }
        _ = try git.run(["branch", "-D", "--", branch])
        return .ref(ref: "refs/heads/" + branch, restore: object, current: nil)
    }

    public func renameBranch(_ branch: String, to name: String) async throws -> UndoStep {
        let git = try runner()
        try validBranchName(name, git: git)
        guard try refObject("refs/heads/" + branch, git: git) != nil else { throw FolmiError.unsupported("分支「\(branch)」不存在。") }
        guard try refObject("refs/heads/" + name, git: git) == nil else { throw FolmiError.unsupported("分支「\(name)」已经存在。") }
        _ = try git.run(["branch", "-m", "--", branch, name])
        return .renameBranch(from: branch, to: name)
    }

    /// An annotated tag when there is a message, a lightweight one otherwise.
    public func createTag(_ name: String, at id: String, message: String) async throws -> UndoStep {
        let git = try runner()
        let object = try verifiedCommit(id, git: git)
        let check = try git.run(["check-ref-format", "refs/tags/" + name], allowFailure: true)
        guard check.status == 0, !name.hasPrefix("-"), !name.isEmpty else { throw FolmiError.unsupported("「\(name)」不是有效的标签名。") }
        guard try refObject("refs/tags/" + name, git: git) == nil else { throw FolmiError.unsupported("标签「\(name)」已经存在。") }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { _ = try git.run(["tag", "--", name, object]) }
        else { _ = try git.run(["tag", "-a", "--cleanup=verbatim", "--file=-", "--", name, object], input: Data((text + "\n").utf8)) }
        let created = try refObject("refs/tags/" + name, git: git)
        return .ref(ref: "refs/tags/" + name, restore: nil, current: created)
    }

    public func deleteTag(_ name: String) async throws -> UndoStep {
        let git = try runner()
        guard let object = try refObject("refs/tags/" + name, git: git) else { throw FolmiError.unsupported("标签「\(name)」不存在。") }
        _ = try git.run(["tag", "-d", "--", name])
        return .ref(ref: "refs/tags/" + name, restore: object, current: nil)
    }

    /// Tags that point at `id`.
    public func tags(at id: String) async throws -> [String] {
        try runner().run(["tag", "--points-at", id]).text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    // MARK: .gitignore

    /// The line to add for a path: rooted at the repository (`/build/out.log`), a folder with a trailing slash.
    public static func ignorePattern(for path: String, folder: Bool) -> String {
        var escaped = ""
        for character in path {
            if "*?[]!#\\".contains(character) || (escaped.isEmpty && character == " ") { escaped.append("\\") }
            escaped.append(character)
        }
        if escaped.hasSuffix(" ") { escaped.insert("\\", at: escaped.index(before: escaped.endIndex)) }
        return "/" + escaped + (folder ? "/" : "")
    }

    /// Adds `pattern` as the last line of the root `.gitignore`, creating it when needed. Tracked files stay tracked
    /// (git keeps following them); the caller says so.
    public func addToGitignore(_ pattern: String) async throws {
        let root = try runner().directory
        let current = try Self.readWorktreeFile(".gitignore", root: root)
        var text = current.data.flatMap { UTF8Text.decode($0) } ?? ""
        if text.components(separatedBy: .newlines).contains(pattern) { return }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += pattern + "\n"
        try Self.writeWorktreeFile(WorktreeFile(path: ".gitignore", data: Data(text.utf8), permissions: current.permissions ?? 0o644), root: root)
    }
}

extension GitRepository {
    /// Whether git already follows anything at `path` (a file, or files under a folder).
    public func isTracked(_ path: String) async throws -> Bool {
        !(try runner().run(["ls-files", "--", path]).text.isEmpty)
    }
}

extension GitRepository {
    /// The project path for a name typed into the file tree's 新建文件 box, created inside `folder` ("" is the root).
    /// A name with slashes makes the folders on the way; a name ending in a slash is refused (that is a folder).
    public static func newFilePath(_ name: String, in folder: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolmiError.unsupported("请输入文件名。") }
        guard !trimmed.hasSuffix("/") else { throw FolmiError.unsupported("文件名不能以 / 结尾。") }
        let path = folder.isEmpty || trimmed.hasPrefix("/") ? String(trimmed.drop { $0 == "/" }) : folder + "/" + trimmed
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw FolmiError.unsupported("文件名不能包含空的路径段、. 、.. 或 .git。")
        }
        return path
    }

    /// Creates an empty file, making the folders on the way. Never overwrites, and never writes through a symlink
    /// or into a path that is a file.
    public func createFile(_ path: String) async throws {
        let root = try runner().directory
        let url = try Self.contained(path, root: root)
        let manager = FileManager.default
        var folder = root
        for component in path.split(separator: "/").dropLast() {
            folder.appendPathComponent(String(component))
            let attributes = try? manager.attributesOfItem(atPath: folder.path)
            switch attributes?[.type] as? FileAttributeType {
            case nil: try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            case .typeDirectory?: continue
            case .typeSymbolicLink?: throw FolmiError.unsupported("\(component) 是符号链接，不在里面新建文件。")
            default: throw FolmiError.unsupported("已经有一个叫 \(component) 的文件，不能把它当文件夹。")
            }
        }
        guard (try? manager.attributesOfItem(atPath: url.path)) == nil else {
            throw FolmiError.unsupported("已经有 \(path) 了。")
        }
        try Data().write(to: url, options: .withoutOverwriting)
    }
}
