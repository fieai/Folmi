import AppKit
import Foundation
import FolmiCore

/// One Git action that ⌘Z can take back: what it was called and what it changed.
struct UndoEntry {
    let id = UUID()
    let title: String
    let step: UndoStep
    /// The touched paths right after the action; undo refuses when they changed since, instead of overwriting.
    var expected: UndoStep?
    /// Review keys the action marked seen (a ⏎ on the review page): undo takes them back, redo marks them again, so
    /// the count follows the change it belongs to.
    var seenKeys: Set<String> = []
}

/// A ⏎ on the review page that went through.
struct RecentAccept: Equatable {
    let id = UUID()
    let path: String
    let scope: String
}

struct DiscardPrompt {
    let title: String
    let message: String
    let action: String
    let confirm: () -> Void
}

/// The commit message the app writes while the user reviews.
enum CommitSuggestion: Equatable {
    case idle
    case generating
    /// Filled into the draft; `source` names the model.
    case ready(source: String)
    /// Not sent: why (secrets found, nothing staged, no model configured).
    case skipped(String)
    case failed(String)
}

/// Today at a glance, for the "all done" state.
struct DaySummary: Equatable {
    var commitsToday: Int
    var unpushed: Int?
    var behind: Int?
    var hasUpstream: Bool
}

extension FolmiModel {
    // MARK: Undo

    private var projectKey: String { repositoryURL?.path ?? "" }

    func pushUndo(_ title: String, _ step: UndoStep, expected: UndoStep? = nil) {
        guard !projectKey.isEmpty else { return }
        undoStacks[projectKey, default: []].append(UndoEntry(title: title, step: step, expected: expected))
        if undoStacks[projectKey]!.count > 50 { undoStacks[projectKey]!.removeFirst() }
        redoStacks[projectKey] = []
        syncUndoLabels()
    }
    func syncUndoLabels() {
        let undo = undoStacks[projectKey]?.last?.title, redo = redoStacks[projectKey]?.last?.title
        if undoLabel != undo { undoLabel = undo }
        if redoLabel != redo { redoLabel = redo }
    }
    func undoGitOperation() {
        if undoLabel != nil { completeTour(.undo) }
        stepHistory(undo: true)
    }
    func redoGitOperation() { stepHistory(undo: false) }

    private func stepHistory(undo: Bool) {
        let key = projectKey
        // The entry stays on its stack until the undo went through: a refused undo can be retried once the conflict
        // is sorted out, and what it would restore is not lost.
        guard !busy, let repository, let entry = (undo ? undoStacks : redoStacks)[key]?.last else {
            NSSound.beep(); return
        }
        if case .branchSwitch = entry.step, let blocker = branchSwitchBlocker {
            errorMessage = blocker
            return
        }
        mutate(undo ? "撤销：\(entry.title)" : "重做：\(entry.title)") { [weak self] in
            if let expected = entry.expected, try await repository.recapture(expected) != expected {
                throw FolmiFailure(message: "「\(entry.title)」之后这些文件又被改过（终端、编辑器或其他工具），撤销会覆盖那些改动，所以没有执行：\n"
                                       + entry.step.paths.joined(separator: "\n") + "\n\n这一步还留着：处理好这些文件后可以再撤销一次。")
            }
            let inverse = try await repository.undo(entry.step)
            let expected = try? await repository.recapture(inverse)
            await MainActor.run {
                guard let self else { return }
                if undo { self.undoStacks[key]?.removeAll { $0.id == entry.id } } else { self.redoStacks[key]?.removeAll { $0.id == entry.id } }
                let next = UndoEntry(title: entry.title, step: inverse, expected: expected, seenKeys: entry.seenKeys)
                if undo { self.redoStacks[key, default: []].append(next) } else { self.undoStacks[key, default: []].append(next) }
                self.syncUndoLabels()
                if !entry.seenKeys.isEmpty {
                    var ledger = self.reviewLedger
                    if undo { ledger.remove(Array(entry.seenKeys)) } else { entry.seenKeys.forEach { ledger.insert($0) } }
                    if ledger != self.reviewLedger { self.reviewLedger = ledger; self.scheduleSave() }
                }
                self.lastAccept = nil
                self.reviewFocusAfterUndo = (entry.step.paths, Date())
            }
            return entry.step.paths.joined(separator: "\n")
        }
    }

    /// Runs a Git change that ⌘Z can take back: `capture` records what it will touch, right before it runs.
    func mutateUndoable(_ title: String, clearDraft: Bool = false, capture: @escaping () async throws -> UndoStep,
                        succeeded: (() -> Void)? = nil, after: (() -> Void)? = nil, operation: @escaping () async throws -> String) {
        mutate(title, clearDraft: clearDraft, operation: { [weak self] in
            guard let repository = await MainActor.run(body: { self?.repository }) else { return "" }
            let step = try await capture()
            let output = try await operation()
            let after = try? await repository.recapture(step)
            await MainActor.run { self?.pushUndo(title, step, expected: after) }
            return output
        }, succeeded: succeeded, after: after)
    }

    /// For operations that capture their undo inside the same repository call as the change.
    func mutateUndoable(_ title: String, succeeded: (() -> Void)? = nil, after: (() -> Void)? = nil,
                        operation: @escaping () async throws -> (UndoStep, String)) {
        guard let repository else { return }
        mutate(title, operation: { [weak self] in
            let (step, output) = try await operation()
            let expected = try? await repository.recapture(step)
            self?.pushUndo(title, step, expected: expected)
            return output
        }, succeeded: succeeded, after: after)
    }

    // MARK: Review progress

    /// Keys of every staged line right now, the same keys the review uses (see `ReviewProgress.stagedHunks`).
    func stagedLineKeys() async -> Set<String> {
        guard let repository, let patch = try? await repository.stagedPatch(limit: 4_000_000).patch else { return [] }
        return Set(ReviewProgress.stagedHunks(patch: patch).flatMap(\.keys))
    }

    /// Staging from Folmi (a checkbox, 全部暂存, a hunk or lines) is the user's own 收下: what it added to the index
    /// counts as seen, so only what went in some other way (an agent's or the terminal's `git add`, a merge) shows
    /// as 没验收. The keys ride on the undo entry the staging just pushed, so ⌘Z takes the mark back with it.
    func markStaged(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        var ledger = reviewLedger
        keys.forEach { ledger.insert($0) }
        if ledger != reviewLedger { reviewLedger = ledger; scheduleSave() }
        if let last = undoStacks[projectKey]?.indices.last { undoStacks[projectKey]![last].seenKeys.formUnion(keys) }
    }

    func loadReviewLedger() {
        let saved = repositoryURL.flatMap { savedProject($0.path) }?.reviewedLines ?? []
        reviewLedger = ReviewLedger(saved)
    }
    /// Line keys of a diff, counted together with the same file's staged lines (see `ReviewProgress`).
    func reviewKeys(_ diff: FileDiff) -> [Int: String] {
        let staged = diff.area == .working ? allChanges.first { $0.area == .staged && $0.file.path == diff.file.path } : nil
        return ReviewKeyCache.keys(diff, staged: staged)
    }
    func isSeen(_ hunk: DiffHunk, in diff: FileDiff) -> Bool {
        reviewLedger.containsAll(ReviewProgress.hunkKeys(hunk, in: reviewKeys(diff)))
    }
    func markSeen(_ hunk: DiffHunk, in diff: FileDiff, seen: Bool = true) {
        let list = ReviewProgress.hunkKeys(hunk, in: reviewKeys(diff))
        var ledger = reviewLedger
        if seen { list.forEach { ledger.insert($0) } } else { ledger.remove(list) }
        if ledger != reviewLedger { reviewLedger = ledger; scheduleSave() }
    }
    func markFileSeen(_ diff: FileDiff, seen: Bool = true) {
        if let key = ReviewProgress.fileKey(diff) {
            var ledger = reviewLedger
            if seen { ledger.insert(key) } else { ledger.remove([key]) }
            if ledger != reviewLedger { reviewLedger = ledger; scheduleSave() }
            return
        }
        for hunk in diff.hunks { markSeen(hunk, in: diff, seen: seen) }
    }
    func isFileSeen(_ diff: FileDiff) -> Bool {
        if let key = ReviewProgress.fileKey(diff) { return reviewLedger.contains(key) }
        return diff.hunks.allSatisfy { isSeen($0, in: diff) }
    }
    /// ⏎ on a whole file (folded, new, binary): stage it and mark it seen once the stage went through. A file without
    /// hunks here (new, binary) becomes a staged diff of its own, which is marked too, so one ⏎ is enough.
    func acceptFile(_ diff: FileDiff) {
        guard diff.area == .working else {
            recordFileDecision(.accept, diff); acceptedReview(diff, scope: "整个文件", undoable: false) { self.markFileSeen(diff) }; return
        }
        let path = diff.file.path
        var staged = false
        stageFile(diff.file, succeeded: { [weak self] in
            staged = true
            self?.recordFileDecision(.accept, diff)
            self?.acceptedReview(diff, scope: "整个文件", undoable: true) {
                self?.markFileSeen(diff)
                // Marked before the reload, so the staged hunk never shows up as unseen in between.
                if diff.file.isUntracked { self?.markSeen(keys: ReviewProgress.stagedKeys(newFile: path, text: diff.rawPatch)) }
            }
        }, after: { [weak self] in
            // Binary and empty files have no lines to predict: mark their staged diff once it has loaded.
            guard staged, diff.hunks.isEmpty, let self,
                  let added = self.allChanges.first(where: { $0.area == .staged && $0.file.path == path }) else { return }
            self.markFileSeen(added)
        })
    }
    /// ⌫ on a whole file: a staged file goes back to the work tree; a work-tree file needs confirmation.
    func rejectFile(_ diff: FileDiff, succeeded: (() -> Void)? = nil) {
        if diff.area == .staged {
            unstageFile(diff.file) { [weak self] in
                self?.recordDaily(.rejected)
                self?.recordFileDecision(.reject, diff)
                succeeded?()
            }
        } else {
            askDiscardFiles([diff.file], diff: diff, succeeded: succeeded)
        }
    }
    var reviewTally: ReviewTally { ReviewTally.make(allChanges, ledger: reviewLedger, keys: ReviewKeyCache.keys) }

    /// A ⏎ that went through: the count, the tour step and the marks it carries. When it changed Git (`undoable`),
    /// the keys it marked ride on that undo entry, so ⌘Z puts the change back as unseen too.
    private func acceptedReview(_ diff: FileDiff, scope: String, undoable: Bool, _ mark: () -> Void) {
        recordDaily(.accepted); completeTour(.accept)
        let before = reviewLedger.keys
        mark()
        let added = reviewLedger.keys.subtracting(before)
        if undoable, !added.isEmpty, let last = undoStacks[projectKey]?.indices.last { undoStacks[projectKey]![last].seenKeys.formUnion(added) }
        lastAccept = RecentAccept(path: diff.file.path, scope: scope)
    }
    /// Marks keys seen that were read before a Git change (after it, the same lines may sit in another diff).
    private func markSeen(keys list: [String]) {
        var ledger = reviewLedger
        list.forEach { ledger.insert($0) }
        if ledger != reviewLedger { reviewLedger = ledger; scheduleSave() }
    }

    /// ⏎ on the review page: this hunk is fine. A work-tree hunk is staged; a staged one is only marked. Nothing is
    /// marked or counted until the stage went through.
    func acceptHunk(_ hunk: DiffHunk, in diff: FileDiff) {
        let keys = ReviewProgress.hunkKeys(hunk, in: reviewKeys(diff))
        let decided: () -> Void = { [weak self] in self?.recordDecision(.accept, scope: .hunk, path: diff.file.path, lines: hunk.lines) }
        guard diff.area == .working else { decided(); acceptedReview(diff, scope: "这处", undoable: false) { markSeen(keys: keys) }; return }
        guard let repository else { return }
        if diff.file.isUntracked || !diff.isPartialSupported {
            stageFile(diff.file) { [weak self] in decided(); self?.acceptedReview(diff, scope: "整个文件", undoable: true) { self?.markSeen(keys: keys) } }
            return
        }
        let path = diff.file.path
        mutateUndoable("暂存 \(path)", capture: { try await repository.captureIndex([path]) },
                       succeeded: { [weak self] in decided(); self?.acceptedReview(diff, scope: "这处", undoable: true) { self?.markSeen(keys: keys) } }) {
            try await repository.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: nil)
            return "\(path)\n\(hunk.header)"
        }
    }
    /// ⏎ with lines picked in a hunk: only those lines are staged (a staged hunk's are only confirmed) and marked
    /// seen; the rest of the hunk stays to review.
    func acceptSelection(_ hunk: DiffHunk, in diff: FileDiff) {
        let selected = allChangesSelected(in: hunk, of: diff)
        guard !selected.isEmpty else { acceptHunk(hunk, in: diff); return }
        let lineKeys = reviewKeys(diff)
        let keys = hunk.lines.filter { selected.contains($0.id) }.compactMap { lineKeys[$0.id] }
        let chosen = hunk.lines.filter { selected.contains($0.id) }
        let decided: () -> Void = { [weak self] in self?.recordDecision(.accept, scope: .lines, path: diff.file.path, lines: chosen) }
        // Staged lines are already where ⏎ would put them: confirming them changes nothing in Git.
        let scope = "选中的 \(chosen.filter { $0.kind == .addition || $0.kind == .deletion }.count) 行"
        guard diff.area == .working else {
            decided()
            acceptedReview(diff, scope: scope, undoable: false) { markSeen(keys: keys) }
            allChangesSelection[diff.allChangesKey]?.subtract(selected)
            return
        }
        apply(hunk, diff: diff, selected: selected) { [weak self] in decided(); self?.acceptedReview(diff, scope: scope, undoable: true) { self?.markSeen(keys: keys) } }
    }
    func rejectSelection(_ hunk: DiffHunk, in diff: FileDiff, confirm: Bool = false, succeeded: (() -> Void)? = nil) {
        let selected = allChangesSelected(in: hunk, of: diff)
        let lines = selected.isEmpty ? nil : selected
        if confirm, diff.area == .working {
            askDiscardHunk(hunk, in: diff, selected: lines, succeeded: succeeded)
        } else {
            rejectHunk(hunk, in: diff, selected: lines, succeeded: succeeded)
        }
    }

    /// A staged hunk or selection goes back to the work tree, preserving its contents.
    func rejectHunk(_ hunk: DiffHunk, in diff: FileDiff, selected: Set<Int>? = nil, succeeded: (() -> Void)? = nil) {
        guard let repository else { return }
        let path = diff.file.path
        let lines = selected.map { ids in hunk.lines.filter { ids.contains($0.id) } } ?? hunk.lines
        let counted: () -> Void = { [weak self] in
            self?.recordDaily(.rejected)
            self?.recordDecision(.reject, scope: selected == nil ? .hunk : .lines, path: path, lines: lines)
            succeeded?()
        }
        if diff.area == .staged {
            guard diff.isPartialSupported else { unstageFile(diff.file, succeeded: counted); return }
            mutateUndoable("取消暂存 \(path)", capture: { try await repository.captureIndex([path]) }, succeeded: counted) {
                try await repository.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: selected)
                return "\(path)\n\(hunk.header)"
            }
            return
        }
        if !diff.isPartialSupported { askDiscardFiles([diff.file], diff: diff, succeeded: succeeded); return }
        let scope = selected.map { "选中的 \($0.count) 行" } ?? "一处改动"
        mutateUndoable("丢弃 \(path) 的\(scope)", succeeded: counted) {
            let step = try await repository.discard(diff: diff, hunkID: hunk.id, selectedLineIDs: selected)
            return (step, "\(path)\n\(hunk.header)")
        }
    }

    func discardBlocker(_ files: [FileChange]) -> String? {
        if files.contains(where: \.isConflict) { return "先解决冲突，再丢弃改动。" }
        if files.contains(where: \.isSubmodule) { return "请在子模块里处理这些改动。" }
        let paths = Set(files.flatMap { [$0.path] + ($0.worktreeCode == "R" ? [$0.originalPath].compactMap { $0 } : []) })
        if editorWorkspace?.documents.contains(where: { $0.isDirty && paths.contains($0.id) }) == true {
            return "编辑器里还有没保存的改动，先保存。"
        }
        return nil
    }

    func askDiscardHunk(_ hunk: DiffHunk, in diff: FileDiff, selected: Set<Int>? = nil, succeeded: (() -> Void)? = nil) {
        guard !busy, diff.area == .working, discardBlocker([diff.file]) == nil else { return }
        guard diff.isPartialSupported else { askDiscardFiles([diff.file], diff: diff, succeeded: succeeded); return }
        let root = repositoryURL
        let scope = selected.map { "选中的 \($0.count) 行" } ?? "这一处改动"
        discardPrompt = DiscardPrompt(title: "丢弃\(scope)？", message: "\(diff.file.path)\n\n⌥⌘Z 可撤销。", action: "丢弃") { [weak self] in
            guard let self, self.repositoryURL == root, self.discardBlocker([diff.file]) == nil else { return }
            self.rejectHunk(hunk, in: diff, selected: selected, succeeded: succeeded)
        }
    }

    func askDiscardFiles(_ files: [FileChange], diff: FileDiff? = nil, succeeded: (() -> Void)? = nil) {
        guard !busy, !files.isEmpty, let repository, let state = snapshot, discardBlocker(files) == nil else { return }
        let new = files.filter(\.isNewInWorktree).count
        let action = new == files.count ? "删除新文件" : "丢弃改动"
        let title = files.count == 1 ? files[0].path : "\(files.count) 个文件"
        var message = files.prefix(6).map(\.path).joined(separator: "\n")
        if files.count > 6 { message += "\n另有 \(files.count - 6) 个文件" }
        if new > 0 { message += "\n\n会删除 \(new) 个新文件。" }
        if new < files.count { message += "\n\n已跟踪文件会恢复到暂存区里的样子。" }
        message += "\n\n⌥⌘Z 可撤销。"
        discardPrompt = DiscardPrompt(title: "\(action)？", message: message, action: action) { [weak self] in
            guard let self, self.repository === repository, self.discardBlocker(files) == nil else { return }
            self.mutateUndoable("\(action) · \(title)", succeeded: { [weak self] in
                for file in files {
                    self?.recordDaily(.rejected)
                    self?.recordDecision(.reject, scope: .file, path: file.path, lines: diff?.hunks.flatMap(\.lines) ?? [])
                }
                succeeded?()
            }) {
                let step = try await repository.discardFiles(files, expectedFingerprint: state.fingerprint)
                return (step, files.map(\.path).joined(separator: "\n"))
            }
        }
    }

    // MARK: Commit message

    /// Writes a commit message for what is staged, in the background, when the staged set changed and the user has
    /// not typed their own. Nothing is sent when the staged text looks like it holds a secret.
    /// `settled`: the review just finished; the slower local `claude` CLI only runs then or when asked (`force`).
    func scheduleCommitSuggestion(force: Bool = false, settled: Bool = false) {
        guard aiSettings.autoCommitMessage || force, let repository, let snapshot, !amendLast else { return }
        let staged = snapshot.files.filter(\.hasStaged)
        guard !staged.isEmpty else {
            suggestionTask?.cancel(); suggestionKey = nil
            if commitSuggestion != .idle { commitSuggestion = .idle }
            if let autoDraft, draftMessage == autoDraft { draftMessage = ""; self.autoDraft = nil }
            return
        }
        let userTyped = !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftMessage != autoDraft
        guard force || !userTyped else { return }
        let key = snapshot.fingerprint + staged.map { $0.path + $0.indexCode }.joined()
        guard force || key != suggestionKey else { return }
        suggestionKey = key
        suggestionTask?.cancel()
        let client = AIClient.client(for: .commitMessage, project: repositoryURL?.path, settings: aiSettings)
        guard client.isAvailable else { commitSuggestion = .idle; suggestionKey = nil; return }
        guard !client.isCLI || force || settled else { suggestionKey = nil; return }
        if let sensitive = staged.first(where: { SecretScan.isSensitivePath($0.path) }) {
            commitSuggestion = .skipped("暂存了 \(sensitive.path)，没有发给 AI"); return
        }
        commitSuggestion = .generating
        let root = repositoryURL
        suggestionTask = Task { [weak self] in
            // Waits for the review to settle: every ⏎ stages a little more.
            do { try await Task.sleep(for: force ? .zero : .milliseconds(1_200)) } catch { return }
            do {
                let staged = try await repository.stagedPatch()
                if let finding = SecretScan.findings(in: staged.patch).first {
                    await MainActor.run { self?.commitSuggestion = .skipped("暂存内容疑似含密钥（\(finding)），没有发给 AI") }
                    return
                }
                let chinese = staged.subjects.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
                let user = "Recent commit subjects:\n" + (staged.subjects.isEmpty ? "<none>" : staged.subjects.joined(separator: "\n"))
                    + "\n\nStat:\n" + staged.stat + "\nStaged diff:\n" + staged.patch
                let text = try await client.complete(system: AIPrompts.commitMessage(chinese: chinese, conventional: AIPrompts.usesConventionalCommits(staged.subjects)),
                                                    user: user, maxTokens: 600)
                let message = Self.cleanCommitMessage(text)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self, self.repositoryURL == root, self.suggestionKey == key, !message.isEmpty else { return }
                    let typed = !self.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && self.draftMessage != self.autoDraft
                    if !typed || force { self.draftMessage = message; self.autoDraft = message }
                    self.commitSuggestion = .ready(source: client.sourceName)
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard let self, self.suggestionKey == key else { return }
                    self.commitSuggestion = .failed(error.localizedDescription)
                }
            }
        }
    }
    nonisolated static func cleanCommitMessage(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.hasPrefix("```") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The review page's last ⏎: commit what is staged with the written message.
    func commitFromReview() {
        guard canCommit else { NSSound.beep(); return }
        commit()
    }

    // MARK: Day summary

    var daySummary: DaySummary? {
        guard let snapshot else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let today = snapshot.commits.filter { ($0.date ?? .distantPast) >= start }.count
        return DaySummary(commitsToday: today, unpushed: snapshot.unpushed.map { _ in unpushedCount }, behind: snapshot.behind, hasUpstream: snapshot.upstream != nil)
    }
    /// Nothing left locally or in the known upstream state: clean worktree, no pending push/pull and no stash.
    /// Upstream counts reflect the local tracking branch from the most recent fetch.
    var isAllDone: Bool {
        guard let snapshot, snapshot.files.isEmpty else { return false }
        // Commits up for review on Gerrit are done on this side: they wait on the reviewers, not on you.
        return unpushedCount == 0 && (snapshot.behind ?? 0) == 0 && stashedCount == 0
    }
    var stashedCount: Int { snapshot?.stashCount ?? 0 }
    /// The 差异 page carries the wrap-up card when it is on screen; the 改动 tab then keeps quiet instead of repeating it.
    var diffPageShowsWrapUp: Bool {
        content == .diff && paneLayout.isShown(.editor) && paneLayout.isShown(.changes)
    }

    // MARK: Diff cache

    func cachedDiff(_ file: FileChange, area: ChangeArea) -> FileDiff? {
        guard let fingerprint = snapshot?.fingerprint else { return nil }
        if diffCacheFingerprintValue != fingerprint { diffCache = [:]; diffCacheFingerprintValue = fingerprint }
        return diffCache[area.rawValue + "\0" + file.path]
    }
    func storeDiff(_ diff: FileDiff, fingerprint: String) {
        guard snapshot?.fingerprint == fingerprint else { return }
        if diffCacheFingerprintValue != fingerprint { diffCache = [:]; diffCacheFingerprintValue = fingerprint }
        if diffCache.count > 400 { diffCache = [:] }
        diffCache[diff.area.rawValue + "\0" + diff.file.path] = diff
    }
    /// Reads a diff for display: from the cache, else with the quick read that trusts the snapshot.
    func displayDiff(_ file: FileChange, area: ChangeArea) async throws -> FileDiff {
        if let cached = cachedDiff(file, area: area) { return cached }
        guard let repository, let fingerprint = snapshot?.fingerprint else { throw FolmiError.staleSnapshot }
        let start = ContinuousClock.now
        let diff = try await repository.diff(for: file, area: area, snapshotFingerprint: fingerprint)
        PerfLog.interval("diff.read", since: start, detail: file.path)
        storeDiff(diff, fingerprint: fingerprint)
        return diff
    }
    /// Loads the neighbours of the selected change so the next ↓ shows at once.
    func prefetchNeighbours(of id: String?) {
        prefetchTaskValue?.cancel()
        let files = visibleFiles
        guard let id, let index = files.firstIndex(where: { $0.id == id }) else { return }
        let area = self.area
        let around = [index + 1, index - 1, index + 2].filter(files.indices.contains).map { files[$0] }
        prefetchTaskValue = Task { [weak self] in
            for file in around {
                guard let self, !Task.isCancelled else { return }
                _ = try? await self.displayDiff(file, area: area)
            }
        }
    }
}

/// Line keys per displayed diff, so views and counts do not hash every line on each render.
@MainActor
enum ReviewKeyCache {
    private static var cache: [String: [Int: String]] = [:]
    static func keys(_ diff: FileDiff, staged: FileDiff? = nil) -> [Int: String] {
        let id = diff.fingerprint + "\0" + diff.area.rawValue + "\0" + diff.file.path + "\0" + (staged?.fingerprint ?? "")
        if let found = cache[id] { return found }
        if cache.count > 600 { cache = [:] }
        let keys = ReviewProgress.lineKeys(diff, staged: staged)
        cache[id] = keys
        return keys
    }
}
