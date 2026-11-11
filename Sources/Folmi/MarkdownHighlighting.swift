import Foundation

/// Lexical colors for Markdown source: headings, emphasis, code, links, list and quote marks, the syntax characters
/// themselves dimmed. Fenced code and YAML front matter are colored by the code tokenizer in their own language.
/// Like the other scanners nothing is parsed into a tree: rules are line by line, and inline spans close on their
/// own line. Unlike them, tokens may nest (a link inside bold text): style-only kinds (`.strong`, `.emphasis`,
/// `.strikethrough`) and `.heading` cover a span whose parts carry their own colors. Tokens come out sorted by
/// location, an enclosing token before the ones inside it.
enum MarkdownScanner {
    static func scan(_ units: [UInt16], maximumTokens: Int,
                     isCancelled: () -> Bool) -> (tokens: [SyntaxToken], scanned: Int, limited: Bool)? {
        let scanner = Scanner(units: units, maximumTokens: max(0, maximumTokens))
        guard scanner.run(isCancelled) else { return nil }
        let tokens = scanner.tokens.enumerated().sorted {
            if $0.element.range.location != $1.element.range.location { return $0.element.range.location < $1.element.range.location }
            if $0.element.range.length != $1.element.range.length { return $0.element.range.length > $1.element.range.length }
            return $0.offset < $1.offset
        }.map(\.element)
        return (tokens, scanner.scanned, scanner.limited)
    }

    private final class Scanner {
        let units: [UInt16]
        let maximumTokens: Int
        var tokens: [SyntaxToken] = []
        var limited = false
        var scanned = 0

        /// An open code fence: its character, run length, language and where its code starts.
        var fence: (char: UInt16, length: Int, language: String, bodyStart: Int)?
        /// Front matter still open: where its YAML starts.
        var frontMatter: Int?
        var inHTMLComment = false

        init(units: [UInt16], maximumTokens: Int) { self.units = units; self.maximumTokens = maximumTokens }

        var full: Bool { tokens.count >= maximumTokens }
        func add(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            guard end > start else { return }
            guard tokens.count < maximumTokens else { limited = true; return }
            tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
        }

        // MARK: Lines

        func run(_ isCancelled: () -> Bool) -> Bool {
            var start = 0
            var lineNumber = 0
            while start < units.count {
                if lineNumber & 0x3F == 0, isCancelled() { return false }
                if full { limited = true; break }
                var end = start
                while end < units.count, units[end] != 10 { end += 1 }
                let next = min(units.count, end + 1)
                if end > start, units[end - 1] == 13 { end -= 1 }
                line(start, end, number: lineNumber, isCancelled)
                scanned = next
                start = next
                lineNumber += 1
            }
            // A fence or front matter still open at the end colors what it has.
            if let fence { embedded(fence.bodyStart, units.count, language: fence.language, isCancelled) }
            if let frontMatter { embedded(frontMatter, units.count, language: "yaml", isCancelled) }
            return !isCancelled()
        }

        func line(_ start: Int, _ end: Int, number: Int, _ isCancelled: () -> Bool) {
            if let open = frontMatter {
                if isRun(start, end, of: 45, exactly: 3) || isRun(start, end, of: 46, exactly: 3) {
                    embedded(open, start, language: "yaml", isCancelled)
                    add(start, end, .markup)
                    frontMatter = nil
                }
                return
            }
            if number == 0, isRun(start, end, of: 45, exactly: 3) {
                add(start, end, .markup)
                frontMatter = end + (end < units.count && units[end] == 13 ? 2 : 1)
                return
            }
            if let open = fence {
                let first = skipSpaces(start, end)
                let runEnd = run(from: first, end, of: open.char)
                if indentation(start, end) <= 3, runEnd - first >= open.length, skipSpaces(runEnd, end) == end {
                    embedded(open.bodyStart, start, language: open.language, isCancelled)
                    add(start, end, .markup)
                    fence = nil
                }
                return
            }
            if inHTMLComment {
                if let close = find([45, 45, 62], from: start, to: end) {
                    add(start, close + 3, .comment)
                    inHTMLComment = false
                    inline(close + 3, end, table: false)
                } else { add(start, end, .comment) }
                return
            }

            let indent = indentation(start, end)
            var i = skipSpaces(start, end)
            guard i < end else { return }
            if indent <= 3 {
                // ``` or ~~~ opens a fence; its info string's first word names the language.
                let char = units[i]
                if char == 96 || char == 126 {
                    let runEnd = run(from: i, end, of: char)
                    let info = skipSpaces(runEnd, end)
                    if runEnd - i >= 3, !(char == 96 && find([96], from: runEnd, to: end) != nil) {
                        var wordEnd = info
                        while wordEnd < end, units[wordEnd] != 32, units[wordEnd] != 9, units[wordEnd] != 123 { wordEnd += 1 }
                        let language = String(decoding: units[info..<wordEnd], as: UTF16.self)
                        add(start, end, .markup)
                        fence = (char, runEnd - i, language, end + (end < units.count && units[end] == 13 ? 2 : 1))
                        return
                    }
                }
                // `$$` on its own line: TeX until the next one.
                if isRun(i, trimEnd(i, end), of: 36, exactly: 2) {
                    add(start, end, .markup)
                    fence = (36, 2, "", end + (end < units.count && units[end] == 13 ? 2 : 1))
                    return
                }
                // # Heading: the marks dimmed, the title bold in the heading color.
                let hashes = run(from: i, end, of: 35)
                if (1...6).contains(hashes - i), hashes == end || units[hashes] == 32 || units[hashes] == 9 {
                    add(i, min(end, hashes + 1), .markup)
                    let title = skipSpaces(hashes, end)
                    let titleEnd = closingHashes(title, end)
                    add(title, titleEnd, .heading)
                    inline(title, titleEnd, table: false)
                    add(titleEnd, end, .markup)
                    return
                }
                // ---, ***, ___ rules and the === / --- under a setext heading.
                if isRule(i, end) || isRun(i, trimEnd(i, end), of: 61) {
                    add(i, end, .markup)
                    return
                }
                // [ref]: https://… link definitions.
                if units[i] == 91, let close = find([93, 58], from: i + 1, to: end) {
                    add(i, close + 2, .markup)
                    let target = skipSpaces(close + 2, end)
                    var targetEnd = target
                    while targetEnd < end, units[targetEnd] != 32, units[targetEnd] != 9 { targetEnd += 1 }
                    add(target, targetEnd, .link)
                    if targetEnd < end { add(targetEnd, end, .string) }
                    return
                }
            }

            // Block prefixes: quote marks, then a list marker and a task box.
            while i < end, units[i] == 62 {
                add(i, i + 1, .markup)
                i = skipSpaces(i + 1, end)
            }
            if let markerEnd = listMarker(at: i, end) {
                add(i, markerEnd, .listMarker)
                i = skipSpaces(markerEnd, end)
                if i + 2 < end, units[i] == 91, units[i + 2] == 93, [32, 120, 88, 47, 45].contains(units[i + 1]),
                   i + 3 == end || units[i + 3] == 32 {
                    add(i, i + 3, .listMarker)
                    i = skipSpaces(i + 3, end)
                }
            }
            let trimmed = trimEnd(i, end)
            if trimmed > i, units[i] == 124 || isTableDelimiter(i, trimmed) {
                if isTableDelimiter(i, trimmed) { add(i, trimmed, .markup); return }
                inline(i, end, table: true)
                return
            }
            inline(i, end, table: false)
        }

        /// Code or YAML between `start` and `end`, colored in its own language.
        func embedded(_ start: Int, _ end: Int, language name: String, _ isCancelled: () -> Bool) {
            guard end > start, !full else { return }
            let language = MarkdownCodeHighlight.language(name)
            guard language != .plainText, language != .markdown else {
                if name.isEmpty, fence?.char == 36 { add(start, end, .code) }
                return
            }
            let text = String(decoding: units[start..<end], as: UTF16.self)
            guard let result = SyntaxTokenizer.tokenize(text, language: language, maximumTokens: maximumTokens - tokens.count,
                                                        isCancelled: isCancelled) else { return }
            for token in result.tokens {
                add(start + token.range.location, start + NSMaxRange(token.range), token.kind)
            }
            if result.isLimited { limited = true }
        }

        // MARK: Inline

        /// Code spans, emphasis, links, autolinks, wiki links, HTML tags and comments between `start` and `end`.
        /// `table` dims the pipes between cells.
        func inline(_ start: Int, _ end: Int, table: Bool) {
            var i = start
            while i < end {
                if full { return }
                let u = units[i]
                switch u {
                case 92: // A backslash escape keeps the next character literal.
                    if i + 1 < end, isPunctuation(units[i + 1]) { add(i, i + 1, .markup); i += 2 } else { i += 1 }
                case 96:
                    let runEnd = run(from: i, end, of: 96)
                    guard let close = closingBackticks(runEnd, end, length: runEnd - i) else { i = runEnd; continue }
                    add(i, runEnd, .markup)
                    add(runEnd, close, .code)
                    add(close, close + (runEnd - i), .markup)
                    i = close + (runEnd - i)
                case 42, 95, 126:
                    i = emphasis(at: i, start: start, end)
                case 33 where i + 1 < end && units[i + 1] == 91:
                    i = link(at: i + 1, opener: i, end)
                case 91:
                    if i + 1 < end, units[i + 1] == 91, let close = find([93, 93], from: i + 2, to: end) {
                        add(i, i + 2, .markup)
                        add(i + 2, close, .link)
                        add(close, close + 2, .markup)
                        i = close + 2
                    } else { i = link(at: i, opener: i, end) }
                case 60:
                    i = angle(at: i, end)
                case 104 where (i == start || !isWordPart(units[i - 1])) && (matches("https://", at: i) || matches("http://", at: i)):
                    var urlEnd = i
                    while urlEnd < end, units[urlEnd] != 32, units[urlEnd] != 9, units[urlEnd] != 60, units[urlEnd] < 0x3000 { urlEnd += 1 }
                    // Closing punctuation after an address belongs to the sentence.
                    while urlEnd > i, [46, 44, 59, 58, 33, 63, 41, 93, 34, 39].contains(units[urlEnd - 1]) { urlEnd -= 1 }
                    add(i, urlEnd, .link)
                    i = max(i + 1, urlEnd)
                case 124 where table:
                    add(i, i + 1, .markup); i += 1
                case 36:
                    i = math(at: i, end)
                default:
                    i += 1
                }
            }
        }

        /// `*em*`, `**strong**`, `***both***`, the same with `_`, and `~~struck~~`. The delimiters are dimmed; the
        /// text between them keeps its own inline marks. Returns where scanning goes on.
        func emphasis(at i: Int, start: Int, _ end: Int) -> Int {
            let char = units[i]
            let runEnd = run(from: i, end, of: char)
            let length = runEnd - i
            if char == 126, length != 2 { return runEnd }
            guard length <= 3, runEnd < end, !isSpace(units[runEnd]) else { return runEnd }
            // `_` inside a word (snake_case) is no emphasis.
            if char == 95, i > start, isWordPart(units[i - 1]) { return runEnd }
            var j = runEnd + 1
            while j < end {
                if units[j] == 92 { j += 2; continue }
                if units[j] == 96 {
                    // Delimiters inside a code span do not close.
                    let tickEnd = run(from: j, end, of: 96)
                    if let close = closingBackticks(tickEnd, end, length: tickEnd - j) { j = close + (tickEnd - j); continue }
                    j = tickEnd; continue
                }
                if units[j] == char {
                    let closeEnd = run(from: j, end, of: char)
                    let closes = closeEnd - j == length && !isSpace(units[j - 1]) &&
                        !(char == 95 && closeEnd < end && isWordPart(units[closeEnd]))
                    if closes {
                        add(i, runEnd, .markup)
                        if char == 126 { add(runEnd, j, .strikethrough) }
                        if char != 126, length >= 2 { add(runEnd, j, .strong) }
                        if char != 126, length != 2 { add(runEnd, j, .emphasis) }
                        inline(runEnd, j, table: false)
                        add(j, closeEnd, .markup)
                        return closeEnd
                    }
                    j = closeEnd; continue
                }
                j += 1
            }
            return runEnd
        }

        /// `[text](target)`, `[text][ref]` or, with `opener` on the `!`, an image. Returns where scanning goes on.
        func link(at open: Int, opener: Int, _ end: Int) -> Int {
            var depth = 0
            var j = open
            var close: Int?
            while j < end {
                if units[j] == 92 { j += 2; continue }
                if units[j] == 91 { depth += 1 } else if units[j] == 93 { depth -= 1; if depth == 0 { close = j; break } }
                j += 1
            }
            guard let close, close + 1 < end else { return open + 1 }
            let after = units[close + 1]
            if after == 40 {
                var parens = 0
                var k = close + 1
                while k < end {
                    if units[k] == 40 { parens += 1 } else if units[k] == 41 { parens -= 1; if parens == 0 { break } }
                    k += 1
                }
                guard k < end else { return open + 1 }
                add(opener, open + 1, .markup)
                inline(open + 1, close, table: false)
                add(close, close + 2, .markup)
                // The address, then a title in quotes after it.
                var target = skipSpaces(close + 2, k)
                if target < k, units[target] == 60, let gt = find([62], from: target, to: k) {
                    add(target, target + 1, .markup); add(target + 1, gt, .link); add(gt, gt + 1, .markup); target = gt + 1
                } else {
                    var targetEnd = target
                    while targetEnd < k, units[targetEnd] != 32 { targetEnd += 1 }
                    add(target, targetEnd, .link); target = targetEnd
                }
                let title = skipSpaces(target, k)
                if title < k { add(title, k, .string) }
                add(k, k + 1, .markup)
                return k + 1
            }
            if after == 91, let refClose = find([93], from: close + 2, to: end) {
                add(opener, open + 1, .markup)
                inline(open + 1, close, table: false)
                add(close, refClose + 1, .markup)
                return refClose + 1
            }
            return open + 1
        }

        /// `<https://…>` autolinks, `<!-- comments -->` and HTML tags.
        func angle(at i: Int, _ end: Int) -> Int {
            if matches("<!--", at: i) {
                if let close = find([45, 45, 62], from: i + 4, to: end) { add(i, close + 3, .comment); return close + 3 }
                add(i, end, .comment)
                inHTMLComment = true
                return end
            }
            guard let close = find([62], from: i + 1, to: end), close > i + 1 else { return i + 1 }
            let inner = i + 1
            if matches("http://", at: inner) || matches("https://", at: inner) || matches("mailto:", at: inner) {
                add(i, i + 1, .markup); add(inner, close, .link); add(close, close + 1, .markup)
                return close + 1
            }
            let first = units[inner] == 47 ? inner + 1 : inner
            guard first < close, isLetter(units[first]), find([60], from: inner, to: close) == nil else { return i + 1 }
            add(i, close + 1, .markup)
            return close + 1
        }

        /// `$…$` inline math, pandoc's rule: no space inside either dollar, and no digit right after the closing one.
        func math(at i: Int, _ end: Int) -> Int {
            let length = i + 1 < end && units[i + 1] == 36 ? 2 : 1
            let content = i + length
            guard content < end, !isSpace(units[content]) else { return content }
            var j = content
            while j < end {
                if units[j] == 92 { j += 2; continue }
                if units[j] == 36 {
                    let closes = length == 2 ? (j + 1 < end && units[j + 1] == 36) : !isSpace(units[j - 1]) && !(j + 1 < end && isDigit(units[j + 1]))
                    if closes, j > content {
                        add(i, content, .markup); add(content, j, .code); add(j, j + length, .markup)
                        return j + length
                    }
                    if length == 1 { return content }
                }
                j += 1
            }
            return content
        }

        // MARK: Helpers

        func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 }
        func isDigit(_ u: UInt16) -> Bool { (48...57).contains(u) }
        func isLetter(_ u: UInt16) -> Bool { (65...90).contains(u) || (97...122).contains(u) }
        func isWordPart(_ u: UInt16) -> Bool { isLetter(u) || isDigit(u) || u >= 128 }
        func isPunctuation(_ u: UInt16) -> Bool {
            (33...47).contains(u) || (58...64).contains(u) || (91...96).contains(u) || (123...126).contains(u)
        }
        /// Leading indentation in columns, a tab counting to the next multiple of 4.
        func indentation(_ start: Int, _ end: Int) -> Int {
            var columns = 0, i = start
            while i < end, isSpace(units[i]) { columns += units[i] == 9 ? 4 - columns % 4 : 1; i += 1 }
            return columns
        }
        func skipSpaces(_ i: Int, _ end: Int) -> Int { var i = i; while i < end, isSpace(units[i]) { i += 1 }; return i }
        func trimEnd(_ start: Int, _ end: Int) -> Int { var e = end; while e > start, isSpace(units[e - 1]) { e -= 1 }; return e }
        func run(from i: Int, _ end: Int, of u: UInt16) -> Int { var j = i; while j < end, units[j] == u { j += 1 }; return j }
        /// The whole of `start..<end` is `u` repeated (`exactly` times when given), spaces after it allowed.
        func isRun(_ start: Int, _ end: Int, of u: UInt16, exactly count: Int? = nil) -> Bool {
            let runEnd = run(from: start, end, of: u)
            guard runEnd > start, skipSpaces(runEnd, end) == end else { return false }
            return count.map { runEnd - start == $0 } ?? true
        }
        func matches(_ text: String, at i: Int) -> Bool {
            var j = i
            for u in text.utf16 { guard j < units.count, units[j] == u else { return false }; j += 1 }
            return true
        }
        func find(_ pattern: [UInt16], from i: Int, to end: Int) -> Int? {
            var j = i
            while j + pattern.count <= end {
                if pattern.indices.allSatisfy({ units[j + $0] == pattern[$0] }) { return j }
                j += 1
            }
            return nil
        }
        /// The start of the next run of exactly `length` backticks.
        func closingBackticks(_ from: Int, _ end: Int, length: Int) -> Int? {
            var j = from
            while j < end {
                if units[j] == 96 {
                    let runEnd = run(from: j, end, of: 96)
                    if runEnd - j == length { return j }
                    j = runEnd
                } else { j += 1 }
            }
            return nil
        }
        /// A heading's optional closing `#` run, when a space separates it: the title ends before it.
        func closingHashes(_ start: Int, _ end: Int) -> Int {
            let trimmed = trimEnd(start, end)
            var j = trimmed
            while j > start, units[j - 1] == 35 { j -= 1 }
            guard j < trimmed, j == start || isSpace(units[j - 1]) else { return trimmed }
            return trimEnd(start, j)
        }
        /// `---`, `***` or `___`, spaces allowed between.
        func isRule(_ start: Int, _ end: Int) -> Bool {
            let char = units[start]
            guard char == 45 || char == 42 || char == 95 else { return false }
            var count = 0
            for j in start..<end {
                if units[j] == char { count += 1 } else if !isSpace(units[j]) { return false }
            }
            return count >= 3
        }
        /// `-`, `*`, `+` or a number with `.` / `)`, followed by a space or the end of the line.
        func listMarker(at i: Int, _ end: Int) -> Int? {
            guard i < end else { return nil }
            var j = i
            if [45, 42, 43].contains(units[j]) { j += 1 } else {
                while j < end, j - i < 9, isDigit(units[j]) { j += 1 }
                guard j > i, j < end, units[j] == 46 || units[j] == 41 else { return nil }
                j += 1
            }
            return j == end || isSpace(units[j]) ? j : nil
        }
        /// A table's `| --- | :-: |` row.
        func isTableDelimiter(_ start: Int, _ end: Int) -> Bool {
            var dashes = 0, pipes = 0
            for j in start..<end {
                switch units[j] {
                case 45: dashes += 1
                case 124: pipes += 1
                case 58, 32, 9: break
                default: return false
                }
            }
            return dashes >= 3 && pipes >= 1
        }
    }
}
