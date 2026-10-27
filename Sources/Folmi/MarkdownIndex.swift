import Foundation
import FolmiCore

/// Headings and task-list items of every Markdown file in the project, for ⌘K, the task view and the progress rings
/// in the file tree. Built off the main thread; a rebuild re-reads only files whose size or date changed.
struct MarkdownIndex: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable {
        /// `done` is true for every closed task, `[x]` and `[-]` alike: the progress rings count both as dealt with.
        enum Kind: Sendable, Equatable { case heading(Int), task(done: Bool) }
        let path: String
        /// 0-based line.
        let line: Int
        let kind: Kind
        /// For a task, the title with its date markers taken out.
        let text: String
        var status: TaskStatus = .open
        var dates = TaskDates()
        var id: String { "\(path):\(line)" }
        /// On the 待办 page: still to do, or done on a day written on the line.
        var isListed: Bool {
            guard case .task = kind else { return false }
            return status.isOpen || (status == .done && dates.done != nil)
        }
    }
    struct FileInfo: Sendable, Equatable {
        let size: Int
        let modified: Date
        let entries: [Entry]
        var tasks: (done: Int, total: Int) {
            var done = 0, total = 0
            for entry in entries { if case .task(let finished) = entry.kind { total += 1; if finished { done += 1 } } }
            return (done, total)
        }
    }
    static func == (lhs: MarkdownIndex, rhs: MarkdownIndex) -> Bool { lhs.files.keys == rhs.files.keys && lhs.revision == rhs.revision }

    private(set) var files: [String: FileInfo] = [:]
    private(set) var revision = 0

    static let maximumFiles = 3_000
    static let maximumBytes = 1_024 * 1_024

    var entries: [Entry] { files.keys.sorted().flatMap { files[$0]!.entries } }
    var openTasks: [Entry] {
        files.keys.sorted().flatMap { path in files[path]!.entries.filter { if case .task(false) = $0.kind { return true }; return false } }
    }

    static func isMarkdown(_ path: String) -> Bool { ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) }

    /// A new index for `paths`, reusing entries of unchanged files from `previous`.
    static func build(root: URL, paths: [String], previous: MarkdownIndex?) -> MarkdownIndex {
        var index = MarkdownIndex()
        index.revision = (previous?.revision ?? 0) &+ 1
        var changed = previous == nil
        for path in paths.lazy.filter(isMarkdown).prefix(maximumFiles) {
            if Task.isCancelled { return previous ?? index }
            let url = root.appendingPathComponent(path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { continue }
            if let old = previous?.files[path], old.size == size, old.modified == modified { index.files[path] = old; continue }
            changed = true
            guard size <= maximumBytes, let data = try? Data(contentsOf: url), let text = UTF8Text.decode(data) else {
                index.files[path] = FileInfo(size: size, modified: modified, entries: []); continue
            }
            // A BOM would hide a heading on the first line; the index only reads lines, so drop it.
            index.files[path] = FileInfo(size: size, modified: modified, entries: parse(String(text.drop(while: { $0 == "\u{FEFF}" })), path: path))
        }
        if !changed, let previous, previous.files.count == index.files.count { return previous }
        return index
    }

    /// Headings (ATX `#`) and task items (`- [ ]`, `* [x]`, `1. [ ]`, `- [/]`, `- [-]`) outside fenced code.
    static func parse(_ text: String, path: String) -> [Entry] {
        var entries: [Entry] = []
        var fence: Substring?
        var lineNumber = 0
        text.enumerateLines { raw, _ in
            defer { lineNumber += 1 }
            let line = raw.drop(while: { $0 == " " })
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = line.prefix(3)
                if let open = fence { if marker == open { fence = nil } } else { fence = marker }
                return
            }
            guard fence == nil, raw.count < 2_000 else { return }
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(hashes)
                guard (1...6).contains(hashes), rest.first == " " else { return }
                let title = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { entries.append(Entry(path: path, line: lineNumber, kind: .heading(hashes), text: title)) }
                return
            }
            var body = line
            if let marker = body.first, "-*+".contains(marker), body.dropFirst().first == " " { body = body.dropFirst(2) }
            else if let dot = body.firstIndex(where: { $0 == "." || $0 == ")" }), dot > body.startIndex,
                    body[..<dot].allSatisfy(\.isNumber), body[body.index(after: dot)...].first == " " {
                body = body[body.index(dot, offsetBy: 2)...]
            } else { return }
            guard body.count >= 3, body.hasPrefix("["), body.dropFirst(2).first == "]",
                  let status = TaskStatus(mark: body.dropFirst().first!) else { return }
            let (title, dates) = TaskDates.split(body.dropFirst(3).trimmingCharacters(in: .whitespaces))
            entries.append(Entry(path: path, line: lineNumber, kind: .task(done: !status.isOpen), text: title.isEmpty ? "（空任务）" : title,
                                 status: status, dates: dates))
        }
        return entries
    }
}

/// A task's checkbox, in Obsidian Tasks' notation: `[ ]`, `[/]` in progress, `[x]` done, `[-]` dropped.
enum TaskStatus: Sendable, Equatable {
    case open, inProgress, done, cancelled
    init?(mark: Character) {
        switch mark {
        case " ": self = .open
        case "/": self = .inProgress
        case "x", "X": self = .done
        case "-": self = .cancelled
        default: return nil
        }
    }
    var mark: Character {
        switch self {
        case .open: return " "
        case .inProgress: return "/"
        case .done: return "x"
        case .cancelled: return "-"
        }
    }
    var isOpen: Bool { self == .open || self == .inProgress }
}

/// The dates written on a task line, as Obsidian Tasks writes them (`📅 2026-10-30`). Kept as `yyyy-MM-dd` text,
/// which sorts and compares as dates do, so nothing here depends on a time zone.
struct TaskDates: Sendable, Equatable {
    enum Kind: CaseIterable, Sendable { case due, scheduled, done
        var marker: String {
            switch self {
            case .due: return "📅"
            case .scheduled: return "⏳"
            case .done: return "✅"
            }
        }
    }
    var due: String?
    var scheduled: String?
    var done: String?

    subscript(kind: Kind) -> String? {
        get { switch kind { case .due: due; case .scheduled: scheduled; case .done: done } }
        set { switch kind { case .due: due = newValue; case .scheduled: scheduled = newValue; case .done: done = newValue } }
    }

    /// The day a task belongs to on a list: its deadline, else the day it was planned for.
    var day: String? { due ?? scheduled }

    static func key(_ date: Date, calendar: Calendar = .current) -> String { DailyStats.dayKey(date, calendar: calendar) }
    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static let pattern = try! NSRegularExpression(pattern: #"\s*(📅|⏳|✅)\uFE0F?\s*(\d{4}-\d{2}-\d{2})"#)

    /// The title without its date markers, and the dates. A marker written twice keeps the first.
    static func split(_ text: String) -> (title: String, dates: TaskDates) {
        guard text.contains("📅") || text.contains("⏳") || text.contains("✅") else { return (text, TaskDates()) }
        let source = text as NSString
        var dates = TaskDates()
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let value = source.substring(with: match.range(at: 2))
            guard let kind = Kind.allCases.first(where: { $0.marker == source.substring(with: match.range(at: 1)) }), dates[kind] == nil else { continue }
            dates[kind] = value
        }
        let title = pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: source.length), withTemplate: "")
        return (title.trimmingCharacters(in: .whitespaces), dates)
    }

    /// `line` with its `kind` date set to `value` (nil takes it out). A new date goes at the end of the line.
    static func setting(_ kind: Kind, to value: String?, in line: String) -> String {
        let source = line as NSString
        let existing = pattern.matches(in: line, range: NSRange(location: 0, length: source.length))
            .first { source.substring(with: $0.range(at: 1)) == kind.marker }
        let written = value.map { " \(kind.marker) \($0)" } ?? ""
        if let existing { return source.replacingCharacters(in: existing.range, with: written) }
        guard value != nil else { return line }
        let trimmed = line.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        return trimmed + written
    }
}
