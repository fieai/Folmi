import Foundation
import FolmiCore

/// Headings and task-list items of every Markdown file in the project, for ⌘K, the task view and the progress rings
/// in the file tree. Built off the main thread; a rebuild re-reads only files whose size or date changed.
struct MarkdownIndex: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable {
        enum Kind: Sendable, Equatable { case heading(Int), task(done: Bool) }
        let path: String
        /// 0-based line.
        let line: Int
        let kind: Kind
        let text: String
        var id: String { "\(path):\(line)" }
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

    /// Headings (ATX `#`) and task items (`- [ ]`, `* [x]`, `1. [ ]`) outside fenced code.
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
            guard body.count >= 3, body.hasPrefix("["), body.dropFirst(2).first == "]" else { return }
            let mark = body.dropFirst().first!
            guard mark == " " || mark == "x" || mark == "X" else { return }
            let title = body.dropFirst(3).trimmingCharacters(in: .whitespaces)
            entries.append(Entry(path: path, line: lineNumber, kind: .task(done: mark != " "), text: title.isEmpty ? "（空任务）" : title))
        }
        return entries
    }
}
