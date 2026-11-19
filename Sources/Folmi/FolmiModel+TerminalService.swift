import AppKit
import FolmiCore

extension FolmiModel {
    func reportTerminalServiceIssue(_ error: Error) {
        if case PTYProtocol.Failure.incompatible(let hello) = error {
            let shouldShow = incompatibleTerminalService == nil
            incompatibleTerminalService = hello
            terminalServiceNotice = nil
            if shouldShow { Task { [weak self] in self?.showIncompatibleTerminalService() } }
        } else {
            terminalServiceNotice = error.localizedDescription
        }
    }

    func showIncompatibleTerminalService() {
        guard let hello = incompatibleTerminalService, let terminalService else { return }
        let alert = NSAlert()
        alert.messageText = hello.protocolVersion < PTYProtocol.version ? "后台终端服务是旧版本" : "后台终端服务版本不兼容"
        alert.informativeText = "已有的 \(hello.runningCount) 个终端还在运行。重启服务会结束它们。"
        alert.addButton(withTitle: "先不")
        alert.addButton(withTitle: "重启服务")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try terminalService.shutdown(confirmingVersion: hello.protocolVersion)
            for (path, tabs) in terminals {
                let remaining = tabs.filter { $0.backgroundID == nil }
                for tab in tabs where tab.backgroundID != nil { tab.stop(endBackground: false) }
                terminals[path] = remaining.isEmpty ? nil : remaining
            }
            incompatibleTerminalService = nil
            terminalServiceNotice = nil
            terminalServiceSharesCoalition = false
            restoredBackgroundTerminals = false
            restoreBackgroundTerminals()
            if showTerminal { startTerminal() } else { syncTerminalTabs() }
            scheduleSave()
        } catch {
            reportTerminalServiceIssue(error)
        }
    }

    func showTerminalQuitNoticeIfNeeded() {
        guard !preferences.terminalQuitNoticeSuppressed else { return }
        let running = terminals.values.joined().contains { $0.backgroundID != nil && $0.isRunning }
        let listed = try? terminalService?.sessions()
        let preserved = listed?.contains { !$0.hasExited } == true || (incompatibleTerminalService?.runningCount ?? 0) > 0
        guard running || preserved else { return }
        let alert = NSAlert()
        alert.messageText = "终端会在后台继续运行"
        alert.informativeText = "下次打开 Folmi 时会接回原来的终端。要结束它们，打开 Folmi 从「终端」菜单选「结束所有后台终端」。"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提示"
        alert.suppressionButton?.state = .on
        alert.addButton(withTitle: "继续退出")
        alert.runModal()
        preferences.terminalQuitNoticeSuppressed = alert.suppressionButton?.state == .on
    }

    func confirmTermination(of tab: TerminalSession) -> Bool {
        confirmTermination(program: tab.runningProgram)
    }

    func confirmTermination(program: String?) -> Bool {
        guard let command = program else { return true }
        return confirmTerminalAction("关闭这个终端？", detail: "「\(command)」还在运行，关闭会结束它。", button: "关闭终端")
    }

    func endTerminal(_ tab: TerminalSession) -> Bool {
        do {
            if let id = tab.backgroundID { try terminalService?.end([id]) }
            tab.stop(endBackground: false)
            return true
        } catch {
            reportTerminalServiceIssue(error)
            return false
        }
    }

    func backgroundTerminals(in path: String) throws -> [PTYProtocol.Session] {
        guard let terminalService, savedProject(path)?.isDemo != true else { return [] }
        let owners = terminalOwners()
        return try terminalService.sessions().filter { terminalOwner($0, owners: owners) == path }
    }

    func confirmProjectTerminalClosure(path: String, sessions: [PTYProtocol.Session]) -> Bool {
        var commands = sessions.compactMap(\.runningProgram)
        let checked = Set(sessions.map(\.id))
        commands += terminals[path, default: []].filter { !checked.contains($0.id) }.compactMap(\.runningProgram)
        guard !commands.isEmpty else { return true }
        return confirmTerminalAction("移除项目并关闭终端？",
                                     detail: "这些程序还在运行，移除项目会结束它们。\n\n" + commands.joined(separator: "\n"),
                                     button: "移除并结束")
    }

    func orphanTerminals(_ sessions: [PTYProtocol.Session]) -> [PTYProtocol.Session] {
        let owners = terminalOwners()
        return sessions.filter { terminalOwner($0, owners: owners) == nil }
    }

    func refreshTerminalMenu() {
        guard let terminalService else { return }
        do {
            let (sessions, sharesCoalition) = try terminalService.sessionStatus()
            noteBackgroundTerminals(sessions)
            terminalServiceSharesCoalition = sharesCoalition
        } catch { reportTerminalServiceIssue(error) }
    }

    func endBackgroundTerminals(orphansOnly: Bool) {
        guard let terminalService else { return }
        do {
            let (all, sharesCoalition) = try terminalService.sessionStatus()
            terminalServiceSharesCoalition = sharesCoalition
            let sessions = orphansOnly ? orphanTerminals(all) : all
            noteBackgroundTerminals(all)
            guard !sessions.isEmpty else {
                _ = confirmTerminalAction("没有后台终端", detail: "", button: "好", canCancel: false)
                return
            }
            let title = orphansOnly ? "结束不属于项目的后台终端？" : "结束所有后台终端？"
            guard confirmTerminalAction(title, detail: "将结束 \(sessions.count) 个后台终端及其中的程序。", button: "结束终端") else { return }
            let owners = terminalOwners()
            if orphansOnly { try terminalService.end(sessions.map(\.id)) }
            else { try terminalService.shutdown() }
            var closed = sessions.map { ($0.id, terminalOwner($0, owners: owners)) }
            if !orphansOnly {
                let listed = Set(sessions.map(\.id))
                closed += terminals.flatMap { path, tabs in
                    tabs.compactMap { tab in tab.backgroundID != nil && !listed.contains(tab.id) ? (tab.id, Optional(path)) : nil }
                }
                terminalServiceSharesCoalition = false
            }
            applyTerminalClosures(closed)
        } catch {
            reportTerminalServiceIssue(error)
        }
    }

    func confirmTerminalAction(_ title: String, detail: String, button: String, canCancel: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        if canCancel { alert.addButton(withTitle: "取消") }
        alert.addButton(withTitle: button)
        return alert.runModal() == (canCancel ? .alertSecondButtonReturn : .alertFirstButtonReturn)
    }
}
