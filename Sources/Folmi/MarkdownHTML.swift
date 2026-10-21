import Foundation

/// Markdown to HTML for the reading view: CommonMark blocks plus the GitHub parts people write (tables, task lists,
/// strikethrough, autolinks, alerts) and `[[wiki links]]`. Raw HTML passes through `MarkdownRawHTML`'s allow list, so a
/// document can never run script in the reader.
///
/// Every block carries `data-line` / `data-end` (0-based source lines), which the reader uses to mark changed blocks,
/// map a selection back to source lines and keep its place when switching to the editor. A task box carries
/// `data-offset`, the UTF-16 offset of the character between its brackets.
enum MarkdownHTML {
    struct Options {
        /// Project-relative path of the document; image and link targets resolve from it.
        var documentPath = ""
        /// The `src` for an image target, or nil when it cannot be shown (missing, outside the project).
        var imageSource: (String) -> String? = { target in
            target.hasPrefix("https://") || target.hasPrefix("http://") || target.hasPrefix("data:image/") ? target : nil
        }
    }

    static func render(_ text: String, options: Options = Options()) -> String {
        var renderer = Renderer(options: options)
        return renderer.document(text)
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text { appendEscaped(character, to: &result) }
        return result
    }
    static func appendEscaped(_ character: Character, to result: inout String) {
        switch character {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        case "'": result += "&#39;"
        default: result.append(character)
        }
    }
}

/// One source line inside the current container, with what the container (quote marker, list indent) stripped.
private struct SourceLine {
    var text: String
    /// 0-based line number in the document.
    let number: Int
    /// UTF-16 offset of `text`'s first character in the document.
    var offset: Int

    var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }
    /// Leading indentation in columns, a tab counting to the next multiple of 4.
    var indent: Int {
        var columns = 0
        for character in text {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 - columns % 4 } else { break }
        }
        return columns
    }
    /// Removes up to `columns` of indentation (a partly used tab is removed whole).
    func dropping(columns: Int) -> SourceLine {
        var used = 0, units = 0
        var index = text.startIndex
        while index < text.endIndex, used < columns {
            let character = text[index]
            if character == " " { used += 1 } else if character == "\t" { used += 4 - used % 4 } else { break }
            units += 1
            index = text.index(after: index)
        }
        return SourceLine(text: String(text[index...]), number: number, offset: offset + units)
    }
    func dropping(units: Int) -> SourceLine {
        let index = text.utf16.index(text.startIndex, offsetBy: min(units, text.utf16.count))
        return SourceLine(text: String(text[index...]), number: number, offset: offset + units)
    }
}

private struct ListMarker {
    let indent: Int
    /// "-", "*", "+" for bullets; "." or ")" for ordered lists.
    let kind: Character
    let ordered: Bool
    let start: Int
    /// Columns from the line start to the item's content.
    let contentIndent: Int
    /// UTF-16 units from the line start to the item's content.
    let contentUnits: Int
}

private struct Renderer {
    let options: MarkdownHTML.Options
    private var headingIDs: [String: Int] = [:]

    init(options: MarkdownHTML.Options) { self.options = options }

    // MARK: Blocks

    mutating func document(_ text: String) -> String {
        var lines: [SourceLine] = []
        var offset = 0
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw)
            let length = line.utf16.count
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(SourceLine(text: line, number: number, offset: offset))
            offset += length + 1
        }
        var html = ""
        var start = 0
        if let (meta, next) = frontMatter(lines) { html += meta; start = next }
        html += blocks(lines[start...])
        return html
    }

    /// YAML front matter (`---` … `---` on the first lines), shown as a quiet properties block.
    private func frontMatter(_ lines: [SourceLine]) -> (String, Int)? {
        guard lines.count > 2, lines[0].text == "---" else { return nil }
        guard let end = lines.indices.dropFirst().first(where: { lines[$0].text == "---" || lines[$0].text == "..." }), end > 1 else { return nil }
        let body = lines[1..<end].map(\.text).joined(separator: "\n")
        return ("<pre class=\"frontmatter\" data-line=\"0\" data-end=\"\(end)\">\(MarkdownHTML.escape(body))</pre>\n", end + 1)
    }

    private mutating func blocks(_ lines: ArraySlice<SourceLine>) -> String {
        var html = ""
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            if line.isBlank { index += 1; continue }
            if line.indent >= 4 {
                index = indentedCode(lines, from: index, into: &html); continue
            }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if let fence = fence(trimmed) {
                index = fencedCode(lines, from: index, fence: fence, into: &html); continue
            }
            if trimmed.hasPrefix("$$"), let next = mathBlock(lines, from: index, into: &html) {
                index = next; continue
            }
            if let (level, title) = atxHeading(trimmed) {
                html += heading(level, title, line: line.number, end: line.number)
                index += 1; continue
            }
            if isThematicBreak(trimmed) {
                html += "<hr data-line=\"\(line.number)\" data-end=\"\(line.number)\">\n"
                index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                index = quote(lines, from: index, into: &html); continue
            }
            if trimmed.hasPrefix("<"), MarkdownRawHTML.blockStart(trimmed) != nil {
                index = rawHTML(lines, from: index, into: &html); continue
            }
            if index + 1 < lines.endIndex, line.text.contains("|"), let aligns = delimiterRow(lines[index + 1].text) {
                index = table(lines, from: index, aligns: aligns, into: &html); continue
            }
            if let marker = listMarker(line.text) {
                index = list(lines, from: index, first: marker, into: &html); continue
            }
            index = paragraph(lines, from: index, into: &html)
        }
        return html
    }

    private func range(_ first: SourceLine, _ last: SourceLine) -> String {
        "data-line=\"\(first.number)\" data-end=\"\(last.number)\""
    }

    private func fence(_ trimmed: String) -> (character: Character, count: Int, info: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return (first, count, info)
    }

    private func fencedCode(_ lines: ArraySlice<SourceLine>, from start: Int, fence: (character: Character, count: Int, info: String),
                            into html: inout String) -> Int {
        let indent = min(lines[start].indent, 3)
        var body: [String] = []
        var index = start + 1
        var closed = false
        while index < lines.endIndex {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            if trimmed.first == fence.character, trimmed.prefix(while: { $0 == fence.character }).count >= fence.count,
               trimmed.allSatisfy({ $0 == fence.character }) { closed = true; break }
            body.append(lines[index].dropping(columns: indent).text)
            index += 1
        }
        let last = closed ? lines[index] : lines[max(start, index - 1)]
        let language = fence.info.split(separator: " ").first.map(String.init) ?? ""
        let code = body.joined(separator: "\n"), attributes = range(lines[start], last)
        switch language.lowercased() {
        case "math", "latex", "katex": html += Self.displayMath(code, attributes: attributes)
        case "mermaid": html += "<div class=\"mermaid\" \(attributes)><pre class=\"src\">\(MarkdownHTML.escape(code))</pre></div>\n"
        default: html += codeBlock(code, language: language, attributes: attributes)
        }
        return closed ? index + 1 : index
    }

    /// `$$ … $$` on its own lines (or one line). Nil when it never closes: then it is plain text.
    private func mathBlock(_ lines: ArraySlice<SourceLine>, from start: Int, into html: inout String) -> Int? {
        let first = lines[start].text.trimmingCharacters(in: .whitespaces).dropFirst(2)
        if let close = first.range(of: "$$") {
            guard first[close.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            html += Self.displayMath(String(first[..<close.lowerBound]), attributes: range(lines[start], lines[start]))
            return start + 1
        }
        var body = [String(first)]
        var index = start + 1
        while index < lines.endIndex {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("$$") {
                body.append(String(trimmed.dropLast(2)))
                html += Self.displayMath(body.joined(separator: "\n"), attributes: range(lines[start], lines[index]))
                return index + 1
            }
            if lines[index].isBlank && body.last?.isEmpty == true { return nil }
            body.append(lines[index].text)
            index += 1
        }
        return nil
    }

    /// The TeX is kept in `data-tex` and shown as code until the page typesets it.
    static func displayMath(_ tex: String, attributes: String) -> String {
        let source = MarkdownHTML.escape(tex.trimmingCharacters(in: .whitespacesAndNewlines))
        return "<div class=\"math display\" \(attributes) data-tex=\"\(source)\"><code>\(source)</code></div>\n"
    }

    private func indentedCode(_ lines: ArraySlice<SourceLine>, from start: Int, into html: inout String) -> Int {
        var body: [String] = []
        var index = start
        var last = start
        while index < lines.endIndex, lines[index].isBlank || lines[index].indent >= 4 {
            body.append(lines[index].dropping(columns: 4).text)
            if !lines[index].isBlank { last = index }
            index += 1
        }
        body.removeLast(index - 1 - last)
        html += codeBlock(body.joined(separator: "\n"), language: "", attributes: range(lines[start], lines[last]))
        return last + 1
    }

    private func codeBlock(_ code: String, language: String, attributes: String) -> String {
        let label = language.isEmpty ? "" : " data-lang=\"\(MarkdownHTML.escape(language))\""
        return "<div class=\"code\" \(attributes)\(label)><pre><code>\(MarkdownCodeHighlight.html(code, language: language))</code></pre></div>\n"
    }

    private func atxHeading(_ trimmed: String) -> (Int, String)? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of # counts only after a space: "# C#" keeps its #.
        if let hashes = title.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            title = String(title[..<hashes.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (level, title)
    }

    private mutating func heading(_ level: Int, _ title: String, line: Int, end: Int) -> String {
        var id = MarkdownLinks.slug(title)
        if let seen = headingIDs[id] { headingIDs[id] = seen + 1; id += "-\(seen + 1)" } else { headingIDs[id] = 0 }
        return "<h\(level) id=\"\(MarkdownHTML.escape(id))\" data-line=\"\(line)\" data-end=\"\(end)\">\(inline(title))</h\(level)>\n"
    }

    private func isThematicBreak(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    private mutating func quote(_ lines: ArraySlice<SourceLine>, from start: Int, into html: inout String) -> Int {
        var inner: [SourceLine] = []
        var index = start
        while index < lines.endIndex {
            let line = lines[index]
            let stripped = line.dropping(columns: 3)
            guard stripped.text.hasPrefix(">") else {
                // A lazy continuation line keeps a paragraph going inside the quote.
                if !line.isBlank, let last = inner.last, !last.isBlank, startsBlock(line.text) == false { inner.append(line); index += 1; continue }
                break
            }
            var content = stripped.dropping(units: 1)
            if content.text.hasPrefix(" ") || content.text.hasPrefix("\t") { content = content.dropping(columns: 1) }
            inner.append(content)
            index += 1
        }
        let attributes = range(lines[start], lines[index - 1])
        // GitHub alerts: a quote whose first line is [!NOTE], [!TIP], [!IMPORTANT], [!WARNING] or [!CAUTION].
        if let first = inner.first, let kind = alertKind(first.text) {
            let title: String
            switch kind {
            case "note": title = "说明"
            case "tip": title = "提示"
            case "important": title = "重要"
            case "warning": title = "警告"
            default: title = "注意"
            }
            html += "<div class=\"alert \(kind)\" \(attributes)><p class=\"alert-title\">\(title)</p>\(blocks(inner[1...]))</div>\n"
        } else {
            html += "<blockquote \(attributes)>\(blocks(inner[...]))</blockquote>\n"
        }
        return index
    }

    private func alertKind(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        for kind in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] where trimmed == "[!\(kind)]" { return kind.lowercased() }
        return nil
    }

    /// Whether a line would start a block other than a paragraph, which ends a paragraph above it.
    private func startsBlock(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if fence(trimmed) != nil || atxHeading(trimmed) != nil || isThematicBreak(trimmed) || trimmed.hasPrefix(">") || trimmed.hasPrefix("$$") { return true }
        if trimmed.hasPrefix("<"), MarkdownRawHTML.blockStart(trimmed) == .interrupting { return true }
        // Only a bullet or a list starting at 1 may interrupt a paragraph, so "2024. 年" stays text.
        if let marker = listMarker(text), !(marker.ordered && marker.start != 1) {
            return text.dropFirst(marker.contentUnits).contains { $0 != " " && $0 != "\t" }
        }
        return false
    }

    // MARK: Raw HTML

    /// An HTML block: lines up to a blank one, kept going while a container tag is still open, so
    /// `<div align="center">`, blank line, Markdown, blank line, `</div>` reads as on GitHub. Markdown between the
    /// HTML parts is rendered as blocks.
    private mutating func rawHTML(_ lines: ArraySlice<SourceLine>, from start: Int, into html: inout String) -> Int {
        var sanitizer = MarkdownRawHTML(imageSource: options.imageSource)
        var body = ""
        var index = start
        var last = start
        while index < lines.endIndex {
            // HTML lines, up to a blank line (or past it, inside a comment or <pre>).
            while index < lines.endIndex, !lines[index].isBlank || sanitizer.continuesOverBlank {
                body += sanitizer.feed(lines[index].text + "\n")
                last = index
                index += 1
            }
            body += sanitizer.finish()
            guard sanitizer.depth > 0 else { break }
            while index < lines.endIndex, lines[index].isBlank { index += 1 }
            guard index < lines.endIndex else { break }
            if MarkdownRawHTML.blockStart(lines[index].text.trimmingCharacters(in: .whitespaces)) != nil { continue }
            // Markdown until the next HTML line after a blank one.
            var end = index + 1
            while end < lines.endIndex,
                  !(lines[end - 1].isBlank && MarkdownRawHTML.blockStart(lines[end].text.trimmingCharacters(in: .whitespaces)) != nil) { end += 1 }
            body += blocks(lines[index..<end])
            last = end - 1
            index = end
        }
        html += "<div class=\"html\" \(range(lines[start], lines[last]))>\(body)</div>\n"
        return index
    }

    // MARK: Tables

    private func delimiterRow(_ text: String) -> [String]? {
        let cells = splitRow(text)
        guard !cells.isEmpty, text.contains("-") else { return nil }
        var aligns: [String] = []
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard value.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            aligns.append(value.hasPrefix(":") && value.hasSuffix(":") ? "center" : value.hasSuffix(":") ? "right" : value.hasPrefix(":") ? "left" : "")
        }
        return aligns
    }

    /// Cells of a table row: outer pipes dropped, `\|` and pipes inside code spans kept.
    private func splitRow(_ text: String) -> [String] {
        var row = text.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for character in row {
            if escaped { cell += character == "|" ? "|" : "\\" + String(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode { cells.append(cell); cell = ""; continue }
            cell.append(character)
        }
        if escaped { cell += "\\" }
        cells.append(cell)
        return cells
    }

    private func table(_ lines: ArraySlice<SourceLine>, from start: Int, aligns: [String], into html: inout String) -> Int {
        func cells(_ text: String, tag: String) -> String {
            var values = splitRow(text)
            if values.count < aligns.count { values += Array(repeating: "", count: aligns.count - values.count) }
            return zip(values.prefix(aligns.count), aligns).map { value, align in
                let style = align.isEmpty ? "" : " style=\"text-align:\(align)\""
                return "<\(tag)\(style)>\(inline(value.trimmingCharacters(in: .whitespaces)))</\(tag)>"
            }.joined()
        }
        var body = ""
        var index = start + 2
        while index < lines.endIndex, !lines[index].isBlank, lines[index].text.contains("|") || !startsBlock(lines[index].text) {
            if startsBlock(lines[index].text) && !lines[index].text.contains("|") { break }
            body += "<tr data-line=\"\(lines[index].number)\" data-end=\"\(lines[index].number)\">\(cells(lines[index].text, tag: "td"))</tr>"
            index += 1
        }
        html += "<div class=\"table\" \(range(lines[start], lines[index - 1]))><table><thead><tr>\(cells(lines[start].text, tag: "th"))</tr></thead>"
            + (body.isEmpty ? "" : "<tbody>\(body)</tbody>") + "</table></div>\n"
        return index
    }

    // MARK: Lists

    private func listMarker(_ text: String) -> ListMarker? {
        let line = SourceLine(text: text, number: 0, offset: 0)
        let indent = line.indent
        guard indent < 4 else { return nil }
        let leading = text.prefix { $0 == " " || $0 == "\t" }
        let rest = text.dropFirst(leading.count)
        var kind: Character
        var ordered = false
        var start = 1
        var markerLength: Int
        if let first = rest.first, "-*+".contains(first) {
            kind = first; markerLength = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else { return nil }
            kind = delimiter; ordered = true; start = Int(digits) ?? 1; markerLength = digits.count + 1
        }
        let after = rest.dropFirst(markerLength)
        if let next = after.first, next != " " && next != "\t" { return nil }
        let spaces = after.prefix { $0 == " " }.count
        // Five or more spaces mean indented code inside the item: the content starts one space after the marker.
        let gap = after.isEmpty || after.allSatisfy({ $0 == " " }) ? 1 : (spaces >= 5 ? 1 : max(1, spaces))
        let units = leading.utf16.count + markerLength + min(gap, after.utf16.count)
        return ListMarker(indent: indent, kind: kind, ordered: ordered, start: start, contentIndent: indent + markerLength + gap, contentUnits: units)
    }

    private mutating func list(_ lines: ArraySlice<SourceLine>, from start: Int, first: ListMarker, into html: inout String) -> Int {
        var items: [(marker: ListMarker, lines: [SourceLine])] = []
        var index = start
        var tight = true
        var sawBlank = false
        while index < lines.endIndex {
            let line = lines[index]
            if let marker = listMarker(line.text), marker.kind == first.kind, marker.ordered == first.ordered,
               marker.indent < (items.last?.marker.contentIndent ?? first.contentIndent),
               marker.ordered || !isThematicBreak(line.text.trimmingCharacters(in: .whitespaces)) {
                if sawBlank && !items.isEmpty { tight = false }
                sawBlank = false
                items.append((marker, [line.dropping(units: marker.contentUnits)]))
                index += 1; continue
            }
            guard !items.isEmpty else { break }
            let current = items[items.count - 1].marker
            if line.isBlank {
                sawBlank = true
                items[items.count - 1].lines.append(SourceLine(text: "", number: line.number, offset: line.offset))
                index += 1; continue
            }
            if line.indent >= current.contentIndent {
                sawBlank = false
                items[items.count - 1].lines.append(line.dropping(columns: current.contentIndent))
                index += 1; continue
            }
            // Lazy continuation of the item's paragraph.
            if !sawBlank, !startsBlock(line.text), let last = items[items.count - 1].lines.last, !last.isBlank {
                items[items.count - 1].lines.append(line.dropping(columns: line.indent))
                index += 1; continue
            }
            break
        }
        // Trailing blank lines belong after the list, not to its last item.
        var end = index - 1
        while end > start, lines[end].isBlank { end -= 1 }
        for i in items.indices {
            while let last = items[i].lines.last, last.isBlank, items[i].lines.count > 1 { items[i].lines.removeLast() }
            if innerBlankSeparatesParagraphs(items[i].lines) { tight = false }
        }
        let tag = first.ordered ? "ol" : "ul"
        let startAttribute = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        let hasTasks = items.contains { taskState($0.lines.first?.text ?? "") != nil }
        let classes = [tight ? "tight" : nil, hasTasks ? "tasks" : nil].compactMap { $0 }
        html += "<\(tag)\(startAttribute)" + (classes.isEmpty ? "" : " class=\"\(classes.joined(separator: " "))\"") + " \(range(lines[start], lines[end]))>"
        for item in items {
            var content = item.lines
            var box = ""
            if let first = content.first, let checked = taskState(first.text) {
                let prefix = first.text.prefix { $0 == " " }.count
                box = "<input type=\"checkbox\" class=\"task\" data-offset=\"\(first.offset + prefix + 1)\"\(checked ? " checked" : "")>"
                content[0] = first.dropping(units: prefix + 3).dropping(columns: 1)
            }
            let lastLine = item.lines.last(where: { !$0.isBlank }) ?? item.lines[0]
            let firstLine = SourceLine(text: "", number: item.lines[0].number, offset: 0)
            let className = box.isEmpty ? "" : " class=\"task-item\""
            html += "<li\(className) \(range(firstLine, lastLine))>\(box)\(blocks(content[...]))</li>"
        }
        html += "</\(tag)>\n"
        return end + 1
    }

    /// A blank line between two blocks of the same item (not just before a nested list) makes the list loose.
    private func innerBlankSeparatesParagraphs(_ lines: [SourceLine]) -> Bool {
        for (index, line) in lines.enumerated() where line.isBlank {
            guard let next = lines[(index + 1)...].first(where: { !$0.isBlank }) else { continue }
            if listMarker(next.text) == nil { return true }
        }
        return false
    }

    private func taskState(_ text: String) -> Bool? {
        let trimmed = text.drop { $0 == " " }
        guard trimmed.count >= 3, trimmed.hasPrefix("["), trimmed.dropFirst(2).first == "]" else { return nil }
        let mark = trimmed.dropFirst().first!
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        let after = trimmed.dropFirst(3)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return mark != " "
    }

    // MARK: Paragraphs

    private mutating func paragraph(_ lines: ArraySlice<SourceLine>, from start: Int, into html: inout String) -> Int {
        var parts: [String] = []
        var index = start
        while index < lines.endIndex {
            let line = lines[index]
            if line.isBlank { break }
            if index > start {
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                // Setext headings: a paragraph underlined with === or ---.
                if line.indent < 4, !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                    let title = parts.joined(separator: "\n")
                    html += heading(trimmed.first == "=" ? 1 : 2, title, line: lines[start].number, end: line.number)
                    return index + 1
                }
                if startsBlock(line.text) { break }
                if line.text.contains("|"), index + 1 < lines.endIndex, delimiterRow(lines[index + 1].text) != nil { break }
            }
            var text = line.text.drop { $0 == " " || $0 == "\t" }
            // Two trailing spaces or a backslash end the line with a hard break.
            let hard = text.hasSuffix("  ") || (text.hasSuffix("\\") && !text.hasSuffix("\\\\"))
            if text.hasSuffix("\\") && hard { text = text.dropLast() }
            parts.append(String(text).trimmingCharacters(in: .whitespaces) + (hard ? Renderer.hardBreak : ""))
            index += 1
        }
        var joined = parts.joined(separator: "\n")
        if joined.hasSuffix(Renderer.hardBreak) { joined.removeLast() }
        html += "<p \(range(lines[start], lines[index - 1]))>\(inline(joined))</p>\n"
        return index
    }

    // MARK: Inline

    static let hardBreak = "\u{E000}"

    func inline(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        out.reserveCapacity(text.utf8.count + 16)
        inline(characters, 0, characters.count, into: &out)
        return out
    }

    private func inline(_ c: [Character], _ from: Int, _ to: Int, into out: inout String) {
        var i = from
        while i < to {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < to, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                    MarkdownHTML.appendEscaped(c[i + 1], to: &out); i += 2; continue
                }
            case "`":
                let run = count(c, i, to, "`")
                if let close = findRun(c, i + run, to, "`", run) {
                    var code = String(c[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) { code = String(code.dropFirst().dropLast()) }
                    out += "<code>\(MarkdownHTML.escape(code))</code>"
                    i = close + run; continue
                }
                out += String(repeating: "`", count: run); i += run; continue
            case "$":
                if let (tex, display, end) = math(c, i, to) {
                    let source = MarkdownHTML.escape(tex)
                    out += "<span class=\"math\(display ? " display" : "")\" data-tex=\"\(source)\"><code>\(source)</code></span>"
                    i = end; continue
                }
            case "!":
                if i + 1 < to, c[i + 1] == "[", let link = parseLink(c, i + 1, to) {
                    let alt = String(c[link.textStart..<link.textEnd])
                    if let source = options.imageSource(link.destination) {
                        out += "<img src=\"\(MarkdownHTML.escape(source))\" alt=\"\(MarkdownHTML.escape(plain(alt)))\" loading=\"lazy\""
                            + (link.title.map { " title=\"\(MarkdownHTML.escape($0))\"" } ?? "") + ">"
                    } else {
                        out += "<span class=\"missing-image\" title=\"\(MarkdownHTML.escape(link.destination))\">\(MarkdownHTML.escape(plain(alt).isEmpty ? link.destination : plain(alt)))</span>"
                    }
                    i = link.end; continue
                }
            case "[":
                if i + 1 < to, c[i + 1] == "[", let close = find(c, i + 2, to, ["]", "]"]), !c[(i + 2)..<close].contains("\n"), close > i + 2 {
                    let inner = String(c[(i + 2)..<close])
                    let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
                    let target = parts[0].trimmingCharacters(in: .whitespaces)
                    let label = parts.count > 1 ? parts[1] : target
                    out += "<a class=\"wiki\" href=\"#\" data-href=\"\(MarkdownHTML.escape("[[" + target + "]]"))\">\(MarkdownHTML.escape(label))</a>"
                    i = close + 2; continue
                }
                if let link = parseLink(c, i, to) {
                    out += "<a href=\"\(MarkdownHTML.escape(link.destination))\" data-href=\"\(MarkdownHTML.escape(link.destination))\""
                        + (link.title.map { " title=\"\(MarkdownHTML.escape($0))\"" } ?? "") + ">"
                    inline(c, link.textStart, link.textEnd, into: &out)
                    out += "</a>"
                    i = link.end; continue
                }
            case "<":
                if let close = c[(i + 1)..<to].firstIndex(of: ">") {
                    let inner = String(c[(i + 1)..<close])
                    if inner.range(of: #"^(https?|mailto):[^\s<>]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        out += "<a href=\"\(MarkdownHTML.escape(inner))\" data-href=\"\(MarkdownHTML.escape(inner))\">\(MarkdownHTML.escape(inner))</a>"
                        i = close + 1; continue
                    }
                }
                if let (tag, end) = MarkdownRawHTML.inline(c, i, to, imageSource: options.imageSource) {
                    out += tag; i = end; continue
                }
            case "&":
                if let semicolon = c[i..<min(to, i + 12)].firstIndex(of: ";"),
                   String(c[i...semicolon]).range(of: #"^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,30});$"#, options: .regularExpression) != nil {
                    out += String(c[i...semicolon]); i = semicolon + 1; continue
                }
            case "*", "_":
                if let (html, next) = emphasis(c, i, to) { out += html; i = next; continue }
                let run = count(c, i, to, ch)
                out += String(repeating: ch, count: run); i += run; continue
            case "~":
                if i + 1 < to, c[i + 1] == "~", i + 2 < to, !c[i + 2].isWhitespace, let close = find(c, i + 2, to, ["~", "~"]), close > i + 2, !c[close - 1].isWhitespace {
                    out += "<del>"; inline(c, i + 2, close, into: &out); out += "</del>"
                    i = close + 2; continue
                }
            case "=":
                if i + 1 < to, c[i + 1] == "=", i + 2 < to, !c[i + 2].isWhitespace, let close = find(c, i + 2, to, ["=", "="]), close > i + 2, !c[close - 1].isWhitespace {
                    out += "<mark>"; inline(c, i + 2, close, into: &out); out += "</mark>"
                    i = close + 2; continue
                }
            case "h", "m", "w":
                if let (url, end) = bareURL(c, i, to) {
                    let href = url.hasPrefix("www.") ? "https://" + url : url
                    out += "<a href=\"\(MarkdownHTML.escape(href))\" data-href=\"\(MarkdownHTML.escape(href))\">\(MarkdownHTML.escape(url))</a>"
                    i = end; continue
                }
            case "\n":
                // A soft break between two CJK characters is no space at all; elsewhere it reads as one.
                let before = i > from ? c[i - 1] : " ", after = i + 1 < to ? c[i + 1] : " "
                out += Renderer.isCJK(before) && Renderer.isCJK(after) ? "" : "\n"
                i += 1; continue
            case Character(Renderer.hardBreak):
                out += "<br>"; i += 1; continue
            default:
                break
            }
            MarkdownHTML.appendEscaped(ch, to: &out)
            i += 1
        }
    }

    /// Inline math, pandoc's rules: `$$…$$`, or `$…$` where the opening `$` is followed by a non-space, the closing
    /// one preceded by a non-space and not followed by a digit (so "$5 and $10" stays text). `\$` is a literal dollar.
    private func math(_ c: [Character], _ i: Int, _ to: Int) -> (String, Bool, Int)? {
        if i + 1 < to, c[i + 1] == "$" {
            guard let close = find(c, i + 2, to, ["$", "$"]), close > i + 2 else { return nil }
            return (String(c[(i + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines), true, close + 2)
        }
        guard i + 1 < to, !c[i + 1].isWhitespace else { return nil }
        var j = i + 1
        while j < to {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "$" {
                if !c[j - 1].isWhitespace, j + 1 >= to || !c[j + 1].isNumber, j > i + 1 {
                    return (String(c[(i + 1)..<j]), false, j + 1)
                }
                return nil
            }
            j += 1
        }
        return nil
    }

    private func count(_ c: [Character], _ at: Int, _ to: Int, _ character: Character) -> Int {
        var n = 0
        while at + n < to, c[at + n] == character { n += 1 }
        return n
    }
    /// The start of the next run of exactly `length` copies of `character`.
    private func findRun(_ c: [Character], _ from: Int, _ to: Int, _ character: Character, _ length: Int) -> Int? {
        var i = from
        while i < to {
            if c[i] == character {
                let run = count(c, i, to, character)
                if run == length { return i }
                i += run
            } else { i += 1 }
        }
        return nil
    }
    private func find(_ c: [Character], _ from: Int, _ to: Int, _ pattern: [Character]) -> Int? {
        guard to - from >= pattern.count else { return nil }
        var i = from
        while i <= to - pattern.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "`", let close = findRun(c, i + count(c, i, to, "`"), to, "`", count(c, i, to, "`")) {
                i = close + count(c, close, to, "`"); continue
            }
            if Array(c[i..<(i + pattern.count)]) == pattern { return i }
            i += 1
        }
        return nil
    }

    private func emphasis(_ c: [Character], _ i: Int, _ to: Int) -> (String, Int)? {
        let ch = c[i]
        let run = min(count(c, i, to, ch), 3)
        let open = i + count(c, i, to, ch) - run
        guard open + run < to, !c[open + run].isWhitespace else { return nil }
        // Underscores inside a word (snake_case) are text.
        if ch == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
        for length in stride(from: run, through: 1, by: -1) {
            var j = open + length
            while j < to {
                if c[j] == "\\" { j += 2; continue }
                if c[j] == "`", let close = findRun(c, j + count(c, j, to, "`"), to, "`", count(c, j, to, "`")) { j = close + count(c, close, to, "`"); continue }
                if c[j] == "[" , let link = parseLink(c, j, to) { j = link.end; continue }
                if c[j] == ch {
                    let closing = count(c, j, to, ch)
                    let after = j + closing < to ? c[j + closing] : " "
                    let rightFlanking = !c[j - 1].isWhitespace
                    let wordAfter = ch == "_" && (after.isLetter || after.isNumber)
                    if closing >= length, rightFlanking, !wordAfter, j > open + length {
                        var html = String(repeating: ch, count: open - i)
                        let tags = length == 3 ? ["<strong><em>", "</em></strong>"] : length == 2 ? ["<strong>", "</strong>"] : ["<em>", "</em>"]
                        html += tags[0]
                        var inner = ""
                        inline(c, open + length, j, into: &inner)
                        html += inner + tags[1]
                        return (html, j + length)
                    }
                    j += closing; continue
                }
                j += 1
            }
        }
        return nil
    }

    private struct Link { let textStart: Int; let textEnd: Int; let destination: String; let title: String?; let end: Int }

    /// `[text](destination "title")` starting at the `[`.
    private func parseLink(_ c: [Character], _ open: Int, _ to: Int) -> Link? {
        var depth = 0
        var i = open
        var close: Int?
        while i < to {
            let ch = c[i]
            if ch == "\\" { i += 2; continue }
            if ch == "`", let end = findRun(c, i + count(c, i, to, "`"), to, "`", count(c, i, to, "`")) { i = end + count(c, end, to, "`"); continue }
            if ch == "[" { depth += 1 }
            if ch == "]" { depth -= 1; if depth == 0 { close = i; break } }
            i += 1
        }
        guard let close, close + 1 < to, c[close + 1] == "(" else { return nil }
        var j = close + 2
        while j < to, c[j] == " " { j += 1 }
        var destination = ""
        if j < to, c[j] == "<" {
            guard let end = c[j..<to].firstIndex(of: ">") else { return nil }
            destination = String(c[(j + 1)..<end]); j = end + 1
        } else {
            var parens = 0
            while j < to {
                let ch = c[j]
                if ch == "\\", j + 1 < to { destination.append(c[j + 1]); j += 2; continue }
                if ch == " " || ch == "\n" { break }
                if ch == "(" { parens += 1 }
                if ch == ")" { if parens == 0 { break }; parens -= 1 }
                destination.append(ch); j += 1
            }
        }
        while j < to, c[j] == " " || c[j] == "\n" { j += 1 }
        var title: String?
        if j < to, let quote = Optional(c[j]), quote == "\"" || quote == "'" || quote == "(" {
            let closer: Character = quote == "(" ? ")" : quote
            guard let end = c[(j + 1)..<to].firstIndex(of: closer) else { return nil }
            title = String(c[(j + 1)..<end]); j = end + 1
            while j < to, c[j] == " " { j += 1 }
        }
        guard j < to, c[j] == ")" else { return nil }
        return Link(textStart: open + 1, textEnd: close, destination: destination, title: title, end: j + 1)
    }

    private func bareURL(_ c: [Character], _ i: Int, _ to: Int) -> (String, Int)? {
        if i > 0, (c[i - 1].isLetter && !Renderer.isCJK(c[i - 1])) || c[i - 1].isNumber || c[i - 1] == "/" || c[i - 1] == "\"" || c[i - 1] == "=" { return nil }
        let prefixes = ["https://", "http://", "mailto:", "www."]
        let ahead = String(c[i..<min(to, i + 8)])
        guard prefixes.contains(where: { ahead.hasPrefix($0) }) else { return nil }
        var end = i
        var parens = 0
        while end < to {
            let ch = c[end]
            if ch.isWhitespace || "<>\"'`".contains(ch) || Renderer.isCJK(ch) || "，。；！？、（）【】「」".contains(ch) { break }
            if ch == "(" { parens += 1 }
            if ch == ")" { if parens == 0 { break }; parens -= 1 }
            end += 1
        }
        while end > i, ".,:;!?*_~".contains(c[end - 1]) { end -= 1 }
        let url = String(c[i..<end])
        guard url.count > (url.hasPrefix("www.") ? 5 : 8) else { return nil }
        return (url, end)
    }

    /// Alt text without Markdown punctuation.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"[*_`~\[\]]"#, with: "", options: .regularExpression)
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x3000...0x303F, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

/// Code block colors from the editor's own tokenizer, as `<span class="tok-…">`.
enum MarkdownCodeHighlight {
    static func language(_ name: String) -> SyntaxLanguage {
        let aliases = ["javascript": "js", "jsx": "jsx", "node": "js", "typescript": "ts", "python": "py", "py3": "py",
                       "shell": "sh", "console": "sh", "bash": "sh", "zsh": "sh", "jsonc": "json", "swift": "swift",
                       "dockerfile": "dockerfile", "docker": "dockerfile", "makefile": "mk", "make": "mk", "env": "env",
                       "dotenv": "env", "gitignore": "gitignore", "postgresql": "sql", "mysql": "sql", "sqlite": "sql"]
        let key = name.lowercased()
        switch aliases[key] ?? key {
        case "dockerfile": return .dockerfile
        case "env": return .dotenv
        case "gitignore": return .ignore
        case let ext: return SyntaxLanguage(path: "x." + ext)
        }
    }

    static func html(_ code: String, language name: String) -> String {
        let language = language(name)
        guard language != .plainText, let result = SyntaxTokenizer.tokenize(code, language: language) else { return MarkdownHTML.escape(code) }
        let source = code as NSString
        var out = ""
        var cursor = 0
        for token in result.tokens.sorted(by: { $0.range.location < $1.range.location }) where token.range.location >= cursor {
            out += MarkdownHTML.escape(source.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            out += "<span class=\"tok-\(className(token.kind))\">\(MarkdownHTML.escape(source.substring(with: token.range)))</span>"
            cursor = NSMaxRange(token.range)
        }
        out += MarkdownHTML.escape(source.substring(from: cursor))
        return out
    }

    private static func className(_ kind: SyntaxTokenKind) -> String {
        switch kind {
        case .keyword: return "keyword"
        case .string: return "string"
        case .number: return "number"
        case .comment: return "comment"
        case .literal: return "literal"
        case .type: return "type"
        case .variable: return "variable"
        }
    }
}
