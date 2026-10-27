import Foundation

/// A function, method or class the call map can center on. `module` stands for a file's top level: calls made
/// outside any function (route tables, `app.get('/x', handler)`, scripts) come from there.
public struct CodeSymbol: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case function, method, `class`, module }
    public let path: String
    public let name: String
    /// The class (or object literal) a method sits in.
    public let container: String?
    public let kind: Kind
    /// 1-based line of the name.
    public let line: Int
    public let endLine: Int
    public var qualifiedName: String { container.map { $0 + "." + name } ?? name }
    public var id: String { "\(path)#\(qualifiedName)@\(line)" }
    public var fileName: String { (path as NSString).lastPathComponent }
}

/// A function's parameter list, as far as calls can be checked against it.
public struct CodeParameters: Sendable, Equatable {
    public struct Parameter: Sendable, Equatable {
        public let name: String
        /// Has a default (`x = 1`, `x=None`) or is marked optional (`x?: T`).
        public let optional: Bool
    }
    public var positional: [Parameter] = []
    /// `...args` / `*args`: any number of positional arguments more.
    public var rest = false
    /// Python parameters after `*` or `*args`: only by name.
    public var keywordOnly: [Parameter] = []
    /// `**kwargs`: any keyword.
    public var keywords = false
    var python = false
    /// A Python method's first parameter was `self`: called on the class itself (`Base.__init__(self, x)`), the
    /// first argument fills it.
    var takesSelf = false

    /// The list as a reader would write it: `(id, opts?)`, `(id, *, force=…, **kw)`.
    public var text: String {
        var parts: [String] = positional.map { python ? ($0.optional ? $0.name + "=…" : $0.name) : ($0.optional ? $0.name + "?" : $0.name) }
        if rest { parts.append(python ? "*args" : "...rest") } else if python, !keywordOnly.isEmpty { parts.append("*") }
        parts += keywordOnly.map { $0.optional ? $0.name + "=…" : $0.name }
        if keywords { parts.append("**kwargs") }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    /// Why a call with these arguments no longer fits; nil when it does or cannot be told (a spread `...args`).
    func problem(with call: CallArguments) -> String? {
        guard !call.spread else { return nil }
        // `Class.method(x)` on a method without `self` (a staticmethod) cannot be told apart.
        if call.unbound, !takesSelf { return nil }
        var covered = Set(call.keywords)
        if !python {
            let required = (positional.lastIndex { !$0.optional }).map { $0 + 1 } ?? 0
            if call.positional < required { return "少了 \(required - call.positional) 个参数（\(positional[call.positional..<required].map(\.name).joined(separator: "、"))）" }
            if !rest, call.positional > positional.count { return "多了 \(call.positional - positional.count) 个参数" }
            return nil
        }
        if !rest, call.positional > positional.count { return "多了 \(call.positional - positional.count) 个参数" }
        let names = Set(positional.map(\.name) + keywordOnly.map(\.name))
        if !keywords, let unknown = call.keywords.first(where: { !names.contains($0) }) { return "没有叫 \(unknown) 的参数" }
        for parameter in positional.prefix(call.positional) { covered.insert(parameter.name) }
        let missing = (positional + keywordOnly).filter { !$0.optional && !covered.contains($0.name) }.map(\.name)
        if !missing.isEmpty { return "少了参数 \(missing.joined(separator: "、"))" }
        return nil
    }

    /// The same list for checking calls: names and what they require, without how the text was written.
    var shape: [String] {
        positional.map { "p:\($0.name):\($0.optional)" } + (rest ? ["rest"] : []) + keywordOnly.map { "k:\($0.name):\($0.optional)" } + (keywords ? ["kw"] : [])
    }
}

/// What a call passes: positional arguments, keyword names (Python), and whether a spread hides the count.
struct CallArguments: Sendable, Equatable {
    var positional = 0
    var keywords: [String] = []
    var spread = false
    /// Called on the class (`Base.method(self, …)`): the first argument filled `self` and was taken off `positional`.
    var unbound = false
}

/// What one file declares, imports, exports and calls, before any name is resolved across files.
struct FileOutline: Sendable {
    struct Definition: Sendable {
        var symbol: CodeSymbol
        /// Token range of the body (inclusive), used to tell which definition a call sits in.
        var body: ClosedRange<Int>
        /// `extends Base` / `class C(Base)`, as written.
        var bases: [[String]] = []
        var parameters: CodeParameters? = nil
    }
    enum Imported: Sendable, Equatable {
        /// `import x from` / `export default`.
        case `default`
        /// `import * as ns`, `const ns = require()`, Python `import a.b as ns`.
        case namespace
        case named(String)
    }
    struct Import: Sendable { let local: String; let module: String; let imported: Imported }
    struct Export: Sendable {
        let exported: String
        /// The local name it stands for; nil with `from` and `star`.
        let local: String?
        let from: String?
        /// `export * from` (nil `exported`-like: exported is "*") or `export * as ns from`.
        let star: Bool
    }
    /// `const h = foo`, `const svc = new Service()`, `h = utils.helper`: a second name for something.
    /// `token`: where it is declared, so a name declared in two functions resolves to the one around a use.
    struct Alias: Sendable { let local: String; let target: [String]; let constructed: Bool; let token: Int }
    enum UseKind: String, Sendable { case call, render, reference }
    struct Use: Sendable {
        let chain: [String]
        let line: Int
        let token: Int
        let kind: UseKind
        var arguments: CallArguments? = nil
    }

    var path: String
    var language: SourceLanguage
    var definitions: [Definition] = []
    var imports: [Import] = []
    var exports: [Export] = []
    var aliases: [Alias] = []
    var uses: [Use] = []
    /// `this.svc: OrderService`, `self.repo = Repo()`: member types per class name.
    var memberTypes: [String: [String: [String]]] = [:]
    /// `from x import *`.
    var starImports: [String] = []
    var lineCount: Int = 0

    /// The innermost definition whose body holds token `index`; nil at the top level.
    func enclosing(_ index: Int, excluding: Int? = nil) -> Int? {
        var best: Int?
        for (offset, definition) in definitions.enumerated() where definition.body.contains(index) && offset != excluding {
            if let current = best, definitions[current].body.lowerBound > definition.body.lowerBound { continue }
            best = offset
        }
        return best
    }

    /// `enclosing` for every use, in one sweep over the uses in token order (bodies nest).
    func enclosingDefinitions() -> [Int?] {
        let order = definitions.indices.sorted { definitions[$0].body.lowerBound < definitions[$1].body.lowerBound }
        var open: [Int] = []
        var next = 0
        var result = [Int?](repeating: nil, count: uses.count)
        for index in uses.indices.sorted(by: { uses[$0].token < uses[$1].token }) {
            let token = uses[index].token
            while next < order.count, definitions[order[next]].body.lowerBound <= token { open.append(order[next]); next += 1 }
            while let last = open.last, !definitions[last].body.contains(token) { open.removeLast() }
            result[index] = open.last
        }
        return result
    }

    /// The class a definition belongs to (itself when it is one), for `this` / `self`.
    func owningClass(of index: Int?) -> Int? {
        guard let index else { return nil }
        if definitions[index].symbol.kind == .class { return index }
        let start = definitions[index].body.lowerBound
        var best: Int?
        for (offset, definition) in definitions.enumerated() where definition.symbol.kind == .class && definition.body.contains(start) {
            if let current = best, definitions[current].body.lowerBound > definition.body.lowerBound { continue }
            best = offset
        }
        return best
    }
}

extension FileOutline {
    static func read(path: String, data: Data) -> FileOutline? {
        guard let language = SourceLanguage.of(path: path) else { return nil }
        let tokens = SourceLexer.tokens(data, language: language)
        var outline: FileOutline
        switch language {
        case .javaScript:
            let ext = (path as NSString).pathExtension.lowercased()
            var outliner = JavaScriptOutliner(tokens: tokens, path: path, jsx: ["jsx", "tsx", "js", "vue"].contains(ext))
            outline = outliner.read()
        case .python:
            var outliner = PythonOutliner(tokens: tokens, path: path)
            outline = outliner.read()
        }
        outline.lineCount = (tokens.last?.line ?? 0)
        return outline
    }
}

/// Keywords that look like a call when followed by `(`.
enum SourceKeywords {
    static let javaScript: Set<String> = ["if", "for", "while", "switch", "catch", "function", "return", "typeof", "instanceof", "in", "of",
                                          "do", "else", "try", "finally", "with", "await", "yield", "void", "delete", "throw", "case",
                                          "import", "export", "class", "extends", "const", "let", "var", "new", "super", "this", "async",
                                          "static", "get", "set", "constructor", "default", "from", "as", "type", "interface", "enum",
                                          "declare", "namespace", "module", "keyof", "satisfies", "is", "asserts", "infer", "readonly",
                                          "public", "private", "protected", "abstract", "override", "implements", "true", "false", "null", "undefined"]
    static let python: Set<String> = ["if", "elif", "else", "while", "for", "return", "not", "and", "or", "in", "is", "lambda", "with",
                                      "assert", "yield", "await", "except", "del", "raise", "def", "class", "import", "from", "as",
                                      "global", "nonlocal", "pass", "break", "continue", "try", "finally", "async", "match", "case",
                                      "True", "False", "None", "print"]
}

extension CodeParameters {
    static func pythonForTests(_ positional: [String], keywordOnly: [String]) -> CodeParameters {
        var list = CodeParameters(); list.python = true
        list.positional = positional.map { .init(name: $0, optional: false) }
        list.keywordOnly = keywordOnly.map { .init(name: $0, optional: false) }
        return list
    }
}
