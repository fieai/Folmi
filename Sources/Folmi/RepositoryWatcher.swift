import FolmiCore
import CoreServices
import Foundation

/// Watches a work tree and its Git directory with FSEvents and reports coalesced, relevant changes on the main queue.
/// Events only trigger a quiet status check; nothing here reads file contents.
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    /// Called with `true` when the batch touched the Git directory (refs, index, HEAD), `false` for work tree files only.
    private let onChange: (Bool) -> Void
    private let gitDirectories: [String]

    /// Generated or dependency folders whose churn never needs a Git status refresh on its own.
    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".build", "__pycache__", ".venv", "venv", ".next", ".nuxt", ".cache", ".gradle", "deriveddata"
    ]
    /// Git internals that change without affecting status (object writes, reflogs, lock files).
    private static let ignoredGitDirectories: Set<String> = ["objects", "logs", "hooks", "lfs"]

    /// `directories`: the work tree first, then Git directories that live outside it (linked worktrees).
    init?(directories: [URL], latency: TimeInterval = 0.3, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        gitDirectories = directories.dropFirst().map { $0.standardizedFileURL.path + "/" }
        let paths = Array(Set(directories.map { $0.standardizedFileURL.path })) as CFArray
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            let relevant = paths.prefix(count).filter(RepositoryWatcher.isRelevant)
            guard !relevant.isEmpty else { return }
            watcher.onChange(relevant.contains { RepositoryWatcher.isGitPath($0, gitDirectories: watcher.gitDirectories) })
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    static func isGitPath(_ path: String, gitDirectories: [String]) -> Bool {
        path.split(separator: "/").contains(".git") || gitDirectories.contains { (path + "/").hasPrefix($0) }
    }

    static func isRelevant(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if let last = components.last, last.hasSuffix(".lock") { return false }
        if components.contains(where: { ignoredDirectories.contains($0.lowercased()) }) { return false }
        if let git = components.lastIndex(of: ".git"), git + 1 < components.count, ignoredGitDirectories.contains(components[git + 1]) {
            return false
        }
        // folmi-hook's saved copies; its events.jsonl next to them does matter.
        if let index = components.lastIndex(of: "folmi"), index + 1 < components.count, components[index + 1] == "batches" { return false }
        // The app's own writes for the MCP server; the agent's replies next to them do matter.
        if components.count >= 2, components[components.count - 2] == "folmi", FolmiShared.appWrittenFiles.contains(components[components.count - 1]) {
            return false
        }
        return true
    }
}
