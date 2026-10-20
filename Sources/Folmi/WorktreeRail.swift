import AppKit
import FolmiCore
import SwiftUI

extension FolmiModel {
    /// Other worktrees are not watched, so their status is read again when the list changes, when asked (the sheet
    /// opens, a cleanup), or a minute after the last read.
    func loadWorktrees(force: Bool = false) async {
        guard let repository, let root = repositoryURL else { return }
        let list = (try? await repository.worktrees()) ?? []
        guard repositoryURL == root else { return }
        let fresh = worktreesRead.map { Date().timeIntervalSince($0) < 60 } ?? false
        guard force || !fresh || list != worktrees.map(\.info) else { return }
        worktreesRead = Date()
        let statuses = await repository.worktreeStatuses(list)
        guard repositoryURL == root, statuses != worktrees else { return }
        worktrees = statuses
    }

    /// Worktrees of the open repository other than the folder that is open.
    var otherWorktrees: [WorktreeStatus] {
        let current = repositoryURL.map { RailEntry.canonical($0.path) }
        return worktrees.filter { RailEntry.canonical($0.info.path) != current }
    }

    /// The worktree that has `branch` checked out, when that is not the open folder: git will not check it out here.
    func worktree(holding branch: String) -> WorktreeStatus? { otherWorktrees.first { $0.info.branch == branch } }

    /// Opens a worktree's folder as a project of its own.
    func openWorktree(_ status: WorktreeStatus) {
        showWorktrees = false
        let key = RailEntry.canonical(status.info.path)
        if let listed = projects.first(where: { RailEntry.canonical($0.rootPath) == key }) { switchProject(listed.rootPath) }
        else { open(URL(fileURLWithPath: status.info.path)) }
    }

    /// `git worktree remove` for each, one after another; stops at the first refusal. Branches stay, and a worktree
    /// that was opened as a project leaves the project list too.
    func removeWorktrees(_ list: [WorktreeStatus]) {
        guard !busy, let repository, !list.isEmpty else { return }
        busy = true
        Task {
            var removed = 0
            var failure: Error?
            for status in list {
                do { try await repository.removeWorktree(status) } catch { failure = error; break }
                removed += 1
                let key = RailEntry.canonical(status.info.path)
                if let listed = projects.first(where: { RailEntry.canonical($0.rootPath) == key }) { forgetProject(listed.rootPath) }
            }
            busy = false
            if let failure { report(failure, title: "清理工作树失败") }
            if removed > 0 { record("清理工作树", "删掉了 \(removed) 个工作树的文件夹，分支都还在。") }
            await loadWorktrees(force: true)
        }
    }
}

/// The project rail's rows: each project, the worktrees of it that were opened as projects, and under the open
/// repository one line when its other worktrees hold work to look at. Worktrees are not listed one by one: agents
/// leave dozens of them, and a column of branch names reads as a branch switcher.
enum RailEntry: Identifiable {
    case project(ProjectPreferences)
    case worktreeProject(ProjectPreferences, title: String)
    /// Other worktrees of the open repository with uncommitted files or commits only they have.
    case worktreeNotice(count: Int, agent: WorktreeAgent?)

    var id: String {
        switch self {
        case .project(let project), .worktreeProject(let project, _): return project.rootPath
        case .worktreeNotice: return "worktree-notice"
        }
    }

    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    @MainActor static func entries(projects: [ProjectPreferences], current: String?, worktrees: [WorktreeStatus]) -> [RailEntry] {
        let listed = Set(projects.map { canonical($0.rootPath) })
        var mains: [String: String] = [:]
        for project in projects {
            if let main = WorktreeInfo.mainRoot(of: project.rootPath).map(canonical), listed.contains(main) {
                mains[project.rootPath] = main
            }
        }
        let currentKey = current.map(canonical)
        let currentGroup = current.flatMap { mains[$0] } ?? currentKey
        let byPath = Dictionary(worktrees.map { (canonical($0.info.path), $0) }, uniquingKeysWith: { first, _ in first })
        let waiting = worktrees.filter { $0.hasWork && canonical($0.info.path) != currentKey }
        var result: [RailEntry] = []
        for project in projects where mains[project.rootPath] == nil {
            result.append(.project(project))
            let key = canonical(project.rootPath)
            for child in projects where mains[child.rootPath] == key {
                // Never a bare commit id: a detached worktree goes by its folder.
                let title = byPath[canonical(child.rootPath)]?.info.branch ?? WelcomeRecents.branch(at: child.rootPath, detached: false)
                    ?? URL(fileURLWithPath: child.rootPath).pathComponents.suffix(2).joined(separator: "/")
                result.append(.worktreeProject(child, title: title))
            }
            if key == currentGroup, !waiting.isEmpty {
                let agents = Set(waiting.map(\.agent))
                result.append(.worktreeNotice(count: waiting.count, agent: agents.count == 1 ? agents.first ?? nil : nil))
            }
        }
        return result
    }
}

/// The rail line that stands for the other worktrees with work in them; a click opens the worktree sheet.
struct WorktreeNoticeRow: View {
    let count: Int
    let agent: WorktreeAgent?
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        let text = "\(agent?.title ?? "其他工作树")有 \(count) 处待看"
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "folder").font(.system(size: 12))
                    Text("\(count)").font(.system(size: 8, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 3).background(ThemeColor(token: .modified), in: Capsule())
                        .foregroundStyle(.white).offset(x: 7, y: -6)
                }
                .frame(width: 28, height: 26)
                Text(text).themedFont(.system(size: 11.5), points: 11.5).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).opacity(expanded ? 1 : 0)
            }
            .modifier(RailRowInsets())
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.pressableRow)
        .accessibilityLabel(text)
        .help("同一仓库的其他文件夹里有没提交的改动或只在那里的提交。点开查看、打开或清理。")
    }
}

/// Every worktree of the open repository: which agent made it, its branch, whether it holds work, and buttons to
/// open it, show it in Finder, or remove the ones that hold nothing.
struct WorktreesSheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: [WorktreeStatus]?

    var body: some View {
        let others = model.otherWorktrees
        let waiting = others.filter(\.hasWork).sorted(by: Self.newestFirst)
        let idle = others.filter { !$0.hasWork }.sorted(by: Self.newestFirst)
        let removable = idle.filter(\.canRemove)
        VStack(alignment: .leading, spacing: 12) {
            Text("工作树").themedFont(.title3.weight(.semibold), points: 15)
            Text("同一个仓库检出在别的文件夹里的副本，多是 Codex、Claude Code 并行干活时建的。每个文件夹有自己的改动，打开后在那里验收。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if others.isEmpty {
                    Text("这个仓库没有别的工作树。").foregroundStyle(.secondary)
                }
                if !waiting.isEmpty {
                    Section("有东西要看（\(waiting.count)）") { ForEach(waiting) { row($0) } }
                }
                if !idle.isEmpty {
                    Section("没有改动（\(idle.count)）") { ForEach(idle) { row($0) } }
                }
            }
            .frame(minHeight: 260)
            HStack {
                if !removable.isEmpty {
                    Button("清理 \(removable.count) 个没有改动的…") { confirming = removable }.disabled(model.busy)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task { await model.loadWorktrees(force: true) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { list in
            Button(list.count == 1 ? "清理" : "清理 \(list.count) 个", role: .destructive) { model.removeWorktrees(list) }
            Button("取消", role: .cancel) {}
        } message: { list in
            Text(list.count == 1 && list[0].info.branch == nil
                 ? "会删掉这个文件夹。它没有未提交的改动，停在的提交别的分支上也有，不会丢东西。"
                 : "会删掉这些文件夹，分支保留。它们都没有未提交的改动，不会丢东西。")
        }
    }

    private var confirmTitle: String {
        guard let list = confirming else { return "" }
        return list.count == 1 ? "清理工作树「\(list[0].info.branch ?? list[0].folder)」？" : "清理 \(list.count) 个没有改动的工作树？"
    }

    private static func newestFirst(_ a: WorktreeStatus, _ b: WorktreeStatus) -> Bool {
        (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
    }

    private func row(_ status: WorktreeStatus) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let agent = status.agent {
                        Text(agent.title).themedFont(.caption2.weight(.semibold), points: 10)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .themedCapsule(ThemeColor(token: .selectedFill))
                    }
                    Text(status.info.branch ?? "未建分支").themedFont(.callout.weight(.medium), points: 12)
                        .foregroundStyle(status.info.branch == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    if status.info.isMain { Text("主目录").themedFont(.caption2, points: 10).foregroundStyle(.secondary) }
                }
                Text(detail(status)).themedFont(.caption, points: 10)
                    .foregroundStyle(status.hasWork ? AnyShapeStyle(ThemeColor(token: .modified)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Text(status.info.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.info.path)]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("在 Finder 中显示")
            if status.canRemove {
                Button("清理") { confirming = [status] }.controlSize(.small).disabled(model.busy)
                    .help("删掉这个文件夹（git worktree remove），分支保留")
            }
            Button("打开") { model.openWorktree(status) }.controlSize(.small).disabled(model.busy)
                .help("在 Folmi 里打开这个文件夹，验收它的改动")
        }
        .padding(.vertical, 2)
    }

    private func detail(_ status: WorktreeStatus) -> String {
        var parts: [String] = []
        if status.unreadable { parts.append("读不到状态") }
        if status.changes > 0 { parts.append("\(status.changes) 个文件没提交") }
        if status.ownCommits > 0 { parts.append("\(status.ownCommits) 个提交只在这里") }
        if parts.isEmpty { parts.append("没有改动") }
        if status.info.branch == nil, let head = status.info.head { parts.append("停在 \(head.prefix(7))") }
        if let date = status.modified { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}
