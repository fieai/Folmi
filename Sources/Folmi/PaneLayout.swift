import AppKit
import os
import SwiftTerm
import SwiftUI
import WebKit

enum FolmiPane: String, Codable, CaseIterable, Sendable {
    /// `changes` is the left block, with the file tree and the Git changes as its two tabs.
    case changes, editor, terminal

    var title: String { switch self { case .changes: return "文件与改动"; case .editor: return "编辑器"; case .terminal: return "终端" } }
    var systemImage: String {
        switch self { case .changes: return "sidebar.left"; case .editor: return "doc.text"; case .terminal: return "terminal" }
    }
    var shortcut: KeyEquivalent { switch self { case .changes: return "1"; case .editor: return "2"; case .terminal: return "3" } }
}

/// The left block's two tabs.
enum SideTab: String, Codable, Sendable {
    case files, changes
    var title: String { self == .files ? "文件" : "改动" }
}

/// Which cards are open, which one is focused or maximized, and the two drag sizes. Pure state so it can be tested and persisted.
struct PaneLayoutState: Codable, Equatable {
    static let sidebarRange: ClosedRange<Double> = 240...560
    static let terminalRange: ClosedRange<Double> = 120...720

    var focused: FolmiPane = .editor
    var maximized: FolmiPane?
    var closed: Set<FolmiPane> = [.terminal]
    var sidebarWidth: Double = 320 { didSet { sidebarWidth = sidebarWidth.clamped(to: Self.sidebarRange) } }
    var terminalHeight: Double = 240 { didSet { terminalHeight = terminalHeight.clamped(to: Self.terminalRange) } }
    var sideTab: SideTab = .files

    var closedPanes: [FolmiPane] { FolmiPane.allCases.filter(closed.contains) }
    func isOpen(_ pane: FolmiPane) -> Bool { !closed.contains(pane) }
    func isShown(_ pane: FolmiPane) -> Bool { isOpen(pane) && (maximized == nil || maximized == pane) }

    /// Focusing reopens a collapsed card and leaves another card's maximized view.
    mutating func focus(_ pane: FolmiPane) {
        closed.remove(pane)
        if let maximized, maximized != pane { self.maximized = nil }
        focused = pane
    }
    mutating func toggleMaximize(_ pane: FolmiPane) {
        guard isOpen(pane) else { return }
        maximized = maximized == pane ? nil : pane
        focused = pane
    }
    mutating func close(_ pane: FolmiPane) {
        closed.insert(pane)
        if maximized == pane { maximized = nil }
        if focused == pane, let next = [FolmiPane.editor, .changes, .terminal].first(where: isOpen) { focused = next }
    }

    private enum CodingKeys: String, CodingKey { case focused, maximized, closed, sidebarWidth, terminalHeight, sideTab }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Pane names this version does not know (a "files" block saved briefly in 0.6) are dropped, not fatal.
        focused = (try? values.decodeIfPresent(FolmiPane.self, forKey: .focused)) ?? .editor
        maximized = try? values.decodeIfPresent(FolmiPane.self, forKey: .maximized)
        closed = Set(((try? values.decodeIfPresent([String].self, forKey: .closed)) ?? ["terminal"]).compactMap(FolmiPane.init(rawValue:)))
        sidebarWidth = (try values.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 320).clamped(to: Self.sidebarRange)
        terminalHeight = (try values.decodeIfPresent(Double.self, forKey: .terminalHeight) ?? 240).clamped(to: Self.terminalRange)
        sideTab = (try? values.decodeIfPresent(SideTab.self, forKey: .sideTab)) ?? .files
    }
}

struct PaneFocusRequest: Equatable {
    let pane: FolmiPane
    var prefersCommitEditor = false
    let id = UUID()
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}

// MARK: - AppKit focus tracking

/// Knows each card's on-screen area through a transparent anchor view, so clicks inside AppKit views
/// (text view, terminal, table) still mark their card focused, and ⌘1/2/3 can hand keyboard focus to the card.
@MainActor
final class PaneFocusTracker: ObservableObject {
    private var anchors: [FolmiPane: WeakView] = [:]
    private var monitor: Any?
    var onClick: ((FolmiPane) -> Void)?

    func register(_ view: NSView, for pane: FolmiPane) { anchors[pane] = WeakView(view: view) }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        for (pane, anchor) in anchors {
            guard let view = anchor.view, view.window === event.window, !view.isHiddenOrHasHiddenAncestor else { continue }
            if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { onClick?(pane); return }
        }
    }

    /// Moves keyboard focus to the main control inside the card: terminal, editor text, then the file list.
    func makeFirstResponder(_ pane: FolmiPane, preferCommitEditor: Bool = false) {
        guard let anchor = anchors[pane]?.view, let window = anchor.window, let root = window.contentView else { return }
        var candidates: [NSView] = []
        func collect(_ view: NSView) {
            // A hidden view (the editor behind the reading view, or the reverse) takes nothing, nor do its subviews.
            guard !view.isHidden else { return }
            if view.acceptsFirstResponder {
                let frame = anchor.convert(view.bounds, from: view)
                if anchor.bounds.contains(NSPoint(x: frame.midX, y: frame.midY)) { candidates.append(view) }
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        let preferred: [(NSView) -> Bool]
        switch pane {
        case .terminal: preferred = [{ $0 is TerminalView }]
        case .editor: preferred = [{ ($0 as? NSTextView)?.isEditable == true }, { $0 is WKWebView }, { $0 is NSTextView }]
        case .changes:
            preferred = preferCommitEditor
                ? [{ ($0 as? NSTextView)?.isEditable == true }, { $0 is NSTableView }, { $0 is NSTextField }]
                : [{ $0 is NSTableView }, { $0 is NSTextField }]
        }
        // The largest match wins, so the editor body beats the find field and the file list beats the search box.
        for matches in preferred {
            if let target = candidates.filter(matches).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                window.makeFirstResponder(target); return
            }
        }
        // No AppKit control (for example the all-changes page): give the SwiftUI host focus so its focused view gets keys.
        if pane == .editor { window.makeFirstResponder(root) }
    }

    private struct WeakView { weak var view: NSView? }
}

/// Transparent, click-through view placed behind a card to report its frame.
struct PaneAnchor: NSViewRepresentable {
    let pane: FolmiPane
    let tracker: PaneFocusTracker
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        tracker.register(view, for: pane)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { tracker.register(nsView, for: pane) }
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Card chrome

struct PaneCard<Tabs: View, Accessory: View, Content: View>: View {
    let pane: FolmiPane
    let focused: Bool
    let maximized: Bool
    let tracker: PaneFocusTracker
    let onMaximize: () -> Void
    let onClose: () -> Void
    @ViewBuilder var tabs: Tabs
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @Environment(\.folmiTheme) private var theme

    var body: some View {
        let _ = PerfLog.body("PaneCard")
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                tabs
                Spacer(minLength: 6)
                accessory
                PaneIconButton(symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: maximized ? "还原（⇧⌘↩）" : "最大化（⇧⌘↩，或双击标题栏）", action: onMaximize)
                PaneIconButton(symbol: "xmark", help: "收起\(pane.title)（⌥⌘W），可从左侧栏恢复", action: onClose)
            }
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: Metrics.paneHeader)
            .folmiSurface(.header)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onMaximize)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(FolmiCardShape(focused: focused))
        .background(PaneAnchor(pane: pane, tracker: tracker))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane.title)
    }
}

/// A block's name in its header, with a quiet detail after it (project name, file count).
struct PaneTitle: View {
    let title: String
    var detail: String?
    var body: some View {
        let _ = PerfLog.body("PaneTitle")
        HStack(spacing: 6) {
            Text(title).themedFont(.system(size: 13, weight: .semibold), points: 13)
            if let detail { Text(detail).themedFont(.system(size: 12), points: 12).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        }
        .padding(.leading, 6)
    }
}

struct PaneTab: View {
    let title: String
    var count: Int?
    /// A small accent dot: something new waits behind this tab.
    var dot = false
    var italic = false
    let selected: Bool
    let action: () -> Void
    var body: some View {
        let _ = PerfLog.body("PaneTab")
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).italic(italic).lineLimit(1).truncationMode(.middle)
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary).contentTransition(.numericText()) }
                if dot { Circle().fill(ThemeColor(token: .accent)).frame(width: 6, height: 6).transition(.scale.combined(with: .opacity)) }
            }
            .themedFont(.system(size: 12, weight: selected ? .medium : .regular), points: 12)
            .foregroundStyle(ThemeColor(token: selected ? .foreground : .secondaryText))
            .padding(.horizontal, 8).padding(.vertical, 4)
            // Underlined tabs stand the header's full height so the line sits on its bottom edge.
            .frame(maxHeight: underlined ? .infinity : nil)
            .background { TabBackground(selected: selected, hovering: hovering) }
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : Motion.hover, value: hovering)
            .animation(reduceMotion ? nil : Motion.state, value: selected)
            .animation(reduceMotion ? nil : Motion.reveal, value: dot)
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.folmiTheme) private var theme
    private var underlined: Bool { theme.style.tabs == .underline }
}

struct PaneIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        let _ = PerfLog.body("PaneIconButton")
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: Metrics.iconSize, weight: .medium))
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .themedBackground(ThemeColor(token: .hover, opacity: hovering ? 1 : 0), .control)
                .contentShape(Rectangle())
                .motion(Motion.hover, value: hovering)
        }
        .buttonStyle(.pressable)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An icon that stays lit while its setting is on (大纲, 自动换行), in place of a checkbox in a toolbar.
struct PaneIconToggle: View {
    let symbol: String
    @Binding var isOn: Bool
    let help: String
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let _ = PerfLog.body("PaneIconToggle")
        Button { isOn.toggle() } label: {
            Image(systemName: symbol).font(.system(size: Metrics.iconSize, weight: .medium))
                .foregroundStyle(ThemeColor(token: isOn ? .accent : .secondaryText))
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .themedBackground(ThemeColor(token: isOn ? .selectedFill : .hover, opacity: isOn || hovering ? 1 : 0), .control)
                .contentShape(Rectangle())
                .motion(Motion.hover, value: hovering)
                .motion(Motion.state, value: isOn)
        }
        .buttonStyle(.pressable)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help + (isOn ? "（已开）" : "（已关）"))
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension AnyTransition {
    /// A card arriving or leaving: it fades while drifting a few points from the edge it belongs to.
    static func paneSlide(edge: Edge) -> AnyTransition {
        let distance: CGFloat = 14
        let offset: CGSize
        switch edge {
        case .leading: offset = CGSize(width: -distance, height: 0)
        case .trailing: offset = CGSize(width: distance, height: 0)
        case .top: offset = CGSize(width: 0, height: -distance)
        case .bottom: offset = CGSize(width: 0, height: distance)
        }
        return .opacity.combined(with: .offset(offset)).combined(with: .scale(scale: 0.985))
    }
}

// MARK: - Live resizing

/// The two drag sizes while the window is open. Kept out of `FolmiModel` so a drag re-lays out the cards
/// without re-rendering the window: only the small `PaneSizeBox` views observe it, and the model (with its save)
/// gets the final value once, on release.
@MainActor
final class PaneSizes: ObservableObject {
    @Published var sidebarWidth: Double = 320
    @Published var terminalHeight: Double = 240
    private(set) var dragging = false

    func sync(from layout: PaneLayoutState) {
        guard !dragging else { return }
        if sidebarWidth != layout.sidebarWidth { sidebarWidth = layout.sidebarWidth }
        if terminalHeight != layout.terminalHeight { terminalHeight = layout.terminalHeight }
    }
    func begin() { dragging = true; PaneLiveResize.begin() }
    func end() { dragging = false; PaneLiveResize.end() }
}

/// Tells AppKit views that a card edge is being dragged, so costly work that follows their size (Markdown restyle,
/// terminal reflow and the shell's SIGWINCH redraw) waits for the release instead of running on every mouse move.
@MainActor
enum PaneLiveResize {
    static let didEnd = Notification.Name("PaneLiveResizeDidEnd")
    private(set) static var isActive = false
    private static var interval: OSSignpostIntervalState?
    static func begin() {
        isActive = true
        interval = Perf.signposter.beginInterval("Pane drag")
    }
    static func end() {
        guard isActive else { return }
        isActive = false
        if let interval { Perf.signposter.endInterval("Pane drag", interval) }
        interval = nil
        NotificationCenter.default.post(name: didEnd, object: nil)
    }
}

/// An empty box sized from `PaneSizes`; a card is laid over it. A size change re-renders only this leaf, so the
/// card's own views are laid out at the new size but none of their bodies run again.
struct PaneSizeBox: View {
    enum Dimension { case sidebarWidth, terminalHeight }
    @ObservedObject var sizes: PaneSizes
    let dimension: Dimension
    var maximumWidth = Double.greatestFiniteMagnitude
    var body: some View {
        let _ = PerfLog.body("PaneSizeBox")
        switch dimension {
        case .sidebarWidth: Color.clear.frame(width: min(sizes.sidebarWidth, maximumWidth))
        case .terminalHeight: Color.clear.frame(height: sizes.terminalHeight)
        }
    }
}

/// The gap between cards doubles as the resize handle. AppKit handles the drag: the mouse is tracked in window
/// coordinates (stable while the handle itself moves), and the cursor is a cursor rect rather than a push/pop pair that
/// SwiftUI hover can unbalance. A short accent grip fades in on hover; while dragging it stretches, bows with the
/// drag speed and springs straight again, and an `elastic` edge gives a little past its limit and springs back on release.
struct PaneResizeHandle: NSViewRepresentable {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    /// Dragging toward the leading/top edge grows the value when true (the terminal sits below the editor).
    var inverted = false
    var thickness: CGFloat = 8
    /// Lets the drag run a little past the limit with resistance, then springs back to it on release.
    var elastic = false
    let value: () -> Double
    /// The largest value that still leaves the neighbouring card its room, given the window's content size.
    var limit: (NSSize) -> ClosedRange<Double> = { _ in 0...Double.greatestFiniteMagnitude }
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    var onReset: (() -> Void)?
    var help: String?
    @Environment(\.folmiTheme) private var theme

    func makeNSView(context: Context) -> PaneDividerView {
        let view = PaneDividerView(vertical: axis == .vertical)
        update(view)
        return view
    }
    func updateNSView(_ view: PaneDividerView, context: Context) { update(view) }
    private func update(_ view: PaneDividerView) {
        view.inverted = inverted
        view.elastic = elastic
        view.value = value; view.limit = limit
        view.onBegin = onBegin; view.onChange = onChange; view.onEnd = onEnd; view.onReset = onReset
        view.accent = theme.palette.accent
        view.toolTip = help
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PaneDividerView, context: Context) -> CGSize? {
        axis == .horizontal ? CGSize(width: thickness, height: proposal.height ?? 10) : CGSize(width: proposal.width ?? 10, height: thickness)
    }
}

final class PaneDividerView: NSView {
    let vertical: Bool
    var inverted = false
    var elastic = false
    var value: () -> Double = { 0 }
    var limit: (NSSize) -> ClosedRange<Double> = { _ in 0...Double.greatestFiniteMagnitude }
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onReset: (() -> Void)?
    var accent: NSColor = .controlAccentColor { didSet { updateLine() } }
    private let line = CAShapeLayer()
    private var start: (point: NSPoint, value: Double)?
    private var hovering = false
    private var hoverWork: DispatchWorkItem?

    /// The grip's length at rest, while dragging, and the most it bows sideways.
    private static let restLength: CGFloat = 28, dragLength: CGFloat = 52, maxBend: CGFloat = 4
    /// Two small springs drive the grip: its length and its sideways bow. Underdamped, so they settle with a slight wobble.
    private var length = Spring(value: restLength), bend = Spring(value: 0)
    private var dragVelocity: CGFloat = 0
    private var lastDrag: (time: TimeInterval, position: CGFloat)?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(vertical: Bool) {
        self.vertical = vertical
        super.init(frame: .zero)
        wantsLayer = true
        line.opacity = 0
        line.fillColor = nil
        line.lineWidth = 3
        line.lineCap = .round
        line.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(line)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var cursor: NSCursor { vertical ? .resizeUpDown : .resizeLeftRight }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.frame = bounds
        drawLine()
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLine() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTicking() }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        // Like VS Code's sash: a short delay so sweeping across the gap does not flash the line.
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showLine(true) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        hoverWork?.cancel()
        if start == nil { showLine(false) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onReset { onReset(); return }
        start = (event.locationInWindow, value())
        lastDrag = nil; dragVelocity = 0
        hoverWork?.cancel()
        showLine(true)
        animate(length: Self.dragLength)
        onBegin()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        cursor.set()
        let point = event.locationInWindow
        // Window coordinates grow upward; the terminal height grows when the edge moves up.
        let delta = vertical ? Double(point.y - start.point.y) : Double(point.x - start.point.x)
        let signed = vertical ? (inverted ? delta : -delta) : (inverted ? -delta : delta)
        let range = limit(window?.contentLayoutRect.size ?? .zero)
        onChange(resisted(start.value + signed, in: range))
        trackVelocity(vertical ? point.y : point.x, time: event.timestamp)
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        let range = limit(window?.contentLayoutRect.size ?? .zero)
        let current = value()
        let settled = Swift.min(range.upperBound, Swift.max(range.lowerBound, current))
        if settled != current {
            // Pulled past the limit: spring back to it.
            withAnimation(reduceMotion ? nil : Motion.settle) { onChange(settled) }
        }
        dragVelocity = 0; lastDrag = nil
        animate(length: Self.restLength, bend: 0)
        onEnd()
        if !hovering { showLine(false) }
    }

    /// Inside the range the value follows the mouse; past it, an elastic edge gives ever less (a rubber band capped
    /// at about 24 points), a plain one stops.
    private func resisted(_ proposed: Double, in range: ClosedRange<Double>) -> Double {
        guard elastic, !reduceMotion else { return Swift.min(range.upperBound, Swift.max(range.lowerBound, proposed)) }
        let reach = 24.0
        func rubber(_ excess: Double) -> Double { reach * (1 - 1 / (excess * 0.55 / reach + 1)) }
        if proposed > range.upperBound { return range.upperBound + rubber(proposed - range.upperBound) }
        if proposed < range.lowerBound { return range.lowerBound - rubber(range.lowerBound - proposed) }
        return proposed
    }

    // MARK: Grip

    private func trackVelocity(_ position: CGFloat, time: TimeInterval) {
        defer { lastDrag = (time, position) }
        guard let lastDrag, time > lastDrag.time else { return }
        let instant = (position - lastDrag.position) / CGFloat(time - lastDrag.time)
        dragVelocity = dragVelocity * 0.6 + instant * 0.4
        guard !reduceMotion else { return }
        // The grip leads with its middle: it bows toward the drag, more the faster it goes.
        bend.target = Swift.max(-Self.maxBend * 2, Swift.min(Self.maxBend * 2, dragVelocity * 0.012))
        startTicking()
    }

    private func animate(length target: CGFloat, bend bendTarget: CGFloat? = nil) {
        length.target = target
        if let bendTarget { bend.target = bendTarget }
        if reduceMotion { length.snap(); bend.snap(); drawLine(); return }
        startTicking()
    }

    private func startTicking() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = nil
    }
    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = Swift.min(1.0 / 30, now - (lastTick ?? now - 1.0 / 60))
        lastTick = now
        // The bow fades once the mouse rests, even if no further drag event arrives.
        if let lastDrag, ProcessInfo.processInfo.systemUptime - lastDrag.time > 0.06 { bend.target = 0; dragVelocity = 0 }
        length.step(dt); bend.step(dt)
        drawLine()
        if length.isSettled && bend.isSettled && (start == nil || bend.target == 0) { stopTicking() }
    }

    private func drawLine() {
        let path = CGMutablePath()
        let half = Swift.min(length.value, vertical ? bounds.width : bounds.height) / 2
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        // A quadratic curve's middle sits halfway to its control point, so the control is twice the bow.
        let bow = Swift.max(-Self.maxBend, Swift.min(Self.maxBend, bend.value)) * 2
        if vertical {
            path.move(to: CGPoint(x: mid.x - half, y: mid.y))
            path.addQuadCurve(to: CGPoint(x: mid.x + half, y: mid.y), control: CGPoint(x: mid.x, y: mid.y + bow))
        } else {
            path.move(to: CGPoint(x: mid.x, y: mid.y - half))
            path.addQuadCurve(to: CGPoint(x: mid.x, y: mid.y + half), control: CGPoint(x: mid.x + bow, y: mid.y))
        }
        line.path = path
    }

    private func showLine(_ visible: Bool) {
        if reduceMotion {
            // Reduce Motion: the line is simply there or not, at its resting length.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            line.removeAnimation(forKey: "opacity")
            line.opacity = visible ? 1 : 0
            CATransaction.commit()
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = line.presentation()?.opacity ?? line.opacity
        animation.duration = visible ? 0.16 : 0.22
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        line.opacity = visible ? 1 : 0
        line.add(animation, forKey: "opacity")
        if visible, start == nil {
            // Grows in from a dot.
            length.value = 8
            animate(length: Self.restLength)
        }
    }
    private func updateLine() {
        effectiveAppearance.performAsCurrentDrawingAppearance { line.strokeColor = accent.withAlphaComponent(0.85).cgColor }
    }

    private struct Spring {
        var value: CGFloat
        var target: CGFloat
        var velocity: CGFloat = 0
        init(value: CGFloat) { self.value = value; target = value }
        mutating func step(_ dt: CFTimeInterval) {
            // Stiffness 520, damping ratio about 0.5: quick, with one soft overshoot.
            let stiffness: CGFloat = 520, damping: CGFloat = 23
            let force = -stiffness * (value - target) - damping * velocity
            velocity += force * CGFloat(dt)
            value += velocity * CGFloat(dt)
            if isSettled { snap() }
        }
        mutating func snap() { value = target; velocity = 0 }
        var isSettled: Bool { abs(value - target) < 0.05 && abs(velocity) < 0.5 }
    }
}
