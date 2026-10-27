import Foundation

/// Reads a Python token stream into a `FileOutline`: bodies by indentation, `import` / `from … import … as`,
/// assignments that rename (`h = helper`, `svc = Service()`), and the member types `self.repo = Repo()` gives.
struct PythonOutliner {
    let tokens: [SourceToken]
    let path: String
    private var outline: FileOutline
    /// Logical lines: the first token of each, its indentation, and the last token.
    private var lines: [(start: Int, end: Int, indent: Int)] = []
    private var declared: Set<Int> = []
    private var skipped: Set<Int> = []

    init(tokens: [SourceToken], path: String) {
        self.tokens = tokens; self.path = path
        outline = FileOutline(path: path, language: .python)
        var depth = 0
        for (index, token) in tokens.enumerated() {
            // A new line inside brackets continues the logical line.
            if token.firstOnLine, depth == 0 {
                if let last = lines.indices.last { lines[last].end = index - 1 }
                lines.append((index, index, token.column))
            }
            if token.kind == .punct {
                if ["(", "[", "{"].contains(token.text) { depth += 1 } else if [")", "]", "}"].contains(token.text) { depth = max(0, depth - 1) }
            }
        }
        if let last = lines.indices.last { lines[last].end = tokens.count - 1 }
    }

    private func token(_ index: Int) -> SourceToken? { index >= 0 && index < tokens.count ? tokens[index] : nil }
    private func ident(_ index: Int) -> String? { token(index).flatMap { $0.isIdentifier ? $0.text : nil } }
    private func punct(_ index: Int, _ text: String) -> Bool { token(index)?.is(text) == true }

    private func chainAt(_ index: Int) -> (parts: [String], next: Int)? {
        guard let first = ident(index) else { return nil }
        var parts = [first], at = index
        while punct(at + 1, "."), let part = ident(at + 2) { parts.append(part); at += 2 }
        return (parts, at + 1)
    }

    private func closing(_ open: Int) -> Int? {
        var depth = 0, at = open
        while at < tokens.count {
            let t = tokens[at]
            if t.kind == .punct {
                if ["(", "[", "{"].contains(t.text) { depth += 1 } else if [")", "]", "}"].contains(t.text) { depth -= 1; if depth == 0 { return at } }
            }
            at += 1
        }
        return nil
    }

    mutating func read() -> FileOutline {
        readStructure()
        readUses()
        return outline
    }

    private mutating func readStructure() {
        // Open definitions: indentation, index in `outline.definitions`, parameter types for `self.x = param`.
        var open: [(indent: Int, definition: Int, parameters: [String: [String]])] = []
        func close(through line: Int, indent: Int) {
            while let last = open.last, last.indent >= indent {
                outline.definitions[last.definition].body = outline.definitions[last.definition].body.lowerBound...max(outline.definitions[last.definition].body.lowerBound, line)
                let end = outline.definitions[last.definition]
                outline.definitions[last.definition].symbol = CodeSymbol(path: path, name: end.symbol.name, container: end.symbol.container,
                                                                        kind: end.symbol.kind, line: end.symbol.line, endLine: tokens[max(end.body.upperBound, 0)].line)
                open.removeLast()
            }
        }
        for line in lines {
            close(through: line.start - 1, indent: line.indent)
            var at = line.start
            guard let first = ident(at) else {
                if punct(at, "@"), let chain = chainAt(at + 1), !punct(chain.next, "(") {
                    outline.uses.append(.init(chain: chain.parts, line: tokens[at].line, token: at + 1, kind: .call))
                }
                continue
            }
            let parentClass: String? = open.last.flatMap { entry in
                let definition = outline.definitions[entry.definition]
                return definition.symbol.kind == .class ? definition.symbol.name : nil
            }
            switch first {
            case "async" where ident(at + 1) == "def", "def":
                if first == "async" { at += 1 }
                guard let name = ident(at + 1), punct(at + 2, "(") else { continue }
                var parameters: [String: [String]] = [:]
                if let close = closing(at + 2) {
                    for (offset, token) in tokens[(at + 3)..<close].enumerated() where token.isIdentifier {
                        let index = at + 3 + offset
                        declared.insert(index)
                        if punct(index + 1, ":"), let type = chainAt(index + 2), type.parts.first?.first?.isUppercase == true { parameters[token.text] = type.parts }
                    }
                    for skip in (at + 2)...close { skipped.insert(skip) }
                }
                let symbol = CodeSymbol(path: path, name: name, container: parentClass, kind: parentClass == nil ? .function : .method,
                                        line: tokens[at + 1].line, endLine: tokens[line.end].line)
                outline.definitions.append(.init(symbol: symbol, body: line.start...line.end, parameters: self.parameters(at + 2, method: parentClass != nil)))
                declared.insert(at + 1)
                open.append((line.indent, outline.definitions.count - 1, parameters))
            case "class":
                guard let name = ident(at + 1) else { continue }
                var bases: [[String]] = []
                if punct(at + 2, "("), let close = closing(at + 2) {
                    var cursor = at + 3
                    while cursor < close {
                        if let chain = chainAt(cursor), !punct(chain.next, "=") { bases.append(chain.parts); cursor = chain.next } else { cursor += 1 }
                        while cursor < close, !punct(cursor, ",") { cursor += 1 }
                        cursor += 1
                    }
                }
                let symbol = CodeSymbol(path: path, name: name, container: nil, kind: .class, line: tokens[at + 1].line, endLine: tokens[line.end].line)
                outline.definitions.append(.init(symbol: symbol, body: line.start...line.end, bases: bases))
                declared.insert(at + 1)
                open.append((line.indent, outline.definitions.count - 1, [:]))
            case "import":
                for skip in line.start...line.end { skipped.insert(skip) }
                var cursor = at + 1
                while cursor <= line.end {
                    guard let chain = chainAt(cursor) else { cursor += 1; continue }
                    let module = chain.parts.joined(separator: ".")
                    if ident(chain.next) == "as", let local = ident(chain.next + 1) {
                        outline.imports.append(.init(local: local, module: module, imported: .namespace)); cursor = chain.next + 2
                    } else {
                        // `import a.b` binds `a`; `a.b.f()` walks down from it.
                        outline.imports.append(.init(local: chain.parts[0], module: chain.parts[0], imported: .namespace)); cursor = chain.next
                    }
                    cursor += 1
                }
            case "from":
                for skip in line.start...line.end { skipped.insert(skip) }
                var cursor = at + 1, module = ""
                while punct(cursor, ".") || punct(cursor, "...") { module += tokens[cursor].text; cursor += 1 }
                if let chain = chainAt(cursor) { module += chain.parts.joined(separator: "."); cursor = chain.next }
                guard ident(cursor) == "import" else { continue }
                cursor += 1
                if punct(cursor, "*") { outline.starImports.append(module); continue }
                while cursor <= line.end {
                    guard let name = ident(cursor) else { cursor += 1; continue }
                    if ident(cursor + 1) == "as", let local = ident(cursor + 2) {
                        outline.imports.append(.init(local: local, module: module, imported: .named(name))); cursor += 3
                    } else {
                        outline.imports.append(.init(local: name, module: module, imported: .named(name))); cursor += 1
                    }
                }
            case "self":
                // self.x = Repo(), self.x: Repo, self.x = param (param: Repo)
                guard let owner = classOf(open), punct(at + 1, "."), let member = ident(at + 2) else { continue }
                if punct(at + 3, ":"), let type = chainAt(at + 4) { outline.memberTypes[owner, default: [:]][member] = type.parts; continue }
                guard punct(at + 3, "="), !punct(at + 4, "="), let value = chainAt(at + 4) else { continue }
                if punct(value.next, "("), value.parts.last?.first?.isUppercase == true { outline.memberTypes[owner, default: [:]][member] = value.parts }
                else if value.parts.count == 1, let type = open.last?.parameters[value.parts[0]] { outline.memberTypes[owner, default: [:]][member] = type }
            default:
                readAssignment(line: line, parentClass: parentClass)
            }
        }
        close(through: tokens.count - 1, indent: Int.min)
    }

    /// The class whose method is open, for `self.x = …`.
    private func classOf(_ open: [(indent: Int, definition: Int, parameters: [String: [String]])]) -> String? {
        for entry in open.reversed() {
            let symbol = outline.definitions[entry.definition].symbol
            if symbol.kind == .class { return symbol.name }
        }
        return nil
    }

    /// `h = helper`, `svc = Service()`, `f = lambda x: …`, `svc: Service = make()`.
    private mutating func readAssignment(line: (start: Int, end: Int, indent: Int), parentClass: String?) {
        let at = line.start
        guard let local = ident(at), parentClass == nil else { return }
        var equals = at + 1
        var annotated: [String]?
        if punct(equals, ":"), let type = chainAt(equals + 1) { annotated = type.parts; equals = type.next }
        guard punct(equals, "="), !punct(equals + 1, "=") else { return }
        declared.insert(at)
        if ident(equals + 1) == "lambda" {
            let symbol = CodeSymbol(path: path, name: local, container: nil, kind: .function, line: tokens[at].line, endLine: tokens[line.end].line)
            outline.definitions.append(.init(symbol: symbol, body: at...line.end))
            return
        }
        if let annotated, annotated.first?.first?.isUppercase == true {
            outline.aliases.append(.init(local: local, target: annotated, constructed: true, token: at)); return
        }
        guard let value = chainAt(equals + 1) else { return }
        var next = value.next, called = false
        if punct(next, "("), let close = closing(next) { called = true; next = close + 1 }
        guard next > line.end else { return }
        outline.aliases.append(.init(local: local, target: value.parts, constructed: called, token: at))
        // A rename is not a use; the calls through the new name are.
        if !called { for skip in (equals + 1)..<value.next { skipped.insert(skip) } }
    }

    /// The parts between `open` and its `)` separated by top-level commas.
    private func segments(_ open: Int) -> [Range<Int>] {
        guard let close = closing(open) else { return [] }
        var result: [Range<Int>] = [], start = open + 1, depth = 0
        for at in (open + 1)..<close {
            let t = tokens[at]
            guard t.kind == .punct else { continue }
            if ["(", "[", "{"].contains(t.text) { depth += 1 } else if [")", "]", "}"].contains(t.text) { depth -= 1 }
            else if t.text == ",", depth == 0 { result.append(start..<at); start = at + 1 }
        }
        result.append(start..<close)
        return result.filter { !$0.isEmpty }
    }

    /// `(self, id, *, force=False, **kw)`; a method's `self` / `cls` is not passed by its callers.
    private func parameters(_ open: Int, method: Bool) -> CodeParameters {
        var list = CodeParameters(); list.python = true
        var keywordOnly = false
        for (offset, segment) in segments(open).enumerated() {
            let at = segment.lowerBound
            if offset == 0, method, let first = ident(at), first == "self" || first == "cls" { list.takesSelf = first == "self"; continue }
            if punct(at, "/") { continue }
            if punct(at, "*"), punct(at + 1, "*") { list.keywords = true; continue }
            if punct(at, "*") { if ident(at + 1) != nil { list.rest = true }; keywordOnly = true; continue }
            guard let name = ident(at) else { continue }
            let optional = (segment).contains { punct($0, "=") && !punct($0 + 1, "=") && !punct($0 - 1, "=") }
            if keywordOnly { list.keywordOnly.append(.init(name: name, optional: optional)) }
            else { list.positional.append(.init(name: name, optional: optional)) }
        }
        return list
    }

    private func arguments(_ open: Int) -> CallArguments {
        var call = CallArguments()
        for segment in segments(open) {
            let at = segment.lowerBound
            if punct(at, "*") { call.spread = true; continue }
            if let name = ident(at), punct(at + 1, "="), !punct(at + 2, "=") { call.keywords.append(name) } else { call.positional += 1 }
        }
        return call
    }

    private mutating func readUses() {
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            let current = tokens[index]
            guard current.isIdentifier, !skipped.contains(index), !declared.contains(index), !punct(index - 1, ".") else { continue }
            let word = current.text
            // super().method(…)
            if word == "super", punct(index + 1, "("), punct(index + 2, ")"), punct(index + 3, "."), let method = ident(index + 4) {
                if punct(index + 5, "(") {
                    outline.uses.append(.init(chain: ["super", method], line: current.line, token: index, kind: .call, arguments: arguments(index + 5)))
                }
                index += 4; continue
            }
            if SourceKeywords.python.contains(word) { continue }
            guard let chain = chainAt(index) else { continue }
            if punct(chain.next, "(") {
                outline.uses.append(.init(chain: chain.parts, line: current.line, token: index, kind: .call, arguments: arguments(chain.next)))
            } else if word != "self", word != "cls" {
                let next = chain.next
                // Keyword arguments and assignment targets are names, not uses: `callback=handler` keeps `handler`.
                if punct(next, "="), !punct(next + 1, "=") { index = chain.next - 1; continue }
                if punct(next, ":"), punct(index - 1, "{") || punct(index - 1, ",") { index = chain.next - 1; continue }
                outline.uses.append(.init(chain: chain.parts, line: current.line, token: index, kind: .reference))
            }
            index = chain.next - 1
        }
    }
}
