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

    /// Finds each note's lines on the new side of its original comparison.
    func relocateReviewComments() async {
        guard let root = repositoryURL else { return }
        let pending = currentReviewComments.filter { !$0.anchor.isEmpty }
        guard !pending.isEmpty else { return }
        let repository = self.repository
        let located = await Task.detached(priority: .utility) { () -> [ReviewComment] in
            var files: [String: [String]] = [:], missing: Set<String> = []
            var result: [ReviewComment] = []
            for comment in pending {
                let key = comment.area.rawValue + ":" + comment.path
                if files[key] == nil, !missing.contains(key) {
                    let lines: [String]?
                    if comment.area == .staged {
                        let data = try? await repository?.bytes(of: .object(":" + comment.path), limit: ReviewComment.maximumAnchorFileBytes)
                        lines = data.flatMap(ReviewComment.fileLines)
                    } else {
                        lines = ReviewComment.fileLines(root.appendingPathComponent(comment.path))
                    }
                    if let lines { files[key] = lines } else { missing.insert(key) }
                }
                result.append(comment.located(in: files[key]))
            }
            return result
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

    var visibleReviewCommentID: UUID? { content == .diff ? reviewCommentReveal?.comment.id : nil }

    @discardableResult
    func revealReviewComment(_ id: UUID, recordingJump: Bool = true) -> Bool {
        guard !busy, let comment = sendableReviewComments.first(where: { $0.id == id }) else { return false }
        let previousComment = visibleReviewCommentID
        if comment.isReaderComment, let editor = editorWorkspace {
            do {
                try editor.reveal(path: comment.path, line: comment.firstLine, fromComment: previousComment)
                editor.markdownReading = true
                editor.readerTopLine[comment.path] = max(0, comment.firstLine - 1)
                reviewCommentReveal = nil
                content = .editor
                focusPane(.editor)
                return true
            } catch { report(error, title: "打开评论位置失败"); return false }
        }

        let change = snapshot?.files.first { file in
            file.path == comment.path && (comment.area == .staged ? file.hasStaged : file.hasWorking)
        }
        guard let change else {
            let group = comment.area == .staged ? "暂存区" : "工作区"
            report(FolmiFailure(message: "\(group)已没有这条评论对应的改动。"), title: "打开评论位置失败")
            return false
        }
        if recordingJump { editorWorkspace?.recordReviewCommentJump(to: id, from: previousComment) }
        selectFiles([change.id], in: comment.area)
        reviewCommentReveal = ReviewCommentReveal(comment: comment)
        focusPane(.editor)
        return true
    }

    /// A comment on Markdown diff lines goes to the source without changing the user's default.
    func showsRenderedMarkdownDiff(_ diff: FileDiff) -> Bool {
        markdownDiffRendered && reviewCommentReveal?.matches(diff) != true
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

    /// Adds the note written on a Markdown reader selection; it is sent with the diff notes (⌥⌘↩).
    func addReaderComment(_ body: String, draft: ReaderCommentDraft) {
        readerCommentDraft = nil
        guard let root = repositoryURL,
              let comment = ReviewComment.make(projectPath: root.path, draft: draft, body: body,
                                               fileLines: ReviewComment.fileLines(root.appendingPathComponent(draft.path))) else { return }
        reviewComments.append(comment)
        recordNote(comment)
        editorWorkspace?.showNotice("已加评论（\(comment.reference)），和其他评论一起发到终端：⌥⌘↩")
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
