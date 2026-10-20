import Foundation

enum Patch {
    static func hunks(_ raw: String) -> [DiffHunk] {
        var result: [DiffHunk] = []
        var header: String?, start = 0, lines: [DiffLine] = []
        var parts = raw.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        for (position, text) in parts.enumerated() {
            if text.hasPrefix("@@ ") {
                if let header { result.append(DiffHunk(id: "hunk-\(start)", header: header, lines: lines)) }
                header = text; start = position; lines = []
            } else if header != nil {
                let kind: DiffLineKind
                switch text.first { case "+": kind = .addition; case "-": kind = .deletion; case " ": kind = .context; default: kind = .meta }
                lines.append(DiffLine(id: position, text: kind == .meta ? text : String(text.dropFirst()), kind: kind))
            }
        }
        if let header { result.append(DiffHunk(id: "hunk-\(start)", header: header, lines: lines)) }
        return result
    }

    /// Applies the chosen lines of one hunk to the current index text and returns the new index text.
    /// Staging (working area, index → work tree) adds selected work-tree changes; unstaging (staged area, HEAD → index)
    /// reverts selected index changes. Every line the hunk claims is in the index is checked against the index first,
    /// so nothing is applied with fuzz.
    static func indexContent(_ index: String, diff: FileDiff, hunk: DiffHunk, selection: Set<Int>?) throws -> String {
        try apply(index, hunk: hunk, selection: selection, forward: diff.area == .working)
    }

    /// Takes the chosen lines of a work-tree hunk (index → work tree) back out of the work-tree text: added lines go,
    /// removed lines return. Same exact matching as `indexContent`.
    static func revertedWorktree(_ worktree: String, hunk: DiffHunk, selection: Set<Int>?) throws -> String {
        try apply(worktree, hunk: hunk, selection: selection, forward: false)
    }

    /// `forward`: the text is the hunk's old side and gets the new side's lines; otherwise the reverse.
    private static func apply(_ index: String, hunk: DiffHunk, selection: Set<Int>?, forward staging: Bool) throws -> String {
        let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        guard let match = regex.firstMatch(in: hunk.header, range: NSRange(hunk.header.startIndex..., in: hunk.header)),
              let oldRange = Range(match.range(at: 1), in: hunk.header), let newRange = Range(match.range(at: 3), in: hunk.header),
              let oldStart = Int(hunk.header[oldRange]), let newStart = Int(hunk.header[newRange]) else {
            throw FolmiError.unsupported("无法解析此差异块。")
        }
        // A line with an empty count starts *after* the given line number.
        let indexStart = staging ? oldStart : newStart
        let countGroup = match.range(at: staging ? 2 : 4)
        let indexCountIsZero = countGroup.location != NSNotFound && Range(countGroup, in: hunk.header).map { hunk.header[$0] == "0" } == true

        // Index lines, each remembering whether it ended with "\n".
        var lines = index.components(separatedBy: "\n").map { (text: $0, newline: true) }
        if index.hasSuffix("\n") || index.isEmpty { lines.removeLast() } else { lines[lines.count - 1].newline = false }
        if index.isEmpty { lines = [] }

        var cursor = indexCountIsZero ? indexStart : indexStart - 1
        guard cursor >= 0, cursor <= lines.count else { throw FolmiError.staleSnapshot }
        var output = Array(lines[..<cursor])
        var changed = false
        var insertedPrevious = false
        for line in hunk.lines {
            if line.kind == .meta {
                // "\ No newline at end of file" belongs to the line before it. Index lines already carry that from
                // the index text itself; a line inserted from the other side takes it over.
                guard line.text.hasPrefix("\\") else { throw FolmiError.unsupported("此差异包含暂不支持的元数据。") }
                if insertedPrevious { output[output.count - 1].newline = false }
                continue
            }
            insertedPrevious = false
            let inIndex = line.kind == .context || line.kind == (staging ? .deletion : .addition)
            let selected = line.kind != .context && (selection?.contains(line.id) ?? true)
            if inIndex {
                guard cursor < lines.count, lines[cursor].text == line.text else { throw FolmiError.staleSnapshot }
                if selected { changed = true } else { output.append(lines[cursor]) }
                cursor += 1
            } else if selected {
                output.append((text: line.text, newline: true))
                insertedPrevious = true
                changed = true
            }
        }
        guard changed else { throw FolmiError.invalidSelection }
        output += lines[cursor...]
        var text = output.map(\.text).joined(separator: "\n")
        if output.last?.newline ?? false { text += "\n" }
        return text
    }
}
