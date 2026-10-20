import SwiftUI
import AppKit
import FolmiCore

/// The left block: the file tree and the Git changes (with the commit box) as two tabs.
struct SideCard: View {
    let model: FolmiModel
    let tracker: PaneFocusTracker
    @Binding var treeQuery: String
    let treeExpansion: ProjectTreeExpansion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PerfLog.body("SideCard")
        let tab = model.paneLayout.sideTab
        folmiCard(.changes, model: model, tracker: tracker) {
            PaneTabGroup {
                PaneTab(title: SideTab.files.title, selected: tab == .files) { model.showSideTab(.files) }
                PaneTab(title: SideTab.changes.title, count: model.snapshot?.files.count, dot: model.openingBanner != nil && tab != .changes,
                        selected: tab == .changes) { model.showSideTab(.changes) }
            }
        } accessory: {
            if model.isDemo {
                Text("演示").themedFont(.caption2.weight(.medium), points: 10)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .themedCapsule(ThemeColor(token: .accent, opacity: 0.12))
            }
        } content: {
            ZStack {
                if tab == .files {
                    TreePane(model: model, query: $treeQuery, expansion: treeExpansion).transition(.opacity)
                } else { ChangesPane(model: model).transition(.opacity) }
            }
            .animation(reduceMotion ? nil : Motion.state, value: tab)
            .onChange(of: model.repositoryURL?.path) { _, _ in treeExpansion.reset(); treeQuery = "" }
        }
    }
}

struct TreePane: View {
    let model: FolmiModel
    @Binding var query: String
    let expansion: ProjectTreeExpansion
    /// What is typed. The tree (and the window state holding `query`) follows after a short pause, so typing does not
    /// redraw the window and refilter thousands of files on every key.
    @State private var typed: String?

    var body: some View {
        let _ = PerfLog.body("TreePane")
        let text = typed ?? query
        VStack(spacing: 0) {
            TextField("按文件名筛选…", text: Binding(get: { text }, set: { typed = $0 }))
                .themedTextField().padding(.horizontal, 10).padding(.top, 8)
                .padding(.bottom, text.trimmingCharacters(in: .whitespaces).isEmpty ? 8 : 4)
                .onSubmit { typed.map { query = $0 } }
                .task(id: typed) {
                    guard let typed, typed != query else { return }
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    query = typed
                }
                .onChange(of: query) { _, new in if typed != new { typed = nil } }
            // The field filters names; the words inside files are 全局搜索's job, one click away.
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 4) {
                    QuietButton(title: "在文件内容里搜索「\(text.trimmingCharacters(in: .whitespaces))」 ⌘⇧F") {
                        model.projectSearchQuery = text.trimmingCharacters(in: .whitespaces)
                        model.openProjectSearch()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
            if model.treeLoading { ProgressView("读取文件树…").controlSize(.small).padding(8) }
            if let error = model.treeError {
                Label(error, systemImage: "exclamationmark.triangle").themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(12)
                Spacer(minLength: 0)
            } else if let tree = model.projectTree {
                ProjectFileTreeView(nodes: tree.roots, query: query,
                                    selectedPath: model.content == .editor ? model.editorChrome?.selected : model.selectedFileID,
                                    changedPaths: Set(model.snapshot?.files.map(\.path) ?? []), busy: model.busy,
                                    onOpen: model.editPath, changeCodes: model.changeCodes, taskCounts: model.taskCounts,
                                    root: model.repositoryURL,
                                    onShowChanges: model.showChanges(ofPath:), onTerminalHere: model.openTerminal(at:isDirectory:),
                                    onSendPath: { model.sendTextToTerminal($0) },
                                    onLoadFolder: model.loadTreeFolder,
                                    expansion: expansion)
                    .id(model.repositoryURL?.path)
                // One line: the count, then why it may be incomplete (the limit notice already says so).
                Text(tree.notice.map { "\(tree.fileCount.formatted()) 个文件 · \($0)" } ?? "\(tree.fileCount.formatted()) 个文件")
                    .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
            } else { Spacer(minLength: 0) }
        }
    }
}

struct ChangesPane: View {
    @Bindable var model: FolmiModel

    var body: some View {
        let _ = PerfLog.body("ChangesPane")
        let staged = model.visibleFiles(in: .staged), working = model.visibleFiles(in: .working)
        VStack(spacing: 0) {
            TextField("搜索改动…", text: $model.fileSearch).themedTextField()
                .padding(10)
            if let operation = model.snapshot?.operation {
                OperationNotice(model: model, operation: operation).padding(.horizontal, 10).padding(.bottom, 8)
            }
            if staged.isEmpty && working.isEmpty {
                if model.fileSearch.isEmpty, model.snapshot?.files.isEmpty == true { DoneState(model: model) }
                else { panePlaceholder(symbol: "magnifyingglass", title: "没有匹配的改动", detail: "换个关键词，或清空搜索。") }
            } else {
                ReviewEntryRow(model: model).padding(.horizontal, 10).padding(.bottom, 6)
                HStack {
                    Text("已选\(model.area == .staged ? "暂存区" : "工作区") \(model.selectedFileIDs.count) 项")
                        .themedFont(.caption, points: 11).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !model.selectedFileIDs.isEmpty {
                        QuietButton(title: model.area == .staged ? "取消暂存所选" : "暂存所选", action: model.toggleStageSelectedFiles)
                            .disabled(model.busy)
                    }
                    QuietButton(title: "编辑所选") { model.editSelectedFiles() }
                }.padding(.horizontal, 12).padding(.bottom, 6)
                HStack {
                    Button("搁置全部改动（\(model.snapshot?.files.count ?? 0) 个文件）") { model.stashAllChanges() }
                        .buttonStyle(.themedLink).themedFont(.caption, points: 11)
                        .help("包括暂存区、工作区和新文件；完成后可点恢复或按 ⌥⌘Z")
                    Spacer()
                }.padding(.horizontal, 12).padding(.bottom, 8)
                // Both groups at once: what the next commit takes (暂存区) above what is still only on disk (工作区).
                // A file changed in both shows in both. Rows are tagged "area:path"; picking rows in the other group
                // moves the selection (and the diff) there.
                List(selection: Binding(get: { Set(model.selectedFileIDs.map { model.area.rawValue + ":" + $0 }) },
                                        set: { select($0) })) {
                    Section {
                        if staged.isEmpty {
                            Text(model.fileSearch.isEmpty ? "还没有暂存的文件。暂存后会出现在这里，提交时只提交这一组。" : "没有匹配的已暂存文件")
                                .themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(.vertical, 2)
                                .selectionDisabled()
                        }
                        ForEach(staged) { file in row(file, .staged) }
                    } header: {
                        GroupHeader(title: "暂存区", detail: "将会提交", count: staged.count, token: .added,
                                    onSelectAll: { model.selectFiles(Set(staged.map(\.id)), in: .staged) },
                                    moveAll: ("全部取消", { model.unstageFiles(staged) }), busy: model.busy)
                    }
                    Section {
                        if working.isEmpty {
                            Text(model.fileSearch.isEmpty ? "工作区没有别的改动。" : "没有匹配的工作区改动")
                                .themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(.vertical, 2)
                                .selectionDisabled()
                        }
                        ForEach(working) { file in row(file, .working) }
                    } header: {
                        GroupHeader(title: "工作区", detail: "未暂存", count: working.count, token: .modified,
                                    onSelectAll: { model.selectFiles(Set(working.map(\.id)), in: .working) },
                                    moveAll: ("全部暂存", { model.stageFiles(working) }), busy: model.busy)
                    }
                }
                // Double-click opens the file. A tap gesture on each row would take single clicks on its text away from the
                // list's selection, so the list's own primary action does it.
                .contextMenu(forSelectionType: String.self, menu: rowMenu) { tags in
                    if let (_, files) = files(for: tags), files.count == 1 { model.editPath(files[0].path) }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden).disabled(model.busy)
                .task(id: model.theme.style.instrument ? model.snapshot?.fingerprint : nil) { await model.loadLineCounts() }
                // Staging, unstaging or committing slides rows from one group to the other instead of a jump.
                .motion(Motion.reveal, value: staged.map(\.id) + ["|"] + working.map(\.id))
            }
            if let count = model.snapshot?.stashCount, count > 0 {
                StashEntryRow(model: model, count: count).padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            CommitSection(model: model)
        }
    }

    private func row(_ file: FileChange, _ group: ChangeArea) -> some View {
        let key = group.rawValue + ":" + file.id
        let selected = model.area == group && model.selectedFileIDs.contains(file.id)
        let focused = model.paneLayout.focused == .changes
        return FileChangeRow(file: file, area: group, counts: model.theme.style.instrument ? model.lineCounts[key] : nil,
                             onAccent: selected && focused && model.theme.style.selection == .solid)
            .tag(key).padding(.vertical, model.theme.style.rowPadding)
            .background(ListHighlightSuppressor())
            .listRowBackground(SelectedRowBackground(selected: selected, focused: focused))
    }

    private func files(for tags: Set<String>) -> (group: ChangeArea, files: [FileChange])? {
        guard let first = tags.first, let group = ChangeArea(rawValue: String(first.prefix { $0 != ":" })) else { return nil }
        let prefix = group.rawValue + ":"
        let paths = Set(tags.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        let files = (model.snapshot?.files ?? []).filter { paths.contains($0.id) && (group == .working ? $0.hasWorking : $0.hasStaged) }
        return files.isEmpty ? nil : (group, files)
    }

    /// Right-click acts on the clicked row, or on the whole selection when the row is part of it (the list decides).
    @ViewBuilder private func rowMenu(_ tags: Set<String>) -> some View {
        if let (group, files) = files(for: tags) {
            let count = files.count > 1 ? " \(files.count) 个文件" : ""
            if group == .working {
                Button("暂存\(count)") { model.stageFiles(files) }.disabled(model.busy)
            } else {
                Button("取消暂存\(count)") { model.unstageFiles(files) }.disabled(model.busy)
            }
            Divider()
            Button(files.count > 1 ? "编辑这 \(files.count) 个文件" : "编辑") {
                // Several rows in the menu are always the selection.
                if files.count == 1 { model.editPath(files[0].path) } else { model.editSelectedFiles() }
            }
        }
    }

    /// The group of the rows just added wins; rows of the other group drop out of the selection.
    private func select(_ tags: Set<String>) {
        let current = Set(model.selectedFileIDs.map { model.area.rawValue + ":" + $0 })
        let added = tags.subtracting(current)
        let group: ChangeArea = added.first.flatMap { ChangeArea(rawValue: String($0.prefix { $0 != ":" })) } ?? model.area
        let prefix = group.rawValue + ":"
        model.selectFiles(Set(tags.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }), in: group)
    }
}

/// A change-list group's title: name, what it means, and a count that rolls as files move.
struct GroupHeader: View {
    let title: String
    let detail: String
    let count: Int
    let token: ThemeToken
    var onSelectAll: (() -> Void)? = nil
    /// Moves every file of the group to the other one: 全部暂存 / 全部取消.
    var moveAll: (title: String, action: () -> Void)? = nil
    var busy = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ThemeColor(token: token)).frame(width: 6, height: 6)
            Text(title).themedFont(.system(size: 11.5, weight: .semibold), points: 11.5).foregroundStyle(ThemeColor(token: .foreground))
            Text("\(count)").themedFont(.system(size: 11, weight: .medium).monospacedDigit(), points: 11).foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Text(detail).themedFont(.caption2, points: 10).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let onSelectAll, count > 0 {
                Button("全选", action: onSelectAll).buttonStyle(.themedLink)
                    .themedFont(.caption, points: 11).accessibilityLabel("全选\(title) \(count) 个文件")
            }
            if let moveAll, count > 0 {
                Button(moveAll.title, action: moveAll.action).buttonStyle(.themedLink).disabled(busy)
                    .themedFont(.caption, points: 11).accessibilityLabel("\(moveAll.title)\(title) \(count) 个文件")
            }
        }
        .motion(Motion.reveal, value: count)
    }
}

/// A quiet way back to the stashes, shown only while there are some, with 「放回」 for the newest one.
struct StashEntryRow: View {
    let model: FolmiModel
    let count: Int
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 6) {
            list
            Button("放回", action: model.popLatestStash)
                .buttonStyle(.pressable).themedFont(.caption.weight(.medium), points: 10)
                .foregroundStyle(.themed(.accent))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .themedBackground(ThemeColor(token: .hover, opacity: 0.5), .control)
                .disabled(model.busy)
                .help("把最近收起的一批改动放回工作区（暂存的部分仍是暂存）")
                .accessibilityLabel("放回最近收起的改动")
        }
    }
    private var list: some View {
        Button(action: model.openStashes) {
            HStack(spacing: 7) {
                Image(systemName: "tray.full").font(.system(size: 12))
                Text("收起的改动").themedFont(.caption, points: 10)
                Text("\(count)").themedFont(.caption.monospacedDigit(), points: 10).contentTransition(.numericText())
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(ThemeColor(token: hovering ? .foreground : .secondaryText))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedBackground(ThemeColor(token: .hover, opacity: hovering ? 1 : 0.5), .control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .motion(Motion.reveal, value: count)
        .help("查看、恢复或删除临时收起的改动")
    }
}

struct ReviewEntryRow: View {
    let model: FolmiModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PerfLog.body("ReviewEntryRow")
        let files = model.snapshot?.files.count ?? 0
        let tally = model.reviewTally
        let fresh = model.openingBanner != nil
        let shape = RoundedRectangle(cornerRadius: model.theme.style.radius(.control), style: .continuous)
        Button { model.showContent(.allChanges); model.focusPane(.editor) } label: {
            HStack(spacing: 8) {
                Image(systemName: tally.hunks > 0 && tally.remaining == 0 ? "checkmark.circle" : "checklist")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ThemeColor(token: fresh ? .accent : .secondaryText))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("逐个验收").themedFont(.system(size: 12.5, weight: .semibold), points: 12.5)
                    Text(model.openingBanner ?? detail(files: files, tally: tally))
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 4)
                if tally.hunks > 0 {
                    ThemeProgressBar(fraction: Double(tally.seen) / Double(max(1, tally.hunks)), width: 36)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .offset(x: hovering && !reduceMotion ? 2 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor(token: fresh ? .accent : .hover, opacity: fresh ? 0.1 : (hovering ? 1 : 0.55)), in: shape)
            .overlay(shape.strokeBorder(ThemeColor(token: fresh ? .accent : .border, opacity: fresh ? 0.45 : 1)))
            .contentShape(shape)
        }
        .buttonStyle(.pressableRow)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.hover, value: hovering)
        .animation(reduceMotion ? nil : Motion.reveal, value: fresh)
        .animation(reduceMotion ? nil : Motion.reveal, value: tally)
        .help("在「全部改动」里一处一处过：空格看下一处，⏎ 通过并暂存，⌫ 不要，⌘Z 撤销")
    }

    private func detail(files: Int, tally: ReviewTally) -> String {
        guard tally.hunks > 0 else { return "\(files) 个文件有改动" }
        return tally.remaining == 0 ? "\(files) 个文件 · \(tally.hunks) 处都看过了" : "\(files) 个文件 · \(tally.remaining) 处没看过"
    }
}

/// The commit box; typing a message re-renders only this.
struct CommitSection: View {
    @Bindable var model: FolmiModel
    @FocusState private var messageFocused: Bool

    var body: some View {
        let _ = PerfLog.body("CommitSection")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已暂存 \(model.stagedCount) 个文件").themedFont(.callout.weight(.medium), points: 12)
                Spacer()
                Button(model.showCommitComposer ? "收起说明" : "准备提交") { model.showCommitComposer.toggle() }
                    .controlSize(.small).disabled(model.busy)
                    .accessibilityIdentifier("toggle-commit-composer")
            }
            if model.showCommitComposer {
            let hint = commitHint
            let needsMessage = hint?.field == true
            let shape = RoundedRectangle(cornerRadius: model.theme.style.radius(.control), style: .continuous)
            TextEditor(text: $model.draftMessage)
                .themedFont(.system(size: 12, design: .monospaced), points: 12)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 72, idealHeight: 96, maxHeight: 180)
                .background(ThemeColor(token: .hover), in: shape)
                .overlay(alignment: .topLeading) {
                    if model.draftMessage.isEmpty {
                        Text(needsMessage ? "写一句提交说明，就能提交暂存区（⌘↵）\n可保留完整正文和 Change-Id。" : "提交说明（⌘↵ 提交）\n可保留完整正文和 Change-Id。")
                            .themedFont(.system(size: 12, design: .monospaced), points: 12)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                // Waiting only on a message: the box itself says so, where the eye already is.
                .overlay(shape.strokeBorder(ThemeColor(token: .border), lineWidth: 1))
                .accessibilityLabel("提交说明").accessibilityIdentifier("commit-message")
                .focused($messageFocused)
                .onAppear { messageFocused = true }
                .motion(Motion.state, value: needsMessage)
                .disabled(model.busy)

            CommitSuggestionStatus(model: model)
            CommitCheckView(model: model)
            Toggle("修订最近一次提交", isOn: Binding(
                get: { model.amendLast },
                set: { model.setAmend($0) }
            ))
            .themedFont(.caption, points: 10)
            .disabled(model.busy || model.snapshot?.head == nil)

            CommitActionButton(model: model)
            HStack {
                Button("生成说明") { model.scheduleCommitSuggestion(force: true) }
                Button("建议拆分") { model.suggestSplit() }
            }.controlSize(.small).disabled(model.busy || model.stagedCount == 0)

            if let hint, !hint.field {
                Label(hint.text, systemImage: hint.symbol)
                    .themedFont(.caption, points: 10)
                    .foregroundStyle(ThemeColor(token: hint.blocking ? .modified : .secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
            } else if !model.isComposingCommit, (model.snapshot?.unpushed ?? 0) > 0 {
                Button("推送 \(model.snapshot?.unpushed ?? 0) 个提交…", action: model.prepareDelivery)
                    .controlSize(.small).disabled(model.busy)
            }
            CommitExclusionNote(model: model)
        }
        .padding(Metrics.contentInset)
        .motion(Motion.reveal, value: commitHint?.text)
    }

    private struct Hint: Equatable {
        let text: String
        var symbol = "info.circle"
        var blocking = false
        /// Shown on the message box instead of as a line under the button.
        var field = false
    }

    /// Why the button cannot act yet, or nothing once it can.
    private var commitHint: Hint? {
        if model.busy { return Hint(text: "操作完成后可继续提交。", symbol: "hourglass") }
        let unpushed = model.snapshot?.unpushed ?? 0
        if !model.isComposingCommit && unpushed > 0 { return Hint(text: "推送前会先预览要执行的命令，确认后才运行。") }
        if model.snapshot?.files.contains(where: \.isConflict) == true { return Hint(text: "仓库仍有冲突，请先解决冲突。", symbol: "exclamationmark.triangle", blocking: true) }
        if model.stagedCount == 0 && !model.amendLast {
            return model.isComposingCommit ? Hint(text: "先暂存要提交的文件、块或行。", symbol: "tray.and.arrow.down", blocking: true) : nil
        }
        if model.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Hint(text: "", field: true) }
        return nil
    }
}

/// The commit box's one primary action. While there is something to commit it commits; once a commit lands it
/// briefly turns green with the new commit, then becomes "推送 N 个提交", so the push follows the commit in the same
/// place instead of a separate button elsewhere.
struct CommitActionButton: View {
    let model: FolmiModel
    @State private var justCommitted: CommitToast?
    @State private var completionTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private enum Phase: Equatable { case commit, committed, push }

    var body: some View {
        let _ = PerfLog.body("CommitActionButton")
        let unpushed = model.snapshot?.unpushed ?? 0
        let phase: Phase = justCommitted != nil ? .committed : (!model.isComposingCommit && unpushed > 0 ? .push : .commit)
        let terrazzo = model.theme == .terrazzo
        let colors = model.theme.definition.colors(dark: colorScheme == .dark)
        let successText = terrazzo ? model.theme.definition.markText(on: colors.added).color : Color.white
        HStack(spacing: 6) {
            Button {
                if phase == .push { model.prepareDelivery() } else { model.commit() }
            } label: {
                ZStack {
                    label(for: phase, unpushed: unpushed)
                        .id(phase)
                        .transition(terrazzo ? .opacity : .asymmetric(insertion: .offset(y: 14).combined(with: .opacity),
                                                                      removal: .offset(y: -14).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .buttonStyle(.folmiProminent)
            .overlay {
                // The commit landing: a green wash over the button that fades as it turns into the push.
                model.theme.style.prominentShape
                    .fill(ThemeColor(token: .added))
                    .overlay { if phase == .committed { label(for: .committed, unpushed: unpushed).foregroundStyle(successText) } }
                    .opacity(phase == .committed ? 1 : 0)
                    .padding(.bottom, model.theme.style.prominent == .clay ? 3 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                // 锌莓's signature: a line runs the button's width once when the commit lands.
                if model.theme.style.instrument { CommitSweepLine(trigger: justCommitted?.id).offset(y: 5) }
            }
            .scaleEffect(phase == .committed && !reduceMotion && !terrazzo ? 1.03 : 1)
            .terrazzoParticles(trigger: completionTick)
            .disabled(phase == .committed || (phase == .push ? model.busy : !model.canCommit))
            .help(phase == .push ? "先预览目标和命令，确认后再推送" : "提交暂存区（⌘↵）")
            if phase == .commit, unpushed > 0 {
                // Still composing, but earlier commits wait: a small way to push them without leaving the box.
                Button { model.prepareDelivery() } label: { Label("↑\(unpushed)", systemImage: "arrow.up").labelStyle(.titleOnly).monospacedDigit() }
                    .disabled(model.busy)
                    .help("推送已有的 \(unpushed) 个提交")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .controlSize(.large)
        .animation(reduceMotion ? nil : (terrazzo ? .easeOut(duration: 0.18) : Motion.settle), value: phase)
        .onChange(of: model.lastCommit) { _, toast in
            guard let toast else { return }
            justCommitted = toast
            if model.theme == .terrazzo { completionTick += 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(reduceMotion ? 1.2 : 1.6))
                if justCommitted == toast { justCommitted = nil }
            }
        }
    }

    @ViewBuilder private func label(for phase: Phase, unpushed: Int) -> some View {
        switch phase {
        case .commit:
            HStack(spacing: 8) {
                Text(model.amendLast ? "修订提交" : "提交暂存区 \(model.stagedCount)").contentTransition(.numericText())
                if model.theme.style.instrument {
                    Text("⌘↩").font(.system(size: 11, design: .monospaced)).opacity(0.7)
                }
            }
        case .committed:
            if model.theme == .terrazzo {
                Label("已提交 \(justCommitted?.id.prefix(7) ?? "")", systemImage: "checkmark.circle.fill")
            } else {
                Label("已提交 \(justCommitted?.id.prefix(7) ?? "")", systemImage: "checkmark.circle.fill")
                    .symbolEffect(.bounce, value: justCommitted?.id)
            }
        case .push:
            Label("推送 \(unpushed) 个提交", systemImage: "arrow.up.circle").contentTransition(.numericText())
        }
    }
}

struct FileChangeRow: View {
    let file: FileChange
    let area: ChangeArea
    /// The file's +N −N, shown by 锌莓.
    var counts: LineCount? = nil
    /// Drawn on the accent (石墨's focused selection): every part of the row takes the on-accent color.
    var onAccent = false

    private var filename: String { (file.path as NSString).lastPathComponent }
    private var directory: String { (file.path as NSString).deletingLastPathComponent }
    /// A one-letter badge in the change's color, as in other Git tools; the word is in its tooltip.
    private var status: (letter: String, word: String, token: ThemeToken) {
        if file.isConflict { return ("!", "冲突", .removed) }
        if file.isUntracked { return ("U", "新文件（未跟踪）", .added) }
        let code = area == .working ? file.worktreeCode : file.indexCode
        switch code {
        case "A": return ("A", "新增", .added)
        case "D": return ("D", "删除", .removed)
        case "R": return ("R", "改名", .link)
        case "C": return ("C", "复制", .link)
        case "T": return ("T", "类型改变", .modified)
        default: return ("M", "修改", .modified)
        }
    }

    @Environment(\.folmiTheme) private var theme
    private var inline: Bool { theme.style.instrument }
    private var hasDirectory: Bool { !directory.isEmpty && directory != "." }

    var body: some View {
        let _ = PerfLog.body("FileChangeRow")
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: file.isConflict ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(ThemeColor(token: onAccent ? .onAccent : (file.isConflict ? .modified : .secondaryText)))
                .frame(width: 15)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if inline {
                    // 锌莓 keeps each file to one line: the folder follows the name in the quiet tone.
                    HStack(spacing: 6) {
                        Text(filename).lineLimit(1).layoutPriority(1)
                        if hasDirectory {
                            Text(directory).themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                } else {
                    Text(filename).lineLimit(1).truncationMode(.middle)
                }
                if !inline, hasDirectory {
                    Text(directory)
                        .themedFont(.caption2, points: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let original = file.originalPath {
                    Text("← \(original)")
                        .themedFont(.caption2, points: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 2)
            if let counts {
                LineCountText(counts: counts, onAccent: onAccent).padding(.top, 1)
            }
            StatusBadge(letter: status.letter, token: onAccent ? .onAccent : status.token)
                .padding(.top, 1)
        }
        .foregroundStyle(onAccent ? AnyShapeStyle(ThemeColor(token: .onAccent)) : AnyShapeStyle(.primary))
        // No `.help` here: a tooltip inside a `List` row keeps clicks on the row's text from selecting it.
    }
}

/// A change's one-letter status (M / A / D / R / U / !) on a soft fill of its color, or as a solid block with an
/// edge where the theme asks for solid marks (像素).
struct StatusBadge: View {
    let letter: String
    let token: ThemeToken
    var size: CGFloat = 16
    @Environment(\.folmiTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let text = Text(letter).themedFont(.system(size: size * 0.625, weight: .bold, design: .monospaced), points: size * 0.625)
        Group {
            if theme.style.solidMarks {
                let definition = theme.definition
                let fill = definition.colors(dark: colorScheme == .dark).markFill(token)
                // Dark ink on bright fills (coin yellow, the dark theme's lit colors), light text on deep ones.
                text.foregroundStyle(definition.markText(on: fill).color)
                    .frame(width: size, height: size)
                    .background(fill.color)
                    .overlay { Rectangle().strokeBorder(.themed(.border), lineWidth: 1) }
            } else {
                switch theme.style.marks {
                case .tint:
                    text.foregroundStyle(ThemeColor(token: token))
                        .frame(width: size, height: size)
                        .background(ThemeColor(token: token, opacity: 0.14), in: theme.style.tabs == .capsule ? AnyShape(Circle())
                            : AnyShape(RoundedRectangle(cornerRadius: theme.style.controlRadius, style: .continuous)))
                case .text:
                    text.foregroundStyle(ThemeColor(token: token)).frame(minWidth: size * 0.75, minHeight: size)
                case .dot:
                    HStack(spacing: 4) {
                        Circle().fill(ThemeColor(token: token)).frame(width: 6, height: 6)
                        Text(letter).themedFont(.system(size: size * 0.625, weight: .medium), points: size * 0.625)
                            .foregroundStyle(ThemeColor(token: token == .onAccent ? .onAccent : .tertiaryText))
                    }
                    .frame(minHeight: size)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small solid square in a status color with the theme's edge, for status-bar counts under solid marks.
struct StatusSquare: View {
    let token: ThemeToken
    @Environment(\.folmiTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Rectangle().fill(theme.definition.colors(dark: colorScheme == .dark).markFill(token).color)
            .frame(width: 8, height: 8)
            .overlay { Rectangle().strokeBorder(.themed(.border), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

/// A small text action that sits beside content (全选, 编辑所选): secondary until hovered, never an accent link.
struct QuietButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).themedFont(.caption, points: 10)
                .foregroundStyle(ThemeColor(token: hovering ? .foreground : .secondaryText))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .themedBackground(ThemeColor(token: .hover, opacity: hovering ? 1 : 0), .control)
                .motion(Motion.hover, value: hovering)
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
    }
}
