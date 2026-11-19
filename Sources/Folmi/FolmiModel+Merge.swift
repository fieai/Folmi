import Foundation
import FolmiCore

/// Merging another branch into the current one, folding unpushed commits into one, and one file's history. Each is
/// read as a plan first and lands as one ⌥⌘Z step.
extension FolmiModel {
    // MARK: Merge a branch

    /// Reads what merging `branch` would do (including the files it would conflict on), then asks (see `mergePrompt`).
    func prepareMerge(_ branch: String) {
        guard let repository, !busy else { return }
        Task {
            do { mergePrompt = try await repository.mergePlan(branch) }
            catch { report(error, title: "无法合并") }
        }
    }

    func runMerge(_ plan: GitRepository.MergePlan) {
        guard let repository else { return }
        mergePrompt = nil
        if editorWorkspace?.hasUnsavedChanges == true {
            report(FolmiFailure(message: "编辑器里还有没保存的改动。先保存，再合并。"), title: "仍有编辑草稿"); return
        }
        let title = "合并 \(plan.source)", key = repositoryURL?.path ?? ""
        mutate(title) { [weak self] in
            let branch = try await repository.currentBranchRef()
            let outcome = try await repository.merge(plan)
            return await MainActor.run {
                guard let self else { return "" }
                switch outcome {
                case let .done(before, after):
                    self.pushUndo(title, .reset(restore: before, current: after, branch: branch))
                    let how = plan.fastForward ? "快进" : "合并"
                    return "已把「\(plan.source)」\(how)进「\(plan.branch)」：带进 \(plan.incoming) 个提交。⌥⌘Z 可回到合并前。"
                case let .conflict(operation, files):
                    self.pullStartHeads[key] = PullStart(head: plan.head, branch: branch, title: title)
                    if self.draftMessage.isEmpty { self.draftMessage = "Merge branch '\(plan.source)' into \(plan.branch)\n" }
                    self.showSideTab(.changes)
                    self.errorMessage = Self.conflictHelp(operation, files: files)
                    return "合并时有冲突，停在中途：\n" + files.joined(separator: "\n")
                }
            }
        }
    }

    static func mergeMessage(_ plan: GitRepository.MergePlan) -> String {
        if let reason = plan.blocked { return reason }
        var text = plan.fastForward
            ? "「\(plan.branch)」没有自己的新提交，会直接前进到「\(plan.source)」，带进 \(plan.incoming) 个提交，不产生合并提交。"
            : "把「\(plan.source)」的 \(plan.incoming) 个提交合并进「\(plan.branch)」，生成一个合并提交。"
        if !plan.conflicts.isEmpty {
            let list = plan.conflicts.prefix(5).joined(separator: "\n") + (plan.conflicts.count > 5 ? "\n…" : "")
            text += "\n\n会在这 \(plan.conflicts.count) 个文件上冲突，需要你解决后再提交：\n\(list)"
        }
        text += "\n\n不会推送。⌥⌘Z 可回到合并前。"
        return text
    }

    // MARK: Fold commits

    /// Reads the commits from `id` up to HEAD; when they can be folded, asks for the message (see `squashPrompt`).
    func prepareSquash(from id: String) {
        guard let repository, !busy else { return }
        Task {
            do { squashPrompt = try await repository.squashPlan(from: id) }
            catch { report(error, title: "无法合并提交") }
        }
    }

    func squash(_ plan: GitRepository.SquashPlan, message: String) {
        guard let repository, let state = snapshot else { return }
        squashPrompt = nil
        let title = "合并 \(plan.count) 个提交"
        mutate(title) { [weak self] in
            let step = try await repository.squash(plan, message: message, expectedFingerprint: state.fingerprint)
            await MainActor.run {
                self?.pushUndo(title, step)
                if case let .head(_, current?, _) = step { self?.selectedCommitID = current }
            }
            return "\(plan.count) 个提交合成了一个，改动和文件都没变。⌥⌘Z 可拆回原来的提交。"
        }
    }

    // MARK: One file's history

    /// Opens the history page filtered to the commits that changed `path`.
    func showFileHistory(_ path: String) {
        guard !busy else { return }
        historyPath = path
        compareBaseID = nil
        historyRequestedLimit = Self.historyLimit
        selectedCommitID = nil
        showContent(.history)
    }

    func clearFileHistory() {
        guard historyPath != nil else { return }
        historyPath = nil
        historyRequestedLimit = Self.historyLimit
        Task { await loadHistory() }
    }
}
