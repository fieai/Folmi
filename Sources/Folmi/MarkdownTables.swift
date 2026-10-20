import Foundation

/// GitHub pipe tables: splitting rows into cells, and Tab / Shift-Tab between cells. Pure, so every rule is testable.
/// The source is never padded or rewritten for display; the editor aligns columns with kerning instead.
enum MarkdownTable {
    enum Alignment: Equatable, Sendable { case left, center, right }

    struct Row: Equatable {
        /// UTF-16 locations of the cell-separating pipes, leading and trailing pipes included.
        let pipes: [Int]
        /// Cell contents between pipes (spaces included), in UTF-16 locations of the whole text.
        let cells: [NSRange]
        let hasLeadingPipe: Bool
    }

    /// Splits `units[start..<end]` (one line without its line break) at unescaped pipes.
    /// Nil when the line has no pipe, so it is not a table row.
    static func row(_ units: [UInt16], start: Int, end: Int) -> Row? {
        var pipes: [Int] = []
        var cursor = start
        while cursor < end {
            if units[cursor] == 92 { cursor += 2; continue }
            if units[cursor] == 124 { pipes.append(cursor) }
            cursor += 1
        }
        guard !pipes.isEmpty else { return nil }
        var contentStart = start
        while contentStart < end, units[contentStart] == 32 || units[contentStart] == 9 { contentStart += 1 }
        var contentEnd = end
        while contentEnd > contentStart, units[contentEnd - 1] == 32 || units[contentEnd - 1] == 9 { contentEnd -= 1 }
        let leading = pipes.first == contentStart
        let trailing = pipes.last == contentEnd - 1 && !(leading && pipes.count == 1)
        var bounds = pipes
        if !leading { bounds.insert(contentStart - 1, at: 0) }
        if !trailing { bounds.append(contentEnd) }
        var cells: [NSRange] = []
        for index in 0..<(bounds.count - 1) {
            let from = bounds[index] + 1, to = bounds[index + 1]
            cells.append(NSRange(location: from, length: max(0, to - from)))
        }
        return Row(pipes: pipes, cells: cells, hasLeadingPipe: leading)
    }

    /// The column alignments of a delimiter row such as `| --- | :-: | --: |`, or nil when it is not one.
    static func delimiter(_ units: [UInt16], start: Int, end: Int) -> [Alignment]? {
        guard let row = row(units, start: start, end: end), !row.cells.isEmpty else { return nil }
        var result: [Alignment] = []
        for cell in row.cells {
            var from = cell.location, to = NSMaxRange(cell)
            while from < to, units[from] == 32 || units[from] == 9 { from += 1 }
            while to > from, units[to - 1] == 32 || units[to - 1] == 9 { to -= 1 }
            guard to > from else { return nil }
            let left = units[from] == 58, right = units[to - 1] == 58
            let dashes = units[(left ? from + 1 : from)..<(right ? to - 1 : to)]
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == 45 }) else { return nil }
            result.append(left && right ? .center : right ? .right : .left)
        }
        return result
    }

    // MARK: Editing

    private static func lineRanges(_ source: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var cursor = 0
        while cursor < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
            lines.append(NSRange(location: start, length: contentsEnd - start))
            cursor = end
        }
        if source.length == 0 || [10, 13].contains(source.character(at: source.length - 1)) {
            lines.append(NSRange(location: source.length, length: 0))
        }
        return lines
    }

    /// The rows of the table around `location`: the header, the delimiter and the body rows.
    static func table(in text: String, at location: Int) -> (rows: [(line: NSRange, row: Row)], delimiterIndex: Int)? {
        let source = text as NSString
        let units = Array(text.utf16)
        let lines = lineRanges(source)
        guard let current = lines.firstIndex(where: { location >= $0.location && location <= NSMaxRange($0) }) else { return nil }
        func row(_ index: Int) -> Row? {
            guard lines.indices.contains(index) else { return nil }
            return MarkdownTable.row(units, start: lines[index].location, end: NSMaxRange(lines[index]))
        }
        guard row(current) != nil else { return nil }
        var first = current
        while first > 0, row(first - 1) != nil { first -= 1 }
        // The header is the row right above the first delimiter row of this run of pipe lines.
        guard let delimiterLine = (first + 1...max(first + 1, current + 1)).first(where: { index in
            lines.indices.contains(index) && row(index) != nil &&
                delimiter(units, start: lines[index].location, end: NSMaxRange(lines[index])) != nil
        }) else { return nil }
        let header = delimiterLine - 1
        guard header <= current else { return nil }
        var last = delimiterLine
        while let _ = row(last + 1) { last += 1 }
        let rows = (header...last).map { (lines[$0], row($0)!) }
        return (rows, delimiterLine - header)
    }

    /// Tab moves to the next cell and selects its text; Shift-Tab to the previous one. The delimiter row is skipped.
    /// Tab in the last cell adds an empty row. Nil outside a table.
    static func tab(text: String, selection: NSRange, backward: Bool) -> EditorLineEdit? {
        guard let table = table(in: text, at: selection.location) else { return nil }
        let source = text as NSString
        var cells: [(row: Int, cell: NSRange)] = []
        for (index, row) in table.rows.enumerated() where index != table.delimiterIndex {
            for cell in row.row.cells { cells.append((index, cell)) }
        }
        guard let current = cells.lastIndex(where: { selection.location >= $0.cell.location && selection.location <= NSMaxRange($0.cell) })
                ?? cells.lastIndex(where: { $0.cell.location <= selection.location }) else { return nil }
        func select(_ cell: NSRange) -> EditorLineEdit {
            var from = cell.location, to = NSMaxRange(cell)
            while from < to, source.character(at: from) == 32 { from += 1 }
            while to > from, source.character(at: to - 1) == 32 { to -= 1 }
            if from == to { from = min(NSMaxRange(cell), cell.location + 1); to = from }
            return EditorLineEdit(range: NSRange(location: from, length: 0), replacement: "", selection: NSRange(location: from, length: to - from))
        }
        if backward {
            guard current > 0 else { return select(cells[current].cell) }
            return select(cells[current - 1].cell)
        }
        if current + 1 < cells.count { return select(cells[current + 1].cell) }
        // Past the last cell: a new row with as many cells as the header.
        let header = table.rows[0].row
        let lastLine = table.rows[table.rows.count - 1].line
        let columns = max(1, header.cells.count)
        let newRow = (header.hasLeadingPipe ? "| " : "") + Array(repeating: " ", count: columns).joined(separator: " | ") + " |"
        let insertion = "\n" + newRow
        let caret = NSMaxRange(lastLine) + 1 + (header.hasLeadingPipe ? 2 : 0)
        return EditorLineEdit(range: NSRange(location: NSMaxRange(lastLine), length: 0), replacement: insertion,
                              selection: NSRange(location: caret, length: 0))
    }

    /// ⌥⌘T: a two-column table with the first header cell selected, on its own lines.
    static func insert(text: String, selection: NSRange) -> EditorLineEdit {
        let source = text as NSString
        let lineStart = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let atLineStart = selection.location == lineStart
        let prefix = atLineStart ? "" : "\n\n"
        let header = "| 列 1 | 列 2 |"
        let table = prefix + header + "\n| --- | --- |\n|  |  |\n"
        let start = selection.location + (prefix as NSString).length + 2
        return EditorLineEdit(range: selection, replacement: table, selection: NSRange(location: start, length: ("列 1" as NSString).length))
    }
}
