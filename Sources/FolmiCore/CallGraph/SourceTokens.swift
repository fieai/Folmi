import Foundation

/// The languages the call map reads. JavaScript covers TypeScript, JSX and TSX: the call map needs names and
/// brackets, not types.
public enum SourceLanguage: Sendable, Equatable {
    case javaScript, python

    public static func of(path: String) -> SourceLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "vue", "svelte": return .javaScript
        case "py", "pyi": return .python
        default: return nil
        }
    }
}

struct SourceToken: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case identifier, string, punct, number }
    let kind: Kind
    /// Identifiers and punctuation as written; a string's contents without its quotes.
    let text: String
    /// 1-based.
    let line: Int
    /// Bytes from the start of the line; only compared within one file (Python indentation).
    let column: Int
    let firstOnLine: Bool

    func `is`(_ punct: String) -> Bool { kind == .punct && text == punct }
    var isIdentifier: Bool { kind == .identifier }
}

/// Splits source into identifiers, strings and punctuation, dropping comments, so a name inside a comment or a string
/// is never taken for a call. Not a full lexer: regex literals and JSX text are guessed, and a guess that goes wrong
/// only costs the rest of that line (quotes never run past a newline in JavaScript).
enum SourceLexer {
    static func tokens(_ data: Data, language: SourceLanguage) -> [SourceToken] {
        let bytes = [UInt8](data)
        var lexer = Lexer(bytes: bytes, python: language == .python)
        lexer.run()
        return lexer.tokens
    }

    private struct Lexer {
        let bytes: [UInt8]
        let python: Bool
        var tokens: [SourceToken] = []
        var i = 0
        var line = 1
        var lineStart = 0
        var lastLineWithToken = 0
        /// `{` that open a template's `${`: their `}` goes back to the template instead of being a token.
        var braces: [Bool] = []

        init(bytes: [UInt8], python: Bool) { self.bytes = bytes; self.python = python }

        static func isIdentifierStart(_ c: UInt8) -> Bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c == 36 || c >= 0x80 }
        static func isIdentifierPart(_ c: UInt8) -> Bool { isIdentifierStart(c) || (c >= 48 && c <= 57) }

        mutating func emit(_ kind: SourceToken.Kind, _ text: String, at start: Int, line startLine: Int, column: Int) {
            tokens.append(SourceToken(kind: kind, text: text, line: startLine, column: column, firstOnLine: lastLineWithToken != startLine))
            // A string that spans lines ends on the current one: what follows its closing quote is not first.
            lastLineWithToken = line
        }

        mutating func newline() { line += 1; lineStart = i + 1 }

        func text(_ from: Int, _ to: Int) -> String { String(decoding: bytes[from..<to], as: UTF8.self) }

        /// Whether a `/` here starts a regex literal rather than dividing.
        var regexAllowed: Bool {
            guard let last = tokens.last else { return true }
            switch last.kind {
            case .identifier: return ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "yield", "await"].contains(last.text)
            case .number, .string: return false
            case .punct: return ![")", "]", "}"].contains(last.text)
            }
        }

        mutating func run() {
            while i < bytes.count {
                let c = bytes[i]
                if c == 10 { newline(); i += 1; continue }
                if c == 32 || c == 9 || c == 13 || c == 12 { i += 1; continue }
                if python && c == 35 { skipToLineEnd(); continue }
                if !python && c == 47 && i + 1 < bytes.count {
                    if bytes[i + 1] == 47 { skipToLineEnd(); continue }
                    if bytes[i + 1] == 42 { skipBlockComment(); continue }
                    if regexAllowed { skipRegex(); continue }
                }
                let column = i - lineStart, startLine = line
                if Self.isIdentifierStart(c) {
                    let start = i
                    while i < bytes.count, Self.isIdentifierPart(bytes[i]) { i += 1 }
                    // r"..", b'..', f"..", rb"..": a Python string prefix.
                    if python, i - start <= 2, i < bytes.count, bytes[i] == 34 || bytes[i] == 39,
                       bytes[start..<i].allSatisfy({ "rRbBuUfF".utf8.contains($0) }) {
                        pythonString(column: column); continue
                    }
                    emit(.identifier, text(start, i), at: start, line: startLine, column: column)
                    continue
                }
                if c >= 48 && c <= 57 {
                    let start = i
                    while i < bytes.count, Self.isIdentifierPart(bytes[i]) || bytes[i] == 46 { i += 1 }
                    emit(.number, text(start, i), at: start, line: startLine, column: column)
                    continue
                }
                if c == 34 || c == 39 {
                    if python { pythonString(column: column) } else { quoted(c, column: column) }
                    continue
                }
                if !python && c == 96 { i += 1; template(column: column, line: startLine); continue }
                if !python && c == 123 { braces.append(false) }
                if !python && c == 125, let template = braces.popLast(), template {
                    i += 1; self.template(column: column, line: startLine); continue
                }
                // The few two- and three-character operators the parsers look at.
                if c == 61, next(1) == 62 { emit(.punct, "=>", at: i, line: startLine, column: column); i += 2; continue }
                if c == 63, next(1) == 46, !(next(2).map { $0 >= 48 && $0 <= 57 } ?? false) {
                    emit(.punct, "?.", at: i, line: startLine, column: column); i += 2; continue
                }
                if c == 46, next(1) == 46, next(2) == 46 { emit(.punct, "...", at: i, line: startLine, column: column); i += 3; continue }
                emit(.punct, String(UnicodeScalar(c)), at: i, line: startLine, column: column)
                i += 1
            }
        }

        func next(_ offset: Int) -> UInt8? { i + offset < bytes.count ? bytes[i + offset] : nil }

        mutating func skipToLineEnd() { while i < bytes.count, bytes[i] != 10 { i += 1 } }

        mutating func skipBlockComment() {
            i += 2
            while i < bytes.count {
                if bytes[i] == 42, next(1) == 47 { i += 2; return }
                if bytes[i] == 10 { newline() }
                i += 1
            }
        }

        mutating func skipRegex() {
            i += 1
            var inClass = false
            while i < bytes.count, bytes[i] != 10 {
                let c = bytes[i]
                if c == 92 { i += 2; continue }
                if c == 91 { inClass = true } else if c == 93 { inClass = false }
                else if c == 47 && !inClass { i += 1; break }
                i += 1
            }
            while i < bytes.count, Self.isIdentifierPart(bytes[i]) { i += 1 }
            // Stands in for the literal, so what follows reads as after a value.
            emit(.string, "", at: i, line: line, column: i - lineStart)
        }

        /// A JavaScript '…' or "…" string; never past the end of its line.
        mutating func quoted(_ quote: UInt8, column: Int) {
            let startLine = line
            i += 1
            let start = i
            while i < bytes.count, bytes[i] != quote, bytes[i] != 10 {
                if bytes[i] == 92 { i += 1 }
                i += 1
            }
            let end = min(i, bytes.count)
            if i < bytes.count, bytes[i] == quote { i += 1 }
            emit(.string, text(start, end), at: start, line: startLine, column: column)
        }

        /// The rest of a template literal, until its closing backtick or the next `${`.
        mutating func template(column: Int, line startLine: Int) {
            let start = i
            while i < bytes.count {
                let c = bytes[i]
                if c == 92 { i += 2; continue }
                if c == 96 { emit(.string, text(start, i), at: start, line: startLine, column: column); i += 1; return }
                if c == 36, next(1) == 123 {
                    emit(.string, text(start, i), at: start, line: startLine, column: column)
                    i += 2; braces.append(true); return
                }
                if c == 10 { newline() }
                i += 1
            }
            emit(.string, text(start, min(i, bytes.count)), at: start, line: startLine, column: column)
        }

        mutating func pythonString(column: Int) {
            let startLine = line
            while i < bytes.count, bytes[i] != 34, bytes[i] != 39 { i += 1 }
            guard i < bytes.count else { return }
            let quote = bytes[i]
            let triple = next(1) == quote && next(2) == quote
            i += triple ? 3 : 1
            let start = i
            while i < bytes.count {
                let c = bytes[i]
                if c == 92 { if next(1) == 10 { i += 1; newline() }; i += 2; continue }
                if c == quote && (!triple || (next(1) == quote && next(2) == quote)) { break }
                if c == 10 { if !triple { break }; newline() }
                i += 1
            }
            let end = min(i, bytes.count)
            if i < bytes.count, bytes[i] == quote { i += triple ? 3 : 1 }
            emit(.string, text(start, end), at: start, line: startLine, column: column)
        }
    }
}
