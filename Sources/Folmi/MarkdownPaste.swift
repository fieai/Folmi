import Foundation

/// Pasted rich text (the HTML flavor a browser, Feishu, Google Docs or Word puts on the pasteboard) turned into
/// Markdown, offline and within a budget. Scripts, frames and embedded objects are dropped as text; nothing is loaded
/// from the network, and pictures keep only a web address. Text with no structure returns nil, so the caller pastes
/// the plain text instead (code copied from an editor arrives as styled spans and must stay code).
enum MarkdownPaste {
    static let maximumBytes = 1_024 * 1_024
    static let maximumNodes = 20_000
    static let maximumDepth = 64

    struct Result: Equatable {
        let markdown: String
        /// What could not be kept, to tell the user.
        let notes: [String]
    }

    static func markdown(fromHTML html: String) -> Result? {
        guard html.utf8.count <= maximumBytes,
              let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement() else { return nil }
        var converter = Converter()
        let body = root.elements(forName: "body").first ?? root
        let blocks = converter.blocks(body.children ?? [], depth: 0)
        guard !converter.overBudget, converter.hasStructure else { return nil }
        var markdown = blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        while markdown.contains("\n\n\n") { markdown = markdown.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        return Result(markdown: markdown, notes: Array(converter.notes).sorted())
    }

    private struct Converter {
        var nodes = 0
        var overBudget = false
        /// Headings, lists, tables, links, emphasis… anything plain text would lose.
        var hasStructure = false
        var notes: Set<String> = []

        static let dropped: Set<String> = ["script", "style", "iframe", "object", "embed", "noscript", "template", "head", "meta",
                                           "link", "svg", "canvas", "button", "select", "textarea", "video", "audio", "title"]
        static let blockNames: Set<String> = ["p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure",
                                              "figcaption", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote",
                                              "pre", "table", "hr", "dl", "dt", "dd", "body", "html"]

        mutating func tick(_ depth: Int) -> Bool {
            nodes += 1
            if nodes > MarkdownPaste.maximumNodes || depth > MarkdownPaste.maximumDepth { overBudget = true }
            return !overBudget
        }

        // MARK: Blocks

        mutating func blocks(_ children: [XMLNode], depth: Int) -> [String] {
            var result: [String] = []
            var inline: [XMLNode] = []
            func flush(_ converter: inout Converter) {
                guard !inline.isEmpty else { return }
                let text = converter.inlineText(inline, depth: depth).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(text) }
                inline = []
            }
            for child in children {
                guard tick(depth) else { break }
                if let element = child as? XMLElement, let name = element.name?.lowercased() {
                    if Self.dropped.contains(name) {
                        if ["iframe", "object", "embed", "video", "audio", "svg", "canvas"].contains(name) { notes.insert("嵌入内容（视频、框架、图形）没有粘贴") }
                        continue
                    }
                    if Self.blockNames.contains(name) {
                        flush(&self)
                        result.append(contentsOf: block(element, name: name, depth: depth + 1))
                        continue
                    }
                }
                inline.append(child)
            }
            flush(&self)
            return result
        }

        mutating func block(_ element: XMLElement, name: String, depth: Int) -> [String] {
            let children = element.children ?? []
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                hasStructure = true
                let level = Int(String(name.dropFirst()))!
                let text = inlineText(children, depth: depth).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]
            case "p", "dt", "dd", "figcaption":
                let text = inlineText(children, depth: depth).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : [text]
            case "hr":
                hasStructure = true
                return ["---"]
            case "pre":
                hasStructure = true
                var code = element.stringValue ?? ""
                if code.hasSuffix("\n") { code.removeLast() }
                let classes = ([element] + (element.elements(forName: "code"))).compactMap { $0.attribute(forName: "class")?.stringValue }.joined(separator: " ")
                let language = classes.split(separator: " ").first { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }
                    .map { String($0.split(separator: "-", maxSplits: 1).last ?? "") } ?? ""
                var fence = "```"
                while code.contains(fence) { fence += "`" }
                return [fence + language + "\n" + code + "\n" + fence]
            case "blockquote":
                hasStructure = true
                let inner = blocks(children, depth: depth).joined(separator: "\n\n")
                guard !inner.isEmpty else { return [] }
                return [inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")]
            case "ul", "ol":
                hasStructure = true
                return [list(element, ordered: name == "ol", depth: depth)].filter { !$0.isEmpty }
            case "li":
                // A stray item outside a list.
                hasStructure = true
                let inner = blocks(children, depth: depth).joined(separator: "\n")
                return inner.isEmpty ? [] : ["- " + inner]
            case "table":
                hasStructure = true
                return [table(element, depth: depth)].filter { !$0.isEmpty }
            default:
                return blocks(children, depth: depth)
            }
        }

        mutating func list(_ element: XMLElement, ordered: Bool, depth: Int) -> String {
            var number = Int(element.attribute(forName: "start")?.stringValue ?? "") ?? 1
            var items: [String] = []
            for child in element.children ?? [] {
                guard tick(depth) else { break }
                guard let item = child as? XMLElement else { continue }
                let name = item.name?.lowercased() ?? ""
                if name == "ul" || name == "ol" {
                    // A nested list placed directly in the list: indent it under the previous item.
                    let nested = list(item, ordered: name == "ol", depth: depth + 1)
                    if !nested.isEmpty { items.append(nested.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")) }
                    continue
                }
                guard name == "li" else { continue }
                var children = item.children ?? []
                var box = ""
                // A leading checkbox (GitHub, Feishu task lists) becomes a task item.
                if let index = firstCheckbox(in: &children) { box = index ? "[x] " : "[ ] " }
                let marker = (ordered ? "\(number)." : "-") + " "
                number += 1
                let inner = blocks(children, depth: depth + 1).joined(separator: "\n")
                let lines = inner.isEmpty ? [""] : inner.components(separatedBy: "\n")
                let indent = String(repeating: " ", count: marker.count)
                items.append(([marker + box + lines[0]] + lines.dropFirst().map { $0.isEmpty ? "" : indent + $0 }).joined(separator: "\n"))
            }
            return items.joined(separator: "\n")
        }

        /// Removes a leading `<input type=checkbox>` (possibly inside the item's first paragraph) and returns its state.
        func firstCheckbox(in children: inout [XMLNode]) -> Bool? {
            for (index, child) in children.enumerated() {
                if child.kind == .text, (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard let element = child as? XMLElement else { return nil }
                if element.name?.lowercased() == "input", element.attribute(forName: "type")?.stringValue?.lowercased() == "checkbox" {
                    children.remove(at: index)
                    return element.attribute(forName: "checked") != nil
                }
                if ["p", "label", "span", "div"].contains(element.name?.lowercased() ?? ""), var inner = element.children {
                    if let checked = firstCheckbox(in: &inner) { element.setChildren(inner); return checked }
                }
                return nil
            }
            return nil
        }

        mutating func table(_ element: XMLElement, depth: Int) -> String {
            var rows: [[String]] = []
            var headerRows = 0
            func collect(_ node: XMLElement, _ converter: inout Converter) {
                for child in node.children ?? [] {
                    guard converter.tick(depth), let child = child as? XMLElement else { continue }
                    switch child.name?.lowercased() ?? "" {
                    case "thead", "tbody", "tfoot": collect(child, &converter)
                    case "tr":
                        var cells: [String] = []
                        var allHeader = true
                        for cell in child.children ?? [] {
                            guard let cell = cell as? XMLElement, let name = cell.name?.lowercased(), name == "td" || name == "th" else { continue }
                            if name == "td" { allHeader = false }
                            if (cell.elements(forName: "table")).isEmpty == false { converter.notes.insert("表格里嵌套的表格按文字粘贴") }
                            let text = converter.inlineText(cell.children ?? [], depth: depth + 1)
                                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
                                .trimmingCharacters(in: .whitespaces)
                            cells.append(text)
                            let span = Int(cell.attribute(forName: "colspan")?.stringValue ?? "") ?? 1
                            if span > 1 {
                                converter.notes.insert("合并的单元格已拆开，内容放在第一格")
                                cells.append(contentsOf: Array(repeating: "", count: min(50, span - 1)))
                            }
                            if (Int(cell.attribute(forName: "rowspan")?.stringValue ?? "") ?? 1) > 1 {
                                converter.notes.insert("合并的单元格已拆开，内容放在第一格")
                            }
                        }
                        if !cells.isEmpty {
                            if allHeader && rows.count == headerRows { headerRows += 1 }
                            rows.append(cells)
                        }
                    default: break
                    }
                }
            }
            collect(element, &self)
            guard !rows.isEmpty else { return "" }
            let columns = rows.map(\.count).max() ?? 1
            func line(_ cells: [String]) -> String {
                "| " + (cells + Array(repeating: "", count: columns - cells.count)).joined(separator: " | ") + " |"
            }
            var lines = [line(rows[0]), "|" + Array(repeating: " --- ", count: columns).joined(separator: "|") + "|"]
            lines += rows.dropFirst().map(line)
            return lines.joined(separator: "\n")
        }

        // MARK: Inline

        mutating func inlineText(_ nodes: [XMLNode], depth: Int) -> String {
            var output = ""
            for node in nodes {
                guard tick(depth) else { break }
                output += inline(node, depth: depth + 1)
            }
            // Collapse runs of spaces the HTML layout would have collapsed, but keep hard breaks.
            var collapsed = output.replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
            collapsed = collapsed.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
            return collapsed
        }

        mutating func inline(_ node: XMLNode, depth: Int) -> String {
            guard let element = node as? XMLElement, let name = element.name?.lowercased() else {
                guard node.kind == .text else { return "" }
                // Source newlines are layout, not breaks.
                return escape((node.stringValue ?? "").replacingOccurrences(of: "\n", with: " "))
            }
            if Self.dropped.contains(name) {
                if ["iframe", "object", "embed", "video", "audio"].contains(name) { notes.insert("嵌入内容（视频、框架、图形）没有粘贴") }
                return ""
            }
            let children = element.children ?? []
            let style = (element.attribute(forName: "style")?.stringValue ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            func wrap(_ marker: String, _ converter: inout Converter) -> String {
                let inner = converter.inlineText(children, depth: depth)
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.contains("\n") else { return inner }
                converter.hasStructure = true
                let leading = inner.prefix { $0 == " " }, trailing = String(inner.reversed().prefix { $0 == " " })
                return leading + marker + trimmed + marker + trailing
            }
            switch name {
            case "br": return "\n"
            case "strong", "b":
                // Google Docs wraps a whole copy in <b style="font-weight:normal">.
                if style.contains("font-weight:normal") || style.contains("font-weight:400") { return inlineText(children, depth: depth) }
                return wrap("**", &self)
            case "em", "i", "cite": return wrap("*", &self)
            case "s", "del", "strike": return wrap("~~", &self)
            case "code", "kbd", "samp", "tt":
                let code = (element.stringValue ?? "").replacingOccurrences(of: "\n", with: " ")
                guard !code.isEmpty else { return "" }
                hasStructure = true
                let ticks = code.contains("`") ? "``" : "`"
                return ticks + (code.hasPrefix("`") || code.hasSuffix("`") ? " \(code) " : code) + ticks
            case "a":
                let text = inlineText(children, depth: depth).trimmingCharacters(in: .whitespaces)
                let href = (element.attribute(forName: "href")?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                let lower = href.lowercased()
                guard !text.isEmpty else { return "" }
                guard !href.isEmpty, !lower.hasPrefix("javascript:"), !lower.hasPrefix("data:"), !lower.hasPrefix("vbscript:") else { return text }
                hasStructure = true
                let address = href.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                return "[\(text)](\(address))"
            case "img":
                let alt = (element.attribute(forName: "alt")?.stringValue ?? "").replacingOccurrences(of: "]", with: "")
                let source = (element.attribute(forName: "src")?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                if source.lowercased().hasPrefix("http://") || source.lowercased().hasPrefix("https://") {
                    hasStructure = true
                    return "![\(alt)](\(source.replacingOccurrences(of: " ", with: "%20")))"
                }
                notes.insert("非网络地址的图片没有粘贴；可以把图片文件直接粘贴或拖进来")
                return alt
            case "input":
                return ""
            default:
                // Styled spans: bold, italic and strike-through from inline CSS.
                if style.contains("font-weight:bold") || style.contains("font-weight:700") || style.contains("font-weight:600") || style.contains("font-weight:800") {
                    return wrap("**", &self)
                }
                if style.contains("font-style:italic") { return wrap("*", &self) }
                if style.contains("line-through") { return wrap("~~", &self) }
                if Self.blockNames.contains(name) {
                    // A block inside inline content (a div in a span): its own line.
                    let text = blocks(children, depth: depth).joined(separator: "\n")
                    return text.isEmpty ? "" : "\n" + text + "\n"
                }
                return inlineText(children, depth: depth)
            }
        }

        /// Characters that would turn plain text into emphasis or code.
        func escape(_ text: String) -> String {
            guard text.contains(where: { $0 == "*" || $0 == "`" }) else { return text }
            return text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "`", with: "\\`")
        }
    }
}
