import AppKit
import Darwin
import FolmiCore
import SwiftUI
import SwiftTerm

/// A project owns this session. Moving its view between SwiftUI layouts never starts another shell.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let root: URL
    let createdAt = Date()
    /// What the shell or program set as its title, or the session's state (启动失败, 已退出); empty when neither.
    @Published var title: String
    /// The name the user gave this tab; empty shows the program's title, else the folder the shell is in.
    @Published var name: String
    @Published var isRunning = false
    /// The last part of the shell's current directory, so two tabs read 「docs · zsh」 and 「repository · zsh」.
    @Published private(set) var folder: String
    @Published private(set) var status: String?
    private(set) var hasExited = false
    private(set) var exitCode: Int32?
    var displayTitle: String {
        if let status { return name.isEmpty ? status : "\(name) · \(status)" }
        return !name.isEmpty ? name : (!title.isEmpty ? title : "\(folder) · zsh")
    }
    private var folderCheckedAt: TimeInterval = 0
    /// ⌘-click on a path or web address in the output.
    var onOpenLink: ((String) -> Void)?
    /// ⌘ held over a path or URL (nil when the pointer leaves it), with the link's cell in the terminal view.
    var onHoverLink: ((String?, NSRect) -> Void)?
    let terminalView: FolmiTerminalView
    let launchEnvironment: [String: String]
    let shellArguments: [String]
    private let isolatedHome: URL?
    private var stopped = false
    private var local = false
    private var backgroundPID: Int32 = 0
    private var connection: TerminalConnection?
    private let service: TerminalService?
    private(set) var backgroundID: UUID?
    private let startDirectory: URL
    var onServiceStatus: ((Result<Bool, Error>) -> Void)?

    /// `directory`: where the shell starts, relative to `root`; the root itself when empty, missing or outside it.
    init(root: URL, environment: [String: String], isDemo: Bool, name: String = "", directory: String = "",
         service: TerminalService? = nil, restoredID: UUID? = nil, opened: TerminalService.Opened? = nil) {
        self.id = opened?.info.id ?? restoredID ?? UUID()
        self.root = root
        self.service = isDemo ? nil : service
        self.name = name
        title = ""
        folder = root.lastPathComponent
        if !directory.isEmpty, !directory.split(separator: "/").contains("..") { folder = (directory as NSString).lastPathComponent }
        var env: [String: String]
        var home: URL?
        var startupError: Error?
        if isDemo {
            // Keep demonstrations independent of the user's dotfiles, history, and Git configuration.
            let temporaryHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("Folmi-Terminal-\(UUID().uuidString)", isDirectory: true)
            home = temporaryHome
            do {
                try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
            } catch {
                startupError = error
            }
            env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            for (key, value) in environment where key.hasPrefix("GIT_AUTHOR_") || key.hasPrefix("GIT_COMMITTER_") {
                env[key] = value
            }
            env["HOME"] = temporaryHome.path
            env["ZDOTDIR"] = temporaryHome.path
            env["HISTFILE"] = "/dev/null"
            env["SAVEHIST"] = "0"
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["XDG_CONFIG_HOME"] = temporaryHome.appendingPathComponent("config").path
            env["XDG_CACHE_HOME"] = temporaryHome.appendingPathComponent("cache").path
            env["XDG_DATA_HOME"] = temporaryHome.appendingPathComponent("data").path
            env["PS1"] = "demo %1~ %# "
            shellArguments = ["-d", "-f"]
        } else {
            env = ProcessInfo.processInfo.environment.merging(environment) { _, provided in provided }
            shellArguments = ["-l"]
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            startupError = NSError(domain: "Folmi.Terminal", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "项目目录不存在，终端没有启动。"])
        }
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "Folmi"
        env["COLORTERM"] = "truecolor"
        // A saved directory is relative to the project and may have vanished while Folmi was closed.
        var start = root.path
        if !directory.isEmpty, !directory.split(separator: "/").contains(".."), !directory.hasPrefix("/") {
            let candidate = root.appendingPathComponent(directory).resolvingSymlinksInPath().path
            let base = root.resolvingSymlinksInPath().path
            var isFolder: ObjCBool = false
            if candidate.hasPrefix(base + "/"),
               FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder), isFolder.boolValue { start = candidate }
        }
        startDirectory = URL(fileURLWithPath: start, isDirectory: true)
        env["PWD"] = start
        launchEnvironment = env
        isolatedHome = home
        var options = TerminalOptions.default
        options.scrollback = 2_000
        options.kittyImageCacheLimitBytes = 8 * 1024 * 1024
        let view = FolmiTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 240),
                                     font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        terminalView = view
        super.init()
        view.terminalDelegate = view
        view.onTitle = { [weak self] title in
            guard let self, !self.stopped else { return }
            self.title = String(title.prefix(160))
        }
        view.onOpenLink = { [weak self] link in self?.onOpenLink?(link) }
        view.onHoverLink = { [weak self] link, rect in self?.onHoverLink?(link, rect) }
        view.onExit = { [weak self] status in
            // The local SwiftTerm forkpty backend reports waitpid's raw status.
            let code = status.map { raw in
                let signal = raw & 0x7f
                return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            }
            self?.didExit(code, showsCode: false)
        }
        // A `cd` shows in the next prompt; look at the directory then, at most twice a second.
        view.onOutput = { [weak self] in self?.refreshFolder() }
        view.applyAppearanceColors()
        view.setAccessibilityIdentifier("embedded-terminal")
        view.setAccessibilityLabel(isDemo ? "演示仓库内嵌终端" : "项目内嵌终端")
        if let opened {
            backgroundID = id
            status = "正在接回终端…"
            connect(opened)
        } else if let startupError, restoredID == nil {
            showStartupFailure(startupError)
        } else if let service = self.service {
            openBackground(service, restoring: restoredID != nil)
        } else {
            startLocal()
        }
    }

    private func showStartupFailure(_ error: Error) {
        title = "终端启动失败"
        status = title
        terminalView.feed(text: "终端无法启动：\(error.localizedDescription)\r\n")
    }

    private func startLocal() {
        local = true
        status = nil
        let view = terminalView
        view.onInput = { [weak view] data in view?.process.send(data: data) }
        view.onResize = { [weak view] in
            guard let view, view.process.running else { return }
            var size = view.getWindowSize()
            _ = ioctl(view.process.childfd, TIOCSWINSZ, &size)
        }
        // SwiftTerm's own helper can ignore a failed chdir. env -C refuses to run in the wrong directory.
        view.process.startProcess(executable: "/usr/bin/env",
                                  args: ["-C", startDirectory.path, "/bin/zsh"] + shellArguments,
                                  environment: launchEnvironment.map { "\($0.key)=\($0.value)" },
                                  currentDirectory: startDirectory.path)
        isRunning = view.process.running
        if !isRunning { title = "终端启动失败"; status = title }
    }

    private func openBackground(_ service: TerminalService, restoring: Bool) {
        backgroundID = id
        status = restoring ? "正在接回终端…" : "正在启动终端…"
        let size = terminalView.getWindowSize()
        let request = PTYProtocol.Create(id: id, projectRoot: root.path, cwd: startDirectory.path, env: launchEnvironment,
                                         argv: ["/bin/zsh"] + shellArguments, cols: size.ws_col, rows: size.ws_row)
        service.open(request, restoring: restoring) { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let opened):
                self.onServiceStatus?(.success(opened.stream.peerSharesResourceCoalition))
                self.connect(opened)
            case .failure(.unavailable(let error)):
                self.backgroundID = nil
                self.onServiceStatus?(.failure(error))
                self.startLocal()
            case .failure(.uncertain(let error)):
                self.showStartupFailure(error)
                self.onServiceStatus?(.failure(error))
            case .failure(.rejected(let error)):
                self.showStartupFailure(error)
                if case PTYProtocol.Failure.incompatible = error {
                    self.onServiceStatus?(.failure(error))
                } else {
                    self.backgroundID = nil
                }
            }
        }
    }

    private func connect(_ opened: TerminalService.Opened) {
        backgroundPID = opened.info.hasExited ? 0 : opened.info.shellPid
        let connection = TerminalConnection(opened.stream)
        self.connection = connection
        connection.onFrame = { [weak self] frame in self?.receive(frame) }
        connection.onDisconnect = { [weak self] _ in self?.connectionLost() }
        terminalView.onInput = { [weak self] data in
            guard let self, self.isRunning else { return }
            // Keep large pastes within the wire frame limit.
            var rest = data
            while !rest.isEmpty {
                self.connection?.send(.bytes(.input, id: self.id, data: Data(rest.prefix(32 * 1_024))))
                rest = rest.dropFirst(32 * 1_024)
            }
        }
        terminalView.onResize = { [weak self] in self?.resizeBackground() }
        sendControl(.attach, id)
    }

    private func receive(_ frame: PTYProtocol.Frame) {
        switch frame.kind {
        case .replay, .output:
            guard let bytes = try? frame.bytes(), bytes.id == id else { return }
            if frame.kind == .replay {
                // Replay may contain terminal queries; their historical replies must not reach the running shell.
                terminalView.getTerminal().resetToInitialState()
                terminalView.receiveOutput(bytes.data)
                status = nil
                isRunning = backgroundPID > 0
                refreshFolder(force: true)
                resizeBackground()
            } else {
                terminalView.receiveOutput(bytes.data)
            }
        case .exited:
            guard let exit = try? frame.decode(PTYProtocol.Exit.self), exit.id == id else { return }
            didExit(exit.exitCode)
            connection?.disconnect()
            connection = nil
        case .displaced:
            connectionLost("终端已在另一个窗口接回")
        case .failure:
            connectionLost((try? frame.decode(String.self)) ?? "后台终端连接已断开")
        default: break
        }
    }

    private func resizeBackground() {
        guard isRunning else { return }
        let size = terminalView.getWindowSize()
        sendControl(.resize, PTYProtocol.Resize(id: id, cols: size.ws_col, rows: size.ws_row))
    }

    private func sendControl(_ kind: PTYProtocol.Kind, _ value: some Encodable) {
        if let frame = try? PTYProtocol.Frame.json(kind, value) { connection?.send(frame) }
    }

    private func didExit(_ code: Int32?, showsCode: Bool = true) {
        hasExited = true
        exitCode = code
        isRunning = false
        backgroundPID = 0
        if !stopped {
            title = showsCode ? code.map { "已退出（退出码 \($0)）" } ?? "终端已退出" : "终端已退出"
            status = title
        }
    }

    private func connectionLost(_ message: String = "后台终端连接已断开") {
        connection?.disconnect()
        connection = nil
        isRunning = false
        backgroundPID = 0
        if !stopped { status = message }
    }

    func detachForQuit() {
        guard backgroundID != nil else { stop(); return }
        stopped = true
        sendControl(.detach, id)
        connection?.disconnect()
        connection = nil
    }

    func stop(endBackground: Bool = true) {
        guard !stopped else { return }
        stopped = true
        isRunning = false
        title = "终端已关闭"
        status = title
        if let backgroundID, endBackground { try? service?.end([backgroundID]) }
        backgroundID = nil
        connection?.disconnect()
        connection = nil
        if local && terminalView.process.running {
            let ownedPID = terminalView.process.shellPid
            // Signal only the shell created by this session. Closing the PTY also hangs up its jobs.
            if ownedPID > 0 { Darwin.kill(ownedPID, SIGHUP) }
            terminalView.process.terminate()
            if ownedPID > 0 {
                // SwiftTerm cancels its exit monitor on terminate; reap our child without blocking AppKit.
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    for _ in 0..<30 {
                        let result = waitpid(ownedPID, &status, WNOHANG)
                        if result == ownedPID || result == -1 { return }
                        usleep(50_000)
                    }
                }
            }
        }
        if let isolatedHome { try? FileManager.default.removeItem(at: isolatedHome) }
    }

    /// Pastes multi-line text without pressing Enter. Only done when the program in the terminal turned on bracketed
    /// paste (zsh's line editor, Claude Code and most REPLs do); otherwise each line could run as a command, so it refuses.
    /// ESC [200~ and ESC [201~ (SwiftTerm keeps them in mutable statics, which strict concurrency rejects).
    private static let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    private static let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
    var acceptsBracketedPaste: Bool { isRunning && terminalView.getTerminal().bracketedPasteMode }
    func paste(_ text: String) -> Bool {
        guard acceptsBracketedPaste else { return false }
        terminalView.send(data: Self.pasteStart[0...])
        terminalView.send(txt: text)
        terminalView.send(data: Self.pasteEnd[0...])
        return true
    }
    /// Where relative paths in the output start from: the foreground program's working directory, else the shell's.
    var currentDirectory: URL? {
        guard isRunning else { return nil }
        for pid in [foregroundPID, shellPID] where pid > 0 {
            if let path = ServiceScanner.workingDirectory(pid) { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return nil
    }
    var savedDirectory: URL { currentDirectory ?? lastDirectory ?? startDirectory }
    private var lastDirectory: URL?
    var shellPID: Int32 { local ? (isRunning ? terminalView.process.shellPid : 0) : backgroundPID }

    var foregroundPID: Int32 {
        guard shellPID > 0 else { return 0 }
        if local { return tcgetpgrp(terminalView.process.childfd) }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(shellPID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return Int32(bitPattern: info.e_tpgid)
    }

    var runsProgram: Bool {
        let foreground = foregroundPID
        return foreground > 0 && foreground != shellPID
    }

    var runningProgram: String? {
        let shell = shellPID
        guard shell > 0 else { return nil }
        let foreground = foregroundPID
        if foreground > 0 && foreground != shell { return PTYProcess.name(of: foreground) ?? "程序" }
        return PTYProcess.backgroundJob(in: shell)
    }
    func refreshFolder(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - folderCheckedAt > 0.5 else { return }
        folderCheckedAt = now
        guard let directory = currentDirectory else { return }
        lastDirectory = directory
        let next = directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent
        if folder != next { folder = next }
    }

    /// Tab titles with repeats numbered (「repository · zsh」「repository · zsh 2」), so each tab can be told apart.
    static func distinctTitles(_ titles: [String]) -> [String] {
        var seen: [String: Int] = [:]
        let counts = Dictionary(titles.map { ($0, 1) }, uniquingKeysWith: +)
        return titles.map { title in
            guard counts[title, default: 0] > 1 else { return title }
            seen[title, default: 0] += 1
            return seen[title] == 1 ? title : "\(title) \(seen[title]!)"
        }
    }
}

/// Both backends use the same SwiftTerm view and interaction policy, including blocking OSC 52 clipboard access.
final class FolmiTerminalView: SwiftTerm.TerminalView, @preconcurrency TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
    lazy var process = LocalProcess(delegate: self)
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onResize: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onOpenLink: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    /// Optional observer used by PTY integration tests; regular sessions retain no output transcript.
    var outputObserver: ((ArraySlice<UInt8>) -> Void)?
    var onOutput: (() -> Void)?

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { onResize?() }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { onInput?(data) }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { onOpenLink?(link) }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { onExit?(exitCode) }
    func dataReceived(slice: ArraySlice<UInt8>) {
        feed(byteArray: slice)
        outputObserver?(slice)
        onOutput?()
    }

    func receiveOutput(_ data: Data) { dataReceived(slice: Array(data)[...]) }

    func getWindowSize() -> winsize {
        let core = getTerminal()
        let cell = cellSize() ?? .zero
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return winsize(ws_row: UInt16(clamping: max(1, core.rows)), ws_col: UInt16(clamping: max(1, core.cols)),
                       ws_xpixel: UInt16(clamping: Int(cell.width * CGFloat(core.cols) * scale)),
                       ws_ypixel: UInt16(clamping: Int(cell.height * CGFloat(core.rows) * scale)))
    }

    /// SwiftTerm stores the dynamic system colors as-is, and the layer and the text then resolve them under different
    /// appearances (white text on a white layer in dark mode). Resolve both to fixed colors for this view's appearance.
    var theme: FolmiTheme = .standard { didSet { if theme != oldValue { applyAppearanceColors() } } }
    func applyAppearanceColors() {
        let palette = theme.palette
        var foreground = palette.foreground, background = palette.editorBackground
        effectiveAppearance.performAsCurrentDrawingAppearance {
            foreground = palette.foreground.usingColorSpace(.sRGB) ?? .white
            background = palette.editorBackground.usingColorSpace(.sRGB) ?? .black
        }
        if nativeForegroundColor != foreground { nativeForegroundColor = foreground }
        if nativeBackgroundColor != background { nativeBackgroundColor = background }
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearanceColors()
        installHoverMonitor()
    }

    // MARK: ⌘-hover link preview

    /// Reported when the link under the pointer changes while ⌘ is held.
    var onHoverLink: ((String?, NSRect) -> Void)?
    /// Only touched on the main thread and in deinit, when nothing else holds the view.
    nonisolated(unsafe) private var hoverMonitor: Any?
    private(set) var hoveredLink: String?
    private var preview: NSPopover?

    private func installHoverMonitor() {
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor); self.hoverMonitor = nil }
        guard window != nil else { report(nil, .zero); return }
        // SwiftTerm handles its own mouse-moved events and offers no hover callback, so this watches the same events.
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackHover(event) }
            return event
        }
    }
    deinit { if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) } }

    private func trackHover(_ event: NSEvent) {
        guard let window, event.window === window, event.type != .keyDown, event.type != .scrollWheel,
              event.modifierFlags.contains(.command) else { report(nil, .zero); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point), let cell = cellSize(), let terminal else { report(nil, .zero); return }
        let col = Int(point.x / cell.width), row = Int((frame.height - point.y) / cell.height)
        guard col >= 0, col < terminal.cols, row >= 0, row < terminal.rows else { report(nil, .zero); return }
        let link = terminal.link(at: .screen(Position(col: col, row: row)), mode: .explicitAndImplicit)
        let rect = NSRect(x: CGFloat(col) * cell.width, y: frame.height - CGFloat(row + 1) * cell.height, width: cell.width, height: cell.height)
        report(link, rect)
    }

    /// The same cell size SwiftTerm lays text out with: the "W" advance snapped to the pixel grid, and the row height
    /// that its optimal frame divides into.
    func cellSize() -> CGSize? {
        guard let terminal, terminal.rows > 0 else { return nil }
        let glyph = font.glyph(withName: "W")
        let scale = window?.backingScaleFactor ?? 2
        let width = (font.advancement(forGlyph: glyph).width * scale).rounded() / scale
        let height = getOptimalFrameSize().height / CGFloat(terminal.rows)
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : nil
    }

    private func report(_ link: String?, _ rect: NSRect) {
        guard link != hoveredLink else { return }
        hoveredLink = link
        if link == nil { closeLinkPreview() }
        onHoverLink?(link, rect)
    }

    func showLinkPreview<Content: View>(_ content: Content, at rect: NSRect) {
        let popover = preview ?? NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: content)
        preview = popover
        if popover.isShown { popover.positioningRect = rect }
        else { popover.show(relativeTo: rect, of: self, preferredEdge: .maxY) }
    }
    func closeLinkPreview() {
        preview?.performClose(nil)
        preview = nil
    }
}

/// One terminal tab in the card header: its name or the program's title. Double-click or the menu renames it.
struct TerminalTabButton: View {
    @ObservedObject var session: TerminalSession
    /// The tab's title, numbered when another tab has the same one.
    let title: String
    let selected: Bool
    let select: () -> Void
    let rename: () -> Void
    let close: () -> Void
    var canSplit = false
    var canMoveLeft = false
    var canMoveRight = false
    /// 向左拆分 / 向右拆分 and 移到左边一栏 / 右边一栏 from the tab's menu; nil hides them.
    var split: ((Bool) -> Void)?
    var move: ((Bool) -> Void)?
    var body: some View {
        let _ = PerfLog.body("TerminalTabButton")
        let currentTitle = session.displayTitle
        let visibleTitle = title.hasPrefix(currentTitle + " ") ? title : currentTitle
        HStack(spacing: 0) {
            PaneTab(title: visibleTitle, italic: !session.isRunning, selected: selected, action: select)
                .simultaneousGesture(TapGesture(count: 2).onEnded(rename))
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.secondary)
            .help("关闭这个终端")
            .accessibilityLabel("关闭终端 \(session.displayTitle)")
        }
        .frame(maxWidth: 200)
        .contextMenu {
            Button("重命名…", action: rename)
            Button("关闭这个终端", action: close)
            if let split {
                Divider()
                Button("向左拆分") { split(false) }.disabled(!canSplit)
                Button("向右拆分（⌘\\）") { split(true) }.disabled(!canSplit)
            }
            if let move, canMoveLeft { Button("移到左边一栏") { move(false) } }
            if let move, canMoveRight { Button("移到右边一栏") { move(true) } }
        }
        .help(visibleTitle + "\n当前目录：\(session.currentDirectory?.path ?? session.root.path)")
        .accessibilityLabel("终端 \(visibleTitle)")
    }
}

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        let _ = PerfLog.body("TerminalPane")
        TerminalRepresentable(session: session)
            .id(session.id)
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> TerminalHostView { TerminalHostView(terminal: session.terminalView) }
    func updateNSView(_ host: TerminalHostView, context: Context) {
        PerfLog.body("TerminalRepresentable.update")
        if host.terminal !== session.terminalView { host.adopt(session.terminalView) }
        host.terminal.theme = context.environment.folmiTheme
        host.terminal.applyAppearanceColors()
        host.layer?.backgroundColor = host.terminal.nativeBackgroundColor.cgColor
    }
    // Deliberately do not terminate on dismantle: a project switch keeps its shell and scrollback.
}

/// Holds the terminal and decides when it takes a new size. Every SwiftTerm resize reflows the scrollback and sends
/// the shell a SIGWINCH (zsh redraws its prompt), so while a card edge is dragged, or the size is still moving (card
/// animations, window resize), the terminal keeps its size pinned to the bottom-left corner — the prompt stays in
/// view — and takes the final size once.
final class TerminalHostView: NSView {
    private(set) var terminal: FolmiTerminalView
    private var settle: DispatchWorkItem?
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var sized = false

    init(terminal: FolmiTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(terminal)
        observer = NotificationCenter.default.addObserver(forName: PaneLiveResize.didEnd, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitSize() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func adopt(_ terminal: FolmiTerminalView) {
        self.terminal.removeFromSuperview()
        self.terminal = terminal
        addSubview(terminal)
        sized = false
        needsLayout = true
    }
    override var isFlipped: Bool { false }
    /// The terminal moves to a new host when its card is rebuilt (maximize, restore, tab changes). The old host keeps
    /// a reference but must never size it again: its late settle used to shrink the terminal into a corner of the new card.
    private var ownsTerminal: Bool { terminal.superview === self }
    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        if subview === terminal { settle?.cancel(); settle = nil }
    }
    override func layout() {
        super.layout()
        settle?.cancel()
        guard ownsTerminal, bounds.width > 0, bounds.height > 0 else { return }
        if terminal.frame == bounds { sized = true; moving = false; return }
        // The first size and plain one-off changes apply at once; a size that keeps moving waits until it rests.
        if !sized || (!PaneLiveResize.isActive && !inLiveResize && !moving) { commitSize(); return }
        terminal.setFrameOrigin(NSPoint(x: 0, y: pinnedOriginY))
        scheduleSettle()
    }
    /// While the size is pinned, the text stays under the card's top edge (so it follows the header when the edge is
    /// dragged up) as long as the cursor line still fits; a full screen keeps its bottom, where the prompt is, in view.
    private var pinnedOriginY: CGFloat {
        let top = bounds.height - terminal.frame.height
        let core = terminal.getTerminal()
        guard core.rows > 0 else { return top }
        let cursorBottom = CGFloat(core.buffer.y + 1) * terminal.frame.height / CGFloat(core.rows)
        return cursorBottom <= bounds.height ? top : 0
    }
    /// Takes the final size once nothing is moving. A pending settle used to be cancelled by a layout during a pane
    /// drag and never come back, leaving the terminal at its old size in a corner of a bigger card.
    private func scheduleSettle() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ownsTerminal else { return }
            if PaneLiveResize.isActive || self.inLiveResize { self.scheduleSettle() } else { self.commitSize() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, terminal.frame != bounds { needsLayout = true }
    }
    /// Set while sizes are arriving in quick succession; cleared when one is committed.
    private var moving = false
    private var lastLayout = Date.distantPast
    override func setFrameSize(_ newSize: NSSize) {
        // Two sizes within a frame or two mean the size is animating, not a one-off change.
        let now = Date()
        if now.timeIntervalSince(lastLayout) < 0.05 { moving = true }
        lastLayout = now
        super.setFrameSize(newSize)
    }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); commitSize() }

    private func commitSize() {
        settle?.cancel()
        moving = false
        guard ownsTerminal, bounds.width > 0, bounds.height > 0 else { return }
        sized = true
        if terminal.frame != bounds { terminal.frame = bounds }
    }
}
