import AppKit
import SwiftUI

struct AllTerminalsSheet: View {
    let model: FolmiModel
    let load: (@MainActor () async -> AllTerminalList)?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var list = AllTerminalList()
    @State private var query = ""
    @State private var selection: UUID?
    @State private var loading = true
    @State private var acting = false

    init(model: FolmiModel, load: (@MainActor () async -> AllTerminalList)? = nil) {
        self.model = model
        self.load = load
    }

    private var selectedRow: AllTerminalRow? {
        list.matching(query).lazy.flatMap(\.rows).first { $0.id == selection }
    }

    var body: some View {
        let groups = list.matching(query)
        let rows = groups.flatMap(\.rows)
        VStack(spacing: 0) {
            header
            Divider()
            results(groups, rows: rows)
            Divider()
            footer
        }
        .frame(width: 680, height: 480)
        .onAppear { searchFocused = true }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .onKeyPress(.downArrow) { moveSelection(1, in: rows); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1, in: rows); return .handled }
        .onExitCommand { dismiss() }
        .background {
            TerminalListDeleteShortcut {
                guard !acting, let selectedRow else { return }
                end(selectedRow)
            }
        }
        .task(id: model.allTerminalsRevision) { await poll() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全部终端").themedFont(.headline, points: 13)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索项目、程序或目录", text: $query)
                    .textFieldStyle(.plain).themedFont(.body, points: 13)
                    .focused($searchFocused)
                    .onSubmit { if let selectedRow { jump(to: selectedRow) } }
                    .accessibilityIdentifier("all-terminals-query")
            }
        }
        .padding(14)
    }

    private func results(_ groups: [AllTerminalGroup], rows: [AllTerminalRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let error = list.error { message(error) }
                    if loading {
                        WaitingIndicator().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 22)
                    } else if rows.isEmpty && list.error == nil {
                        message(query.isEmpty ? "没有打开的终端" : "没有找到终端")
                    }
                    ForEach(groups) { group in
                        Text(group.title).themedFont(.caption.weight(.semibold), points: 11)
                            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 8)
                        ForEach(group.rows) { row in terminalRow(row, group: group).id(row.id) }
                    }
                }
                .padding(8)
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func terminalRow(_ row: AllTerminalRow, group: AllTerminalGroup) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                icon(row, group: group)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.programTitle).themedFont(.body, points: 13).lineLimit(1)
                    Text("\(row.title) · \(row.displayDirectory)")
                        .themedFont(.caption, points: 11).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(status(row)).themedFont(.caption, points: 11).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { jump(to: row) }
            .onTapGesture { selection = row.id }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selection == row.id ? .isSelected : [])
            .accessibilityAction(named: Text("跳过去")) { jump(to: row) }
            .help(row.directory)
            Button { end(row) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .help("结束终端（⌘⌫）")
            .accessibilityLabel("结束终端")
            .disabled(acting)
        }
        .padding(.horizontal, 8)
        .background {
            if selection == row.id {
                RoundedRectangle(cornerRadius: 5).fill(ThemeColor(token: .accent).opacity(0.15))
            }
        }
        .contextMenu {
            if row.projectPath == nil {
                Button("放进当前项目") { perform { await model.claimListedTerminal(row) } }
                    .disabled(!model.canClaimTerminal || acting)
            }
        }
    }

    private func icon(_ row: AllTerminalRow, group: AllTerminalGroup) -> some View {
        let help = group.project?.rootPath ?? group.title
        let attention = attention(for: row)
        return Group {
            if group.isWorktree {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 26)
            } else if let project = group.project {
                ProjectRailIcon(project: project, model: model, help: help, allowsDrop: false)
            } else {
                Image(systemName: "terminal").frame(width: 28, height: 26)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let attention { AgentAttentionBadge(attention: attention).offset(x: 1, y: 1) }
        }
        .help(attention?.text ?? help)
        .accessibilityLabel(attention?.text ?? group.title)
    }

    private func attention(for row: AllTerminalRow) -> AgentAttention? {
        guard row.isRunning, let name = row.foregroundName?.lowercased(), ["claude", "codex"].contains(name) else { return nil }
        if let project = model.board.rows.first(where: { $0.path == row.projectPath }),
           let event = project.hookEvent, event.agent == name,
           let attention = AgentAttention.hook(event, unaccepted: project.unaccepted) {
            return attention
        }
        return AgentAttention(kind: .running, text: name == "codex" ? "Codex 正在运行" : "Claude 正在运行")
    }

    private func status(_ row: AllTerminalRow) -> String {
        if row.hasExited { return row.exitCode.map { "已退出（退出码 \($0)）" } ?? "已退出" }
        guard row.isRunning else { return "未运行" }
        let minutes = max(0, Int(Date().timeIntervalSince(row.createdAt) / 60))
        let duration = minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
        return "\(row.isIdle ? "空闲" : "运行中") · \(duration)"
    }

    private func message(_ text: String) -> some View {
        Text(text).themedFont(.callout, points: 12).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    private var footer: some View {
        let idle = Set(list.rows.filter(\.isIdle).map(\.id))
        return HStack {
            Button("结束 \(idle.count) 个空闲终端") { perform { await model.endIdleTerminals(idle) } }
                .disabled(acting || idle.isEmpty)
            Spacer()
            Button("结束所有后台终端…") { model.endBackgroundTerminals(orphansOnly: false) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(acting || !list.rows.contains { $0.background != nil })
        }
        .padding(12)
    }

    private func poll() async {
        while !Task.isCancelled {
            let refreshed: AllTerminalList
            if let load { refreshed = await load() }
            else { refreshed = await model.loadAllTerminals() }
            guard !Task.isCancelled else { return }
            list = refreshed
            loading = false
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func moveSelection(_ offset: Int, in rows: [AllTerminalRow]) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection } ?? 0
        selection = rows[min(max(index + offset, 0), rows.count - 1)].id
    }

    private func jump(to row: AllTerminalRow) {
        guard !acting, model.canJumpToTerminal(row) else { return }
        model.terminalJump = row
        dismiss()
    }

    private func end(_ row: AllTerminalRow) {
        perform { await model.endListedTerminal(row.id) }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard !acting else { return }
        acting = true
        Task {
            await action()
            acting = false
        }
    }
}

/// The search field's editor would otherwise consume ⌘⌫ as "delete to beginning of line".
private struct TerminalListDeleteShortcut: NSViewRepresentable {
    let onDelete: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.onDelete = onDelete }

    final class MonitorView: NSView {
        var onDelete: (() -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, event.keyCode == 51,
                      event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command else { return event }
                if !event.isARepeat { MainActor.assumeIsolated { self.onDelete?() } }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
