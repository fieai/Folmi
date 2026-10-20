import AppKit
import FolmiCore
import SwiftUI

/// Commit graph on top, the selected commit's message, files and diff below.
struct HistoryView: View {
    @Bindable var model: FolmiModel
    @FocusState private var focused: Bool
    @Environment(\.folmiTheme) private var theme
    @State private var rewording: CommitDetail?
    @State private var rewordText = ""
    @State private var branchFrom: CommitNode?
    @State private var branchName = ""
    @State private var historyQuery = ""

    private var filteredHistory: [CommitNode] { HistoryFilter.matches(model.history, query: historyQuery) }

    var body: some View {
        VSplitView {
            graphList.frame(minHeight: 140, idealHeight: 300)
            detail.frame(minHeight: 160)
        }
        .background(Color.theme(theme, \.card))
        .sheet(item: $rewording) { detail in
            RewordSheet(text: $rewordText, onCancel: { rewording = nil },
                        onSave: { model.rewordCommit(detail.id, message: rewordText); rewording = nil })
                .sheetEntrance()
        }
        .alert("从这个提交新建分支", isPresented: Binding(get: { branchFrom != nil }, set: { if !$0 { branchFrom = nil } })) {
            TextField("分支名，例如 fix/login", text: $branchName)
            Button("新建") { if let commit = branchFrom { model.createBranch(branchName, at: commit.id) }; branchFrom = nil }
            Button("取消", role: .cancel) { branchFrom = nil }
        } message: {
            Text(branchFrom.map { "从 \($0.shortID) \($0.subject.prefix(40)) 新建，不会切换过去。" } ?? "")
        }
    }

    private func startBranch(_ commit: CommitNode) { branchName = ""; branchFrom = commit }

    // MARK: Graph

    private var graphList: some View {
        let filtered = filteredHistory
        let filtering = !historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let lanes = min(HistoryGraphMetrics.maximumLanes, model.historyRows.map(\.width).max() ?? 1)
        let graphWidth = filtering ? 0 : HistoryGraphMetrics.width(lanes: lanes)
        let rowsByID = Dictionary(uniqueKeysWithValues: zip(model.history.map(\.id), model.historyRows))
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(model.history.count) 个提交").themedFont(.caption.weight(.medium), points: 10)
                if filtering {
                    Text("筛选到 \(filtered.count) 个").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                }
                if model.historyLoading { ProgressView().controlSize(.mini) }
                Spacer()
                Text("j/k 上下 · 包含本地、远程分支和标签").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 28)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选已加载的提交：编号、标题、作者、分支或标签", text: $historyQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("筛选提交历史").accessibilityIdentifier("history-filter")
                if !historyQuery.isEmpty {
                    Button { historyQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除历史筛选")
                }
                if model.historyHasMore {
                    Button("继续加载 \(FolmiModel.historyLimit) 个") { Task { await model.loadMoreHistory() } }
                        .disabled(model.historyLoading).accessibilityIdentifier("history-load-more")
                }
            }.themedFont(.system(size: 12), points: 12).padding(.horizontal, 12).padding(.vertical, 8)
                .help("筛选当前已加载提交的编号、标题、作者、邮箱及分支/标签名称；继续加载可搜索更早记录。")
            Divider()
            if filtered.isEmpty && !model.historyLoading {
                Text(filtering ? "已加载记录中没有匹配提交，可清除筛选或继续加载" : "还没有提交记录").themedFont(.caption, points: 10).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { commit in
                                HistoryRow(commit: commit, row: filtering ? nil : rowsByID[commit.id],
                                           graphWidth: graphWidth, isHead: commit.id == model.snapshot?.head,
                                           selected: commit.id == model.selectedCommitID)
                                    .id(commit.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        focused = true
                                        Task { await model.selectCommit(commit.id) }
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(commit.id == model.selectedCommitID ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityAction { Task { await model.selectCommit(commit.id) } }
                                    .contextMenu { rowMenu(commit) }
                            }
                        }
                    }
                    .onChange(of: model.selectedCommitID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            switch press.key {
            case .downArrow: model.moveCommitSelection(by: 1, in: filtered); return .handled
            case .upArrow: model.moveCommitSelection(by: -1, in: filtered); return .handled
            default: break
            }
            switch press.characters {
            case "j": model.moveCommitSelection(by: 1, in: filtered)
            case "k": model.moveCommitSelection(by: -1, in: filtered)
            case "g": model.moveCommitSelection(by: -filtered.count, in: filtered)
            case "G": model.moveCommitSelection(by: filtered.count, in: filtered)
            default: return .ignored
            }
            return .handled
        }
        .onAppear { focused = true }
        .onChange(of: model.repositoryURL) { _, _ in historyQuery = "" }
    }

    @ViewBuilder private func rowMenu(_ commit: CommitNode) -> some View {
        if model.compareBaseID == commit.id {
            Button("结束对比") { model.setCompareBase(nil) }
        } else {
            Button(model.compareBaseID == nil ? "设为对比起点" : "改为对比起点") { model.setCompareBase(commit.id) }
        }
        Button("从这里新建分支…") { startBranch(commit) }
        Divider()
        Button("复制提交编号") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.id, forType: .string) }
        Button("复制提交标题") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.subject, forType: .string) }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let detail = model.commitDetail, let commit = model.history.first(where: { $0.id == detail.id }) {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    if let base = model.compareBaseID, base != detail.id {
                        CompareBanner(base: model.history.first { $0.id == base }, target: commit, files: detail.files.count,
                                      onEnd: { model.setCompareBase(nil) })
                    } else {
                        CommitInfo(commit: commit, detail: detail)
                        CommitActionBar(model: model, commit: commit,
                                        onReword: { rewordText = detail.message; rewording = detail },
                                        onBranch: { startBranch(commit) })
                    }
                    Divider()
                    List(selection: Binding(get: { model.selectedCommitFile },
                                            set: { path in if let file = detail.files.first(where: { $0.path == path }) { model.selectCommitFile(file) } })) {
                        ForEach(detail.files) { file in
                            HStack(spacing: 6) {
                                Text(file.status).themedFont(.caption2.monospaced().weight(.semibold), points: 10)
                                    .foregroundStyle(Self.statusColor(file.status)).frame(width: 14)
                                Text(file.path).themedFont(.system(size: 12, design: .monospaced), points: 12)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .tag(file.path)
                        }
                    }
                    .listStyle(.sidebar).scrollContentBackground(.hidden)
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

                GeometryReader { geometry in
                    ScrollView {
                        if let diff = model.commitFileDiff, diff.file.path == model.selectedCommitFile {
                            SideBySideFile(
                                diff: diff, selected: [], busy: false, columnWidth: max(180, (geometry.size.width - 1) / 2),
                                onToggleLine: { _, _ in }, onApplyHunk: { _, _ in }, onApplySelection: { _, _ in },
                                onStageFile: { _ in }, onUnstageFile: { _ in }, onEditFile: { _ in },
                                comments: [], onComment: { _, _, _ in }, onDeleteComment: { _ in },
                                showsHeader: false, allowsLineSelection: false, anchorPrefix: detail.id + "#",
                                readOnly: true, sideTitles: sideTitles(detail: detail, commit: commit),
                                unified: model.unifiedDiff,
                                previewHeight: max(ChangePreview.defaultHeight, geometry.size.height - 60))
                                .id(detail.id + diff.file.path)
                        } else if detail.files.isEmpty {
                            Text("这个提交和父提交没有文件差异").themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(20)
                        } else {
                            ProgressView().controlSize(.small).padding(20)
                        }
                    }
                }
                .frame(minWidth: 300)
            }
        } else {
            Text(model.history.isEmpty ? "" : "选择一个提交查看详情").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sideTitles(detail: CommitDetail, commit: CommitNode) -> (String, String) {
        if let base = model.compareBaseID, base != detail.id { return ("起点 \(base.prefix(7))（旧）", "终点 \(commit.shortID)（新）") }
        return (commit.isMerge ? "第一个父提交（旧）" : "父提交（旧）", "此提交（新）")
    }

    static func statusColor(_ status: String) -> Color {
        switch status { case "A": return .green; case "D": return .red; case "M": return .orange; default: return .secondary }
    }
}

enum HistoryGraphMetrics {
    static let rowHeight: CGFloat = 26
    static let laneWidth: CGFloat = 14
    static let padding: CGFloat = 8
    static let maximumLanes = 16
    static func width(lanes: Int) -> CGFloat { padding * 2 + CGFloat(max(1, lanes)) * laneWidth }
    static func x(_ lane: Int) -> CGFloat { padding + (CGFloat(lane) + 0.5) * laneWidth }
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]
    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

private struct HistoryRow: View {
    let commit: CommitNode
    let row: CommitGraphRow?
    let graphWidth: CGFloat
    let isHead: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            CommitGraphCell(row: row, isHead: isHead, isMerge: commit.isMerge)
                .frame(width: graphWidth, height: HistoryGraphMetrics.rowHeight)
                .clipped()
            ForEach(commit.refs, id: \.self) { ref in RefBadge(ref: ref) }
            Text(commit.subject).themedFont(.system(size: 12), points: 12).lineLimit(1).truncationMode(.tail)
                .fontWeight(isHead ? .semibold : .regular)
                .foregroundStyle(commit.isMerge ? .secondary : .primary)
            Spacer(minLength: 8)
            Text(commit.author).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 120, alignment: .trailing)
            Text(commit.date, format: .relative(presentation: .numeric)).themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 82, alignment: .trailing)
            Text(commit.shortID).themedFont(.caption.monospaced(), points: 10).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
        }
        .padding(.trailing, 10)
        .frame(height: HistoryGraphMetrics.rowHeight)
        .background(ThemeColor(token: .selectedFill, opacity: selected ? 1 : 0))
        .help(commit.subject)
    }
}

/// Draws one row of the graph; rows stack without gaps so the lines join.
private struct CommitGraphCell: View {
    let row: CommitGraphRow?
    let isHead: Bool
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let mid = size.height / 2, bottom = size.height
            for line in row.lines {
                var path = Path()
                let from = HistoryGraphMetrics.x(line.from), to = HistoryGraphMetrics.x(line.to)
                switch line.half {
                case .full:
                    path.move(to: CGPoint(x: from, y: 0)); path.addLine(to: CGPoint(x: from, y: bottom))
                case .upper:
                    path.move(to: CGPoint(x: from, y: 0))
                    if from == to { path.addLine(to: CGPoint(x: to, y: mid)) }
                    else { path.addCurve(to: CGPoint(x: to, y: mid), control1: CGPoint(x: from, y: mid * 0.7), control2: CGPoint(x: to, y: mid * 0.3)) }
                case .lower:
                    path.move(to: CGPoint(x: from, y: mid))
                    if from == to { path.addLine(to: CGPoint(x: to, y: bottom)) }
                    else { path.addCurve(to: CGPoint(x: to, y: bottom), control1: CGPoint(x: from, y: mid + mid * 0.7), control2: CGPoint(x: to, y: mid + mid * 0.3)) }
                }
                context.stroke(path, with: .color(HistoryGraphMetrics.color(line.color)), lineWidth: 2)
            }
            let center = CGPoint(x: HistoryGraphMetrics.x(row.lane), y: mid)
            let radius: CGFloat = isHead ? 5 : 4
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let color = HistoryGraphMetrics.color(row.color)
            if isMerge {
                context.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(dot, with: .color(color), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color))
            }
            if isHead {
                let ring = Path(ellipseIn: CGRect(x: center.x - radius - 2.5, y: center.y - radius - 2.5, width: (radius + 2.5) * 2, height: (radius + 2.5) * 2))
                context.stroke(ring, with: .color(color.opacity(0.6)), lineWidth: 1.5)
            }
        }
    }
}

private struct RefBadge: View {
    let ref: String
    var body: some View {
        let isHead = ref.hasPrefix("HEAD")
        let isTag = ref.hasPrefix("tag: ")
        let isRemote = !isHead && !isTag && ref.contains("/")
        let label = isTag ? String(ref.dropFirst(5)) : ref.replacingOccurrences(of: "HEAD -> ", with: "")
        let color: Color = isHead ? .accentColor : (isTag ? .yellow : (isRemote ? .purple : .green))
        HStack(spacing: 3) {
            Image(systemName: isTag ? "tag" : (isRemote ? "cloud" : "arrow.triangle.branch")).font(.system(size: 8, weight: .semibold))
            Text(label).themedFont(.caption2.weight(isHead ? .semibold : .medium), points: 10).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(color.opacity(isHead ? 0.25 : 0.14), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(isHead ? 0.6 : 0), lineWidth: 1))
        .help(ref)
        .fixedSize()
    }
}

private struct CommitInfo: View {
    let commit: CommitNode
    let detail: CommitDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(detail.message).themedFont(.system(size: 12), points: 12).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("作者").foregroundStyle(.secondary)
                    Text("\(commit.author) <\(commit.email)>").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text("时间").foregroundStyle(.secondary)
                    Text(commit.date, format: .dateTime.year().month().day().hour().minute())
                }
                if detail.committer != commit.author {
                    GridRow { Text("提交者").foregroundStyle(.secondary); Text(detail.committer) }
                }
                GridRow {
                    Text("提交").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(String(commit.id.prefix(12))).themedFont(.caption.monospaced(), points: 10).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.id, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.pressable).foregroundStyle(.secondary).help("复制完整提交编号").accessibilityLabel("复制完整提交编号")
                    }
                }
                if !commit.parents.isEmpty {
                    GridRow {
                        Text(commit.isMerge ? "父提交 \(commit.parents.count)" : "父提交").foregroundStyle(.secondary)
                        Text(commit.parents.map { String($0.prefix(8)) }.joined(separator: " · ")).themedFont(.caption.monospaced(), points: 10)
                    }
                }
                GridRow { Text("文件").foregroundStyle(.secondary); Text("\(detail.files.count) 个") }
            }
            .themedFont(.caption, points: 10)
        }
        .padding(10)
    }
}

/// What can be done with the selected commit. Each button says why when it is off.
private struct CommitActionBar: View {
    let model: FolmiModel
    let commit: CommitNode
    let onReword: () -> Void
    let onBranch: () -> Void
    @State private var stashFirst: GitRepository.ApplyKind?

    var body: some View {
        let ability = model.selectedCommitAbilities
        let clean = model.snapshot?.files.isEmpty == true
        let changed = model.snapshot?.files.count ?? 0
        let busy = model.busy
        HStack(spacing: 6) {
            action("修改说明", symbol: "pencil", enabled: ability.map { $0.isHead && !$0.pushed } ?? false && !busy,
                   help: ability.map { !$0.isHead ? "只能修改当前分支最新一个提交的说明" : ($0.pushed ? "已推送到远端，改说明会和远端分叉" : "修改这个提交的说明（⌥⌘Z 可撤销）") } ?? "",
                   perform: onReword)
            if ability?.onCurrentBranch ?? true {
                action("撤回", symbol: "arrow.uturn.backward", enabled: !busy,
                       help: clean ? "把这个提交的反向改动放进暂存区，看过后再提交（⌥⌘Z 可撤销）" : "工作区有改动：会先临时收起它们，再撤回",
                       perform: { if clean { model.applyCommit(commit.id, kind: .revert) } else { stashFirst = .revert } })
            } else {
                action("挑到当前分支", symbol: "arrow.down.to.line", enabled: !busy,
                       help: clean ? "把这个提交的改动放进暂存区，看过后再提交（⌥⌘Z 可撤销）" : "工作区有改动：会先临时收起它们，再挑选",
                       perform: { if clean { model.applyCommit(commit.id, kind: .cherryPick) } else { stashFirst = .cherryPick } })
            }
            action("新建分支", symbol: "arrow.triangle.branch", enabled: !busy, help: "从这个提交新建分支，不会切换过去", perform: onBranch)
            action("对比", symbol: "arrow.left.arrow.right", enabled: true,
                   help: "设为对比起点，再选另一个提交就能看两者之间的差异", perform: { model.setCompareBase(commit.id) })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
        .confirmationDialog(stashFirst == .cherryPick ? "先收起改动再挑选？" : "先收起改动再撤回？",
                            isPresented: Binding(get: { stashFirst != nil }, set: { if !$0 { stashFirst = nil } })) {
            Button(stashFirst == .cherryPick ? "先收起改动再挑选" : "先收起改动再撤回") {
                if let kind = stashFirst { model.stashThenApplyCommit(commit.id, kind: kind) }
                stashFirst = nil
            }
            Button("取消", role: .cancel) { stashFirst = nil }
        } message: {
            Text("工作区有 \(changed) 个文件的改动。会先把它们临时收起（之后在改动列表下方的「收起的改动」里恢复），再把\(stashFirst == .cherryPick ? "挑选" : "撤回")的结果放进暂存区。⌥⌘Z 可以一步步撤销。")
        }
    }

    private func action(_ title: String, symbol: String, enabled: Bool, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).themedFont(.caption, points: 10).labelStyle(.titleAndIcon)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .themedBackground(ThemeColor(token: .hover), .control)
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
    }
}

/// Shown instead of one commit's info while two commits are compared.
private struct CompareBanner: View {
    let base: CommitNode?
    let target: CommitNode
    let files: Int
    let onEnd: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(ThemeColor(token: .accent))
                Text("对比两个提交").themedFont(.system(size: 12.5, weight: .semibold), points: 12.5)
                Spacer()
                QuietButton(title: "结束对比", action: onEnd)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("起点").foregroundStyle(.secondary)
                    Text("\(base?.shortID ?? "") \(base?.subject ?? "")").lineLimit(1).truncationMode(.tail)
                }
                GridRow {
                    Text("终点").foregroundStyle(.secondary)
                    Text("\(target.shortID) \(target.subject)").lineLimit(1).truncationMode(.tail)
                }
                GridRow { Text("文件").foregroundStyle(.secondary); Text("\(files) 个不同") }
            }
            .themedFont(.caption, points: 10)
            Text("在上面选别的提交可换终点；右键提交可换起点。").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

private struct RewordSheet: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修改提交说明").themedFont(.headline, points: 13)
            Text("只改说明，不改内容；暂存区里的改动不会被带进这个提交。⌥⌘Z 可以撤销。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            TextEditor(text: $text).themedFont(.system(size: 12, design: .monospaced), points: 12)
                .frame(minWidth: 460, minHeight: 160)
                .themedEditorFrame()
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存说明", action: onSave).buttonStyle(.folmiProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}
