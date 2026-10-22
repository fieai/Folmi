import AppKit
import Observation
import SwiftUI
import FolmiCore

/// Every project and its linked worktrees at a glance: uncommitted changes, commits not pushed, and what the agent
/// last did there. Read in the background with plain `git status` (no file hashing), for the menu bar and ⌘⇧O.
@MainActor
@Observable
final class ProjectBoard {
    struct Row: Identifiable, Equatable {
        let path: String
        var name: String
        var branch = ""
        var changes = 0
        var ahead: Int?
        var behind: Int?
        var upstream: String?
        /// A linked worktree of `parent`, not a project of its own.
        var parent: String?
        /// A worktree's commits no other branch has (see `WorktreeStatus.ownCommits`).
        var ownCommits = 0
        /// Of the commits ahead, those already up for review on Gerrit (`FolmiModel.inReview`).
        var inReview = 0
        /// Commits ahead still waiting for a push.
        var pending: Int { max(0, (ahead ?? 0) - inReview) }
        var aiRunning = false
        var aiLabel: String?
        var aiDate: Date?
        var error: String?
        var id: String { path }
        var needsAttention: Bool { changes > 0 || pending > 0 || (behind ?? 0) > 0 || aiRunning || error != nil }
        /// A linked worktree waiting on you: uncommitted work or commits no other branch has (the same test as the
        /// project rail's 待看, `WorktreeStatus.hasWork`), or an agent at it. Being behind is left out, and so is being
        /// ahead of an upstream: most worktree branches have none, and those that do are counted by their own commits.
        var worktreeNeedsAttention: Bool { changes > 0 || ownCommits > 0 || aiRunning || error != nil }
        var isTrackingSynchronized: Bool { pending == 0 && behind == 0 }
        var statusSummary: String {
            guard error == nil else { return "项目状态读取失败" }
            let workspace = changes == 0 ? "工作区干净" : "\(changes) 个文件有改动"
            guard ahead != nil, let behind else {
                return "\(workspace) · " + (upstream == nil ? "未设置上游分支" : "未取得上游比较")
            }
            let review = inReview > 0 ? " · 评审中 \(inReview) 个提交" : ""
            if isTrackingSynchronized { return "\(workspace) · " + "与本地追踪分支一致" + review }
            let sync = [pending > 0 ? "待推送 \(pending) 个提交" : nil,
                        behind > 0 ? "待拉取 \(behind) 个提交" : nil].compactMap { $0 }.joined(separator: "，")
            return "\(workspace) · \(sync)" + review
        }
    }
    private(set) var rows: [Row] = []
    private(set) var updated: Date?
    /// A refresh is reading the projects; the rows on screen are from `updated` until it ends.
    private(set) var refreshing = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func setRowsForTesting(_ rows: [Row]) { self.rows = rows }

    /// The open project's row from the main window's own state, which is always the newest (it refreshes on every
    /// file change and after each fetch), so the menu bar never contradicts the window between two board refreshes.
    func patch(path: String, snapshot: RepositorySnapshot, inReview: Int) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        var row = rows[index]
        row.branch = snapshot.branch; row.upstream = snapshot.upstream
        row.ahead = snapshot.ahead; row.behind = snapshot.behind; row.changes = snapshot.files.count; row.inReview = inReview
        if row != rows[index] { rows[index] = row }
    }

    func worktrees(of project: Row) -> [Row] { rows.filter { $0.parent == project.path } }

    /// Projects with something waiting, their worktrees included: the number beside the menu bar icon.
    var attentionCount: Int {
        rows.filter { $0.parent == nil && ($0.needsAttention || worktrees(of: $0).contains(where: \.worktreeNeedsAttention)) }.count
    }

    func refresh(projects: [ProjectPreferences]) {
        guard task == nil else { return }
        let list = projects.map { ($0.rootPath, $0.name, $0.isDemo ? $0.environment : [:], $0.reviewWatches) }
        refreshing = true
        task = Task { [weak self] in
            var result: [Row] = []
            for (path, name, environment, watches) in list {
                let root = URL(fileURLWithPath: path)
                var row = await Self.read(root: root, name: name, environment: environment)
                if (row.ahead ?? 0) > 0, !watches.isEmpty {
                    row.inReview = await Task.detached(priority: .utility) { FolmiModel.inReview(root: root, environment: environment, watches: watches) }.value
                }
                result.append(row)
                let repository = GitRepository(url: root, environment: environment)
                let infos = ((try? await repository.worktrees()) ?? []).filter { $0.path != path && FileManager.default.fileExists(atPath: $0.path) }
                let statuses = Dictionary(await repository.worktreeStatuses(infos).map { ($0.info.path, $0) }, uniquingKeysWith: { a, _ in a })
                for info in infos {
                    row = await Self.read(root: URL(fileURLWithPath: info.path), name: (info.path as NSString).lastPathComponent, environment: environment)
                    row.parent = path
                    row.ownCommits = statuses[info.path]?.ownCommits ?? 0
                    result.append(row)
                }
            }
            guard let self else { return }
            self.rows = result; self.updated = Date(); self.task = nil; self.refreshing = false
        }
    }

    private static func read(root: URL, name: String, environment: [String: String]) async -> Row {
        var row = Row(path: root.path, name: name)
        do {
            let text = try await CommandRunner.git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"], at: root, environment: environment)
            for record in text.split(separator: "\0") {
                if record.hasPrefix("# branch.head ") { row.branch = String(record.dropFirst(14)) }
                else if record.hasPrefix("# branch.upstream ") { row.upstream = String(record.dropFirst(18)) }
                else if record.hasPrefix("# branch.ab ") {
                    let parts = record.dropFirst(12).split(separator: " ")
                    if parts.count == 2 { row.ahead = Int(parts[0].dropFirst()); row.behind = Int(parts[1].dropFirst()) }
                } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") || record.hasPrefix("u ") || record.hasPrefix("? ") { row.changes += 1 }
            }
        } catch { row.error = "无法读取" }
        if let gitDir = AIEventStore.locate(from: root)?.gitDir, let last = lastEvent(gitDir: gitDir) {
            row.aiRunning = last.kind != .stop && Date().timeIntervalSince1970 - last.t < 30 * 60
            row.aiDate = Date(timeIntervalSince1970: last.t)
            let agent = last.agent == "codex" ? "Codex" : "Claude"
            row.aiLabel = last.kind == .stop ? "\(agent) 改完了" : "\(agent) 正在改"
        }
        return row
    }

    /// The last line of the hook event log, read from its end.
    private static func lastEvent(gitDir: URL) -> AIEvent? {
        guard let handle = try? FileHandle(forReadingFrom: AIEventStore.events(gitDir: gitDir)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4_096 ? size - 4_096 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return AIEventStore.parse(data).events.last
    }

}

/// The rows of the board, for the menu bar window and the overview sheet.
struct ProjectBoardList: View {
    let board: ProjectBoard
    let current: String?
    let onOpen: (ProjectBoard.Row) -> Void
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            if board.rows.isEmpty {
                Text(board.updated == nil ? "正在读取…" : "还没有项目").themedFont(.callout, points: 12).foregroundStyle(.secondary).padding(8)
            }
            // The menu bar keeps one row per project; its worktrees fold into a line under it.
            ForEach(compact ? board.rows.filter { $0.parent == nil } : board.rows) { row in
                Button { onOpen(row) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(ThemeColor(token: row.error != nil ? .removed
                                                 : row.aiRunning || row.pending > 0 || (row.behind ?? 0) > 0 ? .modified
                                                 : row.changes > 0 ? .accent
                                                 : row.upstream == nil || row.ahead == nil || row.behind == nil ? .secondaryText : .added))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if row.parent != nil { Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                                Text(row.name).themedFont(.system(size: 13, weight: row.path == current ? .semibold : .regular), points: 13).lineLimit(1)
                                if !row.branch.isEmpty { Text(row.branch).themedFont(.caption2, points: 10).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            if !compact {
                                Text(row.statusSummary).themedFont(.caption2, points: 10).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if compact, case let trees = board.worktrees(of: row), !trees.isEmpty {
                                let waiting = trees.filter(\.worktreeNeedsAttention).count
                                Text(waiting > 0 ? "\(trees.count) 个工作树 · \(waiting) 处待看" : "\(trees.count) 个工作树")
                                    .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                            }
                            // In the menu bar only what the agent did today; older news is noise there.
                            if let label = row.aiLabel, let date = row.aiDate, !compact || row.aiRunning || Date().timeIntervalSince(date) < 24 * 3600 {
                                Text("\(label) · \(date.formatted(.relative(presentation: .named)))").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 6)
                        if let error = row.error { Text(error).themedFont(.caption2, points: 10).foregroundStyle(.themed(.removed)) }
                        if row.changes > 0 { Text("\(row.changes) 改动").themedFont(.caption2.monospacedDigit(), points: 10).foregroundStyle(.secondary) }
                        if row.pending > 0 { Text("↑\(row.pending)").themedFont(.caption2.monospacedDigit(), points: 10).foregroundStyle(.themed(.modified)) }
                        if row.inReview > 0 { Text("评审中 \(row.inReview)").themedFont(.caption2.monospacedDigit(), points: 10).foregroundStyle(.secondary) }
                        if let behind = row.behind, behind > 0 { Text("↓\(behind)").themedFont(.caption2.monospacedDigit(), points: 10).foregroundStyle(.themed(.modified)) }
                        if !row.needsAttention && row.isTrackingSynchronized { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.themed(.added)).help("工作区干净，与最近 fetch 的本地追踪分支一致") }
                    }
                    .padding(.horizontal, 8).padding(.vertical, compact ? 4 : 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help(row.statusSummary + "。同步状态根据最近 fetch 的本地追踪分支，刷新不访问远端。")
            }
        }
    }
}

/// ⌘⇧O: all projects and worktrees, who is working and what is waiting.
struct ProjectOverviewSheet: View {
    let model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("项目总览").themedFont(.headline, points: 13)
                if let updated = model.board.updated { Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))").themedFont(.caption, points: 10).foregroundStyle(.secondary) }
                Spacer()
                Button("刷新") { model.board.refresh(projects: model.projects) }.disabled(model.gitStartupState.blocksGit)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Text("同步状态来自最近 fetch 的本地追踪分支；刷新只读取本地，不访问远端。")
                .themedFont(.caption2, points: 10).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            ScrollView {
                ProjectBoardList(board: model.board, current: model.repositoryURL?.path) { row in
                    dismiss(); model.openBoardRow(row)
                }.padding(8)
            }
        }
        .frame(width: 560, height: 460)
        .onAppear { if !model.gitStartupState.blocksGit { model.board.refresh(projects: model.projects) } }
    }
}

/// Menu bar: which projects still have something uncommitted, without opening the main window.
struct MenuBarBoard: View {
    let model: FolmiModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Folmi").themedFont(.headline, points: 13)
                Spacer()
                Button("打开") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
                    .controlSize(.small)
            }
            Divider()
            ProjectBoardList(board: model.board, current: model.repositoryURL?.path, onOpen: { row in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                model.openBoardRow(row)
            }, compact: true)
            HStack(spacing: 6) {
                if model.board.refreshing { ProgressView().controlSize(.mini); Text("正在读取各项目…") }
                else if let updated = model.board.updated { Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))") }
                Text("· 远端状态来自最近一次取回")
            }
            .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("随手记…（\(model.ideaHotKey.title)）") { InboxPanel.shared.show(model: model) }.buttonStyle(.pressable).themedFont(.callout, points: 12)
                Spacer()
                // Through the app delegate, so unsaved edits still get their prompt; activate first so it shows.
                Button("退出 Folmi") { NSApp.activate(ignoringOtherApps: true); NSApp.terminate(nil) }
                    .buttonStyle(.pressable).themedFont(.callout, points: 12).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: 340)
        .onAppear { if !model.gitStartupState.blocksGit { model.board.refresh(projects: model.projects) } }
    }
}

extension FolmiModel {
    func openBoardRow(_ row: ProjectBoard.Row) {
        if projects.contains(where: { $0.rootPath == row.path }) { switchProject(row.path) }
        else { open(URL(fileURLWithPath: row.path)) }
    }
}
