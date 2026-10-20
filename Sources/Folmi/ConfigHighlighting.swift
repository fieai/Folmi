import Foundation

/// Lexical colors for configuration and markup files: YAML, TOML, INI, .env, ignore files, Dockerfile, Makefile,
/// XML / HTML / plist, CSS and SQL. Like the code tokenizer it only tells keys, values, strings and comments apart;
/// nothing is parsed or validated. Keys use the variable color, sections / targets / selectors the type color.
extension SyntaxLanguage {
    var usesConfigScanner: Bool {
        switch self {
        case .yaml, .toml, .ini, .dotenv, .ignore, .dockerfile, .makefile, .xml, .css, .sql: return true
        default: return false
        }
    }

    /// Languages known by the file's name rather than its extension (Dockerfile, .env.local, .gitignore, ~/.zshrc …).
    static func byFileName(_ name: String) -> SyntaxLanguage? {
        let lower = name.lowercased()
        switch lower {
        case "dockerfile", "containerfile": return .dockerfile
        case "makefile", "gnumakefile", "bsdmakefile": return .makefile
        case ".gitignore", ".dockerignore", ".npmignore", ".prettierignore", ".eslintignore", ".stylelintignore",
             ".vscodeignore", ".hgignore", ".ignore", ".rgignore", ".slugignore", ".helmignore": return .ignore
        case ".editorconfig", ".gitconfig", ".gitmodules", ".npmrc", ".pylintrc", ".flake8", ".coveragerc",
             "setup.cfg", "pytest.ini", "tox.ini", ".pypirc": return .ini
        case ".bashrc", ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bash_profile", ".bash_aliases", ".profile",
             ".envrc": return .shell
        case "cargo.lock", "pipfile", "poetry.lock", "uv.lock": return .toml
        case ".babelrc", ".eslintrc", ".prettierrc", ".swcrc", ".jshintrc": return .json
        case ".env": return .dotenv
        default: break
        }
        if lower.hasPrefix(".env.") || lower.hasSuffix(".env") { return .dotenv }
        if lower.hasPrefix("dockerfile.") || lower.hasSuffix(".dockerfile") { return .dockerfile }
        return nil
    }
}

enum ConfigScanner {
    /// Tokens for `units` (already cut to the scanning limit); nil when cancelled.
    static func scan(_ units: [UInt16], language: SyntaxLanguage, maximumTokens: Int,
                     isCancelled: () -> Bool) -> (tokens: [SyntaxToken], scanned: Int, limited: Bool)? {
        let scanner = Scanner(units: units, language: language, maximumTokens: maximumTokens)
        switch language {
        case .css: guard scanner.css(isCancelled) else { return nil }
        case .sql: guard scanner.sql(isCancelled) else { return nil }
        default: guard scanner.lines(isCancelled) else { return nil }
        }
        return (scanner.tokens, scanner.scanned, scanner.limited)
    }

    private final class Scanner {
        let units: [UInt16]
        let language: SyntaxLanguage
        let maximumTokens: Int
        var tokens: [SyntaxToken] = []
        var limited = false
        var scanned = 0

        // State carried from one line to the next.
        var yamlBlockIndent = -1
        /// A quoted YAML scalar still open at the end of the previous line, and `[` / `{` not closed yet.
        var yamlQuote: UInt16 = 0
        var yamlFlowDepth = 0
        var tomlString: UInt16 = 0
        var tomlArrayDepth = 0
        var dockerContinues = false
        enum XMLState { case text, tag, comment, cdata, value(UInt16) }
        var xml = XMLState.text

        init(units: [UInt16], language: SyntaxLanguage, maximumTokens: Int) {
            self.units = units; self.language = language; self.maximumTokens = max(0, maximumTokens)
        }

        // MARK: Shared helpers

        func add(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            guard end > start else { return }
            if let last = tokens.last, NSMaxRange(last.range) > start { return }
            guard tokens.count < maximumTokens else { limited = true; return }
            tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
        }
        var full: Bool { tokens.count >= maximumTokens }

        func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 }
        func isDigit(_ u: UInt16) -> Bool { (48...57).contains(u) }
        func isLetter(_ u: UInt16) -> Bool { (65...90).contains(u) || (97...122).contains(u) || u >= 128 }
        func isIdent(_ u: UInt16) -> Bool { isLetter(u) || isDigit(u) || u == 95 }
        func skipSpaces(_ i: Int, _ end: Int) -> Int { var i = i; while i < end, isSpace(units[i]) { i += 1 }; return i }
        func trimEnd(_ start: Int, _ end: Int) -> Int { var e = end; while e > start, isSpace(units[e - 1]) { e -= 1 }; return e }
        func matches(_ text: String, at i: Int, caseInsensitive: Bool = false) -> Bool {
            var j = i
            for u in text.utf16 {
                guard j < units.count else { return false }
                var v = units[j]
                if caseInsensitive, (65...90).contains(v) { v += 32 }
                guard v == u else { return false }
                j += 1
            }
            return true
        }
        func find(_ text: String, from i: Int, to end: Int) -> Int? {
            var j = i
            while j < end { if matches(text, at: j) { return j }; j += 1 }
            return nil
        }
        func word(_ start: Int, _ end: Int) -> String { String(decoding: units[start..<end], as: UTF16.self) }

        /// A quoted string from `start` on this line; backslash escapes in double quotes (and single when `escapes`).
        func stringEnd(_ start: Int, _ end: Int, singleEscapes: Bool = false) -> Int {
            let quote = units[start]
            var j = start + 1
            while j < end {
                if units[j] == 92, quote == 34 || singleEscapes { j += 2; continue }
                if units[j] == quote {
                    // YAML and SQL write a quote inside single quotes as ''.
                    if quote == 39, j + 1 < end, units[j + 1] == 39 { j += 2; continue }
                    return j + 1
                }
                j += 1
            }
            return end
        }

        /// The whole plain value is a number: 12, -3.5, 1e9, 0x1F, 1_000, .inf.
        func isNumber(_ start: Int, _ end: Int) -> Bool {
            guard start < end else { return false }
            let text = word(start, end).lowercased()
            if [".inf", "-.inf", "+.inf", ".nan", "inf", "+inf", "-inf", "nan"].contains(text) { return true }
            var j = start
            if units[j] == 43 || units[j] == 45 { j += 1 }
            guard j < end else { return false }
            if units[j] == 48, j + 1 < end, [120, 111, 98].contains(units[j + 1]) {
                return end > j + 2 && units[(j + 2)..<end].allSatisfy { isDigit($0) || (97...102).contains($0) || (65...70).contains($0) || $0 == 95 }
            }
            var digits = 0, dot = false, exp = false
            while j < end {
                let u = units[j]
                if isDigit(u) { digits += 1 }
                else if u == 95, digits > 0 {}
                else if u == 46, !dot, !exp { dot = true }
                else if (u == 101 || u == 69), digits > 0, !exp {
                    exp = true
                    if j + 1 < end, units[j + 1] == 43 || units[j + 1] == 45 { j += 1 }
                } else { return false }
                j += 1
            }
            return digits > 0
        }

        /// A comment that starts with `marker` after a space (or at the line's start) runs to the line end.
        func commentStart(_ start: Int, _ end: Int, markers: Set<UInt16>) -> Int? {
            var j = start
            while j < end {
                let u = units[j]
                if u == 34 || u == 39 { j = stringEnd(j, end); continue }
                if markers.contains(u), j == start || isSpace(units[j - 1]) { return j }
                j += 1
            }
            return nil
        }

        // MARK: Line-based languages

        func lines(_ isCancelled: () -> Bool) -> Bool {
            var start = 0, count = 0
            while start < units.count {
                if count & 0xFF == 0, isCancelled() { return false }
                if full { limited = true; break }
                var end = start
                while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
                switch language {
                case .yaml: yamlLine(start, end)
                case .toml: tomlLine(start, end)
                case .ini: iniLine(start, end)
                case .dotenv: envLine(start, end)
                case .ignore: ignoreLine(start, end)
                case .dockerfile: dockerLine(start, end)
                case .makefile: makeLine(start, end)
                case .xml: xmlLine(start, end)
                default: break
                }
                start = end + (end + 1 < units.count && units[end] == 13 && units[end + 1] == 10 ? 2 : 1)
                count += 1
            }
            scanned = min(start, units.count)
            return true
        }

        // YAML: `key:` keys, `- ` items, scalars as a whole, `|` / `>` blocks left plain.
        func yamlLine(_ s: Int, _ e: Int) {
            if yamlQuote != 0 {
                let end = yamlQuoteEnd(s, e, quote: yamlQuote)
                add(s, end.end, .string)
                guard end.closed else { return }
                yamlQuote = 0
                yamlValue(end.end, e)
                return
            }
            if yamlFlowDepth > 0 { yamlValue(skipSpaces(s, e), e); return }
            var i = skipSpaces(s, e)
            let indent = i - s
            if yamlBlockIndent >= 0 {
                if i == e || indent > yamlBlockIndent { return }
                yamlBlockIndent = -1
            }
            guard i < e else { return }
            if units[i] == 35 { add(i, e, .comment); return }
            if i == s, matches("---", at: i) || matches("...", at: i), i + 3 == e || isSpace(units[i + 3]) {
                add(i, i + 3, .keyword); i = skipSpaces(i + 3, e)
            }
            while i < e, units[i] == 45, i + 1 == e || isSpace(units[i + 1]) { i = skipSpaces(i + 1, e) }
            if let (keyEnd, colon) = yamlKey(i, e) { add(i, keyEnd, .variable); i = colon + 1 }
            i = skipSpaces(i, e)
            guard i < e else { return }
            if units[i] == 124 || units[i] == 62 {
                var j = i + 1
                while j < e, units[j] == 45 || units[j] == 43 || isDigit(units[j]) { j += 1 }
                let after = skipSpaces(j, e)
                if after == e || units[after] == 35 {
                    add(i, j, .keyword)
                    if after < e { add(after, e, .comment) }
                    yamlBlockIndent = indent
                    return
                }
            }
            yamlValue(i, e)
        }

        func yamlKey(_ i: Int, _ e: Int) -> (Int, Int)? {
            guard i < e else { return nil }
            if units[i] == 34 || units[i] == 39 {
                let close = stringEnd(i, e)
                let colon = skipSpaces(close, e)
                guard colon < e, units[colon] == 58, colon + 1 == e || isSpace(units[colon + 1]) else { return nil }
                return (close, colon)
            }
            guard ![91, 123, 38, 42, 33, 124, 62, 37, 64, 96].contains(units[i]) else { return nil }
            var j = i
            while j < e {
                if units[j] == 58, j + 1 == e || isSpace(units[j + 1]) { return j > i ? (trimEnd(i, j), j) : nil }
                if units[j] == 35, j > i, isSpace(units[j - 1]) { return nil }
                j += 1
            }
            return nil
        }

        /// Where a quoted scalar that started before `start` (or at `start - 1`) closes on this line.
        func yamlQuoteEnd(_ start: Int, _ e: Int, quote: UInt16) -> (end: Int, closed: Bool) {
            var j = start
            while j < e {
                if units[j] == 92, quote == 34 { j += 2; continue }
                if units[j] == quote {
                    if quote == 39, j + 1 < e, units[j + 1] == 39 { j += 2; continue }
                    return (j + 1, true)
                }
                j += 1
            }
            return (e, false)
        }

        func yamlValue(_ start: Int, _ e: Int) {
            var i = start
            while i < e {
                i = skipSpaces(i, e)
                guard i < e else { return }
                let u = units[i]
                if u == 35, i == start || isSpace(units[i - 1]) { add(i, e, .comment); return }
                if u == 34 || u == 39 {
                    let end = yamlQuoteEnd(i + 1, e, quote: u)
                    add(i, end.end, .string)
                    // A quoted scalar may run on to the next lines.
                    if !end.closed { yamlQuote = u; return }
                    i = end.end; continue
                }
                if u == 38 || u == 42 || u == 33 {
                    var j = i + 1
                    while j < e, !isSpace(units[j]), ![44, 93, 125].contains(units[j]) { j += 1 }
                    add(i, j, .type); i = j; continue
                }
                if u == 91 || u == 123 { yamlFlowDepth += 1; i += 1; continue }
                if u == 93 || u == 125 { yamlFlowDepth = max(0, yamlFlowDepth - 1); i += 1; continue }
                if u == 44 { i += 1; continue }
                // A plain scalar runs to a flow delimiter (inside [ ] / { }, which may span lines), " #" or the line end.
                let inFlow = yamlFlowDepth > 0
                var j = i
                while j < e {
                    if units[j] == 35, j > i, isSpace(units[j - 1]) { break }
                    if inFlow, [44, 93, 125].contains(units[j]) { break }
                    if inFlow, units[j] == 58, j + 1 == e || isSpace(units[j + 1]) { break }
                    j += 1
                }
                let end = trimEnd(i, j)
                if inFlow, j < e, units[j] == 58 { add(i, end, .variable); i = j + 1; continue }
                let text = word(i, end).lowercased()
                if ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(text) { add(i, end, .literal) }
                else if isNumber(i, end) { add(i, end, .number) }
                i = max(j, i + 1)
            }
        }

        // TOML: [tables], keys before `=`, strings including """ blocks, numbers and dates, arrays over lines.
        func tomlLine(_ s: Int, _ e: Int) {
            var i = s
            if tomlString != 0 {
                if let j = tripleClose(from: s, to: e, quote: tomlString) { add(s, j + 3, .string); i = j + 3; tomlString = 0 }
                else { add(s, e, .string); return }
            }
            i = skipSpaces(i, e)
            guard i < e else { return }
            if units[i] == 35 { add(i, e, .comment); return }
            if tomlArrayDepth == 0, i == skipSpaces(s, e) {
                if units[i] == 91 {
                    var j = i
                    while j < e, units[j] != 93 { j += 1 }
                    while j < e, units[j] == 93 { j += 1 }
                    add(i, j, .type)
                    i = j
                } else if let (keyEnd, equals) = tomlKey(i, e) {
                    add(i, keyEnd, .variable); i = equals + 1
                }
            }
            tomlValue(i, e)
        }

        /// The closing `"""` / `'''` on this line; in a basic (double-quoted) string `\"` does not close it.
        func tripleClose(from start: Int, to e: Int, quote: UInt16) -> Int? {
            var j = start
            while j + 2 < e {
                if quote == 34, units[j] == 92 { j += 2; continue }
                if units[j] == quote, units[j + 1] == quote, units[j + 2] == quote {
                    // A quote or two right before the closing three belong to the string (""""x""""").
                    var k = j + 3
                    while k < e, units[k] == quote, k - j < 5 { k += 1 }
                    return k - 3
                }
                j += 1
            }
            return nil
        }

        func tomlKey(_ i: Int, _ e: Int) -> (Int, Int)? {
            var j = i
            while j < e {
                let u = units[j]
                if u == 34 || u == 39 { j = stringEnd(j, e) }
                else if isIdent(u) || u == 45 || u == 46 || isSpace(u) { j += 1 }
                else if u == 61 { return j > i ? (trimEnd(i, j), j) : nil }
                else { return nil }
            }
            return nil
        }

        func tomlValue(_ start: Int, _ e: Int) {
            var i = start
            while i < e {
                let u = units[i]
                if u == 35 { add(i, e, .comment); return }
                if u == 34 || u == 39 {
                    if matches(String(decoding: [u, u, u], as: UTF16.self), at: i) {
                        if let j = tripleClose(from: i + 3, to: e, quote: u) { add(i, j + 3, .string); i = j + 3 }
                        else { add(i, e, .string); tomlString = u; return }
                    } else { let end = stringEnd(i, e, singleEscapes: false); add(i, end, .string); i = end }
                    continue
                }
                if u == 91 { tomlArrayDepth += 1; i += 1; continue }
                if u == 93 { tomlArrayDepth = max(0, tomlArrayDepth - 1); i += 1; continue }
                if u == 123 || u == 44 {
                    // Keys of an inline table: { name = "x", version = 1 }.
                    let k = skipSpaces(i + 1, e)
                    if let (keyEnd, equals) = tomlKey(k, e) { add(k, keyEnd, .variable); i = equals + 1 } else { i += 1 }
                    continue
                }
                if isIdent(u) || u == 43 || u == 45 || u == 46 {
                    var j = i
                    while j < e, isIdent(units[j]) || [43, 45, 46, 58].contains(units[j]) { j += 1 }
                    // A date-time may have one space between date and time.
                    let text = word(i, j)
                    if ["true", "false"].contains(text) { add(i, j, .literal) }
                    else if isDigit(u) || ((u == 43 || u == 45) && j > i + 1 && isDigit(units[i + 1])) || ["inf", "nan", "+inf", "-inf", "+nan", "-nan"].contains(text) {
                        add(i, j, .number)
                    }
                    i = j
                    continue
                }
                i += 1
            }
        }

        // INI, .editorconfig, .gitconfig, .npmrc, setup.cfg: [section], key = value, ; and # comments.
        func iniLine(_ s: Int, _ e: Int) {
            var i = skipSpaces(s, e)
            guard i < e else { return }
            if units[i] == 59 || units[i] == 35 { add(i, e, .comment); return }
            if units[i] == 91 {
                var j = i
                while j < e, units[j] != 93 { if units[j] == 34 { j = stringEnd(j, e) } else { j += 1 } }
                if j < e { j += 1 }
                add(i, j, .type)
                if let c = commentStart(j, e, markers: [59, 35]) { add(c, e, .comment) }
                return
            }
            var j = i
            while j < e, units[j] != 61, units[j] != 58 { j += 1 }
            guard j < e else { return }
            add(i, trimEnd(i, j), .variable)
            i = skipSpaces(j + 1, e)
            let comment = commentStart(i, e, markers: [59, 35])
            let valueEnd = trimEnd(i, comment ?? e)
            if i < valueEnd {
                if units[i] == 34 || units[i] == 39 { add(i, stringEnd(i, valueEnd), .string) }
                else if ["true", "false", "yes", "no", "on", "off", "none", "null"].contains(word(i, valueEnd).lowercased()) { add(i, valueEnd, .literal) }
                else if isNumber(i, valueEnd) { add(i, valueEnd, .number) }
            }
            if let comment { add(comment, e, .comment) }
        }

        // .env: KEY=value, `export`, quoted values, ${VAR} references, # comments.
        func envLine(_ s: Int, _ e: Int) {
            var i = skipSpaces(s, e)
            guard i < e else { return }
            if units[i] == 35 { add(i, e, .comment); return }
            if matches("export", at: i), i + 6 < e, isSpace(units[i + 6]) { add(i, i + 6, .keyword); i = skipSpaces(i + 6, e) }
            var j = i
            while j < e, isIdent(units[j]) || units[j] == 46 || units[j] == 45 { j += 1 }
            let k = skipSpaces(j, e)
            guard j > i, k < e, units[k] == 61 else { return }
            add(i, j, .variable)
            i = skipSpaces(k + 1, e)
            if i < e, units[i] == 34 || units[i] == 39 || units[i] == 96 {
                let end = stringEnd(i, e)
                add(i, end, .string)
                if let c = commentStart(end, e, markers: [35]) { add(c, e, .comment) }
                return
            }
            dollarReferences(i, e, comment: true, quotes: true)
        }

        /// `$NAME`, `${NAME}` and (for Makefiles) `$(NAME)` / `$@` as variables; `#` after a space (or anywhere, as
        /// Make reads it outside recipes) as a comment; quoted strings when `quotes`.
        func dollarReferences(_ start: Int, _ e: Int, comment: Bool, anywhereComment: Bool = false, quotes: Bool,
                              make: Bool = false) {
            var i = start
            while i < e {
                let u = units[i]
                if comment, u == 35, anywhereComment || i == start || isSpace(units[i - 1]) { add(i, e, .comment); return }
                if u == 34 || u == 39, quotes { let end = stringEnd(i, e); add(i, end, .string); i = end; continue }
                if u == 36, i + 1 < e {
                    let next = units[i + 1]
                    if next == 123 || (make && next == 40) {
                        let close: UInt16 = next == 123 ? 125 : 41
                        var depth = 0, j = i + 1
                        while j < e {
                            if units[j] == next { depth += 1 } else if units[j] == close { depth -= 1; if depth == 0 { j += 1; break } }
                            j += 1
                        }
                        add(i, j, .variable); i = j; continue
                    }
                    if isIdent(next) { var j = i + 1; while j < e, isIdent(units[j]) { j += 1 }; add(i, j, .variable); i = j; continue }
                    if make, [64, 60, 94, 42, 63, 43, 37].contains(next) { add(i, i + 2, .variable); i += 2; continue }
                }
                i += 1
            }
        }

        // .gitignore and friends: comments and `!` negations.
        func ignoreLine(_ s: Int, _ e: Int) {
            guard s < e else { return }
            if units[s] == 35 { add(s, e, .comment) }
            else if units[s] == 33 { add(s, s + 1, .keyword) }
        }

        // Dockerfile: instructions, `AS` stages, --flags, strings and $VARs; `\` continues a line.
        static let dockerInstructions: Set<String> = ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD",
            "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL"]
        func dockerLine(_ s: Int, _ e: Int) {
            var i = skipSpaces(s, e)
            guard i < e else { return }
            if units[i] == 35 { add(i, e, .comment); return }
            let continued = dockerContinues
            let last = trimEnd(s, e)
            dockerContinues = last > s && units[last - 1] == 92
            var from = false
            if !continued {
                var j = i
                while j < e, isLetter(units[j]) { j += 1 }
                let instruction = word(i, j).uppercased()
                if Self.dockerInstructions.contains(instruction) { add(i, j, .keyword); i = j; from = instruction == "FROM" }
            }
            dockerArguments(i, e, stages: from)
        }

        func dockerArguments(_ start: Int, _ e: Int, stages: Bool) {
            var i = start
            while i < e {
                i = skipSpaces(i, e)
                guard i < e else { return }
                if matches("--", at: i), i == start || isSpace(units[i - 1]) {
                    var j = i + 2
                    while j < e, isIdent(units[j]) || units[j] == 45 { j += 1 }
                    add(i, j, .type); i = j; continue
                }
                var j = i
                while j < e, !isSpace(units[j]) {
                    if units[j] == 34 || units[j] == 39 { j = stringEnd(j, e) } else { j += 1 }
                }
                if stages, word(i, j).lowercased() == "as" { add(i, j, .keyword) }
                else { dollarReferences(i, j, comment: false, quotes: true) }
                i = j
            }
        }

        // Makefile: targets, variable assignments, directives, $(…) references; tab-indented recipe lines.
        static let makeDirectives: Set<String> = ["include", "-include", "sinclude", "ifeq", "ifneq", "ifdef", "ifndef",
            "else", "endif", "define", "endef", "export", "unexport", "override", "vpath", "private"]
        func makeLine(_ s: Int, _ e: Int) {
            guard s < e else { return }
            if units[s] == 9 { dollarReferences(s + 1, e, comment: true, quotes: true, make: true); return }
            var i = skipSpaces(s, e)
            guard i < e else { return }
            if units[i] == 35 { add(i, e, .comment); return }
            var j = i
            while j < e, !isSpace(units[j]), units[j] != 58, units[j] != 61 { j += 1 }
            let first = word(i, j)
            if Self.makeDirectives.contains(first) {
                add(i, j, .keyword)
                if first != "export" && first != "override" && first != "private" { dollarReferences(j, e, comment: true, anywhereComment: true, quotes: false, make: true); return }
                i = skipSpaces(j, e)
            }
            // The first `=` / `:=` / `?=` / `+=` / `!=` makes an assignment; a lone `:` makes a rule.
            var k = i
            while k < e {
                let u = units[k]
                if u == 36, k + 1 < e, units[k + 1] == 40 || units[k + 1] == 123 {
                    let close: UInt16 = units[k + 1] == 40 ? 41 : 125
                    while k < e, units[k] != close { k += 1 }
                    k += 1; continue
                }
                if u == 61 || (u == 58 && k + 1 < e && units[k + 1] == 61) || (u == 58 && matches("::=", at: k)) {
                    var nameEnd = k
                    while nameEnd > i, [58, 63, 43, 33].contains(units[nameEnd - 1]) { nameEnd -= 1 }
                    add(i, trimEnd(i, nameEnd), .variable)
                    var valueStart = k
                    while valueStart < e, units[valueStart] == 58 || units[valueStart] == 61 { valueStart += 1 }
                    dollarReferences(valueStart, e, comment: true, anywhereComment: true, quotes: false, make: true)
                    return
                }
                if u == 58 {
                    let names = trimEnd(i, k)
                    add(i, names, word(i, names).hasPrefix(".") && word(i, names).uppercased() == word(i, names) ? .keyword : .type)
                    var rest = k + 1
                    if rest < e, units[rest] == 58 { rest += 1 }
                    dollarReferences(rest, e, comment: true, anywhereComment: true, quotes: false, make: true)
                    return
                }
                if u == 35 { break }
                k += 1
            }
            dollarReferences(i, e, comment: true, anywhereComment: true, quotes: false, make: true)
        }

        // XML, HTML, plist, SVG source: tag names, attributes and their values, comments, CDATA and entities.
        func xmlLine(_ s: Int, _ e: Int) {
            var i = s
            while i < e {
                switch xml {
                case .comment:
                    if let j = find("-->", from: i, to: e) { add(i, j + 3, .comment); i = j + 3; xml = .text }
                    else { add(i, e, .comment); return }
                case .cdata:
                    if let j = find("]]>", from: i, to: e) { add(i, j + 3, .string); i = j + 3; xml = .text }
                    else { add(i, e, .string); return }
                case .value(let quote):
                    var j = i
                    while j < e, units[j] != quote { j += 1 }
                    if j < e { add(i, j + 1, .string); i = j + 1; xml = .tag } else { add(i, e, .string); return }
                case .tag:
                    i = skipSpaces(i, e)
                    guard i < e else { return }
                    let u = units[i]
                    if u == 62 { i += 1; xml = .text }
                    else if (u == 47 || u == 63), i + 1 < e, units[i + 1] == 62 { i += 2; xml = .text }
                    else if u == 34 || u == 39 {
                        var j = i + 1
                        while j < e, units[j] != u { j += 1 }
                        if j < e { add(i, j + 1, .string); i = j + 1 } else { add(i, e, .string); xml = .value(u); return }
                    }
                    else if u == 61 || u == 47 || u == 63 { i += 1 }
                    else {
                        var j = i
                        while j < e, !isSpace(units[j]), ![61, 62, 47, 34, 39].contains(units[j]) { j += 1 }
                        add(i, j, .variable); i = max(j, i + 1)
                    }
                case .text:
                    var j = i
                    while j < e, units[j] != 60, units[j] != 38 { j += 1 }
                    guard j < e else { return }
                    i = j
                    if units[i] == 38 {
                        var k = i + 1
                        while k < e, k - i < 12, isIdent(units[k]) || units[k] == 35 { k += 1 }
                        if k < e, units[k] == 59, k > i + 1 { add(i, k + 1, .literal); i = k + 1 } else { i += 1 }
                    } else if matches("<!--", at: i) {
                        if let close = find("-->", from: i + 4, to: e) { add(i, close + 3, .comment); i = close + 3 }
                        else { add(i, e, .comment); xml = .comment; return }
                    } else if matches("<![CDATA[", at: i) {
                        if let close = find("]]>", from: i + 9, to: e) { add(i, close + 3, .string); i = close + 3 }
                        else { add(i, e, .string); xml = .cdata; return }
                    } else {
                        var k = i + 1
                        let declaration = k < e && (units[k] == 63 || units[k] == 33)
                        if k < e, units[k] == 47 || declaration { k += 1 }
                        let nameStart = k
                        while k < e, isIdent(units[k]) || [45, 46, 58].contains(units[k]) { k += 1 }
                        // `a < b` in script text is not a tag.
                        if k > nameStart { add(declaration ? i : nameStart, k, .keyword); xml = .tag }
                        i = max(k, i + 1)
                    }
                }
            }
        }

        // MARK: Whole-text languages

        /// CSS, SCSS, Less: selectors before `{`, `property:` names, @rules, numbers with units, #colors, $ / -- variables.
        func css(_ isCancelled: () -> Bool) -> Bool {
            var i = 0
            var statementStart = true
            while i < units.count {
                if i & 0x3FF == 0, isCancelled() { return false }
                if full { limited = true; break }
                let u = units[i]
                if matches("/*", at: i) {
                    let end = find("*/", from: i + 2, to: units.count).map { $0 + 2 } ?? units.count
                    add(i, end, .comment); i = end; continue
                }
                if matches("//", at: i), i == 0 || isSpace(units[i - 1]) || units[i - 1] == 10 || units[i - 1] == 13 || units[i - 1] == 59 {
                    var j = i; while j < units.count, units[j] != 10, units[j] != 13 { j += 1 }
                    add(i, j, .comment); i = j; continue
                }
                if u == 34 || u == 39 { let end = stringEnd(i, lineEnd(i)); add(i, end, .string); i = end; continue }
                if u == 123 || u == 125 || u == 59 { statementStart = true; i += 1; continue }
                if isSpace(u) || u == 10 || u == 13 { i += 1; continue }
                if u == 64 {
                    var j = i + 1; while j < units.count, isIdent(units[j]) || units[j] == 45 { j += 1 }
                    add(i, j, .keyword); i = j; statementStart = false; continue
                }
                if statementStart {
                    statementStart = false
                    // Look ahead: `{` first means a selector, otherwise a declaration.
                    var j = i
                    while j < units.count, ![59, 123, 125].contains(units[j]) {
                        if units[j] == 34 || units[j] == 39 { j = stringEnd(j, lineEnd(j)) }
                        else if matches("/*", at: j) { break }
                        else { j += 1 }
                    }
                    if j < units.count, units[j] == 123 {
                        add(i, trimEnd(i, trimNewlines(i, j)), .type); i = j; continue
                    }
                    var k = i
                    while k < j, isIdent(units[k]) || units[k] == 45 || units[k] == 36 || units[k] == 42 { k += 1 }
                    let colon = skipSpaces(k, j)
                    if k > i, colon < j, units[colon] == 58 { add(i, k, .variable); i = colon + 1; continue }
                }
                if u == 35, i + 1 < units.count, isHex(units[i + 1]) {
                    var j = i + 1; while j < units.count, isHex(units[j]) { j += 1 }
                    add(i, j, .number); i = j; continue
                }
                // Words take their digits with them (h1, grid-2), so a digit here starts a number: 12px, -1.5em, .5, 50%.
                let startsNumber = isDigit(u) || ((u == 46 || u == 45) && i + 1 < units.count && (isDigit(units[i + 1]) ||
                    (units[i + 1] == 46 && i + 2 < units.count && isDigit(units[i + 2]))))
                if startsNumber {
                    var j = i + 1
                    while j < units.count, isDigit(units[j]) || units[j] == 46 { j += 1 }
                    while j < units.count, isLetter(units[j]) || units[j] == 37 { j += 1 }
                    add(i, j, .number); i = j; continue
                }
                if u == 36 || (u == 45 && i + 1 < units.count && units[i + 1] == 45) {
                    var j = i + 1; while j < units.count, isIdent(units[j]) || units[j] == 45 { j += 1 }
                    add(i, j, .variable); i = j; continue
                }
                if u == 33, matches("!important", at: i, caseInsensitive: true) { add(i, i + 10, .keyword); i += 10; continue }
                if isIdent(u) || u == 45 {
                    var j = i; while j < units.count, isIdent(units[j]) || units[j] == 45 { j += 1 }
                    i = j; continue
                }
                i += 1
            }
            scanned = min(i, units.count)
            return true
        }

        func isHex(_ u: UInt16) -> Bool { isDigit(u) || (97...102).contains(u) || (65...70).contains(u) }
        func lineEnd(_ i: Int) -> Int { var j = i; while j < units.count, units[j] != 10, units[j] != 13 { j += 1 }; return j }
        func trimNewlines(_ start: Int, _ end: Int) -> Int {
            var e = end
            while e > start, isSpace(units[e - 1]) || units[e - 1] == 10 || units[e - 1] == 13 { e -= 1 }
            return e
        }

        static let sqlKeywords: Set<String> = Set(("select from where and or not insert into values update set delete create table " +
            "drop alter add column index view primary key foreign references unique default constraint check join inner left " +
            "right outer full cross on as distinct group by order having limit offset union all exists in between like ilike " +
            "is case when then else end begin commit rollback transaction returning with recursive if replace temporary temp " +
            "database schema grant revoke asc desc cascade trigger function procedure declare return returns language " +
            "using natural over partition window fetch next rows only conflict do nothing upsert merge truncate explain " +
            "analyze vacuum pragma autoincrement auto_increment collate")
            .split(separator: " ").map(String.init))
        static let sqlTypes: Set<String> = Set(("int integer bigint smallint tinyint serial bigserial decimal numeric real " +
            "float double precision varchar char character text blob boolean bool date time timestamp timestamptz interval " +
            "uuid json jsonb bytea money").split(separator: " ").map(String.init))

        func sql(_ isCancelled: () -> Bool) -> Bool {
            var i = 0
            while i < units.count {
                if i & 0x3FF == 0, isCancelled() { return false }
                if full { limited = true; break }
                let u = units[i]
                if matches("--", at: i) { let j = lineEnd(i); add(i, j, .comment); i = j; continue }
                if matches("/*", at: i) {
                    let end = find("*/", from: i + 2, to: units.count).map { $0 + 2 } ?? units.count
                    add(i, end, .comment); i = end; continue
                }
                if u == 39 {
                    // Single-quoted strings may span lines; '' is a quote inside.
                    var j = i + 1
                    while j < units.count {
                        if units[j] == 39 { if j + 1 < units.count, units[j + 1] == 39 { j += 2; continue }; j += 1; break }
                        j += 1
                    }
                    add(i, min(j, units.count), .string); i = min(j, units.count); continue
                }
                if u == 34 || u == 96 { let end = stringEnd(i, lineEnd(i)); add(i, end, .variable); i = end; continue }
                if (u == 64 || u == 58) && i + 1 < units.count && isLetter(units[i + 1]) && (i == 0 || units[i - 1] != 58) {
                    var j = i + 1; while j < units.count, isIdent(units[j]) { j += 1 }
                    add(i, j, .variable); i = j; continue
                }
                if isDigit(u), i == 0 || !isIdent(units[i - 1]) {
                    var j = i; while j < units.count, isDigit(units[j]) || units[j] == 46 { j += 1 }
                    if j < units.count, isIdent(units[j]) { while j < units.count, isIdent(units[j]) { j += 1 }; i = j; continue }
                    add(i, j, .number); i = j; continue
                }
                if isLetter(u) || u == 95 {
                    var j = i; while j < units.count, isIdent(units[j]) { j += 1 }
                    let text = word(i, j).lowercased()
                    if Self.sqlKeywords.contains(text) { add(i, j, .keyword) }
                    else if Self.sqlTypes.contains(text) { add(i, j, .type) }
                    else if ["null", "true", "false"].contains(text) { add(i, j, .literal) }
                    i = j; continue
                }
                i += 1
            }
            scanned = min(i, units.count)
            return true
        }
    }
}
