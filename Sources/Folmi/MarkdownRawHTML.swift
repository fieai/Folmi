import Foundation

/// The raw HTML a Markdown document may carry, the way READMEs use it: `<div align="center">`, `<table>` of
/// screenshots, `<img width>`, `<picture>`, `<details>`, `<kbd>`. Only allow-listed tags and attributes pass; everything
/// else is shown as text (script and style are dropped with their content), image sources go through the same resolver
/// as `![]()` images and links get `data-href`, so a document still can never run script or navigate the reader.
struct MarkdownRawHTML {
    let imageSource: (String) -> String?
    /// Unclosed container tags so far; an HTML block keeps going over blank lines while this is above zero.
    private(set) var depth = 0
    /// An unfinished tag or comment carried over to the next line.
    private var pending = ""
    /// Inside `<script>` / `<style>`: everything up to its close tag is dropped.
    private var skipping: String?
    private var preDepth = 0

    init(imageSource: @escaping (String) -> String?) { self.imageSource = imageSource }

    /// A blank line here does not end the HTML (inside a comment, `<pre>` or a dropped script).
    var continuesOverBlank: Bool { skipping != nil || pending.hasPrefix("<!--") || preDepth > 0 }

    mutating func feed(_ text: String) -> String {
        let c = Array(pending + text)
        pending = ""
        var out = ""
        var i = 0
        while i < c.count {
            if let name = skipping {
                guard let close = Self.closeTag(name, in: c, from: i) else { return out }
                skipping = nil; i = close; continue
            }
            let ch = c[i]
            if ch == "<" {
                if Self.hasPrefix(c, i, "<!--") {
                    guard let end = Self.find(c, i + 4, ["-", "-", ">"]) else { pending = String(c[i...]); return out }
                    i = end + 3; continue
                }
                if let tag = Self.parseTag(c, i, c.count) {
                    if !tag.closing, Self.dropped.contains(tag.name) {
                        if !tag.selfClosing { skipping = tag.name }
                    } else if let html = sanitize(tag) {
                        out += html
                        track(tag)
                    } else {
                        out += MarkdownHTML.escape(String(c[i..<tag.end]))
                    }
                    i = tag.end; continue
                }
                if Self.mayStartTag(c, i), !c[i...].contains(">") { pending = String(c[i...]); return out }
            } else if ch == "&", let end = Self.entity(c, i, c.count) {
                out += String(c[i..<end]); i = end; continue
            }
            MarkdownHTML.appendEscaped(ch, to: &out)
            i += 1
        }
        return out
    }

    /// Whatever is still pending, as text. An unclosed comment or script stays hidden.
    mutating func finish() -> String {
        defer { pending = "" }
        return pending.hasPrefix("<!--") ? "" : MarkdownHTML.escape(pending)
    }

    /// One tag or comment inside a paragraph, sanitized; nil when it is not allowed (the caller shows it as text).
    static func inline(_ c: [Character], _ i: Int, _ to: Int, imageSource: @escaping (String) -> String?) -> (String, Int)? {
        if hasPrefix(c, i, "<!--"), let end = find(c, i + 4, ["-", "-", ">"]), end + 3 <= to { return ("", end + 3) }
        guard let tag = parseTag(c, i, to), !dropped.contains(tag.name),
              let html = MarkdownRawHTML(imageSource: imageSource).sanitize(tag) else { return nil }
        return (html, tag.end)
    }

    enum BlockStart { case interrupting, standalone }

    /// Whether a line opens an HTML block (CommonMark kinds 1, 2, 6 and 7). Only `.interrupting` may cut a paragraph.
    static func blockStart(_ trimmed: String) -> BlockStart? {
        guard trimmed.hasPrefix("<") else { return nil }
        if trimmed.hasPrefix("<!--") { return .interrupting }
        let c = Array(trimmed)
        let slash = c.count > 1 && c[1] == "/" ? 1 : 0
        let name = String(c.dropFirst(1 + slash).prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
        let after = 1 + slash + name.count
        guard !name.isEmpty, c[1 + slash].isLetter else { return nil }
        if after == c.count || c[after] == " " || c[after] == "\t" || c[after] == ">" || (c[after] == "/" && c.count > after + 1 && c[after + 1] == ">") {
            if interruptingTags.contains(name) || (slash == 0 && dropped.contains(name)) { return .interrupting }
        }
        guard let tag = parseTag(c, 0, c.count), c[tag.end...].allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return .standalone
    }

    // MARK: Allow lists

    private static let allowedTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "center", "cite", "code", "col", "colgroup", "dd", "del", "details",
        "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd",
        "li", "mark", "ol", "p", "picture", "pre", "q", "s", "samp", "small", "source", "span", "strike", "strong", "sub",
        "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var", "wbr",
    ]
    private static let voidTags: Set<String> = ["br", "col", "hr", "img", "source", "wbr"]
    /// Tags whose content goes with them.
    private static let dropped: Set<String> = ["script", "style", "iframe", "object", "embed", "template", "textarea", "title", "noscript", "svg", "math"]
    private static let interruptingTags: Set<String> = [
        "address", "article", "aside", "blockquote", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "div",
        "dl", "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav",
        "ol", "p", "picture", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]
    /// Container tags counted for `depth`, so `<div align="center">` … blank line … `</div>` stays one block.
    private static let containers: Set<String> = ["blockquote", "center", "details", "div", "dl", "figure", "ol", "p", "picture", "table", "ul"]
    private static let attributes: Set<String> = [
        "align", "alt", "colspan", "dir", "height", "lang", "media", "open", "reversed", "rowspan", "start", "title", "type",
        "valign", "width",
    ]

    // MARK: Sanitizing

    private func sanitize(_ tag: Tag) -> String? {
        guard Self.allowedTags.contains(tag.name) else { return nil }
        if tag.closing { return Self.voidTags.contains(tag.name) ? "" : "</\(tag.name)>" }
        var out = "<" + tag.name
        for (key, raw) in tag.attributes {
            let value = raw.map(Self.decode) ?? ""
            switch key {
            case "src" where tag.name == "img":
                guard let source = imageSource(value) else {
                    let label = tag.attributes.first { $0.0 == "alt" }?.1.map(Self.decode) ?? ""
                    return "<span class=\"missing-image\" title=\"\(MarkdownHTML.escape(value))\">\(MarkdownHTML.escape(label.isEmpty ? value : label))</span>"
                }
                out += " src=\"\(MarkdownHTML.escape(source))\""
            case "srcset" where tag.name == "source" || tag.name == "img":
                var candidates: [String] = []
                for candidate in value.split(separator: ",") {
                    let parts = candidate.split(separator: " ", omittingEmptySubsequences: true)
                    guard let first = parts.first, let source = imageSource(String(first)) else { return tag.name == "source" ? "" : nil }
                    candidates.append(([source] + parts.dropFirst().map(String.init)).joined(separator: " "))
                }
                out += " srcset=\"\(MarkdownHTML.escape(candidates.joined(separator: ", ")))\""
            case "href" where tag.name == "a":
                // Relative paths and anchors, or http(s) / mailto; never javascript: and the like.
                let head = value.filter { !$0.isWhitespace && !$0.isNewline }.prefix { !"/#?".contains($0) }
                if let colon = head.firstIndex(of: ":"), !["http", "https", "mailto"].contains(head[..<colon].lowercased()) { continue }
                out += " href=\"\(MarkdownHTML.escape(value))\" data-href=\"\(MarkdownHTML.escape(value))\""
            case let key where Self.attributes.contains(key):
                out += raw == nil ? " \(key)" : " \(key)=\"\(MarkdownHTML.escape(value))\""
            default:
                continue
            }
        }
        if tag.name == "img" { out += " loading=\"lazy\"" }
        return out + ">"
    }

    private mutating func track(_ tag: Tag) {
        guard !tag.selfClosing else { return }
        if Self.containers.contains(tag.name) { depth = max(0, depth + (tag.closing ? -1 : 1)) }
        if tag.name == "pre" { preDepth = max(0, preDepth + (tag.closing ? -1 : 1)) }
    }

    private static func decode(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Parsing

    struct Tag {
        var name: String
        var closing: Bool
        var selfClosing = false
        var attributes: [(String, String?)] = []
        /// Index just past the `>`.
        var end: Int
    }

    /// An open or close tag starting at `c[i] == "<"`, attributes may span lines; nil when it is not a well-formed tag.
    static func parseTag(_ c: [Character], _ i: Int, _ to: Int) -> Tag? {
        var j = i + 1
        let closing = j < to && c[j] == "/"
        if closing { j += 1 }
        guard j < to, c[j].isASCII, c[j].isLetter else { return nil }
        let nameStart = j
        while j < to, c[j].isASCII, c[j].isLetter || c[j].isNumber || c[j] == "-" { j += 1 }
        var tag = Tag(name: String(c[nameStart..<j]).lowercased(), closing: closing, end: 0)
        func skipSpace() { while j < to, c[j].isWhitespace { j += 1 } }
        if closing {
            skipSpace()
            guard j < to, c[j] == ">" else { return nil }
            tag.end = j + 1
            return tag
        }
        while true {
            let spaced = j < to && c[j].isWhitespace
            skipSpace()
            guard j < to else { return nil }
            if c[j] == ">" { tag.end = j + 1; return tag }
            if c[j] == "/" { guard j + 1 < to, c[j + 1] == ">" else { return nil }; tag.selfClosing = true; tag.end = j + 2; return tag }
            guard spaced else { return nil }
            let keyStart = j
            while j < to, !c[j].isWhitespace, !"\"'<>/=`".contains(c[j]) { j += 1 }
            guard j > keyStart else { return nil }
            let key = String(c[keyStart..<j]).lowercased()
            let beforeValue = j
            skipSpace()
            guard j < to, c[j] == "=" else { j = beforeValue; tag.attributes.append((key, nil)); continue }
            j += 1
            skipSpace()
            guard j < to else { return nil }
            if c[j] == "\"" || c[j] == "'" {
                let quote = c[j]
                guard let close = c[(j + 1)..<to].firstIndex(of: quote) else { return nil }
                tag.attributes.append((key, String(c[(j + 1)..<close])))
                j = close + 1
                guard j < to, c[j].isWhitespace || c[j] == ">" || c[j] == "/" else { return nil }
            } else {
                let valueStart = j
                while j < to, !c[j].isWhitespace, !"\"'=<>`".contains(c[j]) { j += 1 }
                guard j > valueStart else { return nil }
                tag.attributes.append((key, String(c[valueStart..<j])))
            }
        }
    }

    private static func mayStartTag(_ c: [Character], _ i: Int) -> Bool {
        let j = i + 1 < c.count && c[i + 1] == "/" ? i + 2 : i + 1
        return j < c.count && c[j].isASCII && c[j].isLetter
    }

    /// Index just past `</name …>`, case-insensitive.
    private static func closeTag(_ name: String, in c: [Character], from start: Int) -> Int? {
        var i = start
        while let open = c[i...].firstIndex(of: "<") {
            if let tag = parseTag(c, open, c.count), tag.closing, tag.name == name { return tag.end }
            i = open + 1
        }
        return nil
    }

    private static func entity(_ c: [Character], _ i: Int, _ to: Int) -> Int? {
        guard let semicolon = c[i..<min(to, i + 12)].firstIndex(of: ";"),
              String(c[i...semicolon]).range(of: #"^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,30});$"#, options: .regularExpression) != nil
        else { return nil }
        return semicolon + 1
    }

    private static func hasPrefix(_ c: [Character], _ i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        return i + p.count <= c.count && Array(c[i..<(i + p.count)]) == p
    }

    private static func find(_ c: [Character], _ from: Int, _ pattern: [Character]) -> Int? {
        var i = from
        while i + pattern.count <= c.count {
            if Array(c[i..<(i + pattern.count)]) == pattern { return i }
            i += 1
        }
        return nil
    }
}
