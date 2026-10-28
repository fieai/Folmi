import AppKit
import Darwin
import SwiftUI
import SwiftTerm

/// A project owns this session. Moving its view between SwiftUI layouts never starts another shell.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let root: URL
    /// What the shell or program set as its title, or the session's state (启动失败, 已退出); empty when neither.
    @Published var title: String
    /// The name the user gave this tab; empty shows the program's title, else the folder the shell is in.
    @Published var name: String
    @Published var isRunning = false
    /// The last part of the shell's current directory, so two tabs read 「docs · zsh」 and 「repository · zsh」.
    @Published private(set) var folder: String
    var displayTitle: String { !name.isEmpty ? name : (!title.isEmpty ? title : "\(folder) · zsh") }
    private var folderCheckedAt: TimeInterval = 0
    /// ⌘-click on a path or web address in the output.
    var onOpenLink: ((String) -> Void)?
    /// ⌘ held over a path or URL (nil when the pointer leaves it), with the link's cell in the terminal view.
    var onHoverLink: ((String?, NSRect) -> Void)?
    let terminalView: FolmiTerminalView
    let launchEnvironment: [String: String]
    let shellArguments: [String]
    private let terminalDelegate: TerminalInteractionDelegate
    private let isolatedHome: URL?
    private var stopped = false

    /// `directory`: where the shell starts, relative to `root`; the root itself when empty, missing or outside it.
    init(root: URL, environment: [String: String], isDemo: Bool, name: String = "", directory: String = "") {
        self.root = root
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
        env["PWD"] = root.path
        launchEnvironment = env
        isolatedHome = home
        var options = TerminalOptions.default
        options.scrollback = 2_000
        options.kittyImageCacheLimitBytes = 8 * 1024 * 1024
        let view = FolmiTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 240),
                                         font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        terminalView = view
        terminalDelegate = TerminalInteractionDelegate(view: view)
        super.init()
        view.terminalDelegate = terminalDelegate
        terminalDelegate.openLink = { [weak self] link in self?.onOpenLink?(link) }
        view.onHoverLink = { [weak self] link, rect in self?.onHoverLink?(link, rect) }
        view.processDelegate = self
        view.applyAppearanceColors()
        view.setAccessibilityIdentifier("embedded-terminal")
        view.setAccessibilityLabel(isDemo ? "演示仓库内嵌终端" : "项目内嵌终端")
        if let startupError {
            title = "终端启动失败"
            view.feed(text: "终端无法启动：\(startupError.localizedDescription)\r\n")
            return
        }
        // env -C fails before executing zsh if the directory disappears. SwiftTerm's own
        // forkpty helper ignores a failed chdir, so passing currentDirectory alone is insufficient.
        var start = root.path
        if !directory.isEmpty, !directory.split(separator: "/").contains(".."), !directory.hasPrefix("/") {
            let candidate = root.appendingPathComponent(directory).standardizedFileURL.path
            var folder: ObjCBool = false
            if candidate.hasPrefix(root.standardizedFileURL.path + "/"),
               FileManager.default.fileExists(atPath: candidate, isDirectory: &folder), folder.boolValue { start = candidate }
        }
        view.startProcess(executable: "/usr/bin/env", args: ["-C", start, "/bin/zsh"] + shellArguments,
                          environment: env.keys.sorted().map { "\($0)=\(env[$0]!)" },
                          currentDirectory: start)
        isRunning = view.process.running
        if !isRunning { title = "终端启动失败" }
        // A `cd` shows in the shell's output (the next prompt); look at the directory then, at most twice a second.
        view.onOutput = { [weak self] in self?.refreshFolder() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        isRunning = false
        title = "终端已关闭"
        if terminalView.process.running {
            let ownedPID = terminalView.process.shellPid
            // Signal only the shell created by this session. Closing the PTY also hangs up its jobs.
            if ownedPID > 0 { Darwin.kill(ownedPID, SIGHUP) }
            terminalView.terminate()
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
        let shell = terminalView.process.shellPid
        let foreground = tcgetpgrp(terminalView.process.childfd)
        for pid in [foreground, shell] where pid > 0 {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return nil
    }
    var shellPID: Int32 { isRunning ? terminalView.process.shellPid : 0 }
    /// A program is running in the tab (a dev server, Claude Code) rather than the shell waiting at its prompt.
    var runsProgram: Bool {
        guard isRunning else { return false }
        let foreground = tcgetpgrp(terminalView.process.childfd)
        return foreground > 0 && foreground != terminalView.process.shellPid
    }
    func refreshFolder(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - folderCheckedAt > 0.5 else { return }
        folderCheckedAt = now
        guard let directory = currentDirectory else { return }
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

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !stopped else { return }
        self.title = String(title.prefix(160))
    }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        isRunning = false
        if !stopped { title = "终端已退出" }
    }
}

/// Default keyboard copy/paste remains user initiated. OSC 52 cannot read or replace the clipboard.
/// Links open only on ⌘-click, and only through the session's handler.
/// SwiftTerm calls its delegate on the main thread; the conformance says so and checks it at run time.
@MainActor
private final class TerminalInteractionDelegate: @preconcurrency TerminalViewDelegate {
    weak var view: LocalProcessTerminalView?
    var openLink: ((String) -> Void)?
    init(view: LocalProcessTerminalView) { self.view = view }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        view?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        view?.setTerminalTitle(source: source, title: title)
    }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        view?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { view?.send(source: source, data: data) }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) { view?.scrolled(source: source, position: position) }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
        view?.rangeChanged(source: source, startY: startY, endY: endY)
    }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    /// SwiftTerm reports a ⌘-click on an OSC 8 link or on a URL or path it found in the text.
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { openLink?(link) }
}

final class FolmiTerminalView: LocalProcessTerminalView {
    /// Optional observer used by PTY integration tests; regular sessions retain no output transcript.
    var outputObserver: ((ArraySlice<UInt8>) -> Void)?
    /// Told when output arrives (no bytes kept), for the tab's folder name.
    var onOutput: (() -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        outputObserver?(slice)
        onOutput?()
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
        PaneTab(title: title, italic: !session.isRunning, selected: selected, action: select)
            .frame(maxWidth: 200)
            .simultaneousGesture(TapGesture(count: 2).onEnded(rename))
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
            .help(title + "\n当前目录：\(session.currentDirectory?.path ?? session.root.path)")
            .accessibilityLabel("终端 \(title)")
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
