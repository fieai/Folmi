import Foundation
import FolmiCore
import SwiftUI

/// A note on some diff lines, meant to be handed to an agent in the terminal in one paste.
/// Notes are saved with the project; each keeps a few lines of the file around it so a refresh can tell whether
/// those lines only moved or were changed.
struct ReviewComment: Identifiable, Equatable, Codable {
    var id = UUID()
    let projectPath: String
    let path: String
    let area: ChangeArea
    /// New-side line numbers, kept up to date when the lines move.
    var firstLine: Int
    var lastLine: Int
    /// The commented diff lines with their +/-/space prefix.
    let excerpt: [String]
    var body: String
    /// New-side text at `anchorStart`, the commented lines plus one neighbouring line on each side.
    var anchor: [String] = []
    var anchorStart = 1
    /// The anchored lines are no longer in the file; the note may not apply any more.
    var outdated = false
    var created = Date()
    /// The agent said it dealt with this note (MCP `mark_comment_addressed`): its one-line account, for the user to confirm.
    var addressed: String?

    /// "12" or "12-15".
    var lines: String { firstLine == lastLine ? "\(firstLine)" : "\(firstLine)-\(lastLine)" }

    /// Builds a comment from the selected lines of a hunk, or the whole hunk when nothing in it is selected.
    static func make(projectPath: String, diff: FileDiff, hunk: DiffHunk, selected: Set<Int>, body: String) -> ReviewComment? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let numbers = newLineNumbers(hunk) else { return nil }
        let chosen = hunk.lines.filter { selected.contains($0.id) && $0.kind != .meta }
        let lines = chosen.isEmpty ? hunk.lines.filter { $0.kind != .meta } : chosen
        guard !lines.isEmpty else { return nil }
        let positions = lines.compactMap { numbers[$0.id] }
        let first = positions.min() ?? 1, last = positions.max() ?? first
        let excerpt = lines.prefix(60).map { line -> String in
            switch line.kind { case .addition: return "+" + line.text; case .deletion: return "-" + line.text; default: return " " + line.text }
        } + (lines.count > 60 ? ["…（另有 \(lines.count - 60) 行）"] : [])
        // The hunk's new side, by line number: what the file held around the note when it was written.
        var newSide: [(number: Int, text: String)] = []
        for line in hunk.lines where line.kind == .context || line.kind == .addition {
            if let number = numbers[line.id] { newSide.append((number, line.text)) }
        }
        // A note on deletions only covers no new-side line; the lines either side of the gap stand in for it.
        let low = first - 1, high = chosen.allSatisfy({ $0.kind == .deletion }) && !chosen.isEmpty ? first : last + 1
        let span = newSide.filter { $0.number >= low && $0.number <= high }.prefix(200)
        return ReviewComment(projectPath: projectPath, path: diff.file.path, area: diff.area, firstLine: first, lastLine: last,
                             excerpt: excerpt, body: trimmed, anchor: span.map { $0.text.hasSuffix("\r") ? String($0.text.dropLast()) : $0.text }, anchorStart: span.first?.number ?? first)
    }

    /// A note on lines of a document read in the Markdown reader, not on a diff. The excerpt is the Markdown source
    /// of those lines (what the agent edits), or the selected text when the file cannot be read.
    static func make(projectPath: String, draft: ReaderCommentDraft, body: String, fileLines: [String]?) -> ReviewComment? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let first = max(1, draft.firstLine), last = max(first, draft.lastLine)
        var excerpt: [String], anchor: [String] = [], anchorStart = first
        if let lines = fileLines, last <= lines.count {
            let chosen = lines[(first - 1)..<last]
            excerpt = chosen.prefix(60).map { " " + $0 } + (chosen.count > 60 ? ["…（另有 \(chosen.count - 60) 行）"] : [])
            let low = max(1, first - 1), high = min(lines.count, last + 1)
            anchor = Array(lines[(low - 1)..<high].prefix(200)); anchorStart = low
        } else {
            excerpt = draft.quote.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).map { " " + $0 }
        }
        return ReviewComment(projectPath: projectPath, path: draft.path, area: .working, firstLine: first, lastLine: last,
                             excerpt: excerpt, body: trimmed, anchor: anchor, anchorStart: anchorStart)
    }

    /// Where the anchor is in `fileLines` now: its 1-based start, or nil when it is gone.
    /// Prefers the saved position, then the closest copy.
    static func locate(anchor: [String], near start: Int, in fileLines: [String]) -> Int? {
        guard !anchor.isEmpty, anchor.count <= fileLines.count else { return nil }
        func matches(_ index: Int) -> Bool {
            index >= 0 && index + anchor.count <= fileLines.count && fileLines[index..<(index + anchor.count)].elementsEqual(anchor)
        }
        if matches(start - 1) { return start }
        var best: Int?
        for index in 0...(fileLines.count - anchor.count) where fileLines[index] == anchor[0] && matches(index) {
            if best.map({ abs(index + 1 - start) < abs($0 - start) }) ?? true { best = index + 1 }
        }
        return best
    }

    /// The file's lines for anchoring, or nil when it is missing, too large to scan, or not text.
    static func fileLines(_ url: URL) -> [String]? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 8 << 20,
              let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
        // "\r\n" is a single Character, so it has to be named as a separator of its own.
        return String(decoding: data, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map(String.init)
    }

    /// Follows the anchor to its current place in the file, or marks the note outdated. Nil file lines mean the file is gone.
    /// A note without an anchor cannot be checked and stays as it is.
    func located(in fileLines: [String]?) -> ReviewComment {
        guard !anchor.isEmpty else { return self }
        var next = self
        guard let fileLines, let start = Self.locate(anchor: anchor, near: anchorStart, in: fileLines) else {
            next.outdated = true
            return next
        }
        let delta = start - anchorStart
        next.outdated = false
        next.anchorStart = start; next.firstLine += delta; next.lastLine += delta
        return next
    }

    /// New-side line number of every hunk line; a deleted line takes the number of the line it was removed before.
    static func newLineNumbers(_ hunk: DiffHunk) -> [Int: Int]? {
        guard let regex = try? NSRegularExpression(pattern: #"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@"#),
              let match = regex.firstMatch(in: hunk.header, range: NSRange(hunk.header.startIndex..., in: hunk.header)),
              let range = Range(match.range(at: 1), in: hunk.header), var next = Int(hunk.header[range]) else { return nil }
        var result: [Int: Int] = [:]
        for line in hunk.lines {
            switch line.kind {
            case .context, .addition: result[line.id] = next; next += 1
            case .deletion: result[line.id] = max(1, next)
            case .meta: break
            }
        }
        return result
    }

    var reference: String { "\(path):\(lines)" }

    /// `path:start-end`, the lines in a ```diff fence, then the note.
    var formatted: String {
        Self.sanitize("\(reference)\n```diff\n\(excerpt.joined(separator: "\n"))\n```\n\(body)")
    }

    static func formatted(_ comments: [ReviewComment]) -> String {
        comments.map(\.formatted).joined(separator: "\n\n")
    }

    /// Drops control characters (other than newline and tab) so file content or a note cannot end the bracketed paste
    /// early or send escape sequences to the program in the terminal.
    static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
        }))
    }
}

/// Text selected in the Markdown reader, waiting for its note.
struct ReaderCommentDraft: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let firstLine: Int
    let lastLine: Int
    let quote: String
    var reference: String { firstLine == lastLine ? "\(path):\(firstLine)" : "\(path):\(firstLine)-\(lastLine)" }
}

struct ReviewCommentComposer: View {
    let title: String
    let onAdd: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).themedFont(.caption.weight(.semibold), points: 10)
            TextEditor(text: $text)
                .themedFont(.system(size: 12), points: 12)
                .frame(width: 360, height: 110)
                .themedEditorFrame()
                .focused($editing)
            HStack {
                Text("评论先攒着，之后一次发送到终端").themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("添加评论") { onAdd(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        // Opened with the `c` key or a button: start typing straight away.
        .onAppear { DispatchQueue.main.async { editing = true } }
    }
}

struct ReviewCommentRow: View {
    let comment: ReviewComment
    let onDelete: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: comment.outdated ? "text.bubble.badge.clock" : "text.bubble")
                .foregroundStyle(comment.outdated ? ThemeColor(token: .secondaryText) : ThemeColor(token: .accent)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("第 \(comment.lines) 行").themedFont(.caption2.monospaced(), points: 10).foregroundStyle(.secondary)
                    if comment.addressed != nil {
                        Text("AI 说已处理").themedFont(.caption2.weight(.medium), points: 10).foregroundStyle(.themed(.added))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .themedCapsule(ThemeColor(token: .added, opacity: 0.14))
                            .help("agent 通过 MCP 标记了这条评论；看过改动后点右边的 ✓ 确认并移除")
                    }
                    if comment.outdated {
                        Text("已过时").themedFont(.caption2.weight(.medium), points: 10).foregroundStyle(.themed(.modified))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .themedCapsule(ThemeColor(token: .modified, opacity: 0.14))
                            .help("评论的那几行已经改动，不会随「发送」一起发出")
                    }
                }
                Text(comment.body).themedFont(.caption, points: 10).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(comment.outdated ? .secondary : .primary)
                if let addressed = comment.addressed {
                    Text("AI：\(addressed)").themedFont(.caption, points: 10).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button(action: onDelete) { Image(systemName: comment.addressed == nil ? "trash" : "checkmark").font(.caption) }
                .buttonStyle(.pressable).foregroundStyle(.secondary).help(comment.addressed == nil ? "删除这条评论" : "确认已处理并移除")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((comment.outdated ? ThemeColor(token: .secondaryText) : ThemeColor(token: .accent)).opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
