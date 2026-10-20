import Foundation

/// Finding and resolving the link under a ⌘-click. Pure, so the rules about what may be opened are testable.
enum MarkdownLinks {
    enum Destination: Equatable {
        /// http, https or mailto, opened by the system.
        case web(URL)
        /// A file inside the project, relative to the root, optionally at a line or a heading.
        case file(path: String, line: Int?, anchor: String?)
        /// A heading of the current document.
        case anchor(String)
        /// `[[name#anchor]]`: a note found by name anywhere in the project.
        case wiki(name: String, anchor: String?)
        /// Refused: another scheme, or a path that leaves the project.
        case refused(String)
    }

    private static let inline = try! NSRegularExpression(pattern: #"!?\[(?:[^\[\]\\]|\\.)*\]\(([^()\s]*(?:\([^()\s]*\)[^()\s]*)*)(?:\s+"[^"]*")?\)"#)
    private static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n|]+)(?:\|[^\[\]\n]*)?\]\]"#)
    private static let angle = try! NSRegularExpression(pattern: #"<((?:https?|mailto):[^>\s]+)>"#)
    private static let bare = try! NSRegularExpression(pattern: #"(?:https?://|mailto:)[^\s<>()\[\]"'，。；！？、]+"#)

    /// The target of the link that contains `location`: `[[note]]` (returned with its brackets), `[text](target)`, `![alt](target)`, `<url>` or a bare URL.
    static func target(in text: String, at location: Int) -> String? {
        let source = text as NSString
        guard location >= 0, location <= source.length else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: min(location, max(0, source.length - 1)), length: 0))
        let line = source.substring(with: lineRange)
        let offset = location - lineRange.location
        let whole = NSRange(location: 0, length: (line as NSString).length)
        for match in wiki.matches(in: line, range: whole) where offset >= match.range.location && offset < NSMaxRange(match.range) {
            return "[[" + (line as NSString).substring(with: match.range(at: 1)) + "]]"
        }
        for pattern in [inline, angle] {
            for match in pattern.matches(in: line, range: whole) where offset >= match.range.location && offset < NSMaxRange(match.range) {
                let target = (line as NSString).substring(with: match.range(at: 1))
                return target.hasPrefix("<") && target.hasSuffix(">") ? String(target.dropFirst().dropLast()) : target
            }
        }
        for match in bare.matches(in: line, range: whole) where offset >= match.range.location && offset < NSMaxRange(match.range) {
            var url = (line as NSString).substring(with: match.range)
            while let last = url.last, ".,:;!?".contains(last) { url.removeLast() }
            return url
        }
        return nil
    }

    /// Where a link from `documentPath` (relative to the project root) leads.
    static func resolve(_ rawTarget: String, from documentPath: String) -> Destination {
        let target = rawTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return .refused("链接地址为空") }
        if target.hasPrefix("[["), target.hasSuffix("]]"), target.count > 4 {
            let inner = String(target.dropFirst(2).dropLast(2))
            guard let hash = inner.firstIndex(of: "#") else { return .wiki(name: inner, anchor: nil) }
            let anchor = String(inner[inner.index(after: hash)...])
            return .wiki(name: String(inner[..<hash]), anchor: anchor.isEmpty ? nil : anchor)
        }
        if let scheme = scheme(of: target) {
            guard ["http", "https", "mailto"].contains(scheme), let url = URL(string: target) else {
                return .refused("不打开 \(scheme): 链接")
            }
            return .web(url)
        }
        if target.hasPrefix("#") { return .anchor(decode(String(target.dropFirst()))) }
        var pathPart = target, fragment: String?
        if let hash = target.firstIndex(of: "#") {
            pathPart = String(target[..<hash]); fragment = decode(String(target[target.index(after: hash)...]))
        }
        pathPart = decode(pathPart)
        // "/x" means the project root, as on a code host; anything else is relative to the document.
        var components = pathPart.hasPrefix("/") ? [] : documentPath.split(separator: "/").dropLast().map(String.init)
        for part in pathPart.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return .refused("链接指向项目之外") }
                components.removeLast()
            default: components.append(String(part))
            }
        }
        guard !components.isEmpty else { return .refused("链接没有指向文件") }
        var line: Int?
        var anchor = fragment
        // GitHub-style line fragments: #L12 or #L12-L20.
        if let fragment, fragment.hasPrefix("L"), let number = Int(fragment.dropFirst().prefix { $0.isNumber }), number > 0 {
            line = number; anchor = nil
        }
        return .file(path: components.joined(separator: "/"), line: line, anchor: anchor?.isEmpty == true ? nil : anchor)
    }

    private static func scheme(of target: String) -> String? {
        guard let colon = target.firstIndex(of: ":") else { return nil }
        let scheme = target[..<colon]
        // A Windows drive letter or "a:b" without a valid scheme shape is treated as a path.
        guard scheme.count > 1, let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        return scheme.lowercased()
    }

    private static func decode(_ text: String) -> String { text.removingPercentEncoding ?? text }

    /// GitHub's heading anchor: lowercase, spaces to hyphens, punctuation dropped; letters of any script are kept.
    static func slug(_ heading: String) -> String {
        var result = ""
        for character in heading.lowercased() {
            if character == " " || character == "-" { result.append("-") }
            else if character.isLetter || character.isNumber || character == "_" { result.append(character) }
        }
        return result
    }

    /// The 1-based line of the heading whose anchor is `anchor`, matching the slug or the heading text itself.
    static func headingLine(_ anchor: String, in text: String) -> Int? {
        let wanted = slug(anchor)
        var number = 0
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard hashes <= 6 else { continue }
            let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            if slug(title) == wanted || title == anchor { return number }
        }
        return nil
    }
}
