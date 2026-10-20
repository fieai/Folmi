import AppKit
import FolmiCore
import SwiftUI

/// The index version of an open file, normalized like the editor buffer (LF newlines, no BOM),
/// plus what is needed to write a staged result back in the index's own form.
struct IndexBase: Equatable, Sendable {
    let path: String
    let mode: String
    let object: String
    let text: String
    let newline: String
    let hasBOM: Bool
    let mixedNewlines: Bool

    init?(_ file: GitRepository.IndexFile) {
        let hasBOM = file.data.starts(with: [0xEF, 0xBB, 0xBF])
        let content = hasBOM ? Data(file.data.dropFirst(3)) : file.data
        guard !content.contains(0), let raw = UTF8Text.decode(content) else { return nil }
        let crlf = raw.components(separatedBy: "\r\n").count - 1
        let rest = raw.replacingOccurrences(of: "\r\n", with: "")
        let styles = (crlf > 0 ? 1 : 0) + (rest.contains("\n") ? 1 : 0) + (rest.contains("\r") ? 1 : 0)
        path = file.path; mode = file.mode; object = file.object; self.hasBOM = hasBOM
        newline = crlf > 0 ? "\r\n" : (rest.contains("\r") ? "\r" : "\n")
        mixedNewlines = styles > 1
        text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Index bytes for normalized text, in the index's newline style and BOM.
    func encoded(_ normalized: String) -> Data {
        var data = Data((newline == "\n" ? normalized : normalized.replacingOccurrences(of: "\n", with: newline)).utf8)
        if hasBOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }
}

enum GutterDiff {
    /// Lines with their "\n" kept, so a missing final newline counts as a change like Git shows it.
    static func lines(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while let newline = text[start...].firstIndex(of: "\n") {
            let end = text.index(after: newline)
            result.append(String(text[start..<end]))
            start = end
        }
        if start < text.endIndex { result.append(String(text[start...])) }
        return result
    }

    static func changes(base: String, current: String) -> [LineDiff.Change] {
        LineDiff.changes(old: lines(base), new: lines(current))
    }

    /// The index text after taking one buffer change into it and leaving every other line as the index has it.
    static func staged(base: String, current: String, change: LineDiff.Change) -> String {
        let old = lines(base), new = lines(current)
        guard change.old.upperBound <= old.count, change.new.upperBound <= new.count else { return base }
        var replacement = Array(new[change.new])
        // Taking the buffer's last line into the middle of the index must not glue it to the next index line.
        if change.old.upperBound < old.count, let last = replacement.last, !last.hasSuffix("\n") {
            replacement[replacement.count - 1] = last + "\n"
        }
        return (Array(old[..<change.old.lowerBound]) + replacement + Array(old[change.old.upperBound...])).joined()
    }

    /// The UTF-16 range in the buffer covered by a change, and the index text that replaces it on revert.
    static func revert(base: String, current: String, change: LineDiff.Change) -> (range: NSRange, replacement: String)? {
        let old = lines(base), new = lines(current)
        guard change.old.upperBound <= old.count, change.new.upperBound <= new.count else { return nil }
        let location = new[..<change.new.lowerBound].reduce(0) { $0 + ($1 as NSString).length }
        let length = new[change.new].reduce(0) { $0 + ($1 as NSString).length }
        var replacement = old[change.old].joined()
        // Reverting the buffer's tail must keep the newline that separates it from following buffer lines.
        if change.new.upperBound < new.count, !replacement.isEmpty, !replacement.hasSuffix("\n") { replacement += "\n" }
        return (NSRange(location: location, length: length), replacement)
    }

    /// Per-line kinds for drawing: lines added or modified in the buffer, and the buffer line before which lines were removed.
    struct Marks: Equatable {
        enum Kind: Equatable { case added, modified }
        var lineKinds: [Int: Kind] = [:]
        var deletionsBefore: Set<Int> = []
        var changes: [LineDiff.Change] = []

        init() {}
        init(_ changes: [LineDiff.Change]) {
            self.changes = changes
            for change in changes {
                if change.isDeletion { deletionsBefore.insert(change.new.lowerBound); continue }
                for line in change.new { lineKinds[line] = change.isInsertion ? .added : .modified }
            }
        }

        /// The change a click on this buffer line refers to; a deletion marker sits on the line after the removed lines.
        func change(atLine line: Int) -> LineDiff.Change? {
            changes.first { $0.new.contains(line) } ?? changes.first { $0.isDeletion && ($0.new.lowerBound == line || $0.new.lowerBound == line + 1) }
        }
    }
}

struct GutterPeekView: View {
    let path: String
    let removed: [String]
    let kind: String
    let canStage: Bool
    let stageHelp: String
    let onRevert: () -> Void
    let onStage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind).themedFont(.caption.weight(.semibold), points: 10)
                Text(path).themedFont(.caption, points: 10).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if removed.isEmpty {
                Text("暂存区里没有对应的旧内容。").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(removed.map { "- " + $0.trimmingCharacters(in: .newlines) }.joined(separator: "\n"))
                        .themedFont(.system(size: 11, design: .monospaced), points: 11)
                        .foregroundStyle(ThemeColor(token: .removed, opacity: 0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 220)
                .background(ThemeColor(token: .removed, opacity: 0.07), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("还原这段", action: onRevert).help("用暂存区内容替换编辑器里的这段，可以撤销（⌘Z）")
                Button("暂存这段", action: onStage).disabled(!canStage).help(stageHelp)
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 420)
    }
}
