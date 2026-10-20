import Darwin
import Foundation
import FolmiCore
import SwiftUI

/// What a ⌘-clicked word in the terminal points at.
enum TerminalLinkTarget: Equatable {
    case web(URL)
    /// A file inside the project, as a project-relative path, with the line and column when the text named them.
    case file(path: String, line: Int?, column: Int?)
    /// An existing folder, or a file outside the project; it is shown in Finder rather than opened.
    case outside(URL)
    case missing(String)
}

/// Turns the paths that compilers, test runners and agents print (`Sources/A.swift:42:7`, `./a.py:3`, `a.ts(12,5)`,
/// `/abs/path/b.go:9`, `file:///…`) into a place to open.
enum TerminalLinks {
    /// Splits a trailing `:line[:column]`, `(line[,column])` or `#Lline` off a path.
    static func split(_ text: String) -> (path: String, line: Int?, column: Int?) {
        var path = text
        // Punctuation that ends a sentence or wraps the path in prose is not part of it.
        while let last = path.last, ".,;:'\"`)]>".contains(last), !path.hasSuffix("..") {
            if last == ")", path.range(of: #"\(\d+(,\d+)?\)$"#, options: .regularExpression) != nil { break }
            path.removeLast()
        }
        func number(_ value: Substring?) -> Int? { value.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } }
        if let match = path.range(of: #"\((\d+)(,(\d+))?\)$"#, options: .regularExpression) {
            let numbers = path[match].dropFirst().dropLast().split(separator: ",")
            return (String(path[..<match.lowerBound]), number(numbers.first), number(numbers.dropFirst().first))
        }
        if let match = path.range(of: #"#L\d+(C\d+)?$"#, options: .regularExpression) {
            let numbers = path[match].dropFirst(2).split(separator: "C")
            return (String(path[..<match.lowerBound]), number(numbers.first), number(numbers.dropFirst().first))
        }
        var parts = path.split(separator: ":", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let value = Int(parts.last!), value > 0 {
            numbers.insert(value, at: 0)
            parts.removeLast()
        }
        return (parts.joined(separator: ":"), numbers.first, numbers.dropFirst().first)
    }

    /// Relative paths are tried against the shell's working directory, then the project root, then as the end of a
    /// project path (a test log that prints only `FooTests.swift:12`). `projectPaths` are project-relative.
    static func resolve(_ link: String, root: URL, cwd: URL?, projectPaths: [String]) -> TerminalLinkTarget {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return .web(url)
        }
        var text = trimmed
        if text.lowercased().hasPrefix("file://") {
            text = URL(string: text)?.path ?? String(text.dropFirst(7))
        }
        let (rawPath, line, column) = split(text)
        guard !rawPath.isEmpty else { return .missing(trimmed) }
        var path = (rawPath as NSString).expandingTildeInPath
        let base = canonical(root.path)
        var candidates: [String] = []
        if path.hasPrefix("/") {
            candidates = [path]
        } else {
            // Git prints `a/path` and `b/path` in diffs.
            if path.hasPrefix("a/") || path.hasPrefix("b/") { candidates.append(String(path.dropFirst(2))) }
            if path.hasPrefix("./") { path.removeFirst(2) }
            candidates.insert(path, at: 0)
            let directories = [cwd.map { canonical($0.path) }, base].compactMap { $0 }
            candidates = directories.flatMap { directory in candidates.map { (directory as NSString).appendingPathComponent($0) } }
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) else { continue }
            let resolved = canonical(candidate)
            if !isDirectory.boolValue, resolved.hasPrefix(base + "/") {
                return .file(path: String(resolved.dropFirst(base.count + 1)), line: line, column: column)
            }
            // Folders, and files outside the project, are shown in Finder.
            return .outside(URL(fileURLWithPath: resolved))
        }
        if !path.hasPrefix("/") {
            let suffix = "/" + path
            let matches = projectPaths.filter { $0 == path || $0.hasSuffix(suffix) }
            if let best = matches.min(by: { ($0.count, $0) < ($1.count, $1) }) {
                return .file(path: best, line: line, column: column)
            }
        }
        return .missing(rawPath)
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The text that "发送选区到终端" pastes: `path:start-end`, then the whole selected lines in a fenced block.
enum TerminalSnippet {
    static func make(path: String, text: String, selection: NSRange) -> (reference: String, text: String)? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let range = EditorTextPosition.clamp(selection, in: text)
        // The last line of a selection that ends at a line start (a triple-click) is not part of it.
        let end = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        let lines = source.lineRange(for: NSRange(location: range.location, length: max(0, end - range.location)))
        var body = source.substring(with: lines)
        while let last = body.last, last.isNewline { body.removeLast() }
        // Part of a single line (a phrase in a paragraph) goes as selected; a selection across lines takes them whole.
        if range.length > 0, lines == source.lineRange(for: NSRange(location: range.location, length: 0)) {
            var exact = source.substring(with: range)
            while let last = exact.last, last.isNewline { exact.removeLast() }
            if !exact.trimmingCharacters(in: .whitespaces).isEmpty, exact.count < body.count { body = exact }
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        func lineNumber(_ location: Int) -> Int {
            var count = 1
            source.substring(to: location).utf16.forEach { if $0 == 10 { count += 1 } }
            return count
        }
        let first = lineNumber(lines.location), last = first + body.filter(\.isNewline).count
        let reference = first == last ? "\(path):\(first)" : "\(path):\(first)-\(last)"
        // Only the text itself: no path line, no code fence, no trailing newline, so it lands at the prompt as typed.
        guard let text = plain(body) else { return nil }
        return (reference, text)
    }

    /// Text as it goes into the terminal: control characters removed and trailing blank lines dropped.
    static func plain(_ text: String) -> String? {
        var clean = ReviewComment.sanitize(text)
        while let last = clean.last, last.isNewline || last == " " { clean.removeLast() }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clean
    }
}

/// What ⌘-hovering a path in the terminal shows: a changed file's diff summary and first changed lines, or the lines
/// around the named line of an unchanged file.
struct TerminalLinkPreview: Equatable {
    enum Kind: Equatable { case context, added, removed }
    struct Line: Equatable { let kind: Kind; let text: String }
    let path: String
    let summary: String
    let hint: String
    let lines: [Line]
    static let maximumLines = 10

    /// The first changed lines with one line of context before each block, from the hunks of one or more diffs.
    static func changed(path: String, diffs: [FileDiff]) -> TerminalLinkPreview {
        var added = 0, removed = 0, lines: [Line] = []
        for diff in diffs {
            for hunk in diff.hunks {
                var previous: DiffLine?
                for line in hunk.lines {
                    switch line.kind {
                    case .addition, .deletion:
                        if line.kind == .addition { added += 1 } else { removed += 1 }
                        if lines.count < maximumLines {
                            if let context = previous, context.kind == .context { lines.append(Line(kind: .context, text: context.text)) }
                            lines.append(Line(kind: line.kind == .addition ? .added : .removed, text: line.text))
                        }
                    default: break
                    }
                    previous = line
                }
            }
        }
        let summary = added + removed == 0 ? "有改动" : "+\(added) −\(removed)"
        return TerminalLinkPreview(path: path, summary: summary, hint: "⌘ 点击看改动", lines: Array(lines.prefix(maximumLines)))
    }

    /// Lines around `line` (1-based), or the first lines when no line was named.
    static func file(path: String, text: String, line: Int?, summary: String) -> TerminalLinkPreview {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (line ?? 1) - 3)
        let slice = all.dropFirst(start).prefix(maximumLines).map { Line(kind: .context, text: String($0)) }
        return TerminalLinkPreview(path: path, summary: summary, hint: line.map { "⌘ 点击打开第 \($0) 行" } ?? "⌘ 点击打开",
                                   lines: slice)
    }
}

struct TerminalLinkPreviewView: View {
    let preview: TerminalLinkPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(preview.path).themedFont(.system(size: 12, weight: .semibold, design: .monospaced), points: 12).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(preview.summary).themedFont(.caption.monospacedDigit(), points: 10).foregroundStyle(.secondary)
            }
            if !preview.lines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(color(line.kind))
                            Text(line.text.isEmpty ? " " : line.text).lineLimit(1).truncationMode(.tail)
                        }
                        .themedFont(.system(size: 11, design: .monospaced), points: 11)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.kind))
                    }
                }
                .themedBackground(ThemeColor(token: .hover), .control)
            }
            Text(preview.hint).themedFont(.caption2, points: 10).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 440)
    }
    private func color(_ kind: TerminalLinkPreview.Kind) -> ThemeColor {
        ThemeColor(token: kind == .added ? .added : kind == .removed ? .removed : .tertiaryText)
    }
    private func background(_ kind: TerminalLinkPreview.Kind) -> ThemeColor {
        ThemeColor(token: kind == .added ? .added : .removed, opacity: kind == .context ? 0 : 0.12)
    }
}
