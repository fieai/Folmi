import Foundation

/// A rendered side of a unified-diff row. The source line and its identifier are
/// preserved so selection continues to address the original Git patch.
public struct AlignedDiffCell: Hashable, Sendable {
    public let line: DiffLine
    public let lineNumber: Int?

    public init(line: DiffLine, lineNumber: Int?) {
        self.line = line
        self.lineNumber = lineNumber
    }
}

public struct AlignedDiffRow: Identifiable, Hashable, Sendable {
    /// Unique within the containing hunk; callers must namespace hunks by file.
    public let id: Int
    public let old: AlignedDiffCell?
    public let new: AlignedDiffCell?

    public init(id: Int, old: AlignedDiffCell?, new: AlignedDiffCell?) {
        self.id = id
        self.old = old
        self.new = new
    }
}

public enum DiffAlignment {
    private struct PendingLine {
        let cell: AlignedDiffCell
        var annotations: [DiffLine] = []
    }

    /// Aligns each contiguous change block independently. Context is the boundary
    /// between change blocks, never a candidate for matching a changed line.
    public static func rows(in hunk: DiffHunk) -> [AlignedDiffRow] {
        let starts = startingLines(hunk.header)
        var oldNumber = starts?.old
        var newNumber = starts?.new
        var result: [AlignedDiffRow] = []
        var oldChanges: [PendingLine] = []
        var newChanges: [PendingLine] = []
        var lastChangeWasOld = false

        func append(_ old: AlignedDiffCell?, _ new: AlignedDiffCell?) {
            result.append(AlignedDiffRow(id: result.count, old: old, new: new))
        }

        func flushChanges() {
            for position in 0..<max(oldChanges.count, newChanges.count) {
                let old = position < oldChanges.count ? oldChanges[position] : nil
                let new = position < newChanges.count ? newChanges[position] : nil
                append(old?.cell, new?.cell)
                // Git's no-newline markers belong to the immediately preceding
                // source line. Keep them beside that line without consuming a
                // content line number or disturbing replacement pairing.
                for annotation in 0..<max(old?.annotations.count ?? 0, new?.annotations.count ?? 0) {
                    let oldMeta = annotation < (old?.annotations.count ?? 0) ? old?.annotations[annotation] : nil
                    let newMeta = annotation < (new?.annotations.count ?? 0) ? new?.annotations[annotation] : nil
                    append(oldMeta.map { AlignedDiffCell(line: $0, lineNumber: nil) },
                           newMeta.map { AlignedDiffCell(line: $0, lineNumber: nil) })
                }
            }
            oldChanges.removeAll(keepingCapacity: true)
            newChanges.removeAll(keepingCapacity: true)
        }

        for line in hunk.lines {
            switch line.kind {
            case .context:
                flushChanges()
                append(AlignedDiffCell(line: line, lineNumber: oldNumber),
                       AlignedDiffCell(line: line, lineNumber: newNumber))
                oldNumber = oldNumber.map { $0 + 1 }
                newNumber = newNumber.map { $0 + 1 }
            case .deletion:
                oldChanges.append(PendingLine(cell: AlignedDiffCell(line: line, lineNumber: oldNumber)))
                oldNumber = oldNumber.map { $0 + 1 }
                lastChangeWasOld = true
            case .addition:
                newChanges.append(PendingLine(cell: AlignedDiffCell(line: line, lineNumber: newNumber)))
                newNumber = newNumber.map { $0 + 1 }
                lastChangeWasOld = false
            case .meta:
                if lastChangeWasOld, !oldChanges.isEmpty {
                    oldChanges[oldChanges.count - 1].annotations.append(line)
                } else if !newChanges.isEmpty {
                    newChanges[newChanges.count - 1].annotations.append(line)
                } else {
                    let annotation = AlignedDiffCell(line: line, lineNumber: nil)
                    append(annotation, annotation)
                }
            }
        }
        flushChanges()
        return result
    }

    private static func startingLines(_ header: String) -> (old: Int, new: Int)? {
        let pattern = #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header),
              let old = Int(header[oldRange]), let new = Int(header[newRange]) else { return nil }
        return (old, new)
    }
}
