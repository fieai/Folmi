import Foundation

/// Reads a JavaScript / TypeScript token stream into a `FileOutline`. Patterns, not a grammar: the common ways to
/// declare, import, export and call, which is what AI-written code uses almost always.
struct JavaScriptOutliner {
    let tokens: [SourceToken]
    let path: String
    let jsx: Bool
    private var outline: FileOutline
    /// Partner of every bracket; -1 when unmatched.
    private var partner: [Int]
    /// Token indices of declared names, so they are not read as calls of themselves.
    private var declared: Set<Int> = []
    /// Tokens inside `import … from '…'` and `export { … }`.
    private var skipped: Set<Int> = []
    /// `{` that open a class body (class name) or an object literal (its variable, if any).
    private var classBodies: [Int: String] = [:]
    private var objectNames: [Int: String] = [:]

    init(tokens: [SourceToken], path: String, jsx: Bool) {
        self.tokens = tokens; self.path = path; self.jsx = jsx
        outline = FileOutline(path: path, language: .javaScript)
        partner = Array(repeating: -1, count: tokens.count)
        var stack: [Int] = []
        for (index, token) in tokens.enumerated() where token.kind == .punct {
            switch token.text {
            case "(", "[", "{": stack.append(index)
            case ")", "]", "}":
                let open = token.text == ")" ? "(" : token.text == "]" ? "[" : "{"
                if let at = stack.lastIndex(where: { tokens[$0].text == open }) {
                    partner[stack[at]] = index; partner[index] = stack[at]
                    stack.removeSubrange(at...)
                }
            default: break
            }
        }
    }

    private func token(_ index: Int) -> SourceToken? { index >= 0 && index < tokens.count ? tokens[index] : nil }
    private func ident(_ index: Int) -> String? { token(index).flatMap { $0.isIdentifier ? $0.text : nil } }
    private func punct(_ index: Int, _ text: String) -> Bool { token(index)?.is(text) == true }

    mutating func read() -> FileOutline {
        readImportsAndExports()
        readDefinitions()
        readUses()
        return outline
    }

    // MARK: Imports, exports, require

    private mutating func readImportsAndExports() {
        var index = 0
        while index < tokens.count {
            let current = tokens[index]
            defer { index += 1 }
            guard current.isIdentifier, !punct(index - 1, "."), !punct(index - 1, "?.") else { continue }
            switch current.text {
            case "import" where !punct(index + 1, "(") && !punct(index + 1, "."):
                readImport(at: index)
            case "export":
                readExport(at: index)
            case "require" where punct(index + 1, "(") && token(index + 2)?.kind == .string && punct(index + 3, ")"):
                readRequire(at: index)
            case "module" where punct(index + 1, ".") && ident(index + 2) == "exports":
                readModuleExports(at: index)
            case "exports" where punct(index + 1, ".") && ident(index + 2) != nil && punct(index + 3, "=") && !punct(index + 4, "="):
                readNamedCommonJSExport(name: ident(index + 2)!, value: index + 4)
            default: continue
            }
        }
    }

    /// The `from '…'` string after `index`, within a statement.
    private func fromModule(after index: Int) -> (String, Int)? {
        var at = index
        while at < tokens.count, at < index + 400 {
            if ident(at) == "from", let string = token(at + 1), string.kind == .string { return (string.text, at + 1) }
            if punct(at, ";") { return nil }
            at += 1
        }
        return nil
    }

    private mutating func readImport(at start: Int) {
        var at = start + 1
        // `import type { X }` brings in types only, which never run.
        if ident(at) == "type", !punct(at + 1, ","), ident(at + 1) != "from" { return }
        if token(at)?.kind == .string { return }
        // TypeScript `import x = require('m')`.
        if let local = ident(at), punct(at + 1, "="), ident(at + 2) == "require", let module = token(at + 4), module.kind == .string {
            outline.imports.append(.init(local: local, module: module.text, imported: .namespace)); declared.insert(at); return
        }
        guard let (module, end) = fromModule(after: at) else { return }
        for skip in start...end { skipped.insert(skip) }
        if let local = ident(at), local != "from" || punct(at + 1, ",") {
            outline.imports.append(.init(local: local, module: module, imported: .default))
            at += 1
            if punct(at, ",") { at += 1 }
        }
        if punct(at, "*"), ident(at + 1) == "as", let local = ident(at + 2) {
            outline.imports.append(.init(local: local, module: module, imported: .namespace))
        } else if punct(at, "{"), partner[at] > at {
            for (name, local) in namedList(from: at + 1, to: partner[at]) {
                outline.imports.append(.init(local: local, module: module, imported: name == "default" ? .default : .named(name)))
            }
        }
    }

    /// `a, b as c, type T, default as d` between braces.
    private func namedList(from start: Int, to end: Int) -> [(String, String)] {
        var result: [(String, String)] = []
        var at = start
        while at < end {
            if ident(at) == "type", ident(at + 1) != nil, !punct(at + 1, ","), ident(at + 1) != "as" { at += 1 }
            guard let name = ident(at) ?? token(at).flatMap({ $0.kind == .string ? $0.text : nil }) else { at += 1; continue }
            if ident(at + 1) == "as", let local = ident(at + 2) { result.append((name, local)); at += 3 }
            else { result.append((name, name)); at += 1 }
            while at < end, !punct(at, ",") { at += 1 }
            at += 1
        }
        return result
    }

    private mutating func readExport(at start: Int) {
        let next = start + 1
        guard let word = token(next) else { return }
        if word.is("{"), partner[next] > next {
            let names = namedList(from: next + 1, to: partner[next])
            let source = ident(partner[next] + 1) == "from" ? token(partner[next] + 2).flatMap { $0.kind == .string ? $0.text : nil } : nil
            for skip in start...(partner[next] + (source == nil ? 0 : 2)) { skipped.insert(skip) }
            for (local, exported) in names {
                outline.exports.append(.init(exported: exported, local: source == nil ? local : nil, from: source, star: false))
                if let source { outline.exports.append(.init(exported: exported, local: local, from: source, star: false)) }
            }
            // A re-export names the source's binding in `local`; drop the duplicate without it.
            if source != nil { outline.exports.removeAll { $0.from != nil && $0.local == nil && !$0.star } }
            return
        }
        if word.is("*") {
            guard let (module, end) = fromModule(after: next) else { return }
            for skip in start...end { skipped.insert(skip) }
            if ident(next + 1) == "as", let name = ident(next + 2) {
                outline.exports.append(.init(exported: name, local: nil, from: module, star: true))
            } else {
                outline.exports.append(.init(exported: "*", local: nil, from: module, star: true))
            }
            return
        }
        guard word.isIdentifier else { return }
        switch word.text {
        case "default":
            if let name = ident(next + 1), !["function", "class", "async", "new"].contains(name),
               token(next + 2).map({ $0.is(";") || $0.firstOnLine }) ?? true {
                outline.exports.append(.init(exported: "default", local: name, from: nil, star: false))
                skipped.insert(next + 1)
            }
            // `export default function f` / `class C` / an anonymous function: named while reading definitions.
        case "function", "class", "abstract":
            var at = next + 1
            if punct(at, "*") || ident(at) == "class" { at += 1 }
            if let name = ident(at) { outline.exports.append(.init(exported: name, local: name, from: nil, star: false)) }
        case "async":
            if ident(next + 1) == "function", let name = ident(next + 2) ?? ident(next + 3) {
                outline.exports.append(.init(exported: name, local: name, from: nil, star: false))
            }
        case "const", "let", "var":
            if let name = ident(next + 1) { outline.exports.append(.init(exported: name, local: name, from: nil, star: false)) }
        default: break
        }
    }

    private mutating func readRequire(at index: Int) {
        let module = tokens[index + 2].text
        // `const x = require('m')`, `const { a, b: c } = require('m')`, `const x = require('m').y`.
        guard punct(index - 1, "=") else { return }
        let member = punct(index + 4, ".") ? ident(index + 5) : nil
        if let local = ident(index - 2), ["const", "let", "var"].contains(ident(index - 3) ?? "") {
            outline.imports.append(.init(local: local, module: module, imported: member.map { .named($0) } ?? .namespace))
            declared.insert(index - 2)
        } else if punct(index - 2, "}"), partner[index - 2] >= 0 {
            let open = partner[index - 2]
            for (name, local) in destructured(from: open + 1, to: index - 2) {
                outline.imports.append(.init(local: local, module: module, imported: .named(name)))
            }
        }
    }

    /// `a, b: c, d = 1` inside a destructuring pattern; nested patterns are skipped.
    private mutating func destructured(from start: Int, to end: Int) -> [(String, String)] {
        var result: [(String, String)] = []
        var at = start
        while at < end {
            guard let name = ident(at) else { at += 1; continue }
            if punct(at + 1, ":"), let local = ident(at + 2) { result.append((name, local)); declared.insert(at + 2); at += 3 }
            else { result.append((name, name)); declared.insert(at); at += 1 }
            var depth = 0
            while at < end {
                if let t = token(at), t.kind == .punct {
                    if ["(", "[", "{"].contains(t.text) { depth += 1 } else if [")", "]", "}"].contains(t.text) { depth -= 1 }
                    else if t.text == ",", depth == 0 { break }
                }
                at += 1
            }
            at += 1
        }
        return result
    }

    private mutating func readModuleExports(at index: Int) {
        // module.exports.name = …
        if punct(index + 3, "."), let name = ident(index + 4), punct(index + 5, "="), !punct(index + 6, "=") {
            readNamedCommonJSExport(name: name, value: index + 6); return
        }
        guard punct(index + 3, "="), !punct(index + 4, "=") else { return }
        let value = index + 4
        if punct(value, "{"), partner[value] > value {
            objectNames[value] = ""
            var at = value + 1
            let end = partner[value]
            while at < end {
                if let name = ident(at), punct(at - 1, "{") || punct(at - 1, ",") {
                    if punct(at + 1, ",") || at + 1 == end {
                        outline.exports.append(.init(exported: name, local: name, from: nil, star: false))
                        skipped.insert(at)
                    } else if punct(at + 1, ":"), let local = ident(at + 2), punct(at + 3, ",") || at + 3 == end {
                        outline.exports.append(.init(exported: name, local: local, from: nil, star: false))
                        skipped.insert(at); skipped.insert(at + 2)
                    } else {
                        // `name: function`, `name() {}`, `name: () =>`: a definition named `name`.
                        outline.exports.append(.init(exported: name, local: name, from: nil, star: false))
                    }
                }
                if let t = token(at), ["(", "[", "{"].contains(t.text), partner[at] > at { at = partner[at] }
                at += 1
            }
        } else if let name = ident(value), token(value + 1).map({ $0.is(";") || $0.firstOnLine }) ?? true {
            outline.exports.append(.init(exported: "default", local: name, from: nil, star: false))
            skipped.insert(value)
        } else if ident(value) == "require", let module = token(value + 2), module.kind == .string {
            outline.exports.append(.init(exported: "*", local: nil, from: module.text, star: true))
        }
    }

    private mutating func readNamedCommonJSExport(name: String, value: Int) {
        if let local = ident(value), token(value + 1).map({ $0.is(";") || $0.firstOnLine }) ?? true, !["function", "async"].contains(local) {
            outline.exports.append(.init(exported: name, local: local, from: nil, star: false))
            skipped.insert(value)
        } else {
            outline.exports.append(.init(exported: name, local: name, from: nil, star: false))
        }
    }

    // MARK: Definitions

    private static let modifiers: Set<String> = ["static", "async", "get", "set", "public", "private", "protected", "readonly",
                                                 "override", "abstract", "declare", "accessor"]
    private static let notMethods: Set<String> = ["if", "for", "while", "switch", "catch", "with", "function", "return", "else", "do", "try"]

    private mutating func readDefinitions() {
        var contexts: [(end: Int, kind: Context)] = []
        for index in tokens.indices {
            while let last = contexts.last, last.end < index { contexts.removeLast() }
            let current = tokens[index]
            if current.is("{"), partner[index] > index {
                contexts.append((partner[index], context(at: index)))
                continue
            }
            if current.is("=>") { readArrow(at: index, contexts: contexts); continue }
            guard current.isIdentifier else { continue }
            switch current.text {
            case "function" where !punct(index - 1, "."):
                readFunction(at: index, contexts: contexts)
            case "class" where !punct(index - 1, "."):
                readClass(at: index)
            default:
                readMember(at: index, contexts: contexts)
                readAlias(at: index)
            }
        }
    }

    private enum Context { case block, classBody(String), object(String?) }

    private func context(at index: Int) -> Context {
        if let name = classBodies[index] { return .classBody(name) }
        if let name = objectNames[index] { return .object(name.isEmpty ? nil : name) }
        guard let previous = token(index - 1) else { return .block }
        if previous.kind == .punct, ["=", "(", ",", ":", "[", "?", "|", "&"].contains(previous.text) {
            if previous.is("="), let name = ident(index - 2), ["const", "let", "var"].contains(ident(index - 3) ?? "") { return .object(name) }
            if previous.is("="), let name = ident(index - 2), punct(index - 3, "."), let owner = ident(index - 4), owner != "this" {
                return .object(owner == "exports" ? nil : name)
            }
            return .object(nil)
        }
        if previous.isIdentifier, ["return", "default"].contains(previous.text) { return .object(previous.text == "default" ? "default" : nil) }
        return .block
    }

    private func container(_ contexts: [(end: Int, kind: Context)]) -> (String?, Bool) {
        switch contexts.last?.kind {
        case .classBody(let name)?: return (name, true)
        case .object(let name)?: return (name, name != nil)
        default: return (nil, false)
        }
    }

    private mutating func add(_ name: String, kind: CodeSymbol.Kind, container: String?, nameToken: Int, body: ClosedRange<Int>, bases: [[String]] = [],
                              parameters: CodeParameters? = nil) {
        let symbol = CodeSymbol(path: path, name: name, container: container, kind: kind, line: tokens[nameToken].line,
                                endLine: tokens[min(body.upperBound, tokens.count - 1)].line)
        outline.definitions.append(.init(symbol: symbol, body: body, bases: bases, parameters: parameters))
        declared.insert(nameToken)
    }

    /// The `{` of a body starting the search at `index`; nil when a `;` or a closing bracket comes first (an overload
    /// or a declaration without a body).
    private func bodyBrace(from index: Int) -> Int? {
        var at = index
        while at < tokens.count, at < index + 200 {
            let t = tokens[at]
            if t.is("{") { return partner[at] > at ? at : nil }
            if t.is(";") || t.is("}") || t.is("=>") { return nil }
            if t.is("("), partner[at] > at { at = partner[at] }
            at += 1
        }
        return nil
    }

    /// The name an unnamed function gets from where it is written: `const f =`, `f:` in an object, `a.b = `,
    /// `export default`, a class field.
    private func assignedName(before start: Int, contexts: [(end: Int, kind: Context)]) -> (name: String, container: String?, token: Int, isMember: Bool)? {
        var at = start - 1
        if ident(at) == "async" { at -= 1 }
        if ident(at) == "default", ident(at - 1) == "export" { return ("default", nil, at, false) }
        // A TypeScript annotation between the name and `=`: `const f: Handler = () => …`.
        if punct(at, "=") {
            var nameAt = at - 1
            if !(token(nameAt)?.isIdentifier ?? false) || punct(nameAt - 1, ":") {
                var back = at - 1, steps = 0
                while back > 0, steps < 30, !punct(back, ":") { back -= 1; steps += 1 }
                if punct(back, ":"), ident(back - 1) != nil, ["const", "let", "var"].contains(ident(back - 2) ?? "") { nameAt = back - 1 }
            }
            guard let name = ident(nameAt) else { return nil }
            if punct(nameAt - 1, "."), let owner = ident(nameAt - 2) {
                if owner == "exports" || (owner == "exports" && ident(nameAt - 4) == "module") { return (name, nil, nameAt, false) }
                if owner == "prototype", let type = ident(nameAt - 4) { return (name, type, nameAt, true) }
                if owner == "this" { let (type, _) = container(contexts); return (name, type, nameAt, true) }
                return (name, owner, nameAt, true)
            }
            if case .classBody(let type)? = contexts.last?.kind { return (name, type, nameAt, true) }
            return (name, nil, nameAt, false)
        }
        if punct(at, ":"), let name = ident(at - 1) ?? token(at - 1).flatMap({ $0.kind == .string ? $0.text : nil }),
           punct(at - 2, "{") || punct(at - 2, ",") || token(at - 1)?.firstOnLine == true {
            let (owner, member) = container(contexts)
            return (name, owner, at - 1, member)
        }
        return nil
    }

    /// The variable a wrapped function is stored in: `const save = useCallback(async () => …)`,
    /// `const total = computed(() => …)`, `const View = memo(function () …)`.
    private func wrappedName(at start: Int) -> (String, Int)? {
        let open = ident(start - 1) == "async" ? start - 2 : start - 1
        guard punct(open, "(") else { return nil }
        var head = open - 1
        guard ident(head) != nil else { return nil }
        while punct(head - 1, "."), ident(head - 2) != nil { head -= 2 }
        guard punct(head - 1, "="), let name = ident(head - 2), ["const", "let", "var"].contains(ident(head - 3) ?? "") else { return nil }
        return (name, head - 2)
    }

    /// An unnamed function at the top level passed to a call, named after it: `router.get("/orders/:id")`.
    private func callbackName(at start: Int) -> String? {
        var at = start - 1
        while at >= 0 {
            let t = tokens[at]
            if t.kind == .punct, [")", "]", "}"].contains(t.text), partner[at] >= 0 { at = partner[at] - 1; continue }
            if t.is("("), partner[at] > start {
                var chain: [String] = []
                var head = at - 1
                while let name = ident(head) {
                    chain.insert(name, at: 0)
                    guard punct(head - 1, ".") || punct(head - 1, "?.") else { break }
                    head -= 2
                }
                guard !chain.isEmpty, !SourceKeywords.javaScript.contains(chain[0]) || chain[0] == "this" else { return nil }
                let call = chain.joined(separator: ".")
                if let first = token(at + 1), first.kind == .string, !first.text.isEmpty { return "\(call)(\"\(first.text)\")" }
                return "\(call)(…) 回调"
            }
            if t.is("{") || t.is(";") || t.is("[") { return nil }
            at -= 1
        }
        return nil
    }

    private func insideDefinition(_ index: Int) -> Bool { outline.definitions.contains { $0.body.contains(index) } }

    private mutating func readFunction(at index: Int, contexts: [(end: Int, kind: Context)]) {
        var at = index + 1
        if punct(at, "*") { at += 1 }
        var name = ident(at), nameToken = at, owner: String?, kind = CodeSymbol.Kind.function
        if name != nil { at += 1 } else if let assigned = assignedName(before: index, contexts: contexts) {
            name = assigned.name; nameToken = assigned.token; owner = assigned.container; kind = assigned.isMember ? .method : .function
        }
        if ident(index - 1) == "default", ident(index - 2) == "export", name == nil { name = "default"; nameToken = index }
        if punct(at, "<"), let close = (at..<min(at + 40, tokens.count)).first(where: { punct($0, ">") }) { at = close + 1 }
        guard punct(at, "("), partner[at] > at, let brace = bodyBrace(from: partner[at] + 1) else { return }
        var wrapped = false
        if name == nil, let (outer, at) = wrappedName(at: index) { name = outer; nameToken = at; wrapped = true }
        if name == nil, !insideDefinition(index), let callback = callbackName(at: index) { name = callback; nameToken = index }
        guard let name else { return }
        // A wrapped function's variable holds what the wrapper returns (`createParamDecorator`, `memo`): its
        // parameters are not the inner function's.
        add(name, kind: kind, container: owner, nameToken: nameToken, body: index...partner[brace], parameters: wrapped ? nil : parameters(at))
        if ident(index - 1) == "default" || ident(index - 2) == "default", ident(index - 2) == "export" || ident(index - 3) == "export", name != "default" {
            outline.exports.append(.init(exported: "default", local: name, from: nil, star: false))
        }
    }

    private mutating func readArrow(at arrow: Int, contexts: [(end: Int, kind: Context)]) {
        var start: Int
        if punct(arrow - 1, ")"), partner[arrow - 1] >= 0 { start = partner[arrow - 1] }
        else if ident(arrow - 1) != nil, !punct(arrow - 2, ":") { start = arrow - 1 }
        else {
            // A return type before the arrow: `(x): Promise<T> =>`.
            var back = arrow - 1, steps = 0
            while back > 0, steps < 30, !(punct(back, ")") && punct(back + 1, ":")) { back -= 1; steps += 1 }
            guard punct(back, ")"), partner[back] >= 0 else { return }
            start = partner[back]
        }
        if punct(start - 1, ">"), let open = (max(0, start - 40)..<start).last(where: { punct($0, "<") }) { start = open }
        let end: Int
        if punct(arrow + 1, "{"), partner[arrow + 1] > arrow { end = partner[arrow + 1] }
        else { end = expressionEnd(from: arrow + 1) }
        guard end > arrow else { return }
        var name: String?, nameToken = start, owner: String?, kind = CodeSymbol.Kind.function, wrapped = false
        if let assigned = assignedName(before: start, contexts: contexts) {
            name = assigned.name; nameToken = assigned.token; owner = assigned.container; kind = assigned.isMember ? .method : .function
        } else if let (outer, at) = wrappedName(at: start) {
            name = outer; nameToken = at; wrapped = true
        } else if !insideDefinition(start), let callback = callbackName(at: start) {
            name = callback
        }
        guard let name else { return }
        var list: CodeParameters
        if let open = (start..<arrow).first(where: { punct($0, "(") }), partner[open] > open, partner[open] < arrow { list = parameters(open) }
        else { list = CodeParameters(); if let single = ident(arrow - 1) { list.positional = [.init(name: single, optional: false)] } }
        add(name, kind: kind, container: owner, nameToken: nameToken, body: start...end, parameters: wrapped ? nil : list)
    }

    /// The parts between `open` and its `)` separated by commas at their own depth (types' `<…>` included).
    private func segments(_ open: Int) -> [Range<Int>] {
        guard partner[open] > open else { return [] }
        var result: [Range<Int>] = [], start = open + 1, at = open + 1, angles = 0
        let close = partner[open]
        while at < close {
            let t = tokens[at]
            if t.kind == .punct {
                if ["(", "[", "{"].contains(t.text), partner[at] > at, partner[at] < close { at = partner[at] + 1; continue }
                if t.text == "<" { angles += 1 } else if t.text == ">", angles > 0 { angles -= 1 }
                else if t.text == ",", angles == 0 { result.append(start..<at); start = at + 1 }
            }
            at += 1
        }
        result.append(start..<close)
        return result.filter { !$0.isEmpty }
    }

    /// `(id: string, opts?: Options, { a, b } = {}, ...rest)`; TypeScript's `this:` parameter is not passed.
    private func parameters(_ open: Int) -> CodeParameters {
        var list = CodeParameters()
        for segment in segments(open) {
            var at = segment.lowerBound
            while at < segment.upperBound, punct(at, "@") || (ident(at).map { ["public", "private", "protected", "readonly", "override"].contains($0) && ident(at + 1) != nil } ?? false) {
                if punct(at, "@") { at += 1; while ident(at) != nil || punct(at, ".") { at += 1 }; if punct(at, "("), partner[at] > at { at = partner[at] + 1 } } else { at += 1 }
            }
            guard at < segment.upperBound else { continue }
            if punct(at, "...") { list.rest = true; continue }
            if ident(at) == "this", punct(at + 1, ":") { continue }
            let name = ident(at) ?? (punct(at, "{") ? "{…}" : punct(at, "[") ? "[…]" : "?")
            let optional = punct(at + 1, "?") || (at..<segment.upperBound).contains { punct($0, "=") && !punct($0 + 1, ">") }
            list.positional.append(.init(name: name, optional: optional))
        }
        return list
    }

    private func arguments(_ open: Int) -> CallArguments {
        let parts = segments(open)
        return CallArguments(positional: parts.count, keywords: [], spread: parts.contains { punct($0.lowerBound, "...") })
    }

    /// Where an arrow's expression body ends: a `,` `;` or unmatched closer at its own depth, or a new line that
    /// starts a new statement.
    private func expressionEnd(from start: Int) -> Int {
        var at = start
        let continuing: Set<String> = [".", "?.", "?", ":", "+", "-", "*", "/", "&", "|", "=", "(", ",", "=>", "<", ">", "!"]
        while at < tokens.count {
            let t = tokens[at]
            if t.kind == .punct {
                if ["(", "[", "{"].contains(t.text), partner[at] > at { at = partner[at] + 1; continue }
                if [")", "]", "}", ",", ";"].contains(t.text) { return at - 1 }
            }
            if at > start, t.firstOnLine, let previous = token(at - 1), !(previous.kind == .punct && continuing.contains(previous.text)),
               !(t.kind == .punct && continuing.contains(t.text)) {
                return at - 1
            }
            at += 1
        }
        return tokens.count - 1
    }

    private mutating func readClass(at index: Int) {
        guard let name = ident(index + 1) ?? (ident(index - 2).flatMap { punct(index - 1, "=") ? $0 : nil }) else { return }
        var at = index + 1
        var bases: [[String]] = []
        while at < tokens.count, at < index + 200, !punct(at, "{") {
            if ident(at) == "extends" {
                var chain: [String] = []
                var cursor = at + 1
                while let part = ident(cursor) { chain.append(part); guard punct(cursor + 1, ".") else { break }; cursor += 2 }
                if !chain.isEmpty { bases.append(chain) }
            }
            if punct(at, "("), partner[at] > at { at = partner[at] }
            at += 1
        }
        guard punct(at, "{"), partner[at] > at else { return }
        classBodies[at] = name
        add(name, kind: .class, container: nil, nameToken: ident(index + 1) != nil ? index + 1 : index - 2, body: index...partner[at], bases: bases)
        if ident(index - 1) == "default", ident(index - 2) == "export" {
            outline.exports.append(.init(exported: "default", local: name, from: nil, star: false))
        }
    }

    /// `name(…) {` in a class body or object literal; typed fields and constructor parameter properties.
    private mutating func readMember(at index: Int, contexts: [(end: Int, kind: Context)]) {
        let (owner, _) = container(contexts)
        let inClass: Bool
        switch contexts.last?.kind {
        case .classBody?: inClass = true
        case .object?: inClass = false
        default: return
        }
        let name = tokens[index].text
        guard !Self.notMethods.contains(name), !punct(index - 1, "."), !punct(index - 1, "?.") else { return }
        let previous = token(index - 1)
        let atMemberStart = previous == nil || previous!.is("{") || previous!.is(";") || previous!.is("}") || previous!.is(",")
            || previous!.is("*") || (previous!.isIdentifier && Self.modifiers.contains(previous!.text)) || (inClass && tokens[index].firstOnLine)
        guard atMemberStart else { return }
        var at = index + 1
        if punct(at, "?") || punct(at, "!") { at += 1 }
        if inClass, let className = owner, punct(at, ":") {
            var chain: [String] = []
            var cursor = at + 1
            while let part = ident(cursor) { chain.append(part); guard punct(cursor + 1, ".") else { break }; cursor += 2 }
            if let first = chain.first, first.first?.isUppercase == true { outline.memberTypes[className, default: [:]][name] = chain }
            return
        }
        if Self.modifiers.contains(name), ident(at) != nil || punct(at, "*") || punct(at, "[") { return }
        if punct(at, "<"), let close = (at..<min(at + 40, tokens.count)).first(where: { punct($0, ">") }) { at = close + 1 }
        guard punct(at, "("), partner[at] > at else { return }
        let close = partner[at]
        guard let brace = bodyBrace(from: close + 1), !(token(close + 1)?.is("=>") ?? false) else { return }
        // `if (x) {` was excluded by name; a call followed by a block cannot appear at a member's start.
        if inClass, name == "constructor", let className = owner { readParameterProperties(from: at + 1, to: close, className: className) }
        add(name, kind: .method, container: owner, nameToken: index, body: index...partner[brace], parameters: parameters(at))
    }

    private mutating func readParameterProperties(from start: Int, to end: Int, className: String) {
        var at = start
        while at < end {
            if let word = ident(at), ["private", "public", "protected", "readonly"].contains(word) {
                var cursor = at + 1
                while let next = ident(cursor), ["private", "public", "protected", "readonly"].contains(next) { cursor += 1 }
                if let name = ident(cursor), punct(cursor + 1, ":") {
                    var chain: [String] = []
                    var typeAt = cursor + 2
                    while let part = ident(typeAt) { chain.append(part); guard punct(typeAt + 1, ".") else { break }; typeAt += 2 }
                    if !chain.isEmpty { outline.memberTypes[className, default: [:]][name] = chain }
                    declared.insert(cursor)
                }
            }
            at += 1
        }
    }

    /// `const h = foo`, `const h = a.b`, `const svc = new Service()`, `const h = foo.bind(this)`, `const { a } = ns`;
    /// also `this.svc = new Service()` as a member type.
    private mutating func readAlias(at index: Int) {
        let word = tokens[index].text
        if word == "this", punct(index + 1, "."), let member = ident(index + 2), punct(index + 3, "="), !punct(index + 4, "="),
           ident(index + 4) == "new", let chain = chainAt(index + 5), punct(chain.next, "(") {
            if let owner = classOwning(index) { outline.memberTypes[owner, default: [:]][member] = chain.parts }
            return
        }
        guard ["const", "let", "var"].contains(word) else { return }
        if punct(index + 1, "{"), partner[index + 1] > index + 1, punct(partner[index + 1] + 1, "="),
           let source = chainAt(partner[index + 1] + 2), source.parts != ["require"], ident(partner[index + 1] + 2) != "await" {
            let ends = token(source.next).map { $0.is(";") || $0.firstOnLine } ?? true
            if ends {
                for (name, local) in destructured(from: index + 2, to: partner[index + 1]) {
                    outline.aliases.append(.init(local: local, target: source.parts + [name], constructed: false, token: index))
                }
                for skip in (partner[index + 1] + 2)..<source.next { skipped.insert(skip) }
            }
            return
        }
        guard let local = ident(index + 1) else { return }
        var at = index + 2
        if punct(at, ":") {
            // A typed declaration: `const svc: OrderService = …` gives the type when the value says nothing.
            var chain: [String] = []
            var cursor = at + 1
            while let part = ident(cursor) { chain.append(part); guard punct(cursor + 1, ".") else { break }; cursor += 2 }
            while cursor < tokens.count, !punct(cursor, "="), !punct(cursor, ";"), !tokens[cursor].firstOnLine || cursor == at + 1 { cursor += 1 }
            if !chain.isEmpty, chain[0].first?.isUppercase == true {
                outline.aliases.append(.init(local: local, target: chain, constructed: true, token: index))
                declared.insert(index + 1)
                return
            }
            at = cursor
        }
        guard punct(at, "="), !punct(at + 1, "=") else { return }
        var value = at + 1
        if ident(value) == "await" { return }
        let isNew = ident(value) == "new"
        if isNew { value += 1 }
        guard let chain = chainAt(value), chain.parts != ["require"], !["function", "async", "class"].contains(chain.parts[0]) else { return }
        var next = chain.next
        var parts = chain.parts
        var called = false
        if punct(next, "("), partner[next] > next { called = true; next = partner[next] + 1 }
        guard token(next).map({ $0.is(";") || $0.is(",") || $0.firstOnLine }) ?? true else { return }
        if called, parts.last == "bind", parts.count > 1 { parts.removeLast(); called = false }
        outline.aliases.append(.init(local: local, target: parts, constructed: isNew || called, token: index))
        // A rename is not a use; the calls through the new name are.
        if !isNew && !called { for skip in value..<chain.next { skipped.insert(skip) } }
        declared.insert(index + 1)
    }

    private func classOwning(_ index: Int) -> String? {
        outline.definitions.filter { $0.symbol.kind == .class && $0.body.contains(index) }.max { $0.body.lowerBound < $1.body.lowerBound }?.symbol.name
    }

    private func chainAt(_ index: Int) -> (parts: [String], next: Int)? {
        guard let first = ident(index) else { return nil }
        var parts = [first], at = index
        while punct(at + 1, ".") || punct(at + 1, "?."), let part = ident(at + 2) { parts.append(part); at += 2 }
        return (parts, at + 1)
    }

    // MARK: Uses

    private static let jsxBefore: Set<String> = ["(", "=", ",", "?", ":", "{", "[", ">", "&", "|", ";", "=>"]

    private mutating func readUses() {
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            let current = tokens[index]
            if jsx, current.is("<"), let name = ident(index + 1), name.first?.isUppercase == true,
               let previous = token(index - 1), (previous.kind == .punct && Self.jsxBefore.contains(previous.text)) || ["return", "default"].contains(previous.text) {
                guard let chain = chainAt(index + 1) else { continue }
                outline.uses.append(.init(chain: chain.parts, line: current.line, token: index + 1, kind: .render))
                index = chain.next - 1
                continue
            }
            guard current.isIdentifier, !skipped.contains(index), !declared.contains(index) else { continue }
            if punct(index - 1, ".") || punct(index - 1, "?.") || punct(index - 1, "#") { continue }
            if punct(index - 1, "/"), punct(index - 2, "<") { continue }
            if let previous = ident(index - 1), ["function", "class", "const", "let", "var", "import", "as", "interface", "type", "enum", "namespace"].contains(previous) { continue }
            let word = current.text
            if SourceKeywords.javaScript.contains(word), word != "this", word != "super" { continue }
            guard let chain = chainAt(index) else { continue }
            var next = chain.next
            let isNew = ident(index - 1) == "new"
            // Generic arguments before a call: `useState<Order>(…)`.
            if punct(next, "<"), let close = (next..<min(next + 30, tokens.count)).first(where: { punct($0, ">") }),
               punct(close + 1, "("), (next...close).allSatisfy({ tokens[$0].line == current.line }) {
                next = close + 1
            }
            if punct(next, "?."), punct(next + 1, "(") { next += 1 }
            if punct(next, "(") || isNew {
                outline.uses.append(.init(chain: chain.parts, line: current.line, token: index, kind: .call,
                                          arguments: punct(next, "(") ? arguments(next) : CallArguments()))
            } else if word != "this", word != "super" {
                // A function passed as a value: `onClick={save}`, `router.get('/x', handler)`, `map(format)`.
                if punct(next, "="), !punct(next + 1, "="), !punct(next + 1, ">") { index = chain.next - 1; continue }
                if punct(next, ":"), punct(index - 1, "{") || punct(index - 1, ",") { index = chain.next - 1; continue }
                outline.uses.append(.init(chain: chain.parts, line: current.line, token: index, kind: .reference))
            }
            index = chain.next - 1
        }
    }
}
