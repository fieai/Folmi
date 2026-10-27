import Foundation

/// Typora/Obsidian-style editing commands for Markdown source. Each returns one replacement (UTF-16 ranges) or nil
/// when the key should do what it does in any other file. Nothing here touches AppKit, so every rule is testable.
enum MarkdownEditing {
    typealias Edit = EditorLineEdit

    // MARK: Line structure

    struct ListPrefix: Equatable {
        let indent: String
        /// "-", "*", "+", or a number with "." / ")".
        let marker: String
        let spacing: String
        let task: Bool
        /// UTF-16 length of the whole prefix, task box included.
        let length: Int
        var number: Int? { Int(marker.dropLast()) }
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX/-]\][ \t]+)?"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^([ \t]*)((?:>[ \t]?)+)"#)
    private static let rulePattern = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"^ {0,3}(```|~~~)"#)

    static func listPrefix(_ line: String) -> ListPrefix? {
        let source = line as NSString
        guard rulePattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) == nil,
              let match = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return nil }
        func group(_ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
        return ListPrefix(indent: group(1), marker: group(2), spacing: group(3), task: !group(4).isEmpty, length: match.range.length)
    }

    /// The `>` run of a quote line, with its indent, and its UTF-16 length.
    static func quotePrefix(_ line: String) -> (text: String, length: Int)? {
        let source = line as NSString
        guard let match = quotePattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return nil }
        return (source.substring(with: match.range), match.range.length)
    }

    /// True when `location` is inside a fenced code block (an odd number of fences opened above its line).
    static func inFence(_ text: String, at location: Int) -> Bool {
        let source = text as NSString
        var open = false
        var cursor = 0
        let lineStart = source.lineRange(for: NSRange(location: min(location, source.length), length: 0)).location
        while cursor < lineStart {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            let content = source.substring(with: line)
            if fencePattern.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) != nil { open.toggle() }
            cursor = NSMaxRange(line)
        }
        return open
    }

    /// The line around `location` without its line break.
    private static func line(_ source: NSString, at location: Int) -> NSRange {
        var range = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
        while range.length > 0 {
            let last = source.character(at: NSMaxRange(range) - 1)
            guard last == 10 || last == 13 else { break }
            range.length -= 1
        }
        return range
    }

    // MARK: Return

    /// Continues a list item, task or quote on Return; on an empty item it outdents, or ends the list.
    static func newline(text: String, selection: NSRange, tabSize: Int) -> Edit? {
        let source = text as NSString
        guard NSMaxRange(selection) <= source.length, !inFence(text, at: selection.location) else { return nil }
        let lineRange = line(source, at: selection.location)
        // A selection spanning lines is replaced by a plain newline.
        guard NSMaxRange(selection) <= NSMaxRange(lineRange) else { return nil }
        let content = source.substring(with: lineRange)
        let caret = selection.location - lineRange.location
        let afterSelection = (content as NSString).substring(from: NSMaxRange(selection) - lineRange.location)

        if let list = listPrefix(content) {
            guard caret >= list.length else { return nil }
            let body = (content as NSString).substring(from: list.length)
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                if !list.indent.isEmpty {
                    // Empty nested item: move it one level out.
                    let outdented = outdent(list.indent, tabSize: tabSize)
                    let replacement = outdented + (content as NSString).substring(from: (list.indent as NSString).length)
                    return Edit(range: lineRange, replacement: replacement,
                                selection: NSRange(location: lineRange.location + (replacement as NSString).length, length: 0))
                }
                // Empty top-level item: end the list, leaving an empty line.
                return Edit(range: lineRange, replacement: "", selection: NSRange(location: lineRange.location, length: 0))
            }
            let marker = list.number.map { "\($0 + 1)" + String(list.marker.suffix(1)) } ?? list.marker
            let insertion = "\n" + list.indent + marker + list.spacing + (list.task ? "[ ] " : "")
            let start = selection.location
            return Edit(range: NSRange(location: start, length: NSMaxRange(lineRange) - start),
                        replacement: insertion + afterSelection,
                        selection: NSRange(location: start + (insertion as NSString).length, length: 0))
        }
        if let quote = quotePrefix(content) {
            guard caret >= quote.length else { return nil }
            let body = (content as NSString).substring(from: quote.length)
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                return Edit(range: lineRange, replacement: "", selection: NSRange(location: lineRange.location, length: 0))
            }
            var continued = quote.text
            if !continued.hasSuffix(" ") { continued += " " }
            let insertion = "\n" + continued
            return Edit(range: NSRange(location: selection.location, length: NSMaxRange(lineRange) - selection.location),
                        replacement: insertion + afterSelection,
                        selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        }
        return nil
    }

    private static func outdent(_ indent: String, tabSize: Int) -> String {
        if indent.hasPrefix("\t") { return String(indent.dropFirst()) }
        let spaces = indent.prefix { $0 == " " }.count
        return String(indent.dropFirst(min(spaces, max(1, tabSize))))
    }

    // MARK: Tab

    /// Tab / Shift-Tab on list items: indents or outdents every selected line by one level.
    /// Nil when a selected line is not a list item, so Tab keeps inserting spaces elsewhere.
    static func indent(text: String, selection: NSRange, outdent isOutdent: Bool, tabSize: Int) -> Edit? {
        let source = text as NSString
        guard NSMaxRange(selection) <= source.length else { return nil }
        let first = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let endLocation = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let last = source.lineRange(for: NSRange(location: endLocation, length: 0))
        let block = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let lines = source.substring(with: block).components(separatedBy: "\n")
        // The split leaves an empty piece after a final newline; it is not a line of its own.
        let real = lines.last == "" && lines.count > 1 ? Array(lines.dropLast()) : lines
        guard !real.isEmpty, real.allSatisfy({ listPrefix($0) != nil }) else { return nil }
        let unit = String(repeating: " ", count: min(8, max(1, tabSize)))
        var deltas: [Int] = []
        let changed = real.map { line -> String in
            if isOutdent {
                let prefix = line.prefix { $0 == " " || $0 == "\t" }
                let next = outdent(String(prefix), tabSize: tabSize) + line.dropFirst(prefix.count)
                deltas.append((next as NSString).length - (line as NSString).length)
                return next
            }
            deltas.append((unit as NSString).length)
            return unit + line
        }
        guard deltas.contains(where: { $0 != 0 }) else { return nil }
        let replacement = changed.joined(separator: "\n") + (real.count < lines.count ? "\n" : "")
        let firstDelta = deltas[0], total = deltas.reduce(0, +)
        let start = max(first.location, selection.location + firstDelta)
        let end = max(start, NSMaxRange(selection) + total)
        return Edit(range: block, replacement: replacement, selection: NSRange(location: start, length: selection.length == 0 ? 0 : end - start))
    }

    // MARK: Inline formatting

    /// ⌘B / ⌘I / ⌘⇧X / ⌘E: wraps the selection in `marker`, or removes it when it is already there.
    /// With nothing selected it inserts an empty pair and puts the caret inside.
    static func toggleWrap(text: String, selection: NSRange, marker: String) -> Edit {
        let source = text as NSString
        let width = (marker as NSString).length
        let character = marker.utf16.first!
        func run(backFrom location: Int) -> Int {
            var count = 0
            while location - count - 1 >= 0, source.character(at: location - count - 1) == character { count += 1 }
            return count
        }
        func run(forwardFrom location: Int) -> Int {
            var count = 0
            while location + count < source.length, source.character(at: location + count) == character { count += 1 }
            return count
        }
        // `*` is italic only for a run of 1 or 3 (`***` is bold italic); the other markers need their full width.
        func present(_ count: Int) -> Bool { marker == "*" ? count % 2 == 1 : count >= width }

        let selected = source.substring(with: selection)
        let inner = selected as NSString
        if selection.length >= width * 2, selected.hasPrefix(marker), selected.hasSuffix(marker),
           present(min(run(forwardFrom: selection.location), selection.length / 2)) {
            let stripped = inner.substring(with: NSRange(location: width, length: inner.length - width * 2))
            return Edit(range: selection, replacement: stripped,
                        selection: NSRange(location: selection.location, length: (stripped as NSString).length))
        }
        let before = run(backFrom: selection.location), after = run(forwardFrom: NSMaxRange(selection))
        if present(before), present(after), selection.length > 0 || (before == width && after == width) {
            let range = NSRange(location: selection.location - width, length: selection.length + width * 2)
            return Edit(range: range, replacement: selected, selection: NSRange(location: range.location, length: selection.length))
        }
        return Edit(range: selection, replacement: marker + selected + marker,
                    selection: NSRange(location: selection.location + width, length: selection.length))
    }

    /// ⌘K: `[selection]()` with the caret in the address, or `[](url)` when the selection is an address.
    static func link(text: String, selection: NSRange) -> Edit {
        let selected = (text as NSString).substring(with: selection)
        if selected.contains("://") || selected.hasPrefix("mailto:") {
            return Edit(range: selection, replacement: "[](\(selected))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let length = (selected as NSString).length
        return Edit(range: selection, replacement: "[\(selected)]()",
                    selection: NSRange(location: selection.location + (length == 0 ? 1 : length + 3), length: 0))
    }

    /// ⌥⌘1…6 sets the heading level of the caret's line; the same level again, or 0, turns it back into a paragraph.
    static func heading(text: String, selection: NSRange, level: Int) -> Edit? {
        let source = text as NSString
        guard NSMaxRange(selection) <= source.length else { return nil }
        let lineRange = line(source, at: selection.location)
        let content = source.substring(with: lineRange)
        let match = headingPattern.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length))
        let current = match.map { $0.range(at: 1).length } ?? 0
        let oldPrefix = match?.range.length ?? 0
        let body = (content as NSString).substring(from: oldPrefix)
        let target = current == level ? 0 : level
        let newPrefix = target == 0 ? "" : String(repeating: "#", count: target) + " "
        let delta = (newPrefix as NSString).length - oldPrefix
        let caret = max(lineRange.location, selection.location + delta)
        return Edit(range: lineRange, replacement: newPrefix + body, selection: NSRange(location: caret, length: selection.length))
    }

    // MARK: Pairs

    static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`"]
    private static let wrapOnly: Set<Character> = ["*", "_", "~"]

    /// Typing an opening bracket or quote: wraps a selection, or inserts the closing half when the next character
    /// is a space, the end of the line or closing punctuation. Typing a closing half that is already next steps over it.
    static func typed(_ character: Character, text: String, selection: NSRange) -> Edit? {
        let source = text as NSString
        guard NSMaxRange(selection) <= source.length else { return nil }
        let typed = String(character)
        if selection.length > 0, let close = pairs[character] ?? (wrapOnly.contains(character) ? character : nil) {
            let selected = source.substring(with: selection)
            return Edit(range: selection, replacement: typed + selected + String(close),
                        selection: NSRange(location: selection.location + 1, length: selection.length))
        }
        guard selection.length == 0 else { return nil }
        let next: Character? = selection.location < source.length
            ? Character(source.substring(with: source.rangeOfComposedCharacterSequence(at: selection.location))) : nil
        let previous: Character? = selection.location > 0
            ? Character(source.substring(with: source.rangeOfComposedCharacterSequence(at: selection.location - 1))) : nil
        // Step over a closing half that is already there.
        if next == character, pairs.values.contains(character) {
            return Edit(range: NSRange(location: selection.location, length: 0), replacement: "",
                        selection: NSRange(location: selection.location + 1, length: 0))
        }
        guard let close = pairs[character] else { return nil }
        let nextAllows = next.map { $0.isWhitespace || ")]}>,.;:!?，。；：！？".contains($0) } ?? true
        guard nextAllows else { return nil }
        if character == "\"" || character == "`" {
            // A quote or backtick right after a word (or a second backtick of a fence) is typed as is.
            if let previous, previous.isLetter || previous.isNumber || previous == character { return nil }
        }
        return Edit(range: selection, replacement: typed + String(close), selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// Backspace between an empty pair removes both halves.
    static func deleteBackward(text: String, selection: NSRange) -> Edit? {
        let source = text as NSString
        guard selection.length == 0, selection.location > 0, selection.location < source.length else { return nil }
        let before = Character(source.substring(with: NSRange(location: selection.location - 1, length: 1)))
        let after = Character(source.substring(with: NSRange(location: selection.location, length: 1)))
        guard pairs[before] == after else { return nil }
        return Edit(range: NSRange(location: selection.location - 1, length: 2), replacement: "",
                    selection: NSRange(location: selection.location - 1, length: 0))
    }
}
