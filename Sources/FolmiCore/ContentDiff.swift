import Foundation

extension GitRepository {
    /// A read-only diff between two versions of one file given as bytes (nil: the file did not exist), shown with
    /// the usual hunks. Used to replay a Claude turn: the copy saved before it, against the file right after it.
    public func contentDiff(path: String, before: Data?, after: Data?) async throws -> FileDiff {
        let git = try runner()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-replay-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        func place(_ data: Data?, _ name: String) throws -> String {
            guard let data else { return "/dev/null" }
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url.path
        }
        let old = try place(before, "before"), new = try place(after, "after")
        // --no-index exits 1 when the files differ.
        let output = try git.run(["diff", "--no-index", "--no-color", "--no-ext-diff", "-U3", "--", old, new], allowFailure: true)
        guard output.status <= 1 else {
            throw FolmiError.git(exitCode: output.status, message: String(decoding: output.stderr, as: UTF8.self))
        }
        let raw = output.text
        let binary = raw.contains("Binary files ")
        let code = before == nil ? "A" : (after == nil ? "D" : "M")
        return FileDiff(file: FileChange(path: path, indexCode: ".", worktreeCode: code), area: .working, rawPatch: raw,
                        hunks: binary ? [] : Patch.hunks(raw), fingerprint: "replay", isPartialSupported: false,
                        notice: binary ? "二进制文件，没有文本差异。" : (raw.isEmpty ? "这一轮前后内容相同。" : nil),
                        versions: FileVersions(old: before.map(FileVersion.bytes), new: after.map(FileVersion.bytes)))
    }
}
