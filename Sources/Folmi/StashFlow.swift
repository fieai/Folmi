import SwiftUI
import FolmiCore

/// Stashing and bringing back changes, including new files.
extension FolmiModel {
    var stashFileLists: [String: [String]] { stashPlans.mapValues { $0.files.map(\.id) } }
    var stashConflictLists: [String: [String]] { stashPlans.mapValues(\.conflicts) }

    /// A name that says what is inside: the first few files.
    var defaultStashMessage: String {
        let files = snapshot?.files.map { ($0.path as NSString).lastPathComponent } ?? []
        let names = files.prefix(3).joined(separator: "、") + (files.count > 3 ? " 等" : "")
        return "\(files.count) 个文件：\(names)"
    }

    func stashAllChanges() {
        stashChanges(message: "", workingOnly: false)
    }

    func stashBlocker(workingOnly: Bool) -> String? {
        if editorWorkspace?.hasUnsavedChanges == true { return "先保存编辑器里的改动。" }
        guard let snapshot, snapshot.head != nil else { return "先完成第一次提交。" }
        if snapshot.operation != nil || snapshot.files.contains(where: \.isConflict) { return "先完成当前的冲突处理。" }
        if !snapshot.files.contains(where: { !workingOnly || $0.hasWorking }) {
            return workingOnly ? "工作区没有改动。" : "没有改动可暂放。"
        }
        return nil
    }

    func stashChanges(message: String, workingOnly: Bool) {
        guard let repository, let state = snapshot, stashBlocker(workingOnly: workingOnly) == nil else { return }
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = state.files.filter { !workingOnly || $0.hasWorking }.map { ($0.path as NSString).lastPathComponent }
        let names = paths.prefix(3).joined(separator: "、") + (paths.count > 3 ? " 等" : "")
        let message = note.isEmpty ? "\(paths.count) 个文件：\(names)" : note
        mutate("暂放改动") { [weak self] in
            let entry = workingOnly
                ? try await repository.stashWorking(message: message, expectedFingerprint: state.fingerprint)
                : try await repository.stashAll(message: message, expectedFingerprint: state.fingerprint)
            await MainActor.run { self?.pushUndo("暂放改动（\(message)）", .stash(.pop(object: entry.id))) }
            let kept = workingOnly ? "暂存区里的改动仍然保留。" : "已暂存的改动也一并暂放。"
            return "已暂放「\(entry.message)」。\(kept)可从「暂放的改动」里拿回，或按 ⌥⌘Z。"
        } after: { [weak self] in self?.reloadStashesIfShown() }
    }

    func openStashes() {
        guard snapshot != nil else { return }
        showStashes = true
        Task { await loadStashes() }
    }

    func loadStashes() async {
        guard let repository else { return }
        let request = UUID()
        stashRequest = request
        do {
            let list = try await repository.stashes()
            let plans = try await repository.stashRestorePlans(list.prefix(30).map(\.id))
            guard stashRequest == request, self.repository === repository else { return }
            stashEntries = list; stashPlans = plans
        } catch { if stashRequest == request { report(error, title: "读取暂放的改动失败") } }
    }

    func loadStashPlan(_ id: String) async {
        guard stashPlans[id] == nil, let repository else { return }
        let request = stashRequest
        do {
            let plan = try await repository.stashRestorePlans([id])[id]
            guard !Task.isCancelled, request == stashRequest, self.repository === repository else { return }
            stashPlans[id] = plan
        } catch {
            if !Task.isCancelled, request == stashRequest { report(error, title: "读取暂放预览失败") }
        }
    }

    private func reloadStashesIfShown() {
        if showStashes { Task { await loadStashes() } }
    }

    /// Brings a stash back (staged parts staged again) and takes it off the list. ⌘Z puts it aside again.
    func popStash(_ entry: StashEntry) {
        guard let repository, let state = snapshot else { return }
        guard editorWorkspace?.hasUnsavedChanges != true else {
            errorMessage = "先保存编辑器里的改动，再拿回。"
            return
        }
        let key = repositoryURL?.path ?? state.root.path
        mutateUndoable("拿回暂放的改动（\(entry.message)）", after: { [weak self] in
            guard let self else { return }
            self.reloadStashesIfShown()
            if self.snapshot?.files.isEmpty == false { self.showSideTab(.changes) }
        }) { [weak self] in
            do {
                let step = try await repository.popStash(entry.id, expectedFingerprint: state.fingerprint)
                return (step, "已拿回「\(entry.message)」。")
            } catch {
                if !state.files.contains(where: \.isConflict), (try? await repository.load().files.contains(where: \.isConflict)) == true {
                    self?.conflictedRestores[key] = entry
                    throw FolmiFailure(message: error.localizedDescription + "\n\n不想要的话，点改动列表上方的「撤销拿回」。")
                }
                throw error
            }
        }
    }

    /// 撤销放回: the files go back to before the 放回 that stopped on conflicts; the stash is still on the list.
    func undoConflictedRestore() {
        guard let repository, let key = repositoryURL?.path, let entry = conflictedRestores[key] else { return }
        mutate("撤销拿回") { [weak self] in
            try await repository.undoConflictedRestore(stash: entry.id)
            await MainActor.run { _ = self?.conflictedRestores.removeValue(forKey: key) }
            return "这批文件回到了拿回之前。「\(entry.message)」仍在暂放列表。"
        }
    }

    /// The conflicts of a 放回 are resolved: the stash it came from can go (⌥⌘Z puts it back on the list).
    func finishConflictedRestore() {
        guard let key = repositoryURL?.path, let entry = conflictedRestores.removeValue(forKey: key) else { return }
        dropStash(entry)
    }

    /// 「放回」: the newest stash back, without opening the list first.
    func popLatestStash() {
        guard !busy, let repository, let root = repositoryURL else { return }
        Task { [weak self] in
            do {
                guard let latest = try await repository.stashes().first else { NSSound.beep(); return }
                guard let self, self.repositoryURL == root else { return }
                self.popStash(latest)
            } catch { self?.report(error, title: "读取暂放的改动失败") }
        }
    }

    /// Stashes older than this are offered for clean-up; so is a list that grew past `stashReminderCount`.
    static let staleStashAge: TimeInterval = 14 * 24 * 3600
    static let stashReminderCount = 3

    /// Deletes several stashes at once (the old ones); one ⌥⌘Z puts them all back on the list.
    func dropStashes(_ entries: [StashEntry]) {
        guard let repository, !entries.isEmpty else { return }
        mutate("删除 \(entries.count) 批暂放的改动") { [weak self] in
            var undo: [UndoStep] = []
            for entry in entries { undo.append(try await repository.dropStash(entry.id)) }
            let steps = undo
            await MainActor.run { self?.pushUndo("删除 \(entries.count) 批暂放的改动", .group(steps.reversed())) }
            return "已删除 \(entries.count) 批暂放的改动。⌥⌘Z 可以撤销删除。"
        } after: { [weak self] in self?.reloadStashesIfShown() }
    }

    /// Deletes a stash. ⌘Z puts it back on the list.
    func dropStash(_ entry: StashEntry) {
        guard let repository else { return }
        mutate("删除暂放的改动") { [weak self] in
            let undo = try await repository.dropStash(entry.id)
            await MainActor.run { self?.pushUndo("删除暂放的改动（\(entry.message)）", undo) }
            return "已删除：\(entry.message)。⌥⌘Z 可以撤销删除。"
        } after: { [weak self] in self?.reloadStashesIfShown() }
    }

    /// Revert or cherry-pick on a work tree with changes: put the changes aside first (one undo step), then apply
    /// the commit into the staging area (another). ⌘Z takes back the apply, then the stash.
    func stashThenApplyCommit(_ id: String, kind: GitRepository.ApplyKind) {
        guard let repository, let state = snapshot, !state.files.isEmpty else { applyCommit(id, kind: kind); return }
        if editorWorkspace?.hasUnsavedChanges == true {
            report(FolmiFailure(message: "编辑器里还有没保存的改动。先保存，再暂放。"), title: "仍有编辑草稿"); return
        }
        let verb = kind == .revert ? "撤回" : "挑选"
        // Named for why it exists, so in the list it does not read like something the user put aside on purpose.
        let message = "\(verb) \(id.prefix(7)) 前自动暂放 · " + defaultStashMessage
        let paths = commitDetail?.id == id && compareBaseID == nil ? (commitDetail?.files.map(\.path) ?? []) : []
        let title = "\(verb)提交 \(id.prefix(7))"
        mutate("先暂放改动再\(verb)") { [weak self] in
            let entry = try await repository.stashAll(message: message, expectedFingerprint: state.fingerprint)
            await MainActor.run { self?.pushUndo("暂放改动（\(message)）", .stash(.pop(object: entry.id))) }
            let clean = try await repository.load()
            let touched = paths.isEmpty ? try await repository.commitDetail(id).files.map(\.path) : paths
            let step = UndoStep.group([try await repository.captureIndex(touched), try await repository.captureWorktree(touched)])
            let staged: [String]
            do { staged = try await repository.applyCommit(id, kind: kind, expectedFingerprint: clean.fingerprint, intoWorkTree: true) }
            catch {
                throw FolmiFailure(message: "\(error.localizedDescription)\n\n原来的改动已经暂放，没有丢：在「暂放的改动」里拿回，或按 ⌥⌘Z。")
            }
            let after = try? await repository.recapture(step)
            let suggested = try await repository.suggestedMessage(for: id, kind: kind)
            await MainActor.run {
                guard let self else { return }
                self.pushUndo(title, step, expected: after)
                self.draftMessage = suggested
                self.area = .staged
                self.showSideTab(.changes)
            }
            return "原来的改动已暂放（\(message)）。\n已放进工作区：\(staged.count) 个文件，在逐个验收里看过、收下后再提交；之后在「暂放的改动」里拿回原来的改动。"
        }
    }
}

/// The list of stashes: what each holds, bring it back or delete it.
struct StashSheet: View {
    @Bindable var model: FolmiModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCleanup = false
    @State private var note = ""

    var body: some View {
        let _ = PerfLog.body("StashSheet")
        let changed = model.snapshot?.files.count ?? 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂放的改动").themedFont(.title3.weight(.semibold), points: 15)
                    Text("暂放、拿回和删除都可以用 ⌥⌘Z 撤销。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if changed > 0 {
                HStack {
                    TextField("备注（可不填）", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("stash-message")
                    stashButton("只暂放工作区", workingOnly: true)
                    stashButton("暂放全部改动", workingOnly: false)
                }
                .padding(10)
                .themedBackground(ThemeColor(token: .hover, opacity: 0.6), .control)
            }
            let stale = model.stashEntries.filter { Date().timeIntervalSince($0.date) > FolmiModel.staleStashAge }
            if !stale.isEmpty {
                HStack {
                    Label("有 \(stale.count) 批暂放超过 14 天了，多半已经用不上。", systemImage: "clock.badge.exclamationmark")
                        .themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .modified))
                    Spacer()
                    Button("删掉这 \(stale.count) 批") { confirmingCleanup = true }.disabled(model.busy)
                }
                .padding(10)
                .themedBackground(ThemeColor(token: .modified, opacity: 0.08), .control)
                .confirmationDialog("删掉 \(stale.count) 批超过 14 天的暂放改动？", isPresented: $confirmingCleanup) {
                    Button("删掉", role: .destructive) { model.dropStashes(stale) }
                } message: { Text("⌥⌘Z 可以一次全部撤销。") }
            }
            if model.stashEntries.isEmpty {
                Text("还没有暂放的改动。").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.stashEntries) { entry in
                            StashRow(model: model, entry: entry, plan: model.stashPlans[entry.id])
                        }
                    }
                    .motion(Motion.reveal, value: model.stashEntries.map(\.id))
                }
                .frame(maxHeight: 480)
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
        }
        .padding(22)
        .frame(width: 730)
        .onChange(of: model.snapshot.map { "\($0.fingerprint) \($0.stashCount ?? 0)" }) { _, _ in
            Task { await model.loadStashes() }
        }
        .onChange(of: model.snapshot?.stashCount) { previous, current in
            if let current, current > previous ?? 0 { note = "" }
        }
    }

    private func stashButton(_ title: String, workingOnly: Bool) -> some View {
        let blocker = model.stashBlocker(workingOnly: workingOnly)
        return BusyButton(title, busy: model.busy) {
            model.stashChanges(message: note, workingOnly: workingOnly)
        }
        .disabled(model.busy || blocker != nil)
        .help(blocker ?? (workingOnly ? "暂存区保持原样；新文件也会暂放。" : "工作区、暂存区和新文件一起暂放。"))
    }
}

private struct StashRow: View {
    let model: FolmiModel
    let entry: StashEntry
    let plan: StashRestorePlan?
    @State private var hovering = false
    @State private var expanded = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded, let plan, let repository = model.repository {
                StashFilePreview(repository: repository, files: plan.files, layout: model.diffLayout)
            }
        }
        .padding(10)
        .themedBackground(ThemeColor(token: .hover, opacity: hovering ? 1 : 0.55), .control)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .task(id: plan == nil) {
            if plan == nil { await model.loadStashPlan(entry.id) }
        }
        .confirmationDialog("删除这批暂放的改动？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { model.dropStash(entry) }
        } message: { Text("「\(entry.message)」会从列表里删除。⌥⌘Z 可撤销。") }
    }

    private var header: some View {
        let conflicts = plan?.conflicts ?? []
        let blocker = model.editorWorkspace?.hasUnsavedChanges == true ? "先保存编辑器里的改动。" : plan?.blocker
        return HStack(alignment: .top, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                    title
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            Spacer(minLength: 8)
            QuietButton(title: "删除") { confirmingDelete = true }.disabled(model.busy)
            BusyButton(conflicts.isEmpty ? "拿回" : "仍然拿回", busy: model.busy) { model.popStash(entry) }
                .buttonStyle(.folmiProminent).controlSize(.small)
                .disabled(model.busy || blocker != nil || plan == nil)
                .help(blocker ?? "拿回这批改动，再从暂放列表移除。")
        }
    }

    private var title: some View {
        let conflicts = plan?.conflicts ?? []
        let detail = plan?.blocker ?? (conflicts.isEmpty ? nil : "拿回会有冲突：" + conflicts.prefix(3).joined(separator: "、"))
        return VStack(alignment: .leading, spacing: 3) {
            Text(entry.message).themedFont(.system(size: 12.5, weight: .medium), points: 12.5).lineLimit(1)
            Text([entry.branch.isEmpty ? nil : entry.branch, entry.date.formatted(.relative(presentation: .named)),
                  plan.map { "\($0.files.count) 个文件" }].compactMap { $0 }.joined(separator: " · "))
                .themedFont(.caption, points: 10).foregroundStyle(.secondary)
            if let detail {
                Label(detail, systemImage: "exclamationmark.triangle")
                    .themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .modified))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StashFilePreview: View {
    let repository: GitRepository
    let files: [StashedFile]
    let layout: DiffLayout
    @State private var selection: String?
    @State private var diff: FileDiff?
    @State private var error: String?

    private var file: StashedFile? { files.first { $0.id == selection } ?? files.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { item in
                        Button { selection = item.id } label: {
                            HStack(spacing: 6) {
                                Text(item.change.status).foregroundStyle(HistoryView.statusColor(item.change.status)).frame(width: 14)
                                Text(item.id).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .themedFont(.system(size: 11, design: .monospaced), points: 11)
                            .padding(.horizontal, 6).frame(height: 24)
                            .background(ThemeColor(token: .accent, opacity: item.id == file?.id ? 0.16 : 0))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: CGFloat(min(files.count, 5)) * 24)
            if file != nil {
                Divider()
                GeometryReader { geometry in
                    ScrollView {
                        if let diff, diff.file.path == file?.id {
                            SideBySideFile.history(diff, sideTitles: ("暂放前的基准", "暂放的版本"),
                                                   unified: layout.usesUnified(width: geometry.size.width),
                                                   columnWidth: max(180, (geometry.size.width - 1) / 2))
                                .id(diff.fingerprint)
                        } else if let error {
                            Text(error).themedFont(.caption, points: 10).foregroundStyle(.secondary).padding(10)
                        } else {
                            WaitingIndicator().controlSize(.small).padding(10)
                        }
                    }
                }.frame(height: 245)
            }
        }
        .task(id: file?.id) {
            diff = nil; error = nil
            guard let file else { return }
            do {
                let loaded = try await repository.stashDiff(file)
                if !Task.isCancelled { diff = loaded }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

/// Shown above the change list when files hold conflicts outside a rebase or merge (a 放回 that hit conflicts), and
/// once they are resolved while the stash is still on the list.
struct RestoreConflictNotice: View {
    let model: FolmiModel
    @State private var confirming = false

    var body: some View {
        let conflicts = model.snapshot?.files.filter(\.isConflict).count ?? 0
        let entry = model.repositoryURL.flatMap { model.conflictedRestores[$0.path] }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ThemeColor(token: .modified))
                Text(conflicts > 0 ? "拿回时有冲突" : "拿回的冲突解决了").themedFont(.system(size: 12.5, weight: .semibold), points: 12.5)
            }
            Text(conflicts > 0
                 ? "\(conflicts) 个文件带着冲突标记。解决后暂存即可；不想要了就撤销拿回，文件回到拿回之前，暂放的改动仍在列表里。"
                 : "暂放的改动「\(entry?.message ?? "")」还留在列表里，可以删掉了。")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if conflicts > 0 {
                    Button("撤销拿回") { confirming = true }.buttonStyle(.folmiProminent).controlSize(.small)
                        .disabled(model.busy || entry == nil)
                        .help(entry == nil ? "找不到对应的暂放记录。" : "撤回这批暂放涉及的文件。")
                } else {
                    BusyButton("删掉那份暂放的改动", busy: model.busy, action: model.finishConflictedRestore).buttonStyle(.folmiProminent).controlSize(.small).disabled(model.busy)
                    Button("留着") { if let root = model.repositoryURL { model.conflictedRestores.removeValue(forKey: root.path) } }.controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedBackground(ThemeColor(token: .modified, opacity: 0.08), .control)
        .overlay(RoundedRectangle(cornerRadius: model.theme.style.radius(.control), style: .continuous)
            .strokeBorder(ThemeColor(token: .modified, opacity: 0.35)))
        .confirmationDialog("撤销拿回？", isPresented: $confirming) {
            Button("撤销拿回", role: .destructive, action: model.undoConflictedRestore)
        } message: {
            Text("这批涉及的已跟踪文件会回到当前提交，已经解决的冲突也会撤回。暂放记录会留在列表里。")
        }
    }
}
