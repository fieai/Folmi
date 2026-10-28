import AppKit
import FolmiCore
import SwiftUI

/// 服务: what listens on a port from inside this project, and the commands that start it, in one toolbar popover.
@MainActor @Observable
final class ProjectServicesState {
    /// The project the lists below belong to; a scan finishing after a project switch is dropped.
    var root: String?
    var running: [RunningService] = []
    var found: [LaunchCommand] = []
    var showPanel = false
    /// 停止 was clicked once; the second click stops it.
    var confirmingStop: Int32?
    /// Services stopped from here, so they can be started again the same way (the undo for 停止).
    var stopped: [StoppedService] = []
    /// The terminal tab each command was started in, by command id.
    @ObservationIgnored var launched: [String: UUID] = [:]
    /// Counting starts typed in a terminal: services already looked at, processes already counted, and starts from
    /// the panel (already counted) waiting for their service, so they are not counted twice.
    @ObservationIgnored let since = Date()
    @ObservationIgnored var examined: Set<Int32> = []
    @ObservationIgnored var counted: Set<String> = []
    @ObservationIgnored var pending: [String: [Date]] = [:]
}

struct StoppedService: Identifiable, Equatable {
    let id = UUID()
    let ports: [Int]
    let command: String
    let directory: String
}

extension FolmiModel {
    /// Found and added commands, the most started first; ties keep the order they were found in.
    var launchCommands: [LaunchCommand] {
        let project = repositoryURL.flatMap { savedProject($0.path) }
        let custom = project?.launchCommands ?? []
        let found = projectServices.found.filter { command in !custom.contains { $0.id == command.id } }
        return Self.byUse(found + custom, counts: project?.launchCounts ?? [:])
    }

    static func byUse(_ commands: [LaunchCommand], counts: [String: Int]) -> [LaunchCommand] {
        commands.enumerated()
            .sorted { (counts[$0.element.id] ?? 0, -$0.offset) > (counts[$1.element.id] ?? 0, -$1.offset) }
            .map(\.element)
    }

    func launchCount(_ command: LaunchCommand) -> Int {
        repositoryURL.flatMap { savedProject($0.path) }?.launchCounts[command.id] ?? 0
    }

    /// Counts a start of the command (from the panel or typed in a terminal) under its folder and text.
    func countLaunch(_ id: String) {
        guard let root = repositoryURL?.path else { return }
        func change(_ project: inout ProjectPreferences) { project.launchCounts[id, default: 0] += 1 }
        if let index = projects.firstIndex(where: { $0.rootPath == root }) { change(&projects[index]) }
        if let index = preferences.projects.firstIndex(where: { $0.rootPath == root }) { change(&preferences.projects[index]) }
        scheduleSave()
    }

    /// Re-reads the listening processes; a few milliseconds, off the main thread anyway.
    func refreshServices() async {
        guard let root = repositoryURL, !isDemo else { projectServices.running = []; return }
        let running = await Task.detached(priority: .utility) { ServiceScanner.scan(root: root) }.value
        guard repositoryURL == root else { return }
        if projectServices.root != root.path { projectServices.root = root.path; projectServices.stopped = []; projectServices.examined = [] }
        if projectServices.running != running { projectServices.running = running }
        await countTerminalStarts(running, root: root)
    }

    /// A new service that a start command began, typed in any terminal, counts as a start of that command.
    /// Only new services are looked at, so this costs nothing while nothing starts.
    private func countTerminalStarts(_ running: [RunningService], root: URL) async {
        let state = projectServices
        state.examined.formIntersection(running.map(\.pid))
        let fresh = running.filter { !state.examined.contains($0.pid) }
        guard !fresh.isEmpty else { return }
        state.examined.formUnion(fresh.map(\.pid))
        let commands = launchCommands, since = state.since
        let origins = await Task.detached(priority: .utility) {
            fresh.compactMap { LaunchCommandMatcher.origin(of: $0, root: root, commands: commands, since: since) }
        }.value
        guard repositoryURL == root else { return }
        for origin in origins where state.counted.insert(origin.process).inserted {
            let waiting = (state.pending[origin.commandID] ?? []).filter { $0.timeIntervalSinceNow > -120 }
            if waiting.isEmpty { countLaunch(origin.commandID) } else { state.pending[origin.commandID] = Array(waiting.dropFirst()) }
        }
    }

    /// A start from the panel is counted at once; its service, when it shows, is then not counted again.
    private func countPanelStart(_ id: String) {
        countLaunch(id)
        projectServices.pending[id, default: []].append(Date())
    }

    func refreshLaunchCommands() async {
        guard let root = repositoryURL else { projectServices.found = []; return }
        let found = await Task.detached(priority: .utility) { LaunchCommandScanner.scan(root: root) }.value
        guard repositoryURL == root else { return }
        if projectServices.found != found { projectServices.found = found }
    }

    /// Keeps the toolbar's ports current while the window is in use: every 5 seconds, every 1.5 while the panel is open.
    func watchServices() async {
        await refreshLaunchCommands()
        while !Task.isCancelled {
            if NSApp.isActive || projectServices.showPanel { await refreshServices() }
            do { try await Task.sleep(nanoseconds: projectServices.showPanel ? 1_500_000_000 : 5_000_000_000) } catch { return }
        }
    }

    /// The Folmi terminal tab the service was started from, when it was.
    func terminalTab(for service: RunningService) -> TerminalSession? {
        guard let root = repositoryURL?.path else { return nil }
        let chain = Set(service.ancestors + [service.pid])
        return terminals[root]?.first { $0.shellPID > 0 && chain.contains($0.shellPID) }
    }

    /// The command's tab still runs something, or a service with its port is up in its folder.
    func isRunning(_ command: LaunchCommand) -> Bool {
        if let id = projectServices.launched[command.id], let tab = terminalTabs.first(where: { $0.id == id }), tab.runsProgram { return true }
        guard let port = command.port else { return false }
        return projectServices.running.contains { $0.directory == command.directory && $0.ports.contains(port) }
    }

    func launchedTab(_ command: LaunchCommand) -> TerminalSession? {
        projectServices.launched[command.id].flatMap { id in terminalTabs.first { $0.id == id } }
    }

    func startLaunchCommand(_ command: LaunchCommand) {
        let name = command.directory.isEmpty ? command.name : "\(command.name) · \((command.directory as NSString).lastPathComponent)"
        if let tab = runInNewTerminalTab(command.command, directory: command.directory, name: name) {
            projectServices.launched[command.id] = tab.id
        }
        countPanelStart(command.id)
        record("启动服务", command.command)
        Task { await pollAfterStart() }
    }

    /// Opens a named terminal tab in the folder and runs the command there, so its output stays one click away.
    @discardableResult
    func runInNewTerminalTab(_ command: String, directory: String, name: String) -> TerminalSession? {
        guard let root = repositoryURL else { return nil }
        if !showTerminal { showTerminal = true; startTerminal() }
        let session = makeTerminal(root: root, name: name, directory: directory)
        terminals[root.path, default: []].append(session)
        selectedTerminals[root.path] = session.id
        syncTerminalTabs()
        scheduleSave()
        focusPane(.terminal)
        Task {
            // Typed input waits in the terminal until zsh reads it; waiting for the prompt keeps the echo tidy.
            for _ in 0..<60 where !session.acceptsBracketedPaste {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            session.terminalView.send(txt: command + "\r")
        }
        return session
    }

    /// A server takes a few seconds to open its port; look more often until it shows.
    private func pollAfterStart() async {
        let before = Set(projectServices.running.flatMap(\.ports))
        for _ in 0..<20 {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            await refreshServices()
            if !Set(projectServices.running.flatMap(\.ports)).subtracting(before).isEmpty { return }
        }
    }

    /// Stops it the way a person would: Control-C in the tab it runs in, else a polite SIGTERM. 再启动 undoes it.
    func stopService(_ service: RunningService) {
        projectServices.confirmingStop = nil
        let tab = terminalTab(for: service)
        let launched = tab.flatMap { tab in projectServices.launched.first { $0.value == tab.id } }
            .flatMap { entry in launchCommands.first { $0.id == entry.key } }
        if let tab, tab.runsProgram {
            tab.terminalView.send(txt: "\u{03}")
        } else if kill(service.pid, SIGTERM) != 0 {
            errorMessage = "没能停止 \(service.name)（进程 \(service.pid)）：\(String(cString: strerror(errno)))"
            return
        }
        projectServices.stopped.removeAll { $0.ports == service.ports }
        projectServices.stopped.insert(StoppedService(ports: service.ports, command: launched?.command ?? service.commandLine,
                                                      directory: launched?.directory ?? service.directory), at: 0)
        record("停止服务", service.ports.map { ":\($0)" }.joined(separator: " ") + " " + service.name)
        Task {
            for _ in 0..<10 {
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                await refreshServices()
                if !projectServices.running.contains(where: { $0.pid == service.pid }) { return }
            }
        }
    }

    func restartStopped(_ stopped: StoppedService) {
        projectServices.stopped.removeAll { $0 == stopped }
        let name = (stopped.command.split(separator: " ").first.map(String.init) ?? "服务")
        runInNewTerminalTab(stopped.command, directory: stopped.directory, name: name)
        countPanelStart(LaunchCommand(directory: stopped.directory, name: name, command: stopped.command, source: "").id)
        record("启动服务", stopped.command)
        Task { await pollAfterStart() }
    }

    func showTab(_ tab: TerminalSession) {
        projectServices.showPanel = false
        if !showTerminal { showTerminal = true; startTerminal() }
        selectTerminalTab(tab.id)
    }

    func addLaunchCommand(_ command: String, directory: String) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if folder == "." || folder.split(separator: "/").contains("..") { folder = "" }
        guard !text.isEmpty else { return }
        let name = text.split(separator: " ").prefix(3).joined(separator: " ")
        updateLaunchCommands { $0.append(LaunchCommand(directory: folder, name: name, command: text, source: LaunchCommand.customSource,
                                                       port: LaunchCommandScanner.guessPort(text))) }
    }

    func removeLaunchCommand(_ command: LaunchCommand) {
        updateLaunchCommands { $0.removeAll { $0.id == command.id } }
    }

    private func updateLaunchCommands(_ change: (inout [LaunchCommand]) -> Void) {
        guard let root = repositoryURL?.path else { return }
        if let index = projects.firstIndex(where: { $0.rootPath == root }) { change(&projects[index].launchCommands) }
        if let index = preferences.projects.firstIndex(where: { $0.rootPath == root }) { change(&preferences.projects[index].launchCommands) }
        scheduleSave()
    }
}

/// The toolbar button: the ports in use, so a glance says what is up.
struct ServicesToolbarButton: View {
    let model: FolmiModel
    var body: some View {
        let state = model.projectServices
        let ports = state.running.flatMap(\.ports)
        Button { state.showPanel.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right")
                if !ports.isEmpty {
                    Text(ports.prefix(2).map { ":\($0)" }.joined(separator: " ") + (ports.count > 2 ? " +\(ports.count - 2)" : ""))
                        .monospacedDigit().themedFont(.caption, points: 10)
                }
            }
        }
        .help(ports.isEmpty ? "服务：这个项目里没有在跑的服务。点按看怎么启动" : "服务：这个项目里有 \(state.running.count) 个在跑，点按查看、打开或停止")
        .disabled(!model.hasSnapshot)
        .popover(isPresented: Binding(get: { state.showPanel }, set: { state.showPanel = $0 }), arrowEdge: .bottom) {
            ProjectServicesPanel(model: model)
        }
        .task(id: model.repositoryURL) { await model.watchServices() }
        .onChange(of: state.showPanel) { _, open in
            state.confirmingStop = nil
            if open { Task { await model.refreshServices(); await model.refreshLaunchCommands() } }
        }
    }
}

struct ProjectServicesPanel: View {
    let model: FolmiModel
    @State private var adding = false
    @State private var newCommand = ""
    @State private var newDirectory = ""

    var body: some View {
        let state = model.projectServices
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("在跑的服务", detail: state.running.isEmpty ? nil : "\(state.running.count) 个") {
                        if state.running.isEmpty && state.stopped.isEmpty {
                            hint("这个项目和它的子目录里没有在监听端口的程序。")
                        }
                        ForEach(state.running) { serviceRow($0) }
                        ForEach(state.stopped.filter { stopped in !state.running.contains { $0.ports == stopped.ports } }) { stoppedRow($0) }
                    }
                    section("启动命令", detail: "从项目文件里找到的，常用的排在前面；点「启动」在新的终端标签里运行") {
                        if model.launchCommands.isEmpty && !adding {
                            hint("没找到 package.json、Makefile、Procfile、docker compose 之类的启动方式。可以自己加一条。")
                        }
                        ForEach(model.launchCommands) { commandRow($0) }
                        if adding { addForm } else {
                            Button { adding = true } label: { Label("添加命令", systemImage: "plus") }
                                .buttonStyle(.link).themedFont(.caption, points: 10)
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 560)
        .frame(minHeight: 180, maxHeight: 520)
    }

    private func section<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).themedFont(.headline, points: 12)
                if let detail { Text(detail).themedFont(.caption, points: 10).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func folderTag(_ directory: String) -> some View {
        Text(directory.isEmpty ? "根目录" : directory + "/")
            .themedFont(.caption2.monospaced(), points: 9).lineLimit(1).truncationMode(.head)
            .padding(.horizontal, 5).padding(.vertical, 1).themedCapsule(ThemeColor(token: .selectedFill))
            .help(directory.isEmpty ? "项目根目录" : directory)
    }

    private func serviceRow(_ service: RunningService) -> some View {
        let tab = model.terminalTab(for: service)
        let confirming = model.projectServices.confirmingStop == service.pid
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(ThemeColor(token: .added)).frame(width: 7, height: 7)
                ForEach(service.ports, id: \.self) { port in
                    Button(":\(port)") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
                        .buttonStyle(.link).themedFont(.callout.monospaced().weight(.semibold), points: 12)
                        .help("在浏览器打开 http://localhost:\(port)")
                }
                Text(service.name).themedFont(.callout, points: 12)
                folderTag(service.directory)
                Spacer(minLength: 6)
                if let tab {
                    Button("看终端") { model.showTab(tab) }.themedFont(.caption, points: 10)
                        .help("切到启动它的终端标签「\(tab.displayTitle)」")
                }
                Button(confirming ? "确定停止" : "停止") {
                    if confirming { model.stopService(service) } else { model.projectServices.confirmingStop = service.pid }
                }
                .themedFont(.caption, points: 10)
                .foregroundStyle(confirming ? ThemeColor(token: .removed) : ThemeColor(token: .foreground))
                .help(tab?.runsProgram == true ? "在它的终端标签里按 Control-C。停了可以点「再启动」" : "让进程 \(service.pid) 退出（SIGTERM）。停了可以点「再启动」")
            }
            Text(service.commandLine).themedFont(.caption.monospaced(), points: 10).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(service.commandLine)
                .padding(.leading, 13)
            Text(caption(service, tab: tab)).themedFont(.caption, points: 10).foregroundStyle(.tertiary).padding(.leading, 13)
        }
        .padding(.vertical, 3)
    }

    private func caption(_ service: RunningService, tab: TerminalSession?) -> String {
        var parts = ["进程 \(service.pid)"]
        if let started = service.startedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            parts.append(formatter.localizedString(for: started, relativeTo: Date()) + "启动")
        }
        parts.append(tab.map { "在终端「\($0.displayTitle)」里" } ?? "不是从 Folmi 终端启动的")
        return parts.joined(separator: " · ")
    }

    private func stoppedRow(_ stopped: StoppedService) -> some View {
        HStack(spacing: 6) {
            Circle().stroke(ThemeColor(token: .tertiaryText)).frame(width: 7, height: 7)
            Text(stopped.ports.map { ":\($0)" }.joined(separator: " ")).themedFont(.callout.monospaced(), points: 12).foregroundStyle(.secondary)
            Text("已停止").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            folderTag(stopped.directory)
            Text(stopped.command).themedFont(.caption.monospaced(), points: 10).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button("再启动") { model.restartStopped(stopped) }.themedFont(.caption, points: 10)
                .help("在新的终端标签里，用原来的命令和目录再启动")
        }
        .padding(.vertical, 3)
    }

    private func commandRow(_ command: LaunchCommand) -> some View {
        let running = model.isRunning(command)
        let tab = model.launchedTab(command)
        return HStack(spacing: 6) {
            folderTag(command.directory)
            Text(command.command).themedFont(.callout.monospaced(), points: 12).lineLimit(1).truncationMode(.middle).help(command.command)
            let count = model.launchCount(command)
            if count > 0 {
                Text("\(count) 次").themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1).themedCapsule(ThemeColor(token: .selectedFill))
                    .fixedSize().help("启动过 \(count) 次（在这里点「启动」和在终端里输入都算）")
            }
            Spacer(minLength: 6)
            Text(command.source + (command.port.map { " · :\($0)" } ?? "")).themedFont(.caption, points: 10).foregroundStyle(.tertiary).lineLimit(1)
            if command.source == LaunchCommand.customSource {
                Button { model.removeLaunchCommand(command) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("从列表里去掉这条（不影响项目文件）")
            }
            if running, let tab {
                Button("在跑 · 看终端") { model.showTab(tab) }.themedFont(.caption, points: 10)
            } else {
                Button { model.startLaunchCommand(command) } label: { Label("启动", systemImage: "play.fill") }
                    .themedFont(.caption, points: 10)
                    .disabled(running)
                    .help(running ? "\(command.port.map { ":\($0)" } ?? "它") 已经在跑了" : "在新的终端标签里运行：\(command.command)")
            }
        }
        .padding(.vertical, 2)
    }

    private var addForm: some View {
        HStack(spacing: 6) {
            TextField("目录（空着就是根目录）", text: $newDirectory).frame(width: 150)
            TextField("命令，比如 pnpm dev --port 3000", text: $newCommand).onSubmit(add)
            Button("添加", action: add).disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消") { adding = false; newCommand = ""; newDirectory = "" }
        }
        .textFieldStyle(.roundedBorder).themedFont(.caption, points: 11)
    }

    private func add() {
        model.addLaunchCommand(newCommand, directory: newDirectory)
        adding = false; newCommand = ""; newDirectory = ""
    }
}
