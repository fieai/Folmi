import AppKit
import Foundation
import FolmiCore

/// One turn of an AI agent in this repository, read from the hook events.
struct AIBatch: Identifiable, Equatable {
    let id: String
    let session: String
    var prompt: String?
    var started: Date
    var agent = "claude"
    var agentTitle: String { agent == "codex" ? "Codex" : "Claude" }
    var stopped: Date?
    /// Changed paths in the order they were first touched.
    var paths: [String] = []
    /// Paths whose content before the turn was kept (Edit / Write); only these can be taken back.
    var restorable: Set<String> = []
    /// The turn also ran shell commands, which may have changed files the hooks cannot see.
    var usedShell = false
    /// The touched files right after the turn, for refusing an undo that would overwrite later edits.
    var expected: UndoStep?
    /// The turn ended with no record of the files as it left them (an older hook, and the app was not watching then):
    /// later edits cannot be told apart from the agent's, so the whole turn is not taken back.
    var resultUnknown = false
    var ambiguousLegacySnapshot = false
    var undone = false
    /// Each edit in order, for 回放: when, which file, which tool.
    var steps: [AIStep] = []

    var isRunning: Bool { stopped == nil && Date().timeIntervalSince(started) < 30 * 60 }
    var canUndo: Bool { stopped != nil && !undone && !restorable.isEmpty }
    var label: String { prompt.map { "「\($0)」" } ?? "" }
}

struct AIStep: Equatable, Hashable {
    let time: Date
    let path: String
    let tool: String?
}

/// The capsule above the cards: what the agent is doing now, or what it just finished.
enum AIActivityCapsule: Equatable {
    case working(files: Int, prompt: String?)
    case finished(files: Int, prompt: String?, batch: String)
    /// No hooks installed: files changed while the app was in the background.
    case external(files: Int, key: String)
}

/// Writes only project hooks, preserving other hooks. Codex requires the user to trust these via `/hooks`.
enum HooksInstaller {
    enum Agent: String, CaseIterable { case claude, codex }
    static let marker = "folmi-hook"
    static let editTools = "Edit|Write|MultiEdit|NotebookEdit"

    /// The helper copied to a fixed place, so hooks keep working when the app moves.
    static var installedHelper: URL {
        AppFiles.directory.appendingPathComponent("bin/folmi-hook")
    }
    private static var bundledHelper: URL? { bundledHelperPath() }
    static func settingsURL(_ root: URL, agent: Agent = .claude) -> URL {
        root.appendingPathComponent(agent == .codex ? ".codex/hooks.json" : ".claude/settings.local.json")
    }

    struct Status: Equatable { var installed: Bool; var guarded: Bool }
    static func status(_ root: URL, agent: Agent = .claude) -> Status {
        guard let hooks = (try? readSettings(root, agent: agent))?["hooks"] as? [String: Any] else { return Status(installed: false, guarded: false) }
        let commands = hooks.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["command"] as? String }.compactMap(ourMode)
        return Status(installed: !commands.isEmpty, guarded: commands.contains("guard"))
    }

    static func install(_ root: URL, agent: Agent = .claude, guarded: Bool, helper: URL? = nil, destination: URL? = nil) throws {
        let installedHelper = destination ?? Self.installedHelper
        guard let source = helper ?? bundledHelper else {
            throw FolmiFailure(message: "找不到随 Folmi 提供的 folmi-hook。请用打包后的 App（scripts/build-app.sh）安装。")
        }
        try installHelper(source: source, destination: installedHelper)
        var settings = try readSettings(root, agent: agent) ?? [:]
        var hooks = removeOurs(settings["hooks"] as? [String: Any] ?? [:])
        let quotedHelper = "'" + installedHelper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = { (mode: String, timeout: Int) -> [String: Any] in
            ["type": "command", "command": "\(quotedHelper) \(mode)" + (agent == .codex ? " --agent codex" : ""), "timeout": timeout]
        }
        func add(_ event: String, matcher: String?, _ mode: String, timeout: Int = 10) {
            var group: [String: Any] = ["hooks": [command(mode, timeout)]]
            if let matcher { group["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        add("UserPromptSubmit", matcher: nil, "prompt")
        let edits = agent == .codex ? "apply_patch|Edit|Write" : editTools
        add("PreToolUse", matcher: edits, "pre")
        if guarded { add("PreToolUse", matcher: "Bash", "guard") }
        add("PostToolUse", matcher: edits + "|Bash", "post")
        add("Stop", matcher: nil, "stop")
        if agent == .codex { add("Interrupt", matcher: nil, "stop", timeout: 3) }
        settings["hooks"] = hooks
        try writeSettings(settings, root: root, agent: agent)
    }

    /// Copies the bundled helper (or `source`) to `destination`, replacing an older copy.
    static func installHelper(source: URL? = nil, destination: URL) throws {
        guard let source = source ?? bundledHelper else {
            throw FolmiFailure(message: "找不到随 Folmi 提供的 folmi-hook。请用打包后的 App（scripts/build-app.sh）安装。")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: source, to: destination)
    }

    /// Hooks run the copy made when they were installed; a newer App brings a newer helper. Replaces that copy
    /// when it differs from the bundled one (renamed into place, so a hook running now never reads half a file).
    /// Returns whether it was replaced.
    @discardableResult
    nonisolated static func refreshInstalledHelper(source: URL? = nil, destination: URL) throws -> Bool {
        let manager = FileManager.default
        guard let source = source ?? bundledHelperPath() else { return false }
        guard manager.fileExists(atPath: destination.path),
              !manager.contentsEqual(atPath: source.path, andPath: destination.path) else { return false }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".folmi-hook-\(UUID().uuidString)")
        try manager.copyItem(at: source, to: staging)
        do { _ = try manager.replaceItemAt(destination, withItemAt: staging) }
        catch { try? manager.removeItem(at: staging); throw error }
        return true
    }
    private nonisolated static func bundledHelperPath() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("folmi-hook")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    static func uninstall(_ root: URL, agent: Agent = .claude) throws {
        guard var settings = try readSettings(root, agent: agent) else { return }
        let hooks = removeOurs(settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(settings, root: root, agent: agent)
    }

    /// Drops every hook whose command is ours, and groups and events left empty.
    private static func removeOurs(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let others = list.filter { ($0["command"] as? String).flatMap(ourMode) == nil }
                if others.isEmpty { return nil }
                var copy = group; copy["hooks"] = others; return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    /// Match the executable and mode, not an incidental mention in another user's hook.
    private static func ourMode(_ command: String) -> String? {
        var executable = "", quote: Character?, escaped = false
        var remainder = command[...].drop(while: { $0.isWhitespace })
        while let character = remainder.first {
            remainder = remainder.dropFirst()
            if escaped { executable.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { executable.append(character) }
            } else if character == "'" || character == "\"" { quote = character }
            else if character.isWhitespace { break }
            else { executable.append(character) }
        }
        let arguments = remainder.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard quote == nil, !escaped, URL(fileURLWithPath: executable).lastPathComponent == marker,
              let mode = arguments.first, ["prompt", "pre", "post", "stop", "guard"].contains(mode),
              arguments.count == 1 || arguments == [mode, "--agent", "codex"] else { return nil }
        return mode
    }

    private static func readSettings(_ root: URL, agent: Agent) throws -> [String: Any]? {
        let url = settingsURL(root, agent: agent)
        try validateSettingsPath(url, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FolmiFailure(message: "\(url.path) 不是 JSON 对象，没有修改它。")
        }
        if let hooks = object["hooks"] {
            guard let hooks = hooks as? [String: Any], hooks.values.allSatisfy({ $0 is [[String: Any]] }) else {
                throw FolmiFailure(message: "\(url.path) 的 hooks 格式无效，没有修改它。")
            }
        }
        return object
    }
    private static func validateSettingsPath(_ url: URL, root: URL) throws {
        guard AIEventStore.safeRelativePath(url.path, cwd: root, root: root) != nil else {
            throw FolmiFailure(message: "钩子配置路径包含符号链接或不是普通文件，没有修改它：\(url.path)")
        }
    }
    private static func writeSettings(_ settings: [String: Any], root: URL, agent: Agent) throws {
        let url = settingsURL(root, agent: agent)
        try validateSettingsPath(url, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

extension FolmiModel {
    var aiGitDir: URL? { repositoryURL.flatMap { AIEventStore.locate(from: $0)?.gitDir } }

    /// New lines in the hook's error log go to the activity list, so a copy it could not keep is not a silent gap.
    func readHookErrors() {
        guard let root = repositoryURL, let gitDir = aiGitDir,
              let handle = try? FileHandle(forReadingFrom: AIEventStore.errorLog(gitDir: gitDir)) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let known = hookErrorOffsets[root.path]
        hookErrorOffsets[root.path] = size
        // The first look at a project only remembers where the log ends: old lines were shown before or are stale.
        guard let known, size > known else { return }
        try? handle.seek(toOffset: known)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n").suffix(5) { record("Claude 钩子出错", String(line), isError: true) }
    }

    /// Reads new hook events of the open project. Cheap: only bytes appended since the last read.
    func readAIEvents() {
        readHookErrors()
        readCommentReplies()
        guard let root = repositoryURL, let gitDir = aiGitDir else { return }
        let url = AIEventStore.events(gitDir: gitDir)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let key = root.path
        var offset = aiEventOffsets[key] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; aiBatchStore[key] = [] }
        guard size > offset else { return }
        // At most the last 4 MiB on first read: older turns are not worth showing (a cut first line is skipped).
        let start = offset == 0 && size > 4 * 1024 * 1024 ? size - 4 * 1024 * 1024 : offset
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return }
        let parsed = AIEventStore.parse(data)
        aiEventOffsets[key] = start + UInt64(parsed.consumed)
        guard !parsed.events.isEmpty else { return }
        var batches = aiBatchStore[key] ?? []
        var finished: [(id: String, at: Double)] = []
        for event in parsed.events {
            var index = batches.firstIndex { $0.id == event.batch }
            if index == nil {
                batches.append(AIBatch(id: event.batch, session: event.session, prompt: event.prompt, started: Date(timeIntervalSince1970: event.t)))
                index = batches.count - 1
            }
            guard let i = index else { continue }
            if let agent = event.agent { batches[i].agent = agent }
            switch event.kind {
            case .start: if let prompt = event.prompt { batches[i].prompt = prompt }
            case .edit:
                if event.tool == "Bash" { batches[i].usedShell = true }
                if let path = event.path {
                    if !batches[i].paths.contains(path) { batches[i].paths.append(path) }
                    batches[i].steps.append(AIStep(time: Date(timeIntervalSince1970: event.t), path: path, tool: event.tool))
                }
            case .stop:
                if batches[i].stopped == nil { batches[i].stopped = Date(timeIntervalSince1970: event.t); finished.append((event.batch, event.t)) }
            }
        }
        for index in batches.indices {
            let pre = AIEventStore.batch(batches[index].id, gitDir: gitDir).appendingPathComponent("pre")
            batches[index].ambiguousLegacySnapshot = AIEventStore.hasAmbiguousLegacySnapshot(pre)
            batches[index].restorable = AIEventStore.keptPaths(pre)
            for path in batches[index].restorable where !batches[index].paths.contains(path) { batches[index].paths.append(path) }
        }
        aiBatchStore[key] = Array(batches.suffix(30))
        aiBatches = aiBatchStore[key] ?? []
        updateCapsule()
        schedulePublishShared()
        // What the files hold right after a turn ends: an undo later must not overwrite anything newer.
        for (id, at) in finished { captureBatchResult(id, stoppedAt: at, gitDir: gitDir); notifyAIFinished(id) }
    }

    /// How long after a turn stops the files read now still count as what the turn left (older hooks wrote no
    /// end snapshot; the app catches the stop as it happens).
    static let liveStopWindow: TimeInterval = 5

    /// The files as the turn left them: the hook's end snapshot, or (older hooks) the files now if the stop was
    /// just seen live. Anything else would take later edits for the agent's and let an undo overwrite them.
    private func captureBatchResult(_ id: String, stoppedAt: Double, gitDir: URL) {
        guard let repository, let root = repositoryURL, let batch = aiBatches.first(where: { $0.id == id }), !batch.restorable.isEmpty else { return }
        let paths = Array(batch.restorable)
        let post = AIEventStore.post(batch: id, gitDir: gitDir)
        Task { [weak self] in
            var after: UndoStep?
            var unknown = false
            if FileManager.default.fileExists(atPath: post.path) {
                after = await Task.detached(priority: .utility) { Self.readSnapshot(post, paths: paths) }.value
                unknown = after == nil
            } else if Date().timeIntervalSince1970 - stoppedAt <= Self.liveStopWindow {
                do { after = try await repository.captureWorktree(paths) }
                catch { AppLog.failure("记录 Claude 这一轮结束时的文件失败", error) }
            } else { unknown = true }
            guard let self, self.repositoryURL == root, let index = self.aiBatchStore[root.path]?.firstIndex(where: { $0.id == id }) else { return }
            self.aiBatchStore[root.path]?[index].expected = after
            self.aiBatchStore[root.path]?[index].resultUnknown = unknown
            self.aiBatches = self.aiBatchStore[root.path] ?? []
        }
    }

    /// The end snapshot as an undo step over `paths`; nil if it does not cover them all.
    nonisolated static func readSnapshot(_ folder: URL, paths: [String]) -> UndoStep? {
        var files: [WorktreeFile] = []
        for path in Set(paths).sorted() {
            let url = folder.appendingPathComponent(path)
            if AIEventStore.isAbsent(path, in: folder) { files.append(WorktreeFile(path: path, data: nil, permissions: nil)); continue }
            guard let data = try? Data(contentsOf: url) else { return nil }
            let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            files.append(WorktreeFile(path: path, data: data, permissions: permissions?.intValue))
        }
        return .worktree(files)
    }

    func updateCapsule() {
        let next: AIActivityCapsule?
        if let running = aiBatches.last(where: \.isRunning) {
            next = .working(files: running.paths.count, prompt: running.prompt)
        } else if let last = aiBatches.last(where: { !$0.paths.isEmpty }), let stopped = last.stopped, !last.undone,
                  Date().timeIntervalSince(stopped) < 10 * 60, dismissedCapsule != last.id {
            next = .finished(files: last.paths.count, prompt: last.prompt, batch: last.id)
        } else if case .external(_, let key)? = capsule, dismissedCapsule != key {
            next = capsule
        } else { next = nil }
        if capsule != next { capsule = next }
    }
    var capsuleAgentTitle: String {
        if let running = aiBatches.last(where: \.isRunning) { return running.agentTitle }
        if case .finished(_, _, let id)? = capsule { return aiBatches.first { $0.id == id }?.agentTitle ?? "AI" }
        return "AI"
    }
    func dismissCapsule() {
        if case .finished(_, _, let batch) = capsule { dismissedCapsule = batch }
        if case .external(_, let key) = capsule { dismissedCapsule = key }
        capsule = nil
    }
    /// Without hooks: changes that arrived while the app was in the background, said once when they land.
    func noteExternalChanges(from old: RepositorySnapshot, to new: RepositorySnapshot) {
        guard !(NSApp?.isActive ?? true), aiBatches.last(where: \.isRunning) == nil, aiBatches.isEmpty || capsule == nil else { return }
        let before = Dictionary(old.files.map { ($0.path, $0.indexCode + $0.worktreeCode) }, uniquingKeysWith: { a, _ in a })
        let changed = new.files.filter { before[$0.path] == nil || before[$0.path] != $0.indexCode + $0.worktreeCode }.count
        guard changed > 0 else { return }
        var total = changed
        if case .external(let files, _) = capsule { total += files }
        capsule = .external(files: total, key: new.fingerprint)
    }

    /// Puts back what the files held before the agent's latest finished turn. Goes on the ⌘Z stack, so ⌘⇧Z redoes it.
    func undoLatestAIBatch() {
        guard let batch = aiBatches.last(where: { $0.stopped != nil && !$0.undone && !$0.paths.isEmpty }) else { NSSound.beep(); return }
        undoAIBatch(batch.id)
    }
    func undoAIBatch(_ id: String) {
        guard let repository, let root = repositoryURL, let gitDir = aiGitDir,
              let batch = aiBatches.first(where: { $0.id == id }) else { NSSound.beep(); return }
        guard !batch.ambiguousLegacySnapshot else {
            report(FolmiFailure(message: "这一轮的旧快照含 .absent 后缀，无法区分真实文件与缺失标记。为避免误删文件，不能整批撤回；请在「全部改动」里按块处理。新的钩子已使用独立的缺失记录。"), title: "没有撤回")
            return
        }
        guard batch.canUndo else { NSSound.beep(); return }
        var files: [WorktreeFile] = []
        for path in batch.restorable.sorted() {
            let pre = AIEventStore.preImage(path, batch: id, gitDir: gitDir)
            let preFolder = AIEventStore.batch(id, gitDir: gitDir).appendingPathComponent("pre")
            if AIEventStore.isAbsent(path, in: preFolder) {
                files.append(WorktreeFile(path: path, data: nil, permissions: nil))
            } else if let data = try? Data(contentsOf: pre) {
                let permissions = (try? FileManager.default.attributesOfItem(atPath: pre.path))?[.posixPermissions] as? NSNumber
                files.append(WorktreeFile(path: path, data: data, permissions: permissions?.intValue))
            }
        }
        guard !files.isEmpty else { NSSound.beep(); return }
        // Without the files as the turn left them, an undo could not tell whether they were edited since.
        guard let expected = batch.expected else {
            let message = batch.resultUnknown
                ? "这一轮结束时没有留下当时文件的样子，分不清之后的改动是不是 \(batch.agentTitle) 做的；为了不覆盖它们，不能整批撤回。可以在「全部改动」里按块处理，并在「接入 agent」中更新钩子。"
                : "还没记下这一轮结束时的文件（刚结束时稍等一下再试）；为了不覆盖之后的改动，这次没有撤回。可以在「全部改动」里按块处理。"
            report(FolmiFailure(message: message), title: "没有撤回")
            return
        }
        let title = "撤回 \(batch.agentTitle) 的一批改动\(batch.label)"
        let untracked = Set(batch.paths).subtracting(batch.restorable)
        mutate(title) { [weak self] in
            if try await repository.recapture(expected) != expected {
                throw FolmiFailure(message: "这批改动之后文件又被改过，整批撤回会覆盖那些改动，所以没有执行。可以在「全部改动」里按块处理。")
            }
            let inverse = try await repository.undo(.worktree(files))
            await MainActor.run {
                guard let self else { return }
                if let index = self.aiBatchStore[root.path]?.firstIndex(where: { $0.id == id }) { self.aiBatchStore[root.path]?[index].undone = true }
                self.aiBatches = self.aiBatchStore[root.path] ?? []
                // ⌘Z after this puts the agent's result back.
                self.pushUndo(title, inverse, expected: .worktree(files))
                self.updateCapsule()
                self.recordDaily(.aiUndone)
            }
            var note = files.map(\.path).joined(separator: "\n")
            if !untracked.isEmpty || batch.usedShell {
                note += "\n\n命令行（Bash）改过的文件无法自动撤回" + (untracked.isEmpty ? "。" : "：\n" + untracked.sorted().joined(separator: "\n"))
            }
            return note
        }
    }

    /// 回放: one file of a turn, from the copy saved before the turn to the file right after it (the snapshot taken
    /// when the turn ended, or the file as it is now while the turn runs). Nil before: a file Claude created.
    /// Turns worth picking in 全部改动: ones that changed files and were not taken back, newest first.
    var turnChoices: [AIBatch] { aiBatches.filter { !$0.paths.isEmpty && !$0.undone }.reversed().prefix(20).map { $0 } }

    /// 全部改动 showing only what one turn touched (nil: everything).
    func showTurn(_ id: String?) {
        turnFilter = id
        showContent(.allChanges)
    }

    /// 全部改动 as the page shows it: everything, or only the files the filtered turn touched.
    var visibleAllChanges: [FileDiff] {
        guard let id = turnFilter, let turn = aiBatches.first(where: { $0.id == id }) else { return allChanges }
        let paths = Set(turn.paths)
        return allChanges.filter { paths.contains($0.file.path) }
    }

    /// Whether a turn after `id` edited `path` as well: then the file's diff mixes both turns.
    func laterTurnTouched(_ path: String, after id: String) -> Bool {
        guard let index = aiBatches.firstIndex(where: { $0.id == id }) else { return false }
        return aiBatches[(index + 1)...].contains { !$0.undone && $0.paths.contains(path) }
    }

    /// One file as one turn left it: before the turn against right after it (read only, for 只看这一轮).
    func turnDiff(batch id: String, path: String) async -> (diff: FileDiff?, note: String?) {
        guard let repository, let root = repositoryURL, let gitDir = aiGitDir, let batch = aiBatches.first(where: { $0.id == id }) else {
            return (nil, "这一轮的记录已经不在了。")
        }
        guard batch.restorable.contains(path) else {
            return (nil, "这个文件是用命令行（Bash）改的，钩子没有存下改之前的内容，只能在「全部改动」里看现在的差异。")
        }
        let absent = AIEventStore.isAbsent(path, in: AIEventStore.batch(id, gitDir: gitDir).appendingPathComponent("pre"))
        let before = absent ? nil : try? Data(contentsOf: AIEventStore.preImage(path, batch: id, gitDir: gitDir))
        var after: Data?
        var note: String?
        if case .worktree(let files)? = batch.expected, let file = files.first(where: { $0.path == path }) {
            after = file.data
        } else {
            after = try? Data(contentsOf: root.appendingPathComponent(path))
            note = batch.stopped == nil ? "这一轮还没结束，右边是文件现在的样子。" : "右边是文件现在的样子（这一轮结束时没有留下快照）。"
        }
        do { return (try await repository.contentDiff(path: path, before: before, after: after), note) }
        catch { return (nil, error.localizedDescription) }
    }

    /// Keeps the last 20 turns' saved files and nothing older than a week.
    func pruneAIBatches() {
        guard let gitDir = aiGitDir else { return }
        let folder = AIEventStore.directory(gitDir: gitDir).appendingPathComponent("batches")
        Task.detached(priority: .background) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let dated = items.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            for (index, item) in dated.enumerated() where index >= 20 || item.1 < Date().addingTimeInterval(-7 * 86_400) {
                try? FileManager.default.removeItem(at: item.0)
            }
        }
    }
}

extension FolmiModel {
    /// "Claude 改完了 … · 5 处等你验收": what is waiting, said once when a project opens.
    func prepareOpeningBanner() async {
        guard let root = repositoryURL, let files = snapshot?.files, !files.isEmpty else { openingBanner = nil; return }
        // Counting hunks reads every diff; a big change set is only counted by files so opening stays quick.
        guard files.count <= 60 else {
            openingBanner = aiBatches.last(where: { $0.stopped != nil && !$0.undone && !$0.paths.isEmpty }).map { "\($0.agentTitle) 改完了\($0.label) · \(files.count) 个文件等你验收" }
                ?? "\(files.count) 个文件有改动"
            return
        }
        if allChanges.isEmpty { await loadAllChanges() }
        guard repositoryURL == root else { return }
        let tally = reviewTally
        guard tally.remaining > 0 else { openingBanner = nil; return }
        // Where things were left: what waits for review, plus commits made but not pushed yet.
        let unpushed = snapshot?.unpushed ?? 0
        let tail = unpushed > 0 ? " · \(unpushed) 个提交没推送" : ""
        if let last = aiBatches.last(where: { $0.stopped != nil && !$0.undone && !$0.paths.isEmpty }) {
            openingBanner = "\(last.agentTitle) 改完了\(last.label) · \(tally.remaining) 处等你验收" + tail
        } else if tally.seen > 0 {
            // Some of these were seen before: a review was left half done.
            openingBanner = "上次还有 \(tally.remaining) 处没看完" + tail
        } else {
            openingBanner = "\(tally.remaining) 处改动等你看" + tail
        }
    }
}
