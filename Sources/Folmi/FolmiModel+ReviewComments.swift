import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// Review comments on hunks: kept per project, marked 已过时 when their lines move away, sent to the terminal.
extension FolmiModel {
    var currentReviewComments: [ReviewComment] { reviewComments.filter { $0.projectPath == repositoryURL?.path } }

    /// The notes that still match the file; outdated ones stay listed but are not sent or copied.
    var sendableReviewComments: [ReviewComment] { currentReviewComments.filter { !$0.outdated } }

    func clearOutdatedReviewComments() { reviewComments.removeAll { $0.projectPath == repositoryURL?.path && $0.outdated } }

    /// Finds each note's lines in the working tree again: moved lines carry the note along, changed or removed lines
    /// mark it outdated.
    func relocateReviewComments() async {
        guard let root = repositoryURL else { return }
        let pending = currentReviewComments.filter { !$0.anchor.isEmpty }
        guard !pending.isEmpty else { return }
        let located = await Task.detached(priority: .utility) { () -> [ReviewComment] in
            var files: [String: [String]] = [:], missing: Set<String> = []
            return pending.map { comment in
                if files[comment.path] == nil, !missing.contains(comment.path) {
                    if let lines = ReviewComment.fileLines(root.appendingPathComponent(comment.path)) { files[comment.path] = lines }
                    else { missing.insert(comment.path) }
                }
                return comment.located(in: files[comment.path])
            }
        }.value
        guard repositoryURL == root else { return }
        let byID = Dictionary(located.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Notes may have been deleted while the files were read; only their position is taken over.
        let next = reviewComments.map { comment -> ReviewComment in
            guard let found = byID[comment.id] else { return comment }
            var updated = comment
            updated.firstLine = found.firstLine; updated.lastLine = found.lastLine
            updated.anchorStart = found.anchorStart; updated.outdated = found.outdated
            return updated
        }
        if next != reviewComments { reviewComments = next }
    }

    func addReviewComment(_ body: String, hunk: DiffHunk, in diff: FileDiff) {
        let selected = selectedLines[diff.file.path] ?? []
        // The lines were chosen for this note; staging them next should start from a clean selection.
        if addComment(body, hunk: hunk, in: diff, selected: selected) { selectedLines[diff.file.path]?.subtract(hunk.lines.map(\.id)) }
    }

    func addAllChangesComment(_ body: String, hunk: DiffHunk, in diff: FileDiff) {
        let selected = allChangesSelection[diff.allChangesKey] ?? []
        if addComment(body, hunk: hunk, in: diff, selected: selected) { allChangesSelection[diff.allChangesKey]?.subtract(hunk.lines.map(\.id)) }
    }

    /// True when a comment was added.
    func addComment(_ body: String, hunk: DiffHunk, in diff: FileDiff, selected: Set<Int>) -> Bool {
        guard let root = repositoryURL?.path,
              let comment = ReviewComment.make(projectPath: root, diff: diff, hunk: hunk, selected: selected, body: body) else { return false }
        reviewComments.append(comment)
        recordNote(comment)
        return true
    }

    func deleteReviewComment(_ id: UUID) { reviewComments.removeAll { $0.id == id } }

    func clearReviewComments() { reviewComments.removeAll { $0.projectPath == repositoryURL?.path } }

    func copyReviewComments() {
        let comments = sendableReviewComments
        guard !comments.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReviewComment.formatted(comments), forType: .string)
        preferencesStatus = "已复制 \(comments.count) 条审查评论"
    }

    /// Pastes all notes into this project's terminal without pressing Enter, then clears them.
    func sendReviewCommentsToTerminal() {
        let comments = sendableReviewComments
        guard !comments.isEmpty, snapshot != nil else { return }
        if !showTerminal || terminalSession == nil { focusPane(.terminal) }
        let ids = Set(comments.map(\.id))
        pasteIntoTerminal(ReviewComment.formatted(comments), kept: "评论已复制到剪贴板，并且保留在列表里。") { [weak self] in
            self?.reviewComments.removeAll { ids.contains($0.id) }
            self?.record("发送审查评论到终端", "\(comments.count) 条：\n" + comments.map(\.reference).joined(separator: "\n"))
        }
    }
}
