import AppKit
import FolmiCore

struct AllTerminalRow: Identifiable {
    let id: UUID
    let projectPath: String?
    let title: String
    let directory: String
    let displayDirectory: String
    let runningProgram: String?
    let commandLine: String?
    let foregroundName: String?
    let createdAt: Date
    let isRunning: Bool
    let hasExited: Bool
    let exitCode: Int32?
    let background: PTYProtocol.Session?

    var isIdle: Bool { isRunning && !hasExited && runningProgram == nil }
    var programTitle: String { commandLine ?? runningProgram ?? (isIdle ? "空闲" : "终端") }
}

struct AllTerminalGroup: Identifiable {
    let project: ProjectPreferences?
    let isWorktree: Bool
    var rows: [AllTerminalRow]

    var id: String { project?.rootPath ?? "" }
    var title: String { project?.name ?? "不属于任何项目" }
}

struct AllTerminalList {
    var groups: [AllTerminalGroup] = []
    var error: String?

    var rows: [AllTerminalRow] { groups.flatMap(\.rows) }

    func matching(_ search: String) -> [AllTerminalGroup] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return groups }
        return groups.compactMap { group in
            var match = group
            if !group.title.localizedStandardContains(text) {
                match.rows = group.rows.filter { row in
                    [row.programTitle, row.runningProgram ?? "", row.directory, row.displayDirectory]
                        .contains { $0.localizedStandardContains(text) }
                }
            }
            return match.rows.isEmpty ? nil : match
        }
    }
}

@MainActor
extension FolmiModel {
    /// A saved claim takes precedence over the original server root, which never changes.
    func terminalOwners() -> [UUID: String] {
        var owners: [UUID: String] = [:]
        for project in projects where !project.isDemo {
            if let tabs = terminals[project.rootPath] {
                for id in tabs.compactMap(\.backgroundID) { owners[id] = project.rootPath }
            } else {
                for id in savedProject(project.rootPath)?.terminalSessionIDs ?? [] {
                    if let uuid = UUID(uuidString: id) { owners[uuid] = project.rootPath }
                }
            }
        }
        return owners
    }

    func terminalOwner(_ session: PTYProtocol.Session, owners: [UUID: String]) -> String? {
        owners[session.id] ?? projects.first { !$0.isDemo && $0.rootPath == session.projectRoot }?.rootPath
    }

    func noteBackgroundTerminals(_ sessions: [PTYProtocol.Session]) {
        knownBackgroundTerminals = sessions
        orphanTerminalCount = orphanTerminals(sessions).count
        updateAllTerminalCount()
    }

    func updateAllTerminalCount() {
        let current = repositoryURL?.path
        let tabIDs = Set(terminals.values.joined().map(\.id))
        let detached = knownBackgroundTerminals.filter { !tabIDs.contains($0.id) }
        let owners = terminalOwners()
        let hasOther = terminals.contains { $0.key != current && !$0.value.isEmpty } || detached.contains { session in
            guard let path = terminalOwner(session, owners: owners) else { return true }
            return path != current
        }
        let count = hasOther ? tabIDs.count + detached.count : nil
        if allTerminalCountOutsideProject != count { allTerminalCountOutsideProject = count }
    }

    func terminalsDidEnd(_ ids: Set<UUID>) {
        noteBackgroundTerminals(knownBackgroundTerminals.filter { !ids.contains($0.id) })
        allTerminalsRevision += 1
        scheduleSave()
    }

    func loadAllTerminals() async -> AllTerminalList {
        do {
            let status = try await terminalService?.listedSessions()
            guard !Task.isCancelled else { return AllTerminalList() }
            let listed = status?.sessions ?? []
            if let status { terminalServiceSharesCoalition = status.sharesCoalition }
            noteBackgroundTerminals(listed.map(\.info))
            return AllTerminalList(groups: allTerminalGroups(listed))
        } catch {
            guard !Task.isCancelled else { return AllTerminalList() }
            return AllTerminalList(groups: allTerminalGroups([]), error: "后台终端不可用：\(error.localizedDescription)")
        }
    }

    func allTerminalGroups(_ listed: [TerminalService.ListedSession]) -> [AllTerminalGroup] {
        var rows: [String: [AllTerminalRow]] = [:]
        var titles: [UUID: String] = [:]
        let owners = terminalOwners()
        for (path, tabs) in terminals {
            let labels = TerminalSession.distinctTitles(tabs.map(\.displayTitle))
            for (tab, title) in zip(tabs, labels) {
                titles[tab.id] = title
                guard tab.backgroundID == nil else { continue }
                let directory = tab.savedDirectory.path
                let foreground = tab.runsProgram ? tab.foregroundPID : nil
                rows[path, default: []].append(AllTerminalRow(
                    id: tab.id, projectPath: path, title: title, directory: directory,
                    displayDirectory: Self.terminalDirectory(directory, relativeTo: path), runningProgram: tab.runningProgram,
                    commandLine: TerminalService.commandLine(foreground), foregroundName: foreground.flatMap(PTYProcess.name(of:)),
                    createdAt: tab.createdAt, isRunning: tab.isRunning, hasExited: tab.hasExited,
                    exitCode: tab.exitCode, background: nil))
            }
        }
        for entry in listed {
            let info = entry.info
            let owner = terminalOwner(info, owners: owners)
            let project = owner.flatMap(savedProject)
            let index = project?.terminalSessionIDs.firstIndex(of: info.id.uuidString)
            let savedDirectory = index.flatMap { i in
                project.flatMap { $0.terminalDirectories.indices.contains(i) ? $0.terminalDirectories[i] : nil }
            }
            let directory = entry.directory ?? URL(fileURLWithPath: owner ?? info.projectRoot)
                .appendingPathComponent(savedDirectory ?? "").path
            let savedTitle = index.flatMap { i in
                project.flatMap { $0.terminalTabs.indices.contains(i) && !$0.terminalTabs[i].isEmpty ? $0.terminalTabs[i] : nil }
            }
            let title = titles[info.id] ?? savedTitle ?? "\((directory as NSString).lastPathComponent) · zsh"
            rows[owner ?? "", default: []].append(AllTerminalRow(
                id: info.id, projectPath: owner, title: title, directory: directory,
                displayDirectory: Self.terminalDirectory(directory, relativeTo: owner), runningProgram: info.runningProgram,
                commandLine: entry.commandLine, foregroundName: info.foregroundName,
                createdAt: info.createdAt, isRunning: !info.hasExited, hasExited: info.hasExited,
                exitCode: info.exitCode, background: info))
        }
        func sortedRows(_ path: String) -> [AllTerminalRow] {
            (rows[path] ?? []).sorted {
                let left = $0.runningProgram != nil ? 0 : ($0.hasExited ? 2 : 1)
                let right = $1.runningProgram != nil ? 0 : ($1.hasExited ? 2 : 1)
                return (left, $0.createdAt, $0.id.uuidString) < (right, $1.createdAt, $1.id.uuidString)
            }
        }
        var groups = RailEntry.entries(projects: projects, current: repositoryURL?.path, worktrees: worktrees).compactMap { entry -> AllTerminalGroup? in
            let tabs = sortedRows(entry.id)
            guard !tabs.isEmpty else { return nil }
            switch entry {
            case .project(let project): return AllTerminalGroup(project: project, isWorktree: false, rows: tabs)
            case .worktreeProject(let project, _): return AllTerminalGroup(project: project, isWorktree: true, rows: tabs)
            case .worktreeNotice: return nil
            }
        }
        if rows[""] != nil { groups.append(AllTerminalGroup(project: nil, isWorktree: false, rows: sortedRows(""))) }
        return groups
    }

    private static func terminalDirectory(_ directory: String, relativeTo root: String?) -> String {
        guard let root else { return (directory as NSString).abbreviatingWithTildeInPath }
        let base = ServiceScanner.realPath(root)
        let path = ServiceScanner.realPath(directory)
        if path == base { return "." }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return (directory as NSString).abbreviatingWithTildeInPath
    }

    func canJumpToTerminal(_ row: AllTerminalRow) -> Bool {
        guard let path = row.projectPath, !gitStartupState.blocksGit else { return false }
        return path == repositoryURL?.path || !busy
    }

    func jumpToListedTerminal() {
        guard let row = terminalJump else { return }
        terminalJump = nil
        guard canJumpToTerminal(row), let path = row.projectPath else { return }
        if path == repositoryURL?.path { revealListedTerminal(row, in: path) }
        else {
            switchProject(path) { [weak self] in self?.revealListedTerminal(row, in: path) }
        }
    }

    private func revealListedTerminal(_ row: AllTerminalRow, in path: String) {
        guard let root = repositoryURL, root.path == path else { return }
        let project = savedProject(path)
        if terminals[path] == nil {
            let owners = terminalOwners()
            let live = knownBackgroundTerminals.filter { terminalOwner($0, owners: owners) == path }
            restoreTerminalTabs(root: root, project: project, live: live, needsTab: false)
        }
        if terminals[path]?.contains(where: { $0.id == row.id }) != true, row.background != nil {
            terminals[path, default: []].append(makeTerminal(root: root, name: "", project: project, restoredID: row.id))
        }
        guard terminals[path]?.contains(where: { $0.id == row.id }) == true else { return }
        showTerminal = true
        selectTerminalTab(row.id)
    }

    var canClaimTerminal: Bool { repositoryURL != nil && !isDemo && !busy && !gitStartupState.blocksGit }

    func claimListedTerminal(_ row: AllTerminalRow) async {
        guard canClaimTerminal, row.background != nil, row.projectPath == nil,
              let root = repositoryURL, let terminalService else { return }
        do {
            guard let opened = try await terminalService.openExisting(row.id) else {
                allTerminalsRevision += 1
                return
            }
            guard canClaimTerminal, root == repositoryURL, terminalOwner(opened.info, owners: terminalOwners()) == nil else { return }
            let project = savedProject(root.path)
            if terminals[root.path] == nil {
                let owners = terminalOwners()
                let live = knownBackgroundTerminals.filter { terminalOwner($0, owners: owners) == root.path }
                restoreTerminalTabs(root: root, project: project, live: live, needsTab: false)
            }
            let tab = makeTerminal(root: root, name: "", project: project, opened: opened)
            terminals[root.path, default: []].append(tab)
            syncTerminalTabs()
            noteBackgroundTerminals(knownBackgroundTerminals)
            allTerminalsRevision += 1
            scheduleSave()
        } catch {
            reportTerminalServiceIssue(error)
            errorMessage = "放进当前项目失败：\(error.localizedDescription)"
            allTerminalsRevision += 1
        }
    }

    func endListedTerminal(_ id: UUID) async {
        let fresh = await loadAllTerminals()
        defer { allTerminalsRevision += 1 }
        guard let row = fresh.rows.first(where: { $0.id == id }), confirmTermination(program: row.runningProgram) else { return }
        endListedTerminals([row])
    }

    func endIdleTerminals(_ ids: Set<UUID>, confirm: ((Int) -> Bool)? = nil) async {
        let count = ids.count
        guard count > 0 else { return }
        let confirmed = confirm?(count) ?? confirmTerminalAction("结束 \(count) 个空闲终端？",
            detail: "这些终端没有程序在运行，结束后无法恢复。", button: "结束终端")
        guard confirmed else { return }
        // Read again after the confirmation, because a shell can pick up work while the dialog is open.
        let fresh = await loadAllTerminals()
        let idle = fresh.rows.filter { ids.contains($0.id) && $0.isIdle }
        endListedTerminals(idle)
        allTerminalsRevision += 1
    }

    private func endListedTerminals(_ rows: [AllTerminalRow]) {
        guard !rows.isEmpty else { return }
        do {
            try terminalService?.end(rows.filter { $0.background != nil }.map(\.id))
            applyTerminalClosures(rows.map { ($0.id, $0.projectPath) })
        } catch {
            reportTerminalServiceIssue(error)
            errorMessage = "结束终端失败：\(error.localizedDescription)"
        }
    }

    func applyTerminalClosures(_ closed: [(UUID, String?)]) {
        for (path, tabs) in Dictionary(grouping: closed, by: { $0.1 }) {
            if let path { removeEndedTerminalTabs(Set(tabs.map { $0.0 }), in: path) }
        }
        terminalsDidEnd(Set(closed.map { $0.0 }))
    }
}
