import AppKit
import SwiftUI

/// Narrowest a column gets before the card stops offering another one.
enum ColumnMetrics {
    static let editorMinimum: Double = 320
    static let terminalMinimum: Double = 240
    static let handle: CGFloat = 7
}

/// A split card's columns side by side, with a drag handle between each pair. The drag only moves this view's own
/// widths; the model gets the final share once, on release.
struct PaneColumnsStack<Column: View>: View {
    let pane: FolmiPane
    let model: FolmiModel
    let columns: [PaneColumn]
    let fractions: [Double]
    let minimum: Double
    @ViewBuilder let column: (Int, PaneColumn) -> Column
    @State private var live: [Double]?

    var body: some View {
        let _ = PerfLog.body("PaneColumnsStack")
        GeometryReader { geometry in
            let total = max(1, Double(geometry.size.width) - Double(ColumnMetrics.handle) * Double(columns.count - 1))
            let shares = live.flatMap { $0.count == columns.count ? $0 : nil } ?? fractions
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, item in
                    column(index, item).frame(width: CGFloat(total * share(shares, index)))
                    if index < columns.count - 1 { handle(index, total: total, shares: shares) }
                }
            }
            .onAppear { reportRoom(Double(geometry.size.width)) }
            .onChange(of: geometry.size.width) { _, width in reportRoom(Double(width)) }
            .onChange(of: columns.count) { _, _ in reportRoom(Double(geometry.size.width)) }
        }
    }

    private func share(_ shares: [Double], _ index: Int) -> Double { shares.indices.contains(index) ? shares[index] : 1 / Double(columns.count) }

    /// Room for one more column at the narrowest width; the model greys the split button without it.
    private func reportRoom(_ width: Double) {
        let room = width / Double(columns.count + 1) >= minimum
        if model.splitRoom[pane] != room { model.splitRoom[pane] = room }
    }

    private func handle(_ index: Int, total: Double, shares: [Double]) -> some View {
        let pair = share(shares, index) + share(shares, index + 1)
        let low = min(minimum, total * pair / 2)
        return ZStack {
            Rectangle().fill(ThemeColor(token: .border)).frame(width: 1)
            PaneResizeHandle(axis: .horizontal, thickness: ColumnMetrics.handle, value: { total * share(shares, index) },
                             limit: { _ in low...max(low, total * pair - low) },
                             onBegin: { live = shares; PaneLiveResize.begin() },
                             onChange: { width in
                                 var next = live ?? shares
                                 guard next.indices.contains(index + 1) else { return }
                                 next[index] = width / total
                                 next[index + 1] = pair - next[index]
                                 live = next
                             },
                             onEnd: {
                                 if let live, live.indices.contains(index) {
                                     model.resizeColumns(pane, at: index, to: live[index], minimum: minimum / total)
                                 }
                                 live = nil
                                 PaneLiveResize.end()
                             },
                             onReset: { model.equalizeColumns(pane) },
                             help: "拖动调整宽度，双击等分")
        }
        .frame(width: ColumnMetrics.handle)
    }
}

/// The split button in a card's header: 向左拆分 / 向右拆分, greyed with the reason when the card cannot take a column.
struct SplitMenu: View {
    let reason: String?
    let split: (Bool) -> Void
    var body: some View {
        let _ = PerfLog.body("SplitMenu")
        Menu {
            Button("向左拆分（⌥⌘\\）") { split(false) }
            Button("向右拆分（⌘\\）") { split(true) }
        } label: {
            Image(systemName: "rectangle.split.2x1").font(.system(size: Metrics.iconSize, weight: .medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: Metrics.iconButton, height: Metrics.iconButton)
        .foregroundStyle(.secondary)
        .disabled(reason != nil)
        .help(reason.map { "不能拆分：\($0)" } ?? "拆分：在左边或右边再开一栏，同时看两处")
        .accessibilityLabel("拆分")
    }
}

/// The editor card's split button; it follows the editor's columns.
struct EditorSplitMenu: View {
    let model: FolmiModel
    @ObservedObject var workspace: EditorWorkspace
    var body: some View {
        let _ = PerfLog.body("EditorSplitMenu")
        SplitMenu(reason: model.splitBlockedReason(.editor)) { model.splitEditor(toRight: $0) }
    }
}

/// A thin accent line over the column the keyboard works on, shown only while the card is split.
private struct ActiveColumnMark: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if active { Rectangle().fill(ThemeColor(token: .accent)).frame(height: 2).allowsHitTesting(false) }
        }
    }
}

// MARK: - Editor

/// The 编辑 / 差异 pages. With a 差异 column the diff sits beside the files; otherwise 差异 takes the whole card.
struct EditorOrDiffPage: View {
    let model: FolmiModel
    @ObservedObject var workspace: EditorWorkspace
    let tracker: PaneFocusTracker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let _ = PerfLog.body("EditorOrDiffPage")
        let columnsShown = model.content == .editor || workspace.columns.hasDiff
        ZStack {
            if columnsShown {
                EditorColumnsView(model: model, workspace: workspace, tracker: tracker).transition(.opacity)
            } else {
                DiffPane(model: model).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.state, value: columnsShown)
    }
}

struct EditorColumnsView: View {
    let model: FolmiModel
    @ObservedObject var workspace: EditorWorkspace
    let tracker: PaneFocusTracker
    var body: some View {
        let _ = PerfLog.body("EditorColumnsView")
        let columns = workspace.columns
        let diffActive = model.content == .diff
        PaneColumnsStack(pane: .editor, model: model, columns: columns.columns, fractions: columns.fractions,
                         minimum: ColumnMetrics.editorMinimum) { _, column in
            EditorColumnView(model: model, workspace: workspace, column: column, split: columns.isSplit,
                             active: columns.isSplit && (diffActive ? column.isDiff : (!column.isDiff && column.id == columns.activeID)),
                             tracker: tracker)
        }
    }
}

private struct EditorColumnView: View {
    let model: FolmiModel
    @ObservedObject var workspace: EditorWorkspace
    let column: PaneColumn
    let split: Bool
    let active: Bool
    let tracker: PaneFocusTracker

    var body: some View {
        let _ = PerfLog.body("EditorColumnView")
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if column.isDiff {
                    Image(systemName: "plus.forwardslash.minus").font(.system(size: Metrics.iconSize, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                    PaneTitle(title: "差异", detail: model.fileDiffs.isEmpty ? nil : "\(model.fileDiffs.count) 个文件")
                    Spacer(minLength: 4)
                } else {
                    EditorTabStrip(workspace: workspace, onSave: model.fileDidSave, column: column.id,
                                   onSplit: { tab, right in model.splitEditor(toRight: right, tab: tab, from: column.id) },
                                   onMove: { tab, right in model.moveEditorTab(tab, from: column.id, toRight: right) })
                }
                if split {
                    PaneIconButton(symbol: "xmark",
                                   help: column.isDiff ? "关闭差异栏" : "关闭这一栏：标签并入旁边一栏，文件不会关闭") {
                        model.closeEditorColumn(column.id)
                    }
                    .padding(.trailing, 4)
                }
            }
            .frame(height: Metrics.paneHeader).folmiSurface(.navigation)
            Divider()
            if column.isDiff {
                DiffPane(model: model)
            } else {
                FileEditorPane(workspace: workspace, onSave: model.fileDidSave, column: column.id)
            }
        }
        .modifier(ActiveColumnMark(active: active))
        .background(PaneAnchor(pane: .editor, column: column.id, tracker: tracker))
    }
}

// MARK: - Terminal

/// A split terminal card: each column has its own row of tabs over its shell. The AI tab stays in the left column.
struct TerminalColumnsView: View {
    let model: FolmiModel
    let columns: PaneColumns
    let tracker: PaneFocusTracker
    let rename: (TerminalSession) -> Void
    var body: some View {
        let _ = PerfLog.body("TerminalColumnsView")
        PaneColumnsStack(pane: .terminal, model: model, columns: columns.columns, fractions: columns.fractions,
                         minimum: ColumnMetrics.terminalMinimum) { index, column in
            TerminalColumnView(model: model, columns: columns, column: column, index: index,
                               active: column.id == columns.activeID, tracker: tracker, rename: rename)
        }
    }
}

private struct TerminalColumnView: View {
    let model: FolmiModel
    let columns: PaneColumns
    let column: PaneColumn
    let index: Int
    let active: Bool
    let tracker: PaneFocusTracker
    let rename: (TerminalSession) -> Void

    var body: some View {
        let _ = PerfLog.body("TerminalColumnView")
        let sessions = column.tabs.compactMap { id in model.terminalTabs.first { $0.id.uuidString == id } }
        let shown = sessions.first { $0.id.uuidString == column.selected } ?? sessions.first
        let showsAgent = index == 0 && model.aiTabSelected
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let titles = TerminalSession.distinctTitles(model.terminalTabs.map(\.displayTitle))
                        PaneTabGroup {
                            ForEach(sessions, id: \.id) { session in
                                let title = model.terminalTabs.firstIndex { $0 === session }.map { titles[$0] } ?? session.displayTitle
                                TerminalTabButton(session: session, title: title, selected: session === shown && !showsAgent,
                                                  select: { model.selectTerminalTab(session.id) },
                                                  rename: { rename(session) },
                                                  close: { model.closeTerminalTab(session.id) },
                                                  canSplit: columns.canSplit,
                                                  canMoveLeft: columns.neighbour(of: index, toRight: false) != nil,
                                                  canMoveRight: columns.neighbour(of: index, toRight: true) != nil,
                                                  split: { model.splitTerminal(toRight: $0, tab: session.id, from: column.id) },
                                                  move: { model.moveTerminalTab(session.id, from: column.id, toRight: $0) })
                            }
                            if index == 0 { PaneTab(title: "AI", dot: !model.aiTabSelected && model.agentTabNeedsYou, selected: model.aiTabSelected) { model.openAgentTab() } }
                        }
                    }
                    .padding(.leading, 6)
                }
                PaneIconButton(symbol: "xmark", help: "关闭这一栏：终端并入旁边一栏，不会结束") { model.closeTerminalColumn(column.id) }
                    .padding(.trailing, 4)
            }
            .frame(height: Metrics.paneHeader).folmiSurface(.navigation)
            Divider()
            ZStack {
                if let shown {
                    TerminalPane(session: shown).id(shown.id).opacity(showsAgent ? 0 : 1).allowsHitTesting(!showsAgent)
                }
                if showsAgent { AgentPane(model: model).background(Color.theme(model.theme, \.card)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(ActiveColumnMark(active: active))
        .background(PaneAnchor(pane: .terminal, column: column.id, tracker: tracker))
    }
}
