import Foundation
import FolmiCore

extension FileDiff {
    var canEditPoint: Bool { !isBinary && !file.isConflict && file.worktreeCode != "D" && file.indexCode != "D" }
}

/// A line in the newer side of a diff, before translating it to the editor's working copy.
struct DiffEditPoint {
    let line: Int
    let hunk: DiffHunk?
    var lineID: Int? = nil

    static func inHunk(_ hunk: DiffHunk, selected: Set<Int> = [], lineID: Int? = nil) -> Self? {
        let rows = DiffAlignment.rows(in: hunk)
        let index: Int?
        if let lineID {
            index = rows.firstIndex { $0.old?.line.id == lineID || $0.new?.line.id == lineID }
        } else {
            index = rows.firstIndex { row in row.new.map { $0.line.kind == .addition && selected.contains($0.line.id) } == true }
                ?? rows.firstIndex { row in row.old.map { $0.line.kind == .deletion && selected.contains($0.line.id) } == true }
                ?? rows.firstIndex { $0.new?.line.kind == .addition || $0.old?.line.kind == .deletion }
        }
        guard let index else { return nil }
        let row = rows[index]
        // A deleted row has no editable source; use its replacement or the insertion point between the surrounding lines.
        let line = row.new?.lineNumber
            ?? rows[index...].compactMap { $0.new?.lineNumber }.first
            ?? rows[..<index].reversed().compactMap { $0.new?.lineNumber }.first.map { $0 + 1 }
            ?? 1
        return Self(line: line, hunk: hunk, lineID: lineID ?? row.new?.line.id ?? row.old?.line.id)
    }

    /// An older patch can still be on screen while a refresh is running. Validate its context against the same
    /// version that provided its line numbers before translating them.
    func matches(_ text: String) -> Bool {
        guard let hunk else { return true }
        let lines = text.components(separatedBy: "\n")
        return DiffAlignment.rows(in: hunk).allSatisfy { row in
            guard let cell = row.new, let line = cell.lineNumber else { return true }
            var expected = cell.line.text
            if expected.hasSuffix("\r") { expected.removeLast() }
            if line == 1, expected.hasPrefix("\u{FEFF}") { expected.removeFirst() }
            return line > 0 && lines.indices.contains(line - 1) && lines[line - 1] == expected
        }
    }

    static func translatedLine(_ line: Int, from reference: String, into buffer: String) -> Int {
        guard reference != buffer else { return line }
        let index = line - 1
        var offset = 0
        for change in GutterDiff.changes(base: reference, current: buffer) {
            if index < change.old.lowerBound { break }
            if change.old.contains(index) {
                return change.new.lowerBound + min(index - change.old.lowerBound, max(0, change.new.count - 1)) + 1
            }
            offset = change.new.upperBound - change.old.upperBound
        }
        return max(1, line + offset)
    }
}

/// What to reopen once editing is done. A patch's IDs are positional, so never reuse a row ID after the patch changes.
struct DiffEditReturn: Equatable {
    let path: String
    let area: ChangeArea
    let content: FolmiContent
    let fingerprint: String
    let hunkID: String?
    let hunkHeader: String?
    let line: Int
    let lineID: Int?
    let id = UUID()

    var key: String { area.rawValue + ":" + path }
    var rowAnchor: String { key + "#edit-" + String(lineID ?? -1) }

    func hunk(in diff: FileDiff) -> DiffHunk? {
        if fingerprint == diff.fingerprint, let hunk = diff.hunks.first(where: { $0.id == hunkID }) { return hunk }
        if let hunk = diff.hunks.first(where: { $0.header == hunkHeader }) { return hunk }
        return diff.hunks.min {
            abs((DiffEditPoint.inHunk($0)?.line ?? line) - line) < abs((DiffEditPoint.inHunk($1)?.line ?? line) - line)
        }
    }

    func rowID(in diff: FileDiff) -> Int? { diff.fingerprint == fingerprint ? lineID : nil }
}
