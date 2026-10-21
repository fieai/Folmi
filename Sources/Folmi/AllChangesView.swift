import FolmiCore
import SwiftUI

/// Pure navigation over the all-changes page, so the pager keys can be tested without a window.
struct AllChangesNavigator: Equatable {
    struct Stop: Equatable { let fileKey: String; let hunkID: String? }
    static let foldThreshold = 2_000

    static func key(_ diff: FileDiff) -> String { diff.area.rawValue + ":" + diff.file.path }
    static func changedLines(_ diff: FileDiff) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.hunks.lazy.flatMap(\.lines) {
            if line.kind == .addition { added += 1 } else if line.kind == .deletion { removed += 1 }
        }
        return (added, removed)
    }
    /// Files start folded when they are too long to review by scrolling.
    static func startsFolded(_ diff: FileDiff) -> Bool {
        let counts = changedLines(diff)
        return counts.added + counts.removed > foldThreshold
    }

    /// One stop per hunk of an open file, one per folded or hunk-less file.
    static func stops(_ diffs: [FileDiff], collapsed: Set<String>) -> [Stop] {
        diffs.flatMap { diff -> [Stop] in
            let key = key(diff)
            if collapsed.contains(key) || diff.hunks.isEmpty { return [Stop(fileKey: key, hunkID: nil)] }
            return diff.hunks.map { Stop(fileKey: key, hunkID: $0.id) }
        }
    }

    static func nextFile(_ stops: [Stop], from index: Int, forward: Bool) -> Int {
        guard stops.indices.contains(index) else { return stops.isEmpty ? 0 : (forward ? 0 : stops.count - 1) }
        let file = stops[index].fileKey
        if forward {
            return stops[(index + 1)...].firstIndex { $0.fileKey != file } ?? index
        }
        // Back to the first stop of the previous file.
        guard let previous = stops[..<index].lastIndex(where: { $0.fileKey != file }) else {
            return stops.firstIndex { $0.fileKey == file } ?? index
        }
        let previousFile = stops[previous].fileKey
        return stops.firstIndex { $0.fileKey == previousFile } ?? previous
    }
}

/// What ⏎ and ⌫ do to the change under the cursor, named for where it is: a staged change is confirmed or sent
/// back to the work tree, never "discarded"; a change that cannot be split says it acts on the whole file.
struct ReviewActionNames: Equatable {
    let accept: String
    /// nil: ⌫ does nothing here (a folded tracked file is rejected hunk by hunk).
    let reject: String?

    static func make(_ diff: FileDiff, hunk: DiffHunk?, selected: Int = 0) -> ReviewActionNames {
        let wholeFile = hunk == nil || !diff.isPartialSupported
        if diff.area == .staged {
            if wholeFile { return .init(accept: "确认整个文件", reject: "整个文件退回工作区") }
            return .init(accept: selected > 0 ? "确认选中的 \(selected) 行" : "确认这处", reject: "退回工作区")
        }
        if diff.file.isUntracked { return .init(accept: "收下整个文件", reject: "删除新文件") }
        if wholeFile { return .init(accept: "收下整个文件", reject: hunk == nil ? nil : "丢弃这处") }
        return .init(accept: selected > 0 ? "收下选中的 \(selected) 行" : "收下这处并暂存", reject: "丢弃这处")
    }
}

/// Whether the change under the cursor has been scrolled out of the page. ⏎ / ⌫ act on it, so while it is out
/// of view they first bring it back instead of acting on something the user cannot see.
enum ReviewViewport {
    enum Place: Equatable { case visible, above, below }
    static let space = "allChangesScroll"
    /// `frame` in the scroll view's own coordinates; `visible` is the part not under the review bar. A sliver of
    /// under 12 pt still counts as gone.
    static func place(of frame: CGRect, visible: ClosedRange<CGFloat>) -> Place {
        guard visible.upperBound > visible.lowerBound else { return .visible }
        if frame.maxY < visible.lowerBound + 12 { return .above }
        if frame.minY > visible.upperBound - 12 { return .below }
        return .visible
    }
}

struct AllChangesView: View {
    @Bindable var model: FolmiModel
    @State private var collapsed: Set<String> = []
    @State private var foldDecided: Set<String> = []
    @State private var cursor = 0
    /// The hunk whose comment box is open.
    @State private var commentTarget: AllChangesNavigator.Stop?
    @FocusState private var focused: Bool
    /// After ⏎ / ⌫ the page reloads; the cursor then moves to the next unseen change instead of staying on an index.
    @State private var advanceAfterReload = false
    /// Where the current change sits relative to the visible page, and the visible band itself.
    @State private var currentPlace = ReviewViewport.Place.visible
    @State private var visibleBand: ClosedRange<CGFloat> = 0...0
    /// Bumped to scroll back to the current change from outside the ScrollViewReader.
    @State private var revealTick = 0
    @State private var writingReason = false
    @State private var reasonText = ""
    @State private var completionFeedback = TerrazzoCompletionFeedback()
    @State private var completionTick = 0
    @FocusState private var reasonFocused: Bool
    /// Files whose 只看这一轮 comparison is open (turn filter on).
    @State private var turnOnly: Set<String> = []
    @Environment(\.folmiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The turn 全部改动 is narrowed to, if any (see `FolmiModel.turnFilter`).
    private var turn: AIBatch? { model.turnFilter.flatMap { id in model.aiBatches.first { $0.id == id } } }
    private var diffs: [FileDiff] { model.visibleAllChanges }
    /// Progress over what is on the page: the whole change set, or the turn's files.
    private var tally: ReviewTally {
        turn == nil ? model.reviewTally : ReviewTally.make(diffs, ledger: model.reviewLedger, keys: ReviewKeyCache.keys)
    }
    private var stops: [AllChangesNavigator.Stop] { AllChangesNavigator.stops(diffs, collapsed: collapsed) }
    private var current: AllChangesNavigator.Stop? { stops.indices.contains(cursor) ? stops[cursor] : nil }
    private var completionSnapshot: TerrazzoCompletionFeedback.Snapshot {
        let tally = model.reviewTally
        return .init(project: model.repositoryURL?.path, enabled: theme == .terrazzo,
                     acceptance: model.lastAccept?.id, reviewedKeys: model.reviewLedger.keys,
                     total: tally.hunks, remaining: tally.remaining, loading: model.allChangesLoading,
                     busy: model.busy, completeList: model.allChangesNotice == nil)
    }

    var body: some View {
        let _ = PerfLog.body("AllChangesView")
        // A hunk's explanation sits beside the page instead of over it: the code it explains stays readable, and
        // ⏎ / ⌫ keep working while it is written.
        page.assistBeside(model)
    }

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    summary
                    ForEach(diffs, id: \.allChangesKey) { diff in
                        let key = diff.allChangesKey
                        Section {
                            if let turn, turnOnly.contains(key), !collapsed.contains(key) {
                                TurnOnlyDiff(model: model, batch: turn.id, path: diff.file.path)
                            }
                            if !collapsed.contains(key) {
                                SideBySideFile(
                                    diff: diff, selected: model.allChangesSelection[key] ?? [], busy: model.busy, columnWidth: 400,
                                    onToggleLine: { model.toggleAllChangesLine($0, in: $1) }, onApplyHunk: model.applyHunk,
                                    onApplySelection: { model.applyAllChangesSelection($0, in: $1) },
                                    onStageFile: model.stageFile, onUnstageFile: model.unstageFile, onEditFile: model.editPath,
                                    comments: model.currentReviewComments.filter { $0.path == diff.file.path && $0.area == diff.area },
                                    onComment: { model.addAllChangesComment($0, hunk: $1, in: $2) },
                                    onDeleteComment: model.deleteReviewComment,
                                    showsHeader: false,
                                    currentHunkID: current?.fileKey == key ? current?.hunkID : nil,
                                    seenHunkIDs: seenHunks(diff),
                                    onExplain: model.explainHunk,
                                    quietHunkActions: true,
                                    anchorPrefix: key + "#",
                                    commenting: commentBinding(key),
                                    unified: model.unifiedDiff,
                                    onCurrentFrame: { frame in
                                        let place = ReviewViewport.place(of: frame, visible: visibleBand)
                                        if place != currentPlace { currentPlace = place }
                                    })
                            }
                        } header: {
                            header(diff, key: key).id("file:" + key)
                        }
                    }
                }
            }
            .coordinateSpace(.named(ReviewViewport.space))
            .onGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
                geometry.safeAreaInsets.top...max(geometry.safeAreaInsets.top, geometry.size.height - geometry.safeAreaInsets.bottom)
            } action: { visibleBand = $0 }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) { acceptedNote; rejectReason; backToCurrent }.padding(.bottom, 14)
            }
            .onChange(of: cursor) { _, _ in currentPlace = .visible; reveal(proxy) }
            .onChange(of: revealTick) { _, _ in reveal(proxy) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { reviewBar }
        .background(Color.theme(theme, \.card))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .animation(reduceMotion ? nil : Motion.reveal, value: currentPlace)
        .animation(reduceMotion ? nil : Motion.reveal, value: model.lastReject)
        .animation(reduceMotion ? nil : Motion.reveal, value: model.lastAccept)
        .onAppear { focused = true; decideFolds(); follow() }
        .onChange(of: completionSnapshot, initial: true) { _, snapshot in
            if completionFeedback.observe(snapshot) { completionTick += 1 }
        }
        .onChange(of: current?.fileKey) { _, _ in follow() }
        .onChange(of: diffs.map(\.allChangesKey)) { _, _ in decideFolds(); settleCursor() }
        .onChange(of: diffs.map(\.fingerprint)) { _, _ in settleCursor() }
        .onChange(of: model.reviewTally.remaining == 0 && !diffs.isEmpty) { _, done in
            if done { model.scheduleCommitSuggestion(settled: true) }
        }
    }

    // MARK: Review

    private func seenHunks(_ diff: FileDiff) -> Set<String> {
        Set(diff.hunks.filter { model.isSeen($0, in: diff) }.map(\.id))
    }
    private func isSeen(_ stop: AllChangesNavigator.Stop) -> Bool {
        guard let diff = diff(for: stop) else { return true }
        if let id = stop.hunkID, let hunk = diff.hunks.first(where: { $0.id == id }) { return model.isSeen(hunk, in: diff) }
        return model.isFileSeen(diff)
    }
    /// The next unseen stop after `index` (wrapping), or nil when everything is seen.
    private func nextUnseen(after index: Int, forward: Bool = true) -> Int? {
        let all = stops
        guard !all.isEmpty else { return nil }
        for step in 1...all.count {
            let candidate = ((index + (forward ? step : -step)) % all.count + all.count) % all.count
            if !isSeen(all[candidate]) { return candidate }
        }
        return nil
    }
    /// The change list selects the file of the current change.
    private func follow() {
        if let diff = diff(for: current) { model.followReview(diff) }
    }
    private func settleCursor() {
        let count = stops.count
        cursor = min(cursor, max(0, count - 1))
        // After an undo or redo: back to the change it put back, unseen first, so it is seen returning to its place.
        if let focus = model.reviewFocusAfterUndo, Date().timeIntervalSince(focus.date) < 5 {
            let paths = Set(focus.paths)
            let inPaths = stops.indices.filter { diff(for: stops[$0]).map { paths.contains($0.file.path) } ?? false }
            if let target = inPaths.first(where: { !isSeen(stops[$0]) }) ?? inPaths.first {
                model.reviewFocusAfterUndo = nil
                advanceAfterReload = false
                cursor = target
                return
            }
        }
        guard advanceAfterReload else { return }
        advanceAfterReload = false
        if let current, !isSeen(current) { return }
        if let next = nextUnseen(after: cursor - 1) { cursor = next }
    }
    /// The pill shown once the current change is scrolled away; it only scrolls back, it never acts.
    @ViewBuilder private var backToCurrent: some View {
        if currentPlace != .visible, current?.hunkID != nil {
            Button { revealTick += 1; focused = true } label: {
                Label("回到当前处", systemImage: currentPlace == .above ? "arrow.up" : "arrow.down")
                    .themedFont(.caption.weight(.semibold), points: 10)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .themedCapsule(.regularMaterial, stroke: true)
            }
            .buttonStyle(.plain)
            .help("⏎ / ⌫ 作用在当前处上，它不在视野里时先回到它")
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
    /// After a ⏎ went through: what was taken and what is left, for a moment. Shown only on success, never ahead of it.
    @ViewBuilder private var acceptedNote: some View {
        if let accept = model.lastAccept, model.lastReject == nil {
            let remaining = model.reviewTally.remaining
            Label("已收下 \((accept.path as NSString).lastPathComponent) 的\(accept.scope)"
                  + (remaining > 0 ? " · 还剩 \(remaining) 处" : " · 全部看过了"), systemImage: "checkmark.circle.fill")
                .themedFont(.caption.weight(.semibold), points: 10)
                .symbolRenderingMode(.palette).foregroundStyle(ThemeColor(token: .added), ThemeColor(token: .foreground))
                .contentTransition(.numericText())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .themedCapsule(.regularMaterial, stroke: true)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .task(id: accept) {
                    try? await Task.sleep(for: .seconds(1.6))
                    if model.lastAccept == accept { model.lastAccept = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
    /// After ⌫: an optional line on why. R (or a click) opens the field, ⏎ keeps it, Esc skips; untouched, it goes
    /// away after a few seconds so it never holds up the next change.
    @ViewBuilder private var rejectReason: some View {
        if let reject = model.lastReject {
            Group {
                if writingReason {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        TextField("为什么不要？会告诉 agent，也用来提议规则", text: $reasonText)
                            .textFieldStyle(.plain).frame(width: 300).focused($reasonFocused)
                            .onSubmit { model.recordRejectReason(reasonText); closeReason() }
                            .onExitCommand { model.lastReject = nil; closeReason() }
                    }
                } else {
                    Button { openReason() } label: {
                        Label("已丢弃 \((reject.path as NSString).lastPathComponent) · 写一句原因（R）", systemImage: "text.bubble")
                    }.buttonStyle(.plain)
                }
            }
            .themedFont(.caption.weight(.semibold), points: 10)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .themedCapsule(.regularMaterial, stroke: true)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .task(id: reject) {
                try? await Task.sleep(for: .seconds(6))
                if !writingReason, model.lastReject == reject { model.lastReject = nil }
            }
        }
    }
    private func openReason() {
        guard model.lastReject != nil else { return }
        reasonText = ""
        writingReason = true
        reasonFocused = true
    }
    private func closeReason() {
        writingReason = false
        reasonText = ""
        focused = true
    }

    /// ⏎ / ⌫ / s while the current change is out of view: scroll back to it instead.
    private func revealInsteadOfActing() -> Bool {
        guard currentPlace != .visible, current?.hunkID != nil else { return false }
        revealTick += 1
        return true
    }

    private func accept() {
        guard !revealInsteadOfActing() else { return }
        guard let stop = current, let diff = diff(for: stop), !model.busy else { return }
        if let id = stop.hunkID, let hunk = diff.hunks.first(where: { $0.id == id }) { model.acceptSelection(hunk, in: diff) }
        else { model.acceptFile(diff) }
        advance()
    }
    private func reject() {
        guard !revealInsteadOfActing() else { return }
        guard let stop = current, let diff = diff(for: stop), !model.busy else { return }
        if let id = stop.hunkID, let hunk = diff.hunks.first(where: { $0.id == id }) { model.rejectHunk(hunk, in: diff) }
        else { model.rejectFile(diff) }
        advance()
    }
    /// Moves on at once when nothing will reload; after a Git change the reload moves the cursor.
    private func advance() {
        if model.busy { advanceAfterReload = true; return }
        if let next = nextUnseen(after: cursor) { cursor = next }
    }

    private var actionNames: ReviewActionNames? {
        guard let stop = current, let diff = diff(for: stop) else { return nil }
        let hunk = stop.hunkID.flatMap { id in diff.hunks.first { $0.id == id } }
        return ReviewActionNames.make(diff, hunk: hunk, selected: hunk.map { model.allChangesSelected(in: $0, of: diff).count } ?? 0)
    }

    @ViewBuilder private var reviewBar: some View {
        let tally = self.tally
        if !diffs.isEmpty || model.lastCommit != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if tally.hunks > 0 {
                        ThemeProgressBar(fraction: Double(tally.seen) / Double(max(1, tally.hunks)), width: 90)
                            .terrazzoParticles(trigger: completionTick)
                        Text(tally.remaining == 0 ? "全部看过了 · \(tally.hunks) 处" : "已看 \(tally.seen) / \(tally.hunks) 处")
                            .themedFont(.caption.weight(.medium), points: 10).monospacedDigit().fixedSize()
                    }
                    Spacer(minLength: 8)
                    WhitespaceFoldToggle(model: model)
                    ThemedSegmented(options: [(false, "并排"), (true, "统一")],
                                    selection: Binding(get: { model.unifiedDiff }, set: { model.unifiedDiff = $0 }))
                        .controlSize(.small)
                    if let label = model.undoLabel {
                        Button { model.undoGitOperation() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                            .controlSize(.small).help("撤销：\(label)（⌥⌘Z）").disabled(model.busy)
                    }
                }
                if tally.remaining > 0, let names = actionNames {
                    HStack(spacing: 10) {
                        Button("⏎ \(names.accept)") { accept(); focused = true }.fixedSize()
                            .buttonStyle(.folmiProminent)
                        if let rejectName = names.reject {
                            Button("⌫ \(rejectName)") { reject(); focused = true }.fixedSize()
                        }
                        Spacer(minLength: 0)
                    }.controlSize(.small).disabled(model.busy)
                }
                if tally.hunks > 0 && tally.remaining == 0 { commitPanel }
                if let toast = model.lastCommit, Date().timeIntervalSince(toast.date) < 6, diffs.isEmpty || tally.remaining > 0 {
                    Label("已提交 \(toast.id.prefix(7)) · \(toast.subject)", systemImage: "checkmark.circle.fill")
                        .themedFont(.caption.weight(.medium), points: 10).foregroundStyle(.themed(.added))
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .animation(reduceMotion ? nil : Motion.reveal, value: tally.remaining == 0)
        }
    }

    /// Reading progress is separate from acceptance, staging and automated checks.
    private var commitPanel: some View {
        HStack(spacing: 10) {
            Label("人工已看完", systemImage: "eye").foregroundStyle(.secondary)
            Text("已暂存 \(model.stagedCount) 个文件").monospacedDigit()
            Spacer()
            Button("准备提交…") { model.prepareCommitComposer() }
                .controlSize(.small).disabled(model.busy)
                .accessibilityIdentifier("review-prepare-commit")
        }
        .themedFont(.callout, points: 12)
    }

    private var summary: some View {
        let staged = diffs.filter { $0.area == .staged }.count, working = diffs.count - staged
        return VStack(alignment: .leading, spacing: 4) {
            if !model.turnChoices.isEmpty || turn != nil { turnBar }
            HStack(spacing: 10) {
                Text("已暂存 \(staged) · 未暂存 \(working)").themedFont(.caption.weight(.medium), points: 10)
                if model.allChangesLoading { ProgressView().controlSize(.mini); Text("读取中…").themedFont(.caption, points: 10).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Text("空格：下一处 · ⌥⌘Z：撤销 Git 操作")
                    Text("j / k：上下一处")
                    Text(". / ,：上下一个文件")
                    Text("s：暂存 · u：标记未看 · c：评论")
                    Text("f：折叠 · e：编辑 · 方框：选行")
                } label: { Label("操作提示", systemImage: "keyboard") }
                .menuStyle(.borderlessButton).fixedSize().themedFont(.caption, points: 11)
            }
            if let notice = model.allChangesNotice {
                Label(notice, systemImage: "info.circle").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }
            if diffs.isEmpty && !model.allChangesLoading {
                Text(turn == nil ? "没有改动" : "这一轮改过的文件现在都没有改动了（已经提交，或者被改回去了）")
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Which turn the page shows: every change, or what one AI turn touched, with its prompt and the way to take it back.
    private var turnBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Button("全部改动") { model.turnFilter = nil }
                    Divider()
                    ForEach(model.turnChoices) { batch in
                        Button(Self.turnTitle(batch)) { model.turnFilter = batch.id; turnOnly = [] }
                    }
                } label: {
                    Label(turn.map { "只看这一轮：" + Self.turnTitle($0) } ?? "看哪一轮：全部改动", systemImage: "clock.arrow.circlepath")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                .themedFont(.caption.weight(.medium), points: 10)
                .help("只看某一轮 AI 改过的文件，收下、丢弃照常")
                Spacer(minLength: 4)
                if let turn {
                    if turn.canUndo {
                        // A later turn edited the same files: taking this one back would overwrite that, so it is refused
                        // anyway; say so up front instead of after the click.
                        let overlap = turn.paths.filter { model.laterTurnTouched($0, after: turn.id) }
                        Button("撤回这一轮") { model.undoAIBatch(turn.id) }.controlSize(.small).disabled(model.busy || !overlap.isEmpty)
                            .help(overlap.isEmpty
                                  ? "把这一轮改过的 \(turn.paths.count) 个文件恢复成这一轮之前的样子（⌥⌘Z 可以再恢复）"
                                  : "后面的轮次又改过 \(overlap.prefix(3).joined(separator: "、"))\(overlap.count > 3 ? " 等" : "")，整批撤回会把那些改动一起抹掉，所以不能用；在下面按块丢弃这一轮的改动。")
                    }
                    Button("显示全部") { model.turnFilter = nil }.controlSize(.small)
                }
            }
            if let turn {
                let gone = Set(turn.paths).subtracting(diffs.map(\.file.path)).count
                Text("\(turn.agentTitle) · \(turn.started.formatted(date: .omitted, time: .shortened)) · 改了 \(turn.paths.count) 个文件"
                     + (gone > 0 ? "，其中 \(gone) 个现在没有改动（已提交或已改回）" : ""))
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    static func turnTitle(_ batch: AIBatch) -> String {
        let prompt = batch.prompt.map { String($0.prefix(30)) + ($0.count > 30 ? "…" : "") } ?? "（没有记下提示词）"
        return "\(batch.started.formatted(date: .omitted, time: .shortened))  \(prompt)"
    }

    private func header(_ diff: FileDiff, key: String) -> some View {
        let counts = AllChangesNavigator.changedLines(diff)
        let isCollapsed = collapsed.contains(key)
        let isCurrent = current?.fileKey == key
        return HStack(spacing: 8) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 12)
            Text(diff.area == .staged ? "已暂存" : (diff.file.isUntracked ? "新文件" : "未暂存"))
                .themedFont(.caption2.weight(.medium), points: 10)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .themedCapsule((diff.area == .staged ? ThemeColor(token: .added) : ThemeColor(token: .modified)).opacity(0.15))
            Text(diff.file.path).themedFont(.system(size: 12, weight: .semibold, design: .monospaced), points: 12)
                .lineLimit(1).truncationMode(.middle).help(diff.file.path)
            if let original = diff.file.originalPath {
                Text("← \(original)").themedFont(.caption2, points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            RiskBadge(risk: ReviewRiskRules.assess(diff))
            if let turn {
                if model.laterTurnTouched(diff.file.path, after: turn.id) {
                    Text("后面的轮次也改过").themedFont(.caption2, points: 10).foregroundStyle(ThemeColor(token: .modified))
                        .help("这里显示的是文件现在的差异，混着后面轮次的改动；「只看这一轮」可以单独看这一轮改了什么。收下按文件现在的内容算。")
                }
                Toggle("只看这一轮", isOn: Binding(get: { turnOnly.contains(key) },
                                                  set: { on in if on { turnOnly.insert(key) } else { turnOnly.remove(key) } }))
                    .toggleStyle(.button).controlSize(.mini)
                    .help("对比这一轮之前和这一轮刚结束时的文件（只读）")
            }
            Spacer(minLength: 6)
            if counts.added + counts.removed > 0 {
                Text("+\(counts.added)").themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.themed(.added))
                Text("−\(counts.removed)").themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.themed(.removed))
                ChangeBar(added: counts.added, removed: counts.removed)
            }
            // Whole-file actions stay one click away but out of the way: ⏎ at the bottom is the one main action.
            Menu { fileActions(diff) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary).help("编辑、暂存或取消暂存整个文件").accessibilityLabel("文件操作")
        }
        .controlSize(.small)
        .contextMenu { fileActions(diff) }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Color.theme(theme, \.header))
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .leading) { if isCurrent && current?.hunkID == nil { Rectangle().fill(ThemeColor(token: .accent)).frame(width: 3) } }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleFold(key)
            focused = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isCollapsed ? "展开" : "折叠") { toggleFold(key) }
    }

    @ViewBuilder private func fileActions(_ diff: FileDiff) -> some View {
        Button("编辑（e）") { model.editPath(diff.file.path) }
        Button(diff.area == .working ? "暂存整个文件" : "整个文件取消暂存") {
            if diff.area == .working { model.stageFile(diff.file) } else { model.unstageFile(diff.file) }
        }
        .disabled(model.busy)
    }

    private func commentBinding(_ key: String) -> Binding<String?> {
        Binding(
            get: { commentTarget?.fileKey == key ? commentTarget?.hunkID : nil },
            set: { hunk in
                if let hunk { commentTarget = .init(fileKey: key, hunkID: hunk); return }
                guard commentTarget?.fileKey == key else { return }
                commentTarget = nil
                focused = true
            })
    }

    private func decideFolds() {
        for diff in diffs where !foldDecided.contains(diff.allChangesKey) {
            foldDecided.insert(diff.allChangesKey)
            if AllChangesNavigator.startsFolded(diff) { collapsed.insert(diff.allChangesKey) }
        }
    }

    private func toggleFold(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        cursor = stops.firstIndex { $0.fileKey == key } ?? cursor
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let stop = current else { return }
        withMotion(Motion.hover) {
            if let hunk = stop.hunkID { proxy.scrollTo(stop.fileKey + "#" + hunk, anchor: UnitPoint(x: 0.5, y: 0.2)) }
            else { proxy.scrollTo("file:" + stop.fileKey, anchor: .top) }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Typing the rejection reason: the review keys wait.
        if writingReason { return .ignored }
        if press.modifiers == .command || press.modifiers == [.command, .shift], press.characters.lowercased() == "z" {
            if press.modifiers.contains(.shift) { model.redoGitOperation() } else { model.undoGitOperation() }
            advanceAfterReload = true
            return .handled
        }
        if press.key == .return, press.modifiers == .command {
            model.handleCommitShortcut()
            return .handled
        }
        // Everything seen: ⏎ has nothing left to take, and is not a commit.
        if press.key == .return, press.modifiers.isEmpty, model.reviewTally.remaining == 0, !diffs.isEmpty {
            NSSound.beep(); return .handled
        }
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]), !stops.isEmpty else { return .ignored }
        switch press.key {
        case .space:
            if let next = nextUnseen(after: cursor, forward: !press.modifiers.contains(.shift)) { cursor = next } else { NSSound.beep() }
            return .handled
        case .return: accept(); return .handled
        case .delete, .deleteForward: reject(); return .handled
        default: break
        }
        if press.key == .escape {
            guard !model.allChangesSelection.isEmpty else { return .ignored }
            model.clearAllChangesSelection()
            return .handled
        }
        let all = stops
        switch press.characters {
        case "j", "]": cursor = min(all.count - 1, cursor + 1)
        case "k", "[": cursor = max(0, cursor - 1)
        case ".": cursor = AllChangesNavigator.nextFile(all, from: cursor, forward: true)
        case ",": cursor = AllChangesNavigator.nextFile(all, from: cursor, forward: false)
        case "g": cursor = 0
        case "G": cursor = all.count - 1
        case "f", "o": if let stop = current { toggleFold(stop.fileKey) }
        case "e": if let diff = diff(for: current) { model.editPath(diff.file.path) }
        case "r", "R":
            guard model.lastReject != nil else { return .ignored }
            openReason()
        case "s":
            guard !revealInsteadOfActing() else { return .handled }
            guard let stop = current, let diff = diff(for: stop), !model.busy else { return .handled }
            if let hunkID = stop.hunkID, let hunk = diff.hunks.first(where: { $0.id == hunkID }) {
                guard SideBySideDisplayBudget.cachedPlan(for: diff).partialAllowed else { return .handled }
                if model.allChangesSelected(in: hunk, of: diff).isEmpty { model.applyHunk(hunk, in: diff) }
                else { model.applyAllChangesSelection(hunk, in: diff) }
            } else if diff.area == .working { model.stageFile(diff.file) } else { model.unstageFile(diff.file) }
        case "u":
            guard let stop = current, let diff = diff(for: stop) else { return .handled }
            if let id = stop.hunkID, let hunk = diff.hunks.first(where: { $0.id == id }) {
                model.markSeen(hunk, in: diff, seen: !model.isSeen(hunk, in: diff))
            } else { model.markFileSeen(diff, seen: !model.isFileSeen(diff)) }
        case "c":
            // A folded file has no hunk toolbar to anchor the comment box to.
            guard let stop = current, stop.hunkID != nil else { return .handled }
            commentTarget = stop
        default: return .ignored
        }
        return .handled
    }

    private func diff(for stop: AllChangesNavigator.Stop?) -> FileDiff? {
        guard let stop else { return nil }
        return diffs.first { $0.allChangesKey == stop.fileKey }
    }
}

/// Five blocks split between additions and deletions, like a compact diffstat.
private struct ChangeBar: View {
    let added: Int
    let removed: Int
    var body: some View {
        let _ = PerfLog.body("ChangeBar")
        let total = max(1, added + removed)
        let green = added == 0 ? 0 : max(1, Int((Double(added) / Double(total) * 5).rounded()))
        let red = min(5 - green, removed == 0 ? 0 : max(1, 5 - green))
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < green ? ThemeColor(token: .added) : (index < green + red ? ThemeColor(token: .removed) : ThemeColor(token: .secondaryText, opacity: 0.25)))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

extension FileDiff {
    var allChangesKey: String { AllChangesNavigator.key(self) }
}

/// Why a file was put at the front of 逐个验收: red for things to check before anything else, amber for a second look.
private struct RiskBadge: View {
    let risk: ReviewRisk
    var body: some View {
        if risk.level != .none {
            let token: ThemeToken = risk.level == .high ? .removed : .modified
            HStack(spacing: 3) {
                Image(systemName: risk.level == .high ? "exclamationmark.triangle.fill" : "eye")
                    .font(.system(size: 9, weight: .semibold))
                Text(risk.reasons.joined(separator: " · ")).themedFont(.caption2.weight(.medium), points: 10).lineLimit(1)
            }
            .foregroundStyle(ThemeColor(token: token))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .themedCapsule(ThemeColor(token: token, opacity: 0.14))
            .help(risk.level == .high ? "排在前面：建议先看这一处" : "排在前面：值得多看一眼")
            .accessibilityLabel((risk.level == .high ? "高风险：" : "留意：") + risk.reasons.joined(separator: "，"))
        }
    }
}

/// 只看这一轮: one file before the turn against right after it, read only, above the file's current diff.
private struct TurnOnlyDiff: View {
    let model: FolmiModel
    let batch: String
    let path: String
    @State private var diff: FileDiff?
    @State private var note: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("只看这一轮", systemImage: "clock.arrow.circlepath").themedFont(.caption.weight(.medium), points: 10).foregroundStyle(.secondary)
            if let note { Text(note).themedFont(.caption, points: 10).foregroundStyle(.secondary) }
            if let diff {
                if let notice = diff.notice { Text(notice).themedFont(.caption, points: 10).foregroundStyle(.secondary) }
                SideBySideFile(
                    diff: diff, selected: [], busy: false, columnWidth: 400,
                    onToggleLine: { _, _ in }, onApplyHunk: { _, _ in }, onApplySelection: { _, _ in },
                    onStageFile: { _ in }, onUnstageFile: { _ in }, onEditFile: { _ in },
                    comments: [], onComment: { _, _, _ in }, onDeleteComment: { _ in },
                    showsHeader: false, allowsLineSelection: false, anchorPrefix: "turn#\(batch)#",
                    readOnly: true, sideTitles: ("这一轮之前", "这一轮之后"), unified: model.unifiedDiff)
            } else if !loaded {
                ProgressView().controlSize(.small)
            }
            Divider().padding(.top, 4)
            Text("下面是文件现在的差异，在这里收下或丢弃。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .task(id: batch + path) {
            let result = await model.turnDiff(batch: batch, path: path)
            diff = result.diff; note = result.note; loaded = true
        }
    }
}
