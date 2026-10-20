import Foundation
import AppKit

/// A deliberately small lexical highlighter. It does not provide parsing, LSP or semantic diagnostics.
enum SyntaxLanguage: String, Sendable, CaseIterable {
    case javascript, typescript, python, swift, json, shell
    case yaml, toml, ini, dotenv, ignore, dockerfile, makefile, xml, css, sql
    case plainText

    init(path: String) {
        if let named = Self.byFileName((path as NSString).lastPathComponent) { self = named; return }
        switch (path as NSString).pathExtension.lowercased() {
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "py", "pyi", "pyw": self = .python
        case "swift": self = .swift
        case "json", "jsonc", "json5", "webmanifest", "code-workspace": self = .json
        case "sh", "bash", "zsh", "command": self = .shell
        case "yml", "yaml": self = .yaml
        case "toml": self = .toml
        case "ini", "cfg", "conf", "properties": self = .ini
        case "mk", "mak": self = .makefile
        case "xml", "plist", "html", "htm", "xhtml", "svg", "xib", "storyboard", "xsd", "xsl", "xslt", "csproj",
             "entitlements", "resx", "vue": self = .xml
        case "css", "scss", "sass", "less": self = .css
        case "sql": self = .sql
        default: self = .plainText
        }
    }

    var title: String {
        switch self {
        case .javascript: return "JavaScript / JSX"
        case .typescript: return "TypeScript / TSX"
        case .python: return "Python"
        case .swift: return "Swift"
        case .json: return "JSON"
        case .shell: return "Shell"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .ini: return "INI / 配置"
        case .dotenv: return "环境变量（.env）"
        case .ignore: return "忽略规则"
        case .dockerfile: return "Dockerfile"
        case .makefile: return "Makefile"
        case .xml: return "XML / HTML"
        case .css: return "CSS"
        case .sql: return "SQL"
        case .plainText: return "纯文本"
        }
    }
}

enum SyntaxTokenKind: Sendable, Equatable {
    case keyword, string, number, comment, literal, type, variable
}

struct SyntaxToken: Sendable, Equatable {
    let range: NSRange
    let kind: SyntaxTokenKind
}

struct SyntaxHighlightResult: Sendable {
    let tokens: [SyntaxToken]
    let scannedUTF16Count: Int
    let isLimited: Bool
}

enum SyntaxTokenizer {
    // Bound both scanning and AppKit attribute work even for a 2 MiB editable document.
    static let maximumUTF16Count = 192 * 1_024
    static let maximumTokens = 16_000

    static func tokenize(_ text: String, language: SyntaxLanguage,
                         maximumUTF16Count: Int = maximumUTF16Count,
                         maximumTokens: Int = maximumTokens,
                         isCancelled: () -> Bool = { false }) -> SyntaxHighlightResult? {
        guard language != .plainText else {
            return SyntaxHighlightResult(tokens: [], scannedUTF16Count: 0, isLimited: false)
        }
        guard !isCancelled() else { return nil }
        let limit = max(0, maximumUTF16Count)
        // This never materializes the rest of a large file as a UTF-16 array.
        var units = Array(text.utf16.prefix(limit + 1))
        var isLimited = units.count > limit
        if isLimited { units.removeLast() }
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        if language.usesConfigScanner {
            guard let scan = ConfigScanner.scan(units, language: language, maximumTokens: maximumTokens, isCancelled: isCancelled),
                  !isCancelled() else { return nil }
            return SyntaxHighlightResult(tokens: scan.tokens, scannedUTF16Count: scan.scanned, isLimited: isLimited || scan.limited)
        }
        var tokens: [SyntaxToken] = []
        var i = 0
        let words = keywordSets[language] ?? []
        let literalWords = literals[language] ?? []
        let types = typeWords[language] ?? []
        let supportsSlashComments = [.javascript, .typescript, .swift, .json].contains(language)
        let supportsHashComments = language == .python || language == .shell

        func matches(_ values: [UInt16], at position: Int) -> Bool {
            guard position + values.count <= units.count else { return false }
            return values.indices.allSatisfy { units[position + $0] == values[$0] }
        }
        func token(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            if end > start { tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        func stringEnd(at start: Int, quote: UInt16, triple: Bool) -> Int {
            var cursor = start + (triple ? 3 : 1)
            while cursor < units.count {
                if cursor & 0x3FF == 0, isCancelled() { return cursor }
                if units[cursor] == 92 { cursor = min(units.count, cursor + 2); continue }
                if triple {
                    if matches([quote, quote, quote], at: cursor) { return cursor + 3 }
                } else if units[cursor] == quote { return cursor + 1 }
                // Backtick strings and triple quotes may span lines; ordinary quotes may not.
                if !triple, quote != 96, units[cursor] == 10 || units[cursor] == 13 { return cursor }
                cursor += 1
            }
            return units.count
        }

        while i < units.count {
            if i & 0x3FF == 0, isCancelled() { return nil }
            if tokens.count >= max(0, maximumTokens) { isLimited = true; break }
            let start = i
            let unit = units[i]
            if supportsSlashComments, matches([47, 47], at: i) {
                i += 2
                while i < units.count, units[i] != 10, units[i] != 13 {
                    if i & 0x3FF == 0, isCancelled() { return nil }
                    i += 1
                }
                token(start, i, .comment)
            } else if supportsSlashComments, matches([47, 42], at: i) {
                i += 2
                var depth = 1
                while i < units.count, depth > 0 {
                    if i & 0x3FF == 0, isCancelled() { return nil }
                    if language == .swift, matches([47, 42], at: i) { depth += 1; i += 2 }
                    else if matches([42, 47], at: i) { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                token(start, i, .comment)
            } else if supportsHashComments, unit == 35 {
                while i < units.count, units[i] != 10, units[i] != 13 {
                    if i & 0x3FF == 0, isCancelled() { return nil }
                    i += 1
                }
                token(start, i, .comment)
            } else if unit == 34 || (unit == 39 && language != .json) ||
                        (unit == 96 && (language == .javascript || language == .typescript || language == .shell)) {
                let triple = (language == .python || language == .swift) && matches([unit, unit, unit], at: i)
                i = stringEnd(at: i, quote: unit, triple: triple)
                token(start, i, .string)
            } else if language == .python, let quotePosition = pythonPrefixQuote(in: units, at: i) {
                let quote = units[quotePosition]
                i = stringEnd(at: quotePosition, quote: quote, triple: matches([quote, quote, quote], at: quotePosition))
                token(start, i, .string)
            } else if isDigit(unit) || (unit == 46 && i + 1 < units.count && isDigit(units[i + 1])) {
                i = numberEnd(in: units, at: i)
                token(start, i, .number)
            } else if language == .shell, unit == 36 {
                i += 1
                if i < units.count, units[i] == 123 {
                    i += 1
                    while i < units.count, units[i] != 125, units[i] != 10 { i += 1 }
                    if i < units.count, units[i] == 125 { i += 1 }
                } else {
                    while i < units.count, isIdentifierPart(units[i]) { i += 1 }
                }
                token(start, i, .variable)
            } else if isIdentifierStart(unit) {
                i += 1
                while i < units.count, isIdentifierPart(units[i]) { i += 1 }
                let word = String(decoding: units[start..<i], as: UTF16.self)
                if words.contains(word) { token(start, i, .keyword) }
                else if literalWords.contains(word) { token(start, i, .literal) }
                else if types.contains(word) { token(start, i, .type) }
            } else { i += 1 }
        }
        guard !isCancelled() else { return nil }
        return SyntaxHighlightResult(tokens: tokens, scannedUTF16Count: i, isLimited: isLimited)
    }

    private static func isDigit(_ value: UInt16) -> Bool { (48...57).contains(value) }
    private static func isIdentifierStart(_ value: UInt16) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || value == 95 || value == 36 || value >= 128
    }
    private static func isIdentifierPart(_ value: UInt16) -> Bool { isIdentifierStart(value) || isDigit(value) }
    private static func pythonPrefixQuote(in units: [UInt16], at position: Int) -> Int? {
        guard position == 0 || !isIdentifierPart(units[position - 1]) else { return nil }
        let prefixes: Set<String> = ["r", "u", "b", "f", "br", "rb", "fr", "rf"]
        for length in 1...2 where position + length < units.count {
            let next = units[position + length]
            if next == 34 || next == 39 {
                let prefix = String(decoding: units[position..<(position + length)], as: UTF16.self).lowercased()
                if prefixes.contains(prefix) { return position + length }
            }
        }
        return nil
    }
    private static func numberEnd(in units: [UInt16], at position: Int) -> Int {
        var cursor = position
        if units[cursor] == 48, cursor + 1 < units.count, [98, 66, 111, 79, 120, 88].contains(units[cursor + 1]) {
            cursor += 2
            while cursor < units.count, isDigit(units[cursor]) || (65...70).contains(units[cursor]) || (97...102).contains(units[cursor]) || units[cursor] == 95 { cursor += 1 }
            return cursor
        }
        while cursor < units.count, isDigit(units[cursor]) || units[cursor] == 95 { cursor += 1 }
        if cursor < units.count, units[cursor] == 46 {
            cursor += 1
            while cursor < units.count, isDigit(units[cursor]) || units[cursor] == 95 { cursor += 1 }
        }
        if cursor < units.count, units[cursor] == 101 || units[cursor] == 69 {
            cursor += 1
            if cursor < units.count, units[cursor] == 43 || units[cursor] == 45 { cursor += 1 }
            while cursor < units.count, isDigit(units[cursor]) || units[cursor] == 95 { cursor += 1 }
        }
        return cursor
    }

    private static let keywordSets: [SyntaxLanguage: Set<String>] = [
        .javascript: Set("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch throw try typeof var void while with yield".split(separator: " ").map(String.init)),
        .typescript: Set("abstract as asserts async await break case catch class const constructor continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let module namespace new of override private protected public readonly require return satisfies set static super switch throw try type typeof unique var void while with yield".split(separator: " ").map(String.init)),
        .python: Set("and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try type while with yield".split(separator: " ").map(String.init)),
        .swift: Set("actor any as associatedtype async await borrowing break case catch class consuming continue convenience default defer deinit didSet distributed do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public rethrows required return self Self set some static struct subscript super switch throws throw try typealias unowned var weak where while willSet".split(separator: " ").map(String.init)),
        .shell: Set("if then else elif fi case esac for select while until do done in function time coproc export local readonly declare typeset return break continue".split(separator: " ").map(String.init))
    ]
    private static let literals: [SyntaxLanguage: Set<String>] = [
        .javascript: ["true", "false", "null", "undefined", "this", "NaN", "Infinity"],
        .typescript: ["true", "false", "null", "undefined", "this", "NaN", "Infinity"],
        .python: ["True", "False", "None", "NotImplemented", "Ellipsis"],
        .swift: ["true", "false", "nil"], .json: ["true", "false", "null"]
    ]
    private static let typeWords: [SyntaxLanguage: Set<String>] = [
        .typescript: ["boolean", "number", "string", "unknown", "never", "any", "object", "symbol", "bigint"],
        .python: ["bool", "bytes", "dict", "float", "int", "list", "object", "set", "str", "tuple"],
        .swift: ["Bool", "Data", "Date", "Double", "Float", "Int", "String", "UInt", "URL", "Void"]
    ]
}

@MainActor
enum SyntaxHighlightApplier {
    /// Attribute-only changes bypass text editing, delegate dirty notifications and the undo stack.
    static func apply(_ result: SyntaxHighlightResult, to editor: NSTextView, presentation: EditorPresentation? = nil, effectiveDark: Bool = false) {
        guard let storage = editor.textStorage, !editor.hasMarkedText() else { return }
        let selectedRanges = editor.selectedRanges
        let undo = editor.undoManager
        undo?.disableUndoRegistration()
        defer { undo?.enableUndoRegistration() }
        let palette = presentation.map { EditorPalette(presentation: $0, effectiveDark: effectiveDark) }
        let foreground = palette?.foreground ?? NSColor.textColor
        storage.beginEditing()
        let all = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: foreground, range: all)
        if let presentation {
            // Leaving Markdown preview resets every presentation attribute without changing the source.
            storage.setAttributes([.font: presentation.font(), .foregroundColor: foreground, .paragraphStyle: presentation.paragraphStyle()], range: all)
        }
        for token in result.tokens where token.range.location >= 0 && NSMaxRange(token.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind, palette: palette), range: token.range)
        }
        storage.endEditing()
        editor.typingAttributes[.foregroundColor] = foreground
        // AppKit normally preserves these for an attribute edit; keep multi-selections explicit.
        if editor.selectedRanges != selectedRanges { editor.selectedRanges = selectedRanges }
    }

    static func color(for kind: SyntaxTokenKind, palette: EditorPalette? = nil) -> NSColor {
        if let palette {
            switch kind {
            case .keyword: return palette.keyword
            case .string: return palette.string
            case .number, .literal: return palette.number
            case .comment: return palette.comment
            case .type: return palette.type
            case .variable: return palette.variable
            }
        }
        // Keep the semantic default for callers that do not choose an editor presentation.
        switch kind {
        case .keyword: return .systemPurple
        case .string: return .systemRed
        case .number, .literal: return .systemOrange
        case .comment: return .secondaryLabelColor
        case .type: return .systemTeal
        case .variable: return .systemBlue
        }
    }
}

/// One instance per native editor. Scanning occurs off the main actor; stale results never apply.
@MainActor
final class EditorSyntaxHighlighter {
    weak var editor: NSTextView?
    var onStatus: ((String) -> Void)?
    var presentation: EditorPresentation?
    var effectiveDark = false
    private var pending: Task<Void, Never>?
    private var scanning: Task<SyntaxHighlightResult?, Never>?
    private var revision: UInt64 = 0

    func schedule(language: SyntaxLanguage, immediately: Bool = false) {
        cancel()
        let expectedRevision = revision
        report(language == .plainText ? "等待刷新" : "等待高亮", revision: expectedRevision)
        pending = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(nanoseconds: 230_000_000) } catch { return }
            }
            guard let self else { return }
            while let editor = self.editor, editor.hasMarkedText() {
                self.report("输入法组合中", revision: expectedRevision)
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
            guard !Task.isCancelled, self.revision == expectedRevision, let editor = self.editor else { return }
            let snapshot = editor.string
            let work = Task.detached(priority: .userInitiated) {
                Perf.measure("Syntax tokenize") { SyntaxTokenizer.tokenize(snapshot, language: language, isCancelled: { Task.isCancelled }) }
            }
            self.scanning = work
            let result = await work.value
            guard !Task.isCancelled, self.revision == expectedRevision,
                  let result, let editor = self.editor, editor.string == snapshot, !editor.hasMarkedText() else { return }
            Perf.measure("Syntax apply") {
                SyntaxHighlightApplier.apply(result, to: editor, presentation: self.presentation, effectiveDark: self.effectiveDark)
            }
            self.scanning = nil
            let status = language == .plainText ? "无高亮" : (result.isLimited ? "部分词法高亮 · 有界预览" : "词法高亮")
            self.report(status, revision: expectedRevision)
        }
    }

    func cancel() {
        revision &+= 1
        pending?.cancel()
        scanning?.cancel()
        pending = nil
        scanning = nil
    }

    private func report(_ status: String, revision expectedRevision: UInt64) {
        // NSViewRepresentable updates must not synchronously mutate SwiftUI state.
        Task { @MainActor [weak self] in
            guard let self, self.revision == expectedRevision else { return }
            self.onStatus?(status)
        }
    }
}
