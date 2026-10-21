import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// The 历史 page: the commit graph, a commit's files and diffs, and actions on commits.
extension FolmiModel {
    /// Reads the graph; keeps the selected commit when it is still listed, otherwise selects HEAD.
    func loadHistory() async {
        guard let repository, let root = repositoryURL else { return }
        let request = UUID()
        historyRequest = request
        historyLoading = true
        defer { if historyRequest == request { historyLoading = false } }
        do {
            let requestedLimit = historyRequestedLimit
            let loaded = try await repository.history(limit: requestedLimit + 1)
            let commits = Array(loaded.prefix(requestedLimit))
            let rows = await Task.detached(priority: .userInitiated) { CommitGraph.layout(commits) }.value
            guard historyRequest == request, repositoryURL == root else { return }
            history = commits; historyRows = rows
            historyHasMore = loaded.count > requestedLimit
            let keep = selectedCommitID.flatMap { id in commits.contains { $0.id == id } ? id : nil }
            if let target = keep ?? commits.first(where: { $0.id == snapshot?.head })?.id ?? commits.first?.id {
                if target != selectedCommitID || commitDetail == nil { await selectCommit(target) }
            } else { selectedCommitID = nil; commitDetail = nil; selectedCommitFile = nil; commitFileDiff = nil }
        } catch { if historyRequest == request { report(error, title: "读取提交历史失败") } }
    }

    /// Expands the current graph without changing the selected commit.
    func loadMoreHistory() async {
        guard !historyLoading, historyHasMore else { return }
        historyRequestedLimit += Self.historyLimit
        await loadHistory()
    }

    /// Shows a commit's message and files, and the diff of its first file (or the file that was open, if it is there).
    func selectCommit(_ id: String) async {
        guard let repository, let root = repositoryURL else { return }
        let request = UUID()
        commitRequest = request
        let previousFile = selectedCommitFile
        selectedCommitID = id
        do {
            let comparing = compareBaseID.flatMap { $0 == id ? nil : $0 }
            let detail: CommitDetail
            if let comparing { detail = try await repository.compareDetail(base: comparing, target: id) }
            else { detail = try await repository.commitDetail(id) }
            let abilities = try? await repository.abilities(of: id)
            guard commitRequest == request, repositoryURL == root else { return }
            commitDetail = detail
            selectedCommitAbilities = abilities
            let file = detail.files.first { $0.path == previousFile } ?? detail.files.first
            selectedCommitFile = file?.path
            commitFileDiff = nil
            if let file { await loadCommitFile(file, request: request) }
        } catch { if commitRequest == request { report(error, title: "读取提交失败") } }
    }

    func selectCommitFile(_ file: CommitFileChange) {
        guard let detail = commitDetail else { return }
        let request = UUID()
        commitRequest = request
        selectedCommitFile = file.path
        Task { await loadCommitFile(file, request: request, commit: detail.id) }
    }

    func loadCommitFile(_ file: CommitFileChange, request: UUID, commit: String? = nil) async {
        guard let repository, let id = commit ?? commitDetail?.id else { return }
        do {
            let diff: FileDiff
            if let base = compareBaseID, base != id { diff = try await repository.compareDiff(base: base, target: id, file: file) }
            else { diff = try await repository.commitDiff(id, file: file) }
            guard commitRequest == request else { return }
            commitFileDiff = diff
        } catch { if commitRequest == request { report(error, title: "读取提交差异失败") } }
    }

    /// Compares every later selection against this commit, or ends comparing with nil.
    func setCompareBase(_ id: String?) {
        compareBaseID = id
        if let selected = selectedCommitID { Task { await selectCommit(selected) } }
    }

    /// Rewrites the latest commit's message; ⌘Z puts the old commit back.
    func rewordCommit(_ id: String, message: String) {
        guard let repository, let state = snapshot else { return }
        mutate("修改提交说明") { [weak self] in
            let before = try await repository.currentHead(), branch = try await repository.currentBranchRef()
            let head = try await repository.reword(id, message: message, expectedFingerprint: state.fingerprint)
            await MainActor.run {
                self?.pushUndo("修改提交说明 \(head.prefix(7))", .head(restore: before, current: head, branch: branch))
                self?.selectedCommitID = head
            }
            return head
        }
    }

    /// Revert or cherry-pick into the work tree, with git's message in the commit box: the result is reviewed and
    /// accepted like any other change before it can be committed (staging it directly would skip that). ⌘Z clears it.
    func applyCommit(_ id: String, kind: GitRepository.ApplyKind) {
        guard let repository, let state = snapshot else { return }
        let paths = commitDetail?.id == id && compareBaseID == nil ? (commitDetail?.files.map(\.path) ?? []) : []
        let title = kind == .revert ? "撤回提交 \(id.prefix(7))" : "挑选提交 \(id.prefix(7))"
        mutateUndoable(title, capture: {
            let touched = paths.isEmpty ? try await repository.commitDetail(id).files.map(\.path) : paths
            return .group([try await repository.captureIndex(touched), try await repository.captureWorktree(touched)])
        }) { [weak self] in
            let changed = try await repository.applyCommit(id, kind: kind, expectedFingerprint: state.fingerprint, intoWorkTree: true)
            let message = try await repository.suggestedMessage(for: id, kind: kind)
            await MainActor.run {
                guard let self else { return }
                self.draftMessage = message
                self.area = .working
                self.showSideTab(.changes)
            }
            return "已放进工作区：\(changed.count) 个文件。和其他改动一样，在逐个验收里看过、收下后再提交。"
        }
    }

    /// Reads what rolling back to `id` would drop, then asks (see `rollbackPrompt`).
    func prepareRollback(to id: String) {
        guard let repository, !busy else { return }
        Task {
            do { rollbackPrompt = try await repository.rollbackPlan(to: id) }
            catch { report(error, title: "无法回滚") }
        }
    }

    /// Moves the branch back; ⌥⌘Z moves it forward again.
    func rollback(_ plan: GitRepository.RollbackPlan, mode: GitRepository.RollbackMode) {
        guard let repository, let state = snapshot else { return }
        rollbackPrompt = nil
        if mode == .discardChanges, editorWorkspace?.hasUnsavedChanges == true {
            report(FolmiFailure(message: "编辑器里还有没保存的改动。先保存，再回滚。"), title: "仍有编辑草稿"); return
        }
        let title = "回滚到 \(plan.target.prefix(7))"
        mutate(title) { [weak self] in
            let step = try await repository.rollback(plan, mode: mode, expectedFingerprint: state.fingerprint)
            await MainActor.run {
                self?.pushUndo(title, step)
                self?.selectedCommitID = plan.target
                if mode == .keepChanges { self?.area = .staged }
            }
            let pushed = plan.pushed > 0 ? "其中 \(plan.pushed) 个已经推送过，要让远端也回滚得强制推送（Folmi 不会替你强制推送）。" : ""
            return mode == .keepChanges
                ? "去掉了 \(plan.commits) 个提交，它们的改动在暂存区。\(pushed)⌥⌘Z 可撤销。"
                : "去掉了 \(plan.commits) 个提交，文件回到了 \(plan.target.prefix(7)) 时的样子。\(pushed)⌥⌘Z 可撤销。"
        }
    }

    /// Puts one file in the work tree back to how a commit left it (`after`) or found it (`before`).
    func restoreFile(_ path: String, from commit: String, side: GitRepository.RestoreSide) {
        guard let repository else { return }
        if editorWorkspace?.hasUnsavedChanges == true {
            report(FolmiFailure(message: "编辑器里还有没保存的改动。先保存，再恢复文件。"), title: "仍有编辑草稿"); return
        }
        let title = "恢复 \((path as NSString).lastPathComponent)"
        mutateUndoable(title, capture: { try await repository.captureWorktree([path]) }) {
            try await repository.restoreFile(path, from: commit, side: side)
            return "\(path) 已恢复成 \(commit.prefix(7)) \(side == .after ? "提交后" : "提交前")的样子，在工作区里，看过再收下。⌥⌘Z 可撤销。"
        }
    }

    func createBranch(_ name: String, at id: String) {
        guard let repository else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate("新建分支 \(trimmed)") {
            try await repository.createBranch(trimmed, at: id)
            return "已从 \(id.prefix(7)) 新建分支 \(trimmed)（没有切换过去）。"
        }
    }

    /// Moves the history selection by `offset` rows.
    func moveCommitSelection(by offset: Int, in commits: [CommitNode]? = nil) {
        let commits = commits ?? history
        guard !commits.isEmpty else { return }
        let current = selectedCommitID.flatMap { id in commits.firstIndex { $0.id == id } } ?? -1
        let next = min(commits.count - 1, max(0, current + offset))
        guard commits[next].id != selectedCommitID else { return }
        let id = commits[next].id
        Task { await selectCommit(id) }
    }
}
