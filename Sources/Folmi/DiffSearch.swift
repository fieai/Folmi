import Foundation
import FolmiCore

struct DiffSearchHit: Hashable, Sendable {
    let fileKey: String
    let hunkID: String?
    let lineID: Int
    let range: NSRange

    func rowIndex(in rows: [AlignedDiffRow], unified: Bool) -> Int? {
        if unified { return DiffRowsCanvas.unify(rows).firstIndex { $0.cell.line.id == lineID } }
        return rows.firstIndex { $0.old?.line.id == lineID || $0.new?.line.id == lineID }
    }
}

enum DiffSearch {
    static let limit = 10_000

    struct Result: Sendable {
        var hits: [DiffSearchHit] = []
        var limited = false
    }

    /// Search the same bounded projection the canvas can display, including removed lines and folded files.
    static func find(_ query: String, in diffs: [FileDiff]) throws -> Result {
        var result = Result()
        guard !query.isEmpty else { return result }
        for diff in diffs {
            try Task.checkCancellation()
            let plan = SideBySideDisplayBudget.plan(for: diff)
            func scan(_ rows: [AlignedDiffRow], hunkID: String?) throws -> Bool {
                for row in DiffRowsCanvas.unify(rows) {
                    try Task.checkCancellation()
                    let line = row.cell.line
                    guard line.kind != .meta else { continue }
                    let text = SideBySideDisplayBudget.clippedText(line.text).text as NSString
                    var start = 0
                    while start < text.length {
                        let range = text.range(of: query, options: [.caseInsensitive, .literal],
                                               range: NSRange(location: start, length: text.length - start))
                        guard range.location != NSNotFound else { break }
                        guard result.hits.count < limit else { return false }
                        result.hits.append(.init(fileKey: diff.allChangesKey, hunkID: hunkID, lineID: line.id, range: range))
                        start = NSMaxRange(range)
                    }
                }
                return true
            }
            for section in plan.sections {
                if try !scan(section.rows, hunkID: section.id) { result.limited = true; return result }
            }
            if try !scan(plan.untrackedRows, hunkID: nil) { result.limited = true; return result }
        }
        return result
    }
}

enum DiffWords {
    private static let tokens = try! NSRegularExpression(pattern: #"\p{Han}|(?:(?!\p{Han})[\p{L}\p{M}\p{N}_])+|\s+|\X"#)

    /// Calculate only for paired lines the canvas draws. Bound the word diff on minified or generated code.
    static func changedRanges(in text: String, comparedTo other: String) -> [NSRange] {
        guard text != other, !text.isEmpty else { return [] }
        func tokenize(_ value: String) -> [(text: String, range: NSRange)] {
            let string = value as NSString
            return tokens.matches(in: value, range: NSRange(location: 0, length: string.length))
                .map { (string.substring(with: $0.range), $0.range) }
        }
        let current = tokenize(text), previous = tokenize(other)
        let a = current.map(\.text), b = previous.map(\.text)
        if a.count <= 128, b.count <= 128 {
            return a.difference(from: b).insertions.compactMap {
                if case let .insert(offset, _, _) = $0 { return current[offset].range }
                return nil
            }
        }
        let prefix = zip(a, b).prefix(while: { $0.0 == $0.1 }).count
        let suffix = zip(a.dropFirst(prefix).reversed(), b.dropFirst(prefix).reversed()).prefix(while: { $0.0 == $0.1 }).count
        let end = current.count - suffix
        guard prefix < end else { return [] }
        let start = current[prefix].range.location
        return [NSRange(location: start, length: NSMaxRange(current[end - 1].range) - start)]
    }
}
