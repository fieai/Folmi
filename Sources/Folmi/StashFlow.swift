import SwiftUI
import FolmiCore

/// 临时收起改动: everything (untracked included) put aside in one step and brought back later, each step undoable.
extension FolmiModel {
    /// A name that says what is inside: the first few files.
    var defaultStashMessage: String {
        let files = snapshot?.files.map { ($0.path as NSString).lastPathComponent } ?? []
        let names = files.prefix(3).joined(separator: "、") + (files.count > 3 ? " 等" : "")
        return "\(files.count) 个文件：\(names)"
    }

    func stashAllChanges() {
        guard let repository, let state = snapshot, !state.files.isEmpty else { return }
        if editorWorkspace?.hasUnsavedChanges == true {
            report(FolmiFailure(message: "编辑器里还有没保存的改动。先保存，再暂放，否则它们不会一起暂放。"), title: "仍有编辑草稿"); return
        }
        let message = defaultStashMessage
        mutate("暂放改动") { [weak self] in
            let entry = try await repository.stashAll(message: message, expectedFingerprint: state.fingerprint)
            await MainActor.run { self?.pushUndo("暂放改动（\(message)）", .stash(.pop(object: entry.id))) }
            return "已暂放：\(message)。工作区和暂存区现在是干净的；在改动列表下方的「暂放的改动」里拿回，或按 ⌥⌘Z。"
        } after: { [weak self] in self?.reloadStashesIfShown() }
    }

    func openStashes() {
        guard snapshot != nil else { return }
        showStashes = true
        Task { await loadStashes() }
    }

    func loadStashes() async {
        guard let repository, let root = repositoryURL else { return }
        do {
            let list = try await repository.stashes()
            var files: [String: [String]] = [:], conflicts: [String: [String]] = [:]
            for entry in list.prefix(30) {
                files[entry.id] = try? await repository.stashFiles(entry.id)
                conflicts[entry.id] = try? await repository.stashConflicts(entry.id)
            }
            guard repositoryURL == root else { return }
            stashEntries = list; stashFileLists = files; stashConflictLists = conflicts
        } catch { report(error, title: "读取暂放的改动失败") }
    }

    private func reloadStashesIfShown() {
        if showStashes { Task { await loadStashes() } }
    }

    /// Brings a stash back (staged parts staged again) and takes it off the list. ⌘Z puts it aside again.
    func popStash(_ entry: StashEntry) {
        guard let repository, let state = snapshot else { return }
        let key = repositoryURL?.path ?? state.root.path
        mutate("拿回暂放的改动") { [weak self] in
            do { try await repository.popStash(entry.id, expectedFingerprint: state.fingerprint) } catch {
                // Conflicts were written into the files; the notice above the change list offers the way back.
                if try await repository.load().files.contains(where: \.isConflict) {
                    await MainActor.run { self?.conflictedRestores[key] = entry }
                    throw FolmiFailure(message: error.localizedDescription + "\n\n不想要的话，点改动列表上方的「撤销拿回」，文件回到拿回之前。")
                }
                throw error
            }
            await MainActor.run { self?.pushUndo("拿回暂放的改动（\(entry.message)）", .stash(.push(message: entry.message))) }
            return "已恢复：\(entry.message)"
        } after: { [weak self] in
            guard let self else { return }
            self.reloadStashesIfShown()
            if self.snapshot?.files.isEmpty == false { self.showSideTab(.changes) }
        }
    }

    /// 撤销放回: the files go back to before the 放回 that stopped on conflicts; the stash is still on the list.
    func undoConflictedRestore() {
        guard let repository, let key = repositoryURL?.path else { return }
        let entry = conflictedRestores[key]
        mutate("撤销拿回") { [weak self] in
            try await repository.undoConflictedRestore(stash: entry?.id)
            await MainActor.run { _ = self?.conflictedRestores.removeValue(forKey: key) }
            return "文件回到了拿回之前。" + (entry.map { "「\($0.message)」还在暂放的改动里。" } ?? "")
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

    var body: some View {
        let _ = PerfLog.body("StashSheet")
        let changed = model.snapshot?.files.count ?? 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂放的改动").themedFont(.title3.weight(.semibold), points: 15)
                    Text("把手上的改动（包括新文件）先放到一边，工作区变干净，之后再原样拿回来。拿回、删除都能用 ⌥⌘Z 撤销。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if changed > 0 {
                HStack {
                    Text("现在有 \(changed) 个文件的改动").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    Spacer()
                    BusyButton("暂放全部改动", busy: model.busy, action: model.stashAllChanges).disabled(model.busy)
                        .help("包括没跟踪的新文件；暂存过的部分恢复时仍是暂存的")
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
                    VStack(spacing: 8) {
                        ForEach(model.stashEntries) { entry in
                            StashRow(model: model, entry: entry, files: model.stashFileLists[entry.id],
                                     conflicts: model.stashConflictLists[entry.id], canRestore: !hasTrackedChanges)
                        }
                    }
                    .motion(Motion.reveal, value: model.stashEntries.map(\.id))
                }
                .frame(maxHeight: 360)
                if hasTrackedChanges {
                    Text("工作区或暂存区有改动时不能拿回：先提交或暂放它们，免得混在一起。")
                        .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private var hasTrackedChanges: Bool { model.snapshot?.files.contains { !$0.isUntracked } ?? false }
}

private struct StashRow: View {
    let model: FolmiModel
    let entry: StashEntry
    let files: [String]?
    /// Files that would conflict with the current commit; nil while not worked out yet.
    let conflicts: [String]?
    let canRestore: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.full").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.message).themedFont(.system(size: 12.5, weight: .medium), points: 12.5).lineLimit(1).truncationMode(.tail)
                Text([entry.branch.isEmpty ? nil : entry.branch, entry.date.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " · "))
                    .themedFont(.caption, points: 10).foregroundStyle(.secondary)
                if let files, !files.isEmpty {
                    Text(files.prefix(4).joined(separator: "  ") + (files.count > 4 ? "  …共 \(files.count) 个" : ""))
                        .themedFont(.caption.monospaced(), points: 10).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if let conflicts, !conflicts.isEmpty {
                    Label("拿回会和当前代码冲突：" + conflicts.prefix(3).joined(separator: "、") + (conflicts.count > 3 ? " 等 \(conflicts.count) 个" : ""),
                          systemImage: "exclamationmark.triangle")
                        .themedFont(.caption, points: 10).foregroundStyle(ThemeColor(token: .modified))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help("这批改动是在更早的代码上做的，之后同样的地方又被改过。拿回后要解决冲突，或者撤销拿回。")
                }
            }
            Spacer(minLength: 8)
            QuietButton(title: "删除") { model.dropStash(entry) }
                .disabled(model.busy)
                .help("从列表里删掉（⌥⌘Z 可以撤销删除）")
            let clashes = !(conflicts ?? []).isEmpty
            BusyButton(clashes ? "仍然拿回" : "拿回", busy: model.busy) { model.popStash(entry) }
                .buttonStyle(.folmiProminent).controlSize(.small)
                .disabled(model.busy || !canRestore)
                .help(canRestore ? "把这些改动拿回工作区（暂存过的仍是暂存的），并从列表里拿掉" : "先提交或暂放现有改动")
        }
        .padding(10)
        .themedBackground(ThemeColor(token: .hover, opacity: hovering ? 1 : 0.55), .control)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
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
                    Button("撤销拿回") { confirming = true }.buttonStyle(.folmiProminent).controlSize(.small).disabled(model.busy)
                        .help("已跟踪的文件回到当前提交，拿回带出来的新文件删掉；暂放的改动不受影响")
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
            Text("已跟踪文件里的改动（包括你刚解决的冲突）都会回到当前提交。暂放的改动还在列表里，随时可以再拿回。")
        }
    }
}
