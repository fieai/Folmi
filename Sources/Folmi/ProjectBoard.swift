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
        var unaccepted = 0
        var ahead: Int?
        var behind: Int?
        var unpushed: Int?
        var upstream: String?
        /// A linked worktree of `parent`, not a project of its own.
        var parent: String?
        /// A worktree's commits no other branch has (see `WorktreeStatus.ownCommits`).
        var ownCommits = 0
        /// Of the commits absent from remote branches, those already up for review on Gerrit.
        var inReview = 0
        var pending: Int { max(0, (unpushed ?? ahead ?? 0) - inReview) }
        var hookEvent: AIEvent?
        var acpAttention: AgentAttention?
        var attention: AgentAttention? {
            AgentAttention.highest(acpAttention, hookEvent.flatMap { AgentAttention.hook($0, unaccepted: unaccepted) })
        }
        var error: String?
        var id: String { path }
        var needsAttention: Bool { changes > 0 || pending > 0 || (behind ?? 0) > 0 || attention != nil || error != nil }
        /// A linked worktree waiting on you: uncommitted work or commits no other branch has (the same test as the
        /// project rail's 待看, `WorktreeStatus.hasWork`), or an agent at it. Being behind is left out, and so is being
        /// ahead of an upstream: most worktree branches have none, and those that do are counted by their own commits.
        var worktreeNeedsAttention: Bool { changes > 0 || ownCommits > 0 || attention != nil || error != nil }
        var isTrackingSynchronized: Bool { pending == 0 && ahead == inReview && behind == 0 }
        var statusSummary: String {
            guard error == nil else { return "项目状态读取失败" }
            let workspace = changes == 0 ? "工作区干净" : "\(changes) 个文件有改动"
            let review = inReview > 0 ? " · 评审中 \(inReview) 个提交" : ""
            let sync = [pending > 0 ? "待推送 \(pending) 个提交" : nil,
                        behind.flatMap { $0 > 0 ? "待拉取 \($0) 个提交" : nil }].compactMap { $0 }.joined(separator: "，")
            if !sync.isEmpty { return "\(workspace) · \(sync)" + review }
            if isTrackingSynchronized { return "\(workspace) · 与本地追踪分支一致" + review }
            if let ahead, ahead > 0 { return "\(workspace) · 领先上游 \(ahead) 个提交" + review }
            return "\(workspace) · " + (upstream == nil ? "未设置上游分支" : "未取得上游比较") + review
        }
    }
    private(set) var rows: [Row] = []
    private(set) var updated: Date?
    /// A refresh is reading the projects; the rows on screen are from `updated` until it ends.
    private(set) var refreshing = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var readingPaths: [String] = []
    @ObservationIgnored private var pendingProjects: [ProjectPreferences]?
    @ObservationIgnored private var eventWatches: [String: AgentEventWatch] = [:]
    @ObservationIgnored private var environments: [String: [String: String]] = [:]
    @ObservationIgnored private var acpReports: [String: AgentAttention] = [:]
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var currentSnapshot: (path: String, snapshot: RepositorySnapshot, inReview: Int)?
    @ObservationIgnored private var changedDuringRefresh: [String: (changes: Int, unaccepted: Int)] = [:]
    @ObservationIgnored private var pathReads: [String: Task<Void, Never>] = [:]

    func setRowsForTesting(_ rows: [Row]) { self.rows = rows }

    /// The open project's snapshot is newer than a plain status read and includes staging as soon as it happens.
    func patch(path: String, snapshot: RepositorySnapshot, inReview: Int) {
        snapshotRevision &+= 1
        currentSnapshot = (path, snapshot, inReview)
        changedDuringRefresh[path] = nil
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        var row = rows[index]
        Self.patch(&row, snapshot: snapshot, inReview: inReview)
        if row != rows[index] { rows[index] = row }
    }

    private static func patch(_ row: inout Row, snapshot: RepositorySnapshot, inReview: Int) {
        row.branch = snapshot.branch; row.upstream = snapshot.upstream
        row.ahead = snapshot.ahead; row.behind = snapshot.behind; row.unpushed = snapshot.unpushed
        row.changes = snapshot.files.count; row.inReview = inReview
        row.unaccepted = snapshot.files.count(where: \.hasWorking)
    }

    func updateAgentAttention(_ reports: [String: AgentAttention]) {
        guard reports != acpReports else { return }
        acpReports = reports
        for index in rows.indices {
            let attention = reports[rows[index].path]
            if rows[index].acpAttention != attention { rows[index].acpAttention = attention }
        }
    }

    func worktrees(of project: Row) -> [Row] { rows.filter { $0.parent == project.path } }

    func attention(for path: String, includeWorktrees: Bool) -> AgentAttention? {
        if let attention = rows.first(where: { $0.path == path })?.attention { return attention }
        guard includeWorktrees else { return nil }
        return rows.lazy.filter { $0.parent == path }.reduce(nil) { AgentAttention.highest($0, $1.attention) }
    }

    /// Projects with something waiting, their worktrees included: the number beside the menu bar icon.
    var attentionCount: Int {
        rows.filter { $0.parent == nil && ($0.needsAttention || worktrees(of: $0).contains(where: \.worktreeNeedsAttention)) }.count
    }

    func refresh(projects: [ProjectPreferences]) {
        let paths = projects.map(\.rootPath)
        if task != nil {
            // A project can be added or removed while Git is still reading the previous list.
            pendingProjects = paths == readingPaths ? nil : projects
            return
        }
        readingPaths = paths
        let list = projects.map { ($0.rootPath, $0.name, $0.isDemo ? $0.environment : [:], $0.reviewWatches) }
        let names = Dictionary(projects.map { ($0.rootPath, $0.name) }, uniquingKeysWith: { first, _ in first })
        let listedPaths = Dictionary(paths.map { (RailEntry.canonical($0), $0) }, uniquingKeysWith: { first, _ in first })
        let startingRevision = snapshotRevision
        changedDuringRefresh.removeAll()
        refreshing = true
        task = Task { [weak self] in
            var result: [Row] = []
            var environments: [String: [String: String]] = [:]
            for (path, name, environment, watches) in list {
                let root = URL(fileURLWithPath: path)
                var row = await Self.read(root: root, name: name, environment: environment)
                if row.pending > 0, !watches.isEmpty {
                    row.inReview = await Task.detached(priority: .utility) { FolmiModel.inReview(root: root, environment: environment, watches: watches) }.value
                }
                result.append(row)
                environments[path] = environment
                // The main project lists the same worktrees, including this one.
                if let main = WorktreeInfo.mainRoot(of: path), listedPaths[RailEntry.canonical(main)] != nil { continue }
                let repository = GitRepository(url: root, environment: environment)
                let canonicalPath = RailEntry.canonical(path)
                let infos = ((try? await repository.worktrees()) ?? []).filter {
                    RailEntry.canonical($0.path) != canonicalPath && FileManager.default.fileExists(atPath: $0.path)
                }
                let statuses = Dictionary(await repository.worktreeStatuses(infos).map { ($0.info.path, $0) }, uniquingKeysWith: { a, _ in a })
                for info in infos {
                    let treePath = listedPaths[RailEntry.canonical(info.path)] ?? info.path
                    row = await Self.read(root: URL(fileURLWithPath: treePath), name: names[treePath] ?? (treePath as NSString).lastPathComponent,
                                          environment: environment)
                    row.parent = path
                    row.ownCommits = statuses[info.path]?.ownCommits ?? 0
                    result.append(row)
                    environments[treePath] = environment
                }
            }
            guard let self else { return }
            self.task = nil
            if let next = self.pendingProjects {
                self.pendingProjects = nil
                self.refresh(projects: next)
                return
            }
            // An explicitly opened worktree can also be found from its main project. Keep its link and one path ID.
            let groups = Dictionary(grouping: result, by: \.path)
            var seen: Set<String> = []
            result = result.compactMap { row in
                guard seen.insert(row.path).inserted else { return nil }
                let copies = groups[row.path] ?? []
                var preferred = copies.first { $0.parent == nil } ?? row
                let parent = copies.first { $0.parent != nil }
                preferred.parent = parent?.parent
                preferred.ownCommits = parent?.ownCommits ?? 0
                return preferred
            }
            self.environments = environments
            self.eventWatches = self.eventWatches.filter { seen.contains($0.key) }
            for path in self.pathReads.keys.filter({ !seen.contains($0) }) {
                self.pathReads.removeValue(forKey: path)?.cancel()
            }
            for index in result.indices {
                let path = result[index].path
                result[index].hookEvent = self.eventWatches[path]?.last
                result[index].acpAttention = self.acpReports[path]
                if self.snapshotRevision != startingRevision, let current = self.currentSnapshot, current.path == path {
                    Self.patch(&result[index], snapshot: current.snapshot, inReview: current.inReview)
                }
                if let counts = self.changedDuringRefresh[path] {
                    result[index].changes = counts.changes
                    result[index].unaccepted = counts.unaccepted
                }
            }
            self.changedDuringRefresh.removeAll()
            self.rows = result; self.updated = Date(); self.refreshing = false
            for row in result { self.watchEvents(path: row.path) }
        }
    }

    private func watchEvents(path: String) {
        if let watch = eventWatches[path] { watch.start(); return }
        guard let gitDir = AIEventStore.locate(from: URL(fileURLWithPath: path))?.gitDir else { return }
        let watch = AgentEventWatch(gitDir: gitDir) { [weak self] event in self?.received(event, path: path) }
        eventWatches[path] = watch
        watch.start()
    }

    private func received(_ event: AIEvent?, path: String) {
        guard let index = rows.firstIndex(where: { $0.path == path }) else { return }
        rows[index].hookEvent = event
        guard let event else { return }
        if event.kind == .waiting {
            AINotifier.shared.postHookWaiting(event, project: path, name: rows[index].name)
        }
        if event.kind == .stop, Date().timeIntervalSince1970 - event.t < 24 * 3600 {
            rereadChanges(path: path)
        }
    }

    private func rereadChanges(path: String) {
        pathReads[path]?.cancel()
        let environment = environments[path] ?? [:]
        // A window snapshot published while status is in flight wins over that status read.
        let revision = snapshotRevision
        pathReads[path] = Task { [weak self] in
            let root = URL(fileURLWithPath: path)
            let text = try? await Self.status(root: root, environment: environment)
            guard !Task.isCancelled, let self else { return }
            defer { self.pathReads[path] = nil }
            guard let text, let index = self.rows.firstIndex(where: { $0.path == path }) else { return }
            if self.currentSnapshot?.path == path, self.snapshotRevision != revision { return }
            var counts = Row(path: path, name: "")
            Self.parseStatus(text, into: &counts)
            if self.refreshing { self.changedDuringRefresh[path] = (counts.changes, counts.unaccepted) }
            if self.rows[index].changes != counts.changes || self.rows[index].unaccepted != counts.unaccepted {
                self.rows[index].changes = counts.changes
                self.rows[index].unaccepted = counts.unaccepted
            }
        }
    }

    private static func status(root: URL, environment: [String: String]) async throws -> String {
        try await CommandRunner.git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"], at: root, environment: environment)
    }

    @discardableResult
    static func parseStatus(_ text: String, into row: inout Row) -> String? {
        row.changes = 0; row.unaccepted = 0
        var head: String?
        var records = text.split(separator: "\0").makeIterator()
        while let record = records.next() {
            if record.hasPrefix("# branch.head ") { row.branch = String(record.dropFirst(14)) }
            else if record.hasPrefix("# branch.oid "), record != "# branch.oid (initial)" { head = String(record.dropFirst(13)) }
            else if record.hasPrefix("# branch.upstream ") { row.upstream = String(record.dropFirst(18)) }
            else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst(12).split(separator: " ")
                if parts.count == 2 { row.ahead = Int(parts[0].dropFirst()); row.behind = Int(parts[1].dropFirst()) }
            } else if record.hasPrefix("? ") {
                row.changes += 1; row.unaccepted += 1
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") || record.hasPrefix("u ") {
                row.changes += 1
                if let y = record.dropFirst(3).first, y != "." && y != " " { row.unaccepted += 1 }
                // In -z output a rename's old path is the next record, even if its name resembles a status line.
                if record.hasPrefix("2 ") { _ = records.next() }
            }
        }
        return head
    }

    private static func read(root: URL, name: String, environment: [String: String]) async -> Row {
        var row = Row(path: root.path, name: name)
        do {
            let text = try await status(root: root, environment: environment)
            if let head = parseStatus(text, into: &row) {
                let remotes = try await CommandRunner.git(["remote"], at: root, environment: environment)
                if !remotes.isEmpty {
                    let count = try await CommandRunner.git(GitRepository.unpushedCountArguments(from: head), at: root, environment: environment)
                    row.unpushed = Int(count.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        } catch { row.error = "无法读取" }
        return row
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
                    let attention = board.attention(for: row.path, includeWorktrees: row.parent == nil)
                    HStack(spacing: 8) {
                        if let attention { AgentAttentionBadge(attention: attention) }
                        else {
                            Circle().fill(ThemeColor(token: row.error != nil ? .removed
                                                 : row.pending > 0 || (row.behind ?? 0) > 0 ? .modified
                                                 : row.changes > 0 ? .accent
                                                 : row.upstream == nil || row.ahead == nil || row.behind == nil ? .secondaryText : .added))
                            .frame(width: 7, height: 7)
                        }
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
                            if let attention {
                                Text(attention.text).themedFont(.caption2, points: 10).foregroundStyle(.secondary).lineLimit(1)
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
