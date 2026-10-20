import FolmiCore
import SwiftUI

/// 回放 Claude 的改动: every turn of the open project, its edits in order, and for each file what it looked like
/// before the turn against right after it. ←/→ step through, ▶ plays one step every two seconds.
struct ReplaySheet: View {
    let model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var batchID: String?
    @State private var stepIndex = 0
    @State private var diff: FileDiff?
    @State private var note: String?
    @State private var loading = false
    /// Batch and file of the diff on screen; several edits to one file in a row do not reload it.
    @State private var loadedKey: String?
    @State private var playing = false
    @FocusState private var focused: Bool

    private var batches: [AIBatch] { model.aiBatches.filter { !$0.steps.isEmpty }.reversed() }
    private var batch: AIBatch? { batches.first { $0.id == batchID } ?? batches.first }
    private var steps: [AIStep] { batch?.steps ?? [] }
    private var step: AIStep? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("回放 AI 的改动").themedFont(.headline, points: 12)
                Spacer()
                if !steps.isEmpty {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(stepIndex == 0).help("上一步（←）").accessibilityLabel("上一步")
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                        .help(playing ? "暂停" : "每两秒走一步（空格）").accessibilityLabel(playing ? "暂停回放" : "自动回放")
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(stepIndex >= steps.count - 1).help("下一步（→）").accessibilityLabel("下一步")
                    Text("\(stepIndex + 1) / \(steps.count)").themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.secondary)
                }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(12)
            Divider()
            if batches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text("还没有 AI 的改动记录").themedFont(.callout, points: 12)
                    Text("通过「接入 agent」配置并信任钩子后，每一轮改了哪些文件、按什么顺序改的都会记在这里。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    batchList.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    timeline.frame(minWidth: 200, idealWidth: 250, maxWidth: 340)
                    diffPane.frame(minWidth: 360)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true; load() }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.space) { playing.toggle(); return .handled }
        .task(id: playing) {
            while playing, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard playing else { break }
                if stepIndex >= steps.count - 1 { playing = false } else { move(1) }
            }
        }
    }

    private var batchList: some View {
        List(selection: Binding(get: { batch?.id }, set: { batchID = $0; stepIndex = 0; playing = false; load() })) {
            ForEach(batches) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.prompt ?? "（没有记下提示词）").themedFont(.callout, points: 12).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.started, format: .dateTime.month().day().hour().minute())
                        Text("\(item.paths.count) 个文件")
                        if let stopped = item.stopped { Text(Self.duration(stopped.timeIntervalSince(item.started))) } else { Text("进行中") }
                        if item.undone { Text("已撤回").foregroundStyle(.themed(.removed)) }
                    }
                    .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(item.id)
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { stepIndex }, set: { if let index = $0 { stepIndex = index; load() } })) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Text(Self.offset(item.time.timeIntervalSince(batch?.started ?? item.time)))
                            .themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        Image(systemName: Self.icon(item.tool)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                        Text((item.path as NSString).lastPathComponent).themedFont(.callout, points: 12).lineLimit(1)
                    }
                    .tag(index).id(index)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .onChange(of: stepIndex) { _, index in proxy.scrollTo(index) }
        }
    }

    private var diffPane: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let step {
                        Text(step.path).themedFont(.system(size: 12, weight: .semibold, design: .monospaced), points: 12)
                            .padding(.horizontal, 12).padding(.top, 10)
                    }
                    if let note { Text(note).themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(.horizontal, 12) }
                    if let diff {
                        if let notice = diff.notice { Text(notice).themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(.horizontal, 12) }
                        SideBySideFile(
                            diff: diff, selected: [], busy: false, columnWidth: max(160, (geometry.size.width - 1) / 2),
                            onToggleLine: { _, _ in }, onApplyHunk: { _, _ in }, onApplySelection: { _, _ in },
                            onStageFile: { _ in }, onUnstageFile: { _ in }, onEditFile: { _ in },
                            comments: [], onComment: { _, _, _ in }, onDeleteComment: { _ in },
                            showsHeader: false, allowsLineSelection: false, anchorPrefix: "replay#",
                            readOnly: true, sideTitles: ("这一轮之前", "这一轮之后"), unified: model.unifiedDiff,
                            previewHeight: max(ChangePreview.defaultHeight, geometry.size.height - 110))
                            .id((batch?.id ?? "") + (step?.path ?? ""))
                    } else if loading {
                        ProgressView().controlSize(.small).padding(20)
                    }
                }
            }
        }
    }

    private func move(_ delta: Int) {
        let next = min(max(0, stepIndex + delta), max(0, steps.count - 1))
        guard next != stepIndex else { return }
        stepIndex = next
        load()
    }

    private func load() {
        guard let batch, let step else { diff = nil; note = nil; loadedKey = nil; return }
        let id = batch.id, path = step.path, key = id + "\0" + path
        guard loadedKey != key else { return }
        loadedKey = key
        diff = nil; note = nil
        loading = true
        Task {
            let result = await model.replayDiff(batch: id, path: path)
            guard self.step?.path == path, self.batch?.id == id else { return }
            diff = result.diff; note = result.note; loading = false
        }
    }

    static func offset(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "+%d:%02d", total / 60, total % 60)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total < 60 ? "\(total) 秒" : "\(total / 60) 分 \(total % 60) 秒"
    }
    static func icon(_ tool: String?) -> String {
        switch tool {
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "NotebookEdit": return "book"
        default: return "pencil"
        }
    }
}
