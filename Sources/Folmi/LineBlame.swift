import AppKit
import FolmiCore
import SwiftUI

/// The faint note after the caret's line: who last changed it, or that it is not committed yet.
struct LineBlameNote: Equatable {
    /// 0-based line in the editor buffer.
    let line: Int
    let text: String
    let commit: FileBlame.Commit?
    /// The commit's author is the user (`user.email`).
    var isMine = false
    /// The same line in HEAD (0-based), for its history.
    let headLine: Int?
}

/// What the editor knows about the open file for the note: HEAD's authors and the gutter's index marks.
enum LineBlame {
    /// The loader's answer for one file.
    enum Source: Equatable {
        case blame(FileBlame)
        /// Tracked, but HEAD has no such file (new, or the branch has no commit yet).
        case notInHead
        /// Untracked, or Git could not answer: nothing is shown.
        case unavailable
    }

    /// Lines without their newline, so a missing final newline does not make the last line look changed.
    static func lines(_ text: String) -> [Substring] {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        if result.last == "" { result.removeLast() }
        return result
    }

    /// For each buffer line, the HEAD line it is unchanged from; nil for lines added or edited since.
    static func headLines(head: String, current: String) -> [Int?] {
        let old = lines(head), new = lines(current)
        var map = [Int?](repeating: nil, count: new.count)
        var oldIndex = 0, newIndex = 0
        for change in LineDiff.changes(old: old, new: new) {
            while newIndex < change.new.lowerBound, newIndex < new.count { map[newIndex] = oldIndex; newIndex += 1; oldIndex += 1 }
            newIndex = change.new.upperBound; oldIndex = change.old.upperBound
        }
        while newIndex < new.count, oldIndex < old.count { map[newIndex] = oldIndex; newIndex += 1; oldIndex += 1 }
        return map
    }

    static func note(line: Int, source: Source, headLine: Int?, unstaged: Bool, now: Date = Date()) -> LineBlameNote? {
        switch source {
        case .unavailable: return nil
        case .notInHead:
            return LineBlameNote(line: line, text: unstaged ? "还没收下" : "新文件 · 还没提交过", commit: nil, headLine: nil)
        case .blame(let blame):
            guard let headLine, let commit = blame.commit(atHeadLine: headLine) else {
                return LineBlameNote(line: line, text: unstaged ? "还没收下" : "已收下 · 还没提交", commit: nil, headLine: nil)
            }
            let mine = blame.userEmail.map { $0.caseInsensitiveCompare(commit.email) == .orderedSame } ?? false
            let parts = [mine ? "你" : commit.author, relative(commit.date, now: now), commit.subject].filter { !$0.isEmpty }
            return LineBlameNote(line: line, text: parts.joined(separator: " · "), commit: commit, isMine: mine, headLine: headLine)
        }
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "昨天" }
        if days < 30 { return "\(days) 天前" }
        return absolute(date, now: now, time: false)
    }

    static func absolute(_ date: Date, now: Date = Date(), time: Bool = true) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = (sameYear ? "M月d日" : "yyyy年M月d日") + (time ? " HH:mm" : "")
        return formatter.string(from: date)
    }
}

/// Opened from the note: the commit behind the line and, on request, every commit that changed the line.
struct LineBlameCard: View {
    let commit: FileBlame.Commit
    let isMine: Bool
    let loadHistory: (() async -> [FileBlame.Commit])?
    let onShowCommit: (String) -> Void
    @State private var history: [FileBlame.Commit]?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject.isEmpty ? "（没有提交说明）" : commit.subject)
                .themedFont(.callout.weight(.semibold), points: 12)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("\(isMine ? "你" : commit.author) <\(commit.email)>")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(LineBlame.absolute(commit.date))（\(LineBlame.relative(commit.date))）· \(commit.shortID)")
                .themedFont(.caption, points: 10).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("在历史里看这次提交") { onShowCommit(commit.id) }
                if loadHistory != nil, history == nil {
                    Button(loading ? "正在读取…" : "这一行改过几次") { load() }.disabled(loading)
                        .help("列出改过这一行的提交（按提交里的样子，不含还没提交的编辑）")
                }
                Spacer()
            }
            .controlSize(.small)
            if let history {
                Text(history.isEmpty ? "没找到改过这一行的提交。" : "这一行改过 \(history.count)\(history.count >= 20 ? "+" : "") 次")
                    .themedFont(.caption.weight(.semibold), points: 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(history, id: \.id) { item in
                            Button { onShowCommit(item.id) } label: {
                                HStack(spacing: 6) {
                                    Text(item.shortID).themedFont(.system(size: 10, design: .monospaced), points: 10).foregroundStyle(.secondary)
                                    Text(item.subject).themedFont(.caption, points: 10).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 4)
                                    Text("\(item.author) · \(LineBlame.relative(item.date))")
                                        .themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("在历史里看这次提交")
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func load() {
        guard let loadHistory else { return }
        loading = true
        Task { @MainActor in
            history = await loadHistory()
            loading = false
        }
    }
}
