import CryptoKit
import Foundation
import FolmiCore

/// The last Git status of each project, saved on the way out, so the next launch draws the window from it at once
/// and the real status replaces it a moment later. Changes are never made from it: every Git write re-checks the
/// fingerprint against the repository first.
/// The folder of the settings file the app (or a test) is using; every other file of ours lives beside it.
enum AppFiles {
    nonisolated(unsafe) static var directory = RuntimeOptions.workspaceURL.deletingLastPathComponent()
}

enum SnapshotCache {
    private static var directory: URL { AppFiles.directory.appendingPathComponent("snapshots", isDirectory: true) }
    /// One spelling per folder: Git reports /private/var/…, while a standardized URL of an existing path drops /private.
    static func key(_ root: String) -> String { URL(fileURLWithPath: root).resolvingSymlinksInPath().path }
    private static func url(_ root: String) -> URL {
        let name = SHA256.hash(data: Data(key(root).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    static func load(root: String) -> RepositorySnapshot? {
        guard let data = try? Data(contentsOf: url(root)), data.count < 8 * 1024 * 1024,
              let snapshot = try? JSONDecoder().decode(RepositorySnapshot.self, from: data),
              key(snapshot.root.path) == key(root), FileManager.default.fileExists(atPath: root) else { return nil }
        return snapshot
    }
    static func save(_ snapshot: RepositorySnapshot) {
        // Huge change sets are cheaper to read again than to decode.
        guard snapshot.files.count <= 5_000, let data = try? JSONEncoder().encode(snapshot) else { return }
        AppLog.attempt("启动缓存写入失败") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url(snapshot.root.path), options: .atomic)
        }
    }
}

struct CommitToast: Equatable {
    let id: String
    let subject: String
    let date = Date()
}
