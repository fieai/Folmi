import Foundation

/// Commands behind the selection format bar, the `/` menu and the code-block tools. Each produces one
/// `EditorLineEdit` against the Markdown source, so every command is a single undo step and touches only its lines.
/// Nothing here touches AppKit.
enum MarkdownCommands {
    typealias Edit = EditorLineEdit

    // MARK: Format bar state

    /// Which inline styles already wrap the selection, so the bar shows them as on.
    struct FormatState: Equatable {
        var bold = false, italic = false, strike = false, code = false
        /// The heading level of the selection's first line; 0 for body text.
        var heading = 0
        /// The selection spans more than one line; inline wraps are disabled.
        var multiline = false
    }

    static func formatState(text: String, selection: NSRange) -> FormatState {
        let source = text as NSString
        guard NSMaxRange(selection) <= source.length else { return FormatState() }
        func wrapped(_ marker: String) -> Bool {
            let edit = MarkdownEditing.toggleWrap(text: text, selection: selection, marker: marker)
            return (edit.replacement as NSString).length < edit.range.length
        }
        let selected = source.substring(with: selection)
        var state = FormatState()
        state.multiline = selected.contains("\n") || selected.contains("\r")
        if !state.multiline {
            state.bold = wrapped("**"); state.italic = wrapped("*"); state.strike = wrapped("~~"); state.code = wrapped("`")
        }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let content = source.substring(with: line)
        let hashes = content.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), content.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) == true { state.heading = hashes }
        return state
    }

    /// Sets the heading level (0 = body text) of every line the selection touches, in one edit. Other block prefixes
    /// (lists, quotes) are kept as source; a heading replaces only a heading prefix.
    static func heading(text: String, selection: NSRange, level: Int) -> Edit? {
        let source = text as NSString
        guard NSMaxRange(selection) <= source.length else { return nil }
        let end = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let first = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = source.lineRange(for: NSRange(location: max(selection.location, end), length: 0))
        let block = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let lines = source.substring(with: block).components(separatedBy: "\n")
        var shift = 0, firstShift = 0
        let rewritten = lines.enumerated().map { index, line -> String in
            let isTrailingEmpty = index == lines.count - 1 && line.isEmpty && lines.count > 1
            guard !isTrailingEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty || lines.count == 1 else { return line }
            let hashes = line.prefix { $0 == "#" }.count
            let hasHeading = (1...6).contains(hashes) && line.dropFirst(hashes).first.map { $0 == " " || $0 == "\t" } == true
            var body = line
            if hasHeading { body = String(line.dropFirst(hashes)).replacingOccurrences(of: #"^[ \t]+"#, with: "", options: .regularExpression) }
            let prefix = level == 0 ? "" : String(repeating: "#", count: level) + " "
            let result = prefix + body
            let delta = (result as NSString).length - (line as NSString).length
            if index == 0 { firstShift = delta }
            shift += delta
            return result
        }
        let replacement = rewritten.joined(separator: "\n")
        guard replacement != source.substring(with: block) else { return nil }
        let start = max(first.location, selection.location + firstShift)
        let length = selection.length == 0 ? 0 : max(0, selection.length + shift - firstShift)
        return Edit(range: block, replacement: replacement, selection: NSRange(location: start, length: length))
    }

    // MARK: `/` menu

    struct SlashCommand: Equatable, Identifiable {
        enum Action: Equatable {
            case paragraph, heading(Int), bullet, numbered, task, quote, rule, code, table, image, link, wiki
        }
        let id: String
        let title: String
        let symbol: String
        let hint: String
        let aliases: [String]
        let action: Action
    }

    static let slashCommands: [SlashCommand] = [
        SlashCommand(id: "text", title: "正文", symbol: "text.alignleft", hint: "⌥⌘0", aliases: ["zhengwen", "zw", "text", "paragraph", "p", "body"], action: .paragraph),
        SlashCommand(id: "h1", title: "一级标题", symbol: "1.square", hint: "⌥⌘1", aliases: ["biaoti1", "bt1", "h1", "heading1", "标题1", "title"], action: .heading(1)),
        SlashCommand(id: "h2", title: "二级标题", symbol: "2.square", hint: "⌥⌘2", aliases: ["biaoti2", "bt2", "h2", "heading2", "标题2"], action: .heading(2)),
        SlashCommand(id: "h3", title: "三级标题", symbol: "3.square", hint: "⌥⌘3", aliases: ["biaoti3", "bt3", "h3", "heading3", "标题3"], action: .heading(3)),
        SlashCommand(id: "h4", title: "四级标题", symbol: "4.square", hint: "⌥⌘4", aliases: ["biaoti4", "bt4", "h4", "heading4", "标题4"], action: .heading(4)),
        SlashCommand(id: "h5", title: "五级标题", symbol: "5.square", hint: "⌥⌘5", aliases: ["biaoti5", "bt5", "h5", "heading5", "标题5"], action: .heading(5)),
        SlashCommand(id: "h6", title: "六级标题", symbol: "6.square", hint: "⌥⌘6", aliases: ["biaoti6", "bt6", "h6", "heading6", "标题6"], action: .heading(6)),
        SlashCommand(id: "bullet", title: "无序列表", symbol: "list.bullet", hint: "- ", aliases: ["wuxuliebiao", "wxlb", "liebiao", "lb", "bullet", "ul", "list"], action: .bullet),
        SlashCommand(id: "numbered", title: "有序列表", symbol: "list.number", hint: "1. ", aliases: ["youxuliebiao", "yxlb", "bianhao", "bh", "ol", "number", "numbered"], action: .numbered),
        SlashCommand(id: "task", title: "待办", symbol: "checklist", hint: "- [ ]", aliases: ["daiban", "db", "renwu", "rw", "todo", "task", "checkbox"], action: .task),
        SlashCommand(id: "quote", title: "引用", symbol: "text.quote", hint: "> ", aliases: ["yinyong", "yy", "quote", "blockquote"], action: .quote),
        SlashCommand(id: "rule", title: "分隔线", symbol: "minus", hint: "---", aliases: ["fengexian", "fgx", "divider", "hr", "line", "rule"], action: .rule),
        SlashCommand(id: "code", title: "代码块", symbol: "chevron.left.forwardslash.chevron.right", hint: "```", aliases: ["daimakuai", "daima", "dm", "dmk", "code", "codeblock"], action: .code),
        SlashCommand(id: "table", title: "表格", symbol: "tablecells", hint: "⌥⌘T", aliases: ["biaoge", "bg", "table"], action: .table),
        SlashCommand(id: "image", title: "图片", symbol: "photo", hint: "选择文件", aliases: ["tupian", "tp", "image", "img", "picture", "pic"], action: .image),
        SlashCommand(id: "link", title: "链接", symbol: "link", hint: "⇧⌘K", aliases: ["lianjie", "lj", "link", "url"], action: .link),
        SlashCommand(id: "wiki", title: "双链笔记", symbol: "link.badge.plus", hint: "[[ ]]", aliases: ["shuanglian", "sl", "wiki", "note", "biji", "bj"], action: .wiki),
    ]

    /// Commands for what was typed after `/`: exact matches, then prefixes, then other matches; all of them, in
    /// their fixed order, for an empty query.
    static func slashMatches(_ query: String) -> [SlashCommand] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return slashCommands }
        let ranked = slashCommands.enumerated().compactMap { index, command -> (Int, Int, SlashCommand)? in
            let names = [command.title.lowercased()] + command.aliases
            if names.contains(needle) { return (0, index, command) }
            if names.contains(where: { $0.hasPrefix(needle) }) { return (1, index, command) }
            if names.contains(where: { $0.contains(needle) }) { return (2, index, command) }
            return nil
        }
        return ranked.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    /// The `/query` just before the caret, when a menu may open there: at the start of a line (after indentation or a
    /// list/quote prefix) or after a space, outside code, link addresses and `[[` names. `、` counts as `/`, since a
    /// Chinese input method types it for that key.
    static func slashTrigger(text: String, selection: NSRange) -> (range: NSRange, query: String)? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: selection.location - line.location)) as NSString
        var index = before.length - 1
        while index >= 0, before.length - index <= 21 {
            let character = before.character(at: index)
            if character == 47 || character == 0x3001 { break } // "/" or "、"
            if character == 32 || character == 9 || character == 0x3000 { return nil }
            index -= 1
        }
        guard index >= 0, before.length - index <= 21 else { return nil }
        let character = before.character(at: index)
        guard character == 47 || character == 0x3001 else { return nil }
        if index > 0 {
            let previous = before.character(at: index - 1)
            guard previous == 32 || previous == 9 || previous == 0x3000 else { return nil }
        }
        let head = before.substring(to: index)
        // Inside inline code: an odd number of backticks before it on the line.
        guard head.filter({ $0 == "`" }).count % 2 == 0 else { return nil }
        // Inside a link address: an unclosed "](" before it.
        if let open = head.range(of: "](", options: .backwards), !head[open.upperBound...].contains(")") { return nil }
        guard MarkdownWiki.partialRange(text: text, selection: selection) == nil else { return nil }
        guard !MarkdownEditing.inFence(text, at: selection.location) else { return nil }
        let query = before.substring(from: index + 1)
        return (NSRange(location: line.location + index, length: selection.location - line.location - index), query)
    }

    /// The edit a `/` command makes, replacing its trigger. Nil for `.image`, which needs a file first (`imageEdit`).
    static func slashEdit(_ action: SlashCommand.Action, text: String, trigger: NSRange) -> Edit? {
        let source = text as NSString
        guard NSMaxRange(trigger) <= source.length else { return nil }
        // The trigger's line without its newline, and the same line with the trigger taken out.
        var line = source.lineRange(for: NSRange(location: trigger.location, length: 0))
        if line.length > 0, source.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let offset = trigger.location - line.location
        let content = source.substring(with: line) as NSString
        let without = content.replacingCharacters(in: NSRange(location: offset, length: trigger.length), with: "")
        let blank = without.trimmingCharacters(in: .whitespaces).isEmpty

        func prefixed(_ prefix: String) -> Edit {
            // Swap any block prefix the line already has for the new one, keeping its text.
            let body = strippedBlockPrefix(without)
            let lost = (without as NSString).length - (body.text as NSString).length
            let caret = line.location + (prefix as NSString).length + max(0, offset - lost)
            return Edit(range: line, replacement: prefix + body.text, selection: NSRange(location: caret, length: 0))
        }
        /// A block of its own: in place of a blank line, or on new lines after the text.
        func block(_ lines: String, caretInBlock: Int) -> Edit {
            if blank {
                return Edit(range: line, replacement: lines, selection: NSRange(location: line.location + caretInBlock, length: 0))
            }
            let kept = without as NSString
            let replacement = (kept as String) + "\n" + lines
            return Edit(range: line, replacement: replacement,
                        selection: NSRange(location: line.location + kept.length + 1 + caretInBlock, length: 0))
        }
        switch action {
        case .paragraph: return prefixed("")
        case .heading(let level): return prefixed(String(repeating: "#", count: min(6, max(1, level))) + " ")
        case .bullet: return prefixed("- ")
        case .numbered: return prefixed("1. ")
        case .task: return prefixed("- [ ] ")
        case .quote: return prefixed("> ")
        case .rule:
            // The new line after the rule is where typing goes on.
            return block("---\n", caretInBlock: 4)
        case .code:
            return block("```\n\n```", caretInBlock: 4)
        case .table:
            let after = source.replacingCharacters(in: trigger, with: "")
            let table = MarkdownTable.insert(text: after, selection: NSRange(location: trigger.location, length: 0))
            return Edit(range: trigger, replacement: table.replacement, selection: table.selection)
        case .link:
            return Edit(range: trigger, replacement: "[]()", selection: NSRange(location: trigger.location + 1, length: 0))
        case .wiki:
            return Edit(range: trigger, replacement: "[[]]", selection: NSRange(location: trigger.location + 2, length: 0))
        case .image:
            return nil
        }
    }

    /// Image Markdown chosen for a `/图片` trigger, on its own line.
    static func imageEdit(_ markdown: String, text: String, trigger: NSRange) -> Edit {
        let source = text as NSString
        var line = source.lineRange(for: NSRange(location: trigger.location, length: 0))
        if line.length > 0, source.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let content = source.substring(with: line) as NSString
        let without = content.replacingCharacters(in: NSRange(location: trigger.location - line.location, length: trigger.length), with: "")
        let replacement = without.trimmingCharacters(in: .whitespaces).isEmpty ? markdown : without + "\n" + markdown
        return Edit(range: line, replacement: replacement,
                    selection: NSRange(location: line.location + (replacement as NSString).length, length: 0))
    }

    /// The text of a line after its heading, list, task or quote prefix (indentation kept out too).
    static func strippedBlockPrefix(_ line: String) -> (text: String, prefix: String) {
        let patterns = [#"^[ \t]*#{1,6}[ \t]+"#, #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#, #"^[ \t]*(?:>[ \t]?)+"#]
        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                return (String(line[range.upperBound...]), String(line[range]))
            }
        }
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return (String(trimmed), String(line.prefix(line.count - trimmed.count)))
    }

    // MARK: Code blocks

    /// A fenced code block: its whole range, the opening fence line, the code between the fences, and the info string.
    struct Fence: Equatable {
        let range: NSRange
        let opening: NSRange
        let content: NSRange
        let language: String
        /// Where the language word sits in the opening line (zero length right after the fence when there is none).
        let languageRange: NSRange
    }

    /// The fenced block holding `location`, by the same rules as the live parser.
    static func fence(in text: String, at location: Int) -> Fence? {
        let source = text as NSString
        var cursor = 0
        while cursor < source.length {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            var content = line
            while content.length > 0, [10, 13].contains(source.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            let text = source.substring(with: content)
            if let open = text.range(of: #"^ {0,3}(`{3,}|~{3,})"#, options: .regularExpression) {
                let marker = String(text[open]).trimmingCharacters(in: .whitespaces)
                let character = marker.first!
                let info = String(text[open.upperBound...])
                if character == "`" && info.contains("`") { cursor = NSMaxRange(line); continue }
                // Find the closing fence.
                var next = NSMaxRange(line)
                var closing: NSRange?
                while next < source.length {
                    let candidate = source.lineRange(for: NSRange(location: next, length: 0))
                    let body = source.substring(with: candidate).trimmingCharacters(in: .newlines)
                    let trimmed = body.drop { $0 == " " }
                    if body.count - trimmed.count <= 3, trimmed.hasPrefix(String(repeating: String(character), count: marker.count)),
                       trimmed.allSatisfy({ $0 == character || $0 == " " || $0 == "\t" }) {
                        closing = candidate; break
                    }
                    next = NSMaxRange(candidate)
                }
                let end = closing.map(NSMaxRange) ?? source.length
                let block = NSRange(location: line.location, length: end - line.location)
                if location >= block.location && (location < NSMaxRange(block) || (closing == nil && location == end)) {
                    let codeStart = NSMaxRange(line)
                    let codeEnd = closing?.location ?? end
                    let word = info.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                    let infoStart = content.location + (text.distance(from: text.startIndex, to: open.upperBound) == 0 ? 0 :
                        (String(text[..<open.upperBound]) as NSString).length)
                    let leading = (String(info.prefix { $0 == " " || $0 == "\t" }) as NSString).length
                    let languageRange = NSRange(location: infoStart + (word.isEmpty ? 0 : leading), length: (word as NSString).length)
                    return Fence(range: block, opening: content, content: NSRange(location: codeStart, length: max(0, codeEnd - codeStart)),
                                 language: word, languageRange: languageRange)
                }
                cursor = end
                continue
            }
            cursor = NSMaxRange(line)
        }
        return nil
    }

    /// The code of a fence as it would be copied: its lines without the fences, keeping blank lines but not the
    /// newline that ends the last line.
    static func code(of fence: Fence, in text: String) -> String {
        var code = (text as NSString).substring(with: fence.content)
        if code.hasSuffix("\n") { code.removeLast() }
        return code
    }

    /// Changes only the language word of the opening fence; other info stays.
    static func setLanguage(_ language: String, of fence: Fence, text: String) -> Edit {
        let word = language.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "")
        if fence.languageRange.length == 0, !word.isEmpty {
            return Edit(range: fence.languageRange, replacement: word, selection: NSRange(location: fence.languageRange.location + (word as NSString).length, length: 0))
        }
        return Edit(range: fence.languageRange, replacement: word,
                    selection: NSRange(location: fence.languageRange.location + (word as NSString).length, length: 0))
    }

    static let codeLanguages = ["swift", "python", "javascript", "typescript", "json", "bash", "go", "rust", "java", "c", "cpp", "sql", "yaml", "html", "css", "markdown", "text"]
}

// MARK: - Tables

extension MarkdownTable {
    enum RowPosition { case above, below }
    enum ColumnPosition { case left, right }

    /// The table, row and column at `location`; nil outside a table.
    private static func locate(_ text: String, _ location: Int) -> (table: (rows: [(line: NSRange, row: Row)], delimiterIndex: Int), row: Int, column: Int)? {
        guard let table = table(in: text, at: location) else { return nil }
        guard let row = table.rows.firstIndex(where: { location >= $0.line.location && location <= NSMaxRange($0.line) }) else { return nil }
        let cells = table.rows[row].row.cells
        let column = cells.lastIndex(where: { $0.location <= location }) ?? 0
        return (table, row, min(column, max(0, cells.count - 1)))
    }

    /// Splits each row into its trimmed cell texts, plus the delimiter alignments.
    private static func grid(_ text: String, _ table: (rows: [(line: NSRange, row: Row)], delimiterIndex: Int)) -> (cells: [[String]], alignments: [Alignment], leading: Bool) {
        let source = text as NSString
        let units = Array(text.utf16)
        let delimiterLine = table.rows[table.delimiterIndex].line
        let alignments = delimiter(units, start: delimiterLine.location, end: NSMaxRange(delimiterLine)) ?? []
        let cells = table.rows.enumerated().filter { $0.offset != table.delimiterIndex }.map { _, entry in
            entry.row.cells.map { source.substring(with: $0).trimmingCharacters(in: .whitespaces) }
        }
        return (cells, alignments, table.rows[0].row.hasLeadingPipe)
    }

    /// Writes the grid back as one table. Short rows are padded to the header's width; a row with extra cells
    /// (which GFM ignores) keeps them, so nothing typed is lost. Only this table's lines change.
    private static func render(_ cells: [[String]], _ alignments: [Alignment], leading: Bool) -> String {
        let columns = max(1, cells.first?.count ?? 1, alignments.count)
        func row(_ values: [String]) -> String {
            let padded = values + Array(repeating: "", count: max(0, columns - values.count))
            let inner = padded.map { $0.isEmpty ? " " : " \($0) " }.joined(separator: "|")
            return (leading ? "|" : "") + inner + "|"
        }
        let marks = (0..<columns).map { index -> String in
            switch index < alignments.count ? alignments[index] : .left {
            case .left: return " --- "
            case .center: return " :---: "
            case .right: return " ---: "
            }
        }
        var lines = [row(cells.first ?? [])]
        lines.append((leading ? "|" : "") + marks.joined(separator: "|") + "|")
        for body in cells.dropFirst() { lines.append(row(body)) }
        return lines.joined(separator: "\n")
    }

    private static func rewrite(_ text: String, _ table: (rows: [(line: NSRange, row: Row)], delimiterIndex: Int),
                                cells: [[String]], alignments: [Alignment], leading: Bool, caret: (row: Int, column: Int)) -> EditorLineEdit {
        let range = NSRange(location: table.rows[0].line.location, length: NSMaxRange(table.rows[table.rows.count - 1].line) - table.rows[0].line.location)
        let replacement = render(cells, alignments, leading: leading)
        // Put the caret at the start of the target cell's text in the new table.
        let lines = replacement.components(separatedBy: "\n")
        let lineIndex = caret.row == 0 ? 0 : caret.row + 1
        var offset = lines.prefix(min(lineIndex, lines.count)).reduce(0) { $0 + ($1 as NSString).length + 1 }
        if lineIndex < lines.count {
            let line = lines[lineIndex] as NSString
            var pipes = 0, index = 0
            let skip = caret.column + (leading ? 1 : 0)
            while index < line.length, pipes < skip { if line.character(at: index) == 124 { pipes += 1 }; index += 1 }
            offset += min(line.length, index + 1)
        }
        return EditorLineEdit(range: range, replacement: replacement, selection: NSRange(location: range.location + offset, length: 0))
    }

    static func insertRow(text: String, at location: Int, _ position: RowPosition) -> EditorLineEdit? {
        guard let found = locate(text, location) else { return nil }
        var (cells, alignments, leading) = grid(text, found.table)
        // Grid rows skip the delimiter: row 0 is the header.
        let current = found.row == 0 ? 0 : max(1, found.row - (found.row > found.table.delimiterIndex ? 1 : 0))
        let columns = max(cells.first?.count ?? 1, alignments.count)
        let index = position == .above ? max(1, current) : current + 1
        cells.insert(Array(repeating: "", count: columns), at: min(index, cells.count))
        return rewrite(text, found.table, cells: cells, alignments: alignments, leading: leading, caret: (index, found.column))
    }

    static func insertColumn(text: String, at location: Int, _ position: ColumnPosition) -> EditorLineEdit? {
        guard let found = locate(text, location) else { return nil }
        var (cells, alignments, leading) = grid(text, found.table)
        let index = position == .left ? found.column : found.column + 1
        for row in cells.indices {
            while cells[row].count < index { cells[row].append("") }
            cells[row].insert(row == 0 ? "列" : "", at: index)
        }
        while alignments.count < index { alignments.append(.left) }
        alignments.insert(.left, at: index)
        let row = found.row > found.table.delimiterIndex ? found.row - 1 : found.row
        return rewrite(text, found.table, cells: cells, alignments: alignments, leading: leading, caret: (row, index))
    }

    /// Deletes the caret's body row. The header row cannot be deleted (there would be no table left to read).
    static func deleteRow(text: String, at location: Int) -> EditorLineEdit? {
        guard let found = locate(text, location), found.row > found.table.delimiterIndex else { return nil }
        var (cells, alignments, leading) = grid(text, found.table)
        let index = found.row - 1
        cells.remove(at: index)
        return rewrite(text, found.table, cells: cells, alignments: alignments, leading: leading, caret: (min(index, cells.count - 1), found.column))
    }

    /// Deletes the caret's column; the last remaining column stays.
    static func deleteColumn(text: String, at location: Int) -> EditorLineEdit? {
        guard let found = locate(text, location) else { return nil }
        var (cells, alignments, leading) = grid(text, found.table)
        let columns = max(cells.first?.count ?? 0, alignments.count)
        guard columns > 1 else { return nil }
        for row in cells.indices where found.column < cells[row].count { cells[row].remove(at: found.column) }
        if found.column < alignments.count { alignments.remove(at: found.column) }
        let row = found.row > found.table.delimiterIndex ? found.row - 1 : found.row
        return rewrite(text, found.table, cells: cells, alignments: alignments, leading: leading, caret: (row, max(0, found.column - 1)))
    }

    static func align(text: String, at location: Int, _ alignment: Alignment) -> EditorLineEdit? {
        guard let found = locate(text, location) else { return nil }
        var (cells, alignments, leading) = grid(text, found.table)
        while alignments.count <= found.column { alignments.append(.left) }
        alignments[found.column] = alignment
        let row = found.row > found.table.delimiterIndex ? found.row - 1 : found.row
        return rewrite(text, found.table, cells: cells, alignments: alignments, leading: leading, caret: (row, found.column))
    }

    /// The table's source, for copying.
    static func source(text: String, at location: Int) -> String? {
        guard let table = table(in: text, at: location) else { return nil }
        let range = NSRange(location: table.rows[0].line.location, length: NSMaxRange(table.rows[table.rows.count - 1].line) - table.rows[0].line.location)
        return (text as NSString).substring(with: range)
    }
}
