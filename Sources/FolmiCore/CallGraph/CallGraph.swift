import Foundation

/// One end of a call relation as the call map lists it: who calls (or is called), from which lines, how sure.
public struct CallLink: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case call, render, reference }
    /// The function at the other end; nil for an outside package's function.
    public let symbol: CodeSymbol?
    /// `react.useState`, `requests.get`: what an outside call names.
    public let external: String?
    /// Where the use is written (always in the caller's file) and on which lines.
    public let sitePath: String
    public let siteLines: [Int]
    /// False when the callee was matched only by method name (`obj.save()` with `obj` unknown).
    public let certain: Bool
    public let kinds: [Kind]
    public var id: String { (symbol?.id ?? "ext:" + (external ?? "")) + "|" + sitePath }
    public var title: String { symbol?.qualifiedName ?? external ?? "" }
}

/// Saved outlines keyed by path, so a rebuild reads only files whose size or date changed. Only a cache.
public struct CallGraphCache: Sendable {
    var entries: [String: (stamp: String, outline: FileOutline?)] = [:]
    var configs: [String: (stamp: String, data: Data)] = [:]
    public init() {}
}

/// Who calls whom in a project's JavaScript, TypeScript and Python, from reading the files (no type checker, no
/// language server). Names are followed through imports, re-exports, renames (`import { a as b }`, `const h = a`,
/// `from m import f as g`), path aliases and namespace objects.
public struct CallGraph: Sendable {
    public let symbols: [CodeSymbol]
    public let fileCount: Int
    /// Files left out: too large, or minified.
    public let skippedFiles: Int
    struct Edge: Sendable {
        let from: Int; let to: Int; let external: String?; let line: Int; let certain: Bool; let kind: CallLink.Kind; let path: String
        var arguments: CallArguments? = nil
    }
    let edges: [Edge]
    let outgoing: [[Int]]
    let incoming: [[Int]]
    /// Per file: each use's line, chain and what it resolved to, for finding the function under the cursor.
    let resolvedUses: [String: [(line: Int, chain: [String], target: Int)]]
    let symbolsByPath: [String: [Int]]
    /// Kept to link again with one file swapped for its earlier version (`removedImpacts`).
    let outlines: [String: FileOutline]
    let resolver: ModuleResolver?

    public static let empty = CallGraph(symbols: [], fileCount: 0, skippedFiles: 0, edges: [], outgoing: [], incoming: [], resolvedUses: [:],
                                        symbolsByPath: [:], outlines: [:], resolver: nil)

    public var isEmpty: Bool { symbols.isEmpty }

    public func index(of symbol: CodeSymbol) -> Int? {
        symbolsByPath[symbol.path]?.first { symbols[$0] == symbol }
    }

    /// Who calls `symbol`, one entry per calling function.
    public func callers(of symbol: CodeSymbol) -> [CallLink] {
        guard let index = index(of: symbol) else { return [] }
        return links(incoming[index].map { edges[$0] }, otherEnd: \.from)
    }

    /// What `symbol` calls, one entry per callee.
    public func callees(of symbol: CodeSymbol) -> [CallLink] {
        guard let index = index(of: symbol) else { return [] }
        return links(outgoing[index].map { edges[$0] }, otherEnd: \.to)
    }

    private func links(_ list: [Edge], otherEnd: KeyPath<Edge, Int>) -> [CallLink] {
        var order: [String] = []
        var grouped: [String: [Edge]] = [:]
        for edge in list {
            let key = edge[keyPath: otherEnd] >= 0 ? "s\(edge[keyPath: otherEnd])" : "e" + (edge.external ?? "")
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(edge)
        }
        return order.map { key in
            let group = grouped[key]!
            let first = group[0]
            let end = first[keyPath: otherEnd]
            var kinds: [CallLink.Kind] = []
            for edge in group where !kinds.contains(edge.kind) { kinds.append(edge.kind) }
            return CallLink(symbol: end >= 0 ? symbols[end] : nil, external: end >= 0 ? nil : first.external, sitePath: first.path,
                            siteLines: Array(Set(group.map(\.line))).sorted(), certain: group.contains(where: \.certain), kinds: kinds)
        }
        .sorted { a, b in
            if a.certain != b.certain { return a.certain }
            if (a.symbol == nil) != (b.symbol == nil) { return a.symbol != nil }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// The functions called from the most places.
    public func mostCalled(limit: Int) -> [(symbol: CodeSymbol, count: Int)] {
        Array(symbols.indices.filter { symbols[$0].kind != .module && !incoming[$0].isEmpty }
            .map { (symbols[$0], Set(incoming[$0].map { edges[$0].from }).count) }
            .sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// Functions whose name contains `query`; names starting with it first.
    public func search(_ query: String, limit: Int = 40) -> [CodeSymbol] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let found = symbols.filter { $0.kind != .module && $0.qualifiedName.lowercased().contains(needle) }
        return Array(found.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(needle), pb = b.name.lowercased().hasPrefix(needle)
            if pa != pb { return pa }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.path < b.path
        }.prefix(limit))
    }

    /// The function the cursor means: the one declared under it, the one the call under it resolves to, or the one
    /// the cursor sits in.
    public func symbol(path: String, line: Int, word: String?) -> CodeSymbol? {
        let inFile = (symbolsByPath[path] ?? []).map { symbols[$0] }
        if let word, !word.isEmpty {
            if let declared = inFile.first(where: { $0.name == word && $0.line == line }) { return declared }
            if let use = resolvedUses[path]?.first(where: { $0.line == line && $0.chain.contains(word) }) { return symbols[use.target] }
            if let declared = inFile.first(where: { $0.name == word && $0.kind != .module }) { return declared }
        }
        return inFile.filter { $0.kind != .module && $0.line <= line && line <= $0.endLine }.max { $0.line < $1.line }
    }

    public func moduleSymbol(path: String) -> CodeSymbol? {
        symbolsByPath[path]?.map { symbols[$0] }.first { $0.kind == .module }
    }

    // MARK: Building

    /// Reads `files` (paths relative to `root`) and links them. Unchanged files come from `cache`.
    public static func build(root: URL, files: [String], cache: CallGraphCache) -> (CallGraph, CallGraphCache) {
        var cache = cache
        let sources = files.filter { SourceLanguage.of(path: $0) != nil }
        let configPaths = files.filter(ModuleResolver.isConfig)
        let manager = FileManager.default
        func stamp(_ path: String) -> String? {
            guard let attributes = try? manager.attributesOfItem(atPath: root.appendingPathComponent(path).path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)-\(date)"
        }
        var configs: [String: Data] = [:]
        for path in configPaths {
            guard let current = stamp(path) else { continue }
            if let saved = cache.configs[path], saved.stamp == current { configs[path] = saved.data; continue }
            guard let data = try? Data(contentsOf: root.appendingPathComponent(path)), data.count < 1_000_000 else { continue }
            cache.configs[path] = (current, data); configs[path] = data
        }
        cache.configs = cache.configs.filter { configs[$0.key] != nil }

        let stamps = sources.map(stamp)
        let work = OutlineWork(count: sources.count)
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            guard let current = stamps[index] else { return }
            let path = sources[index]
            if let saved = cache.entries[path], saved.stamp == current { work.set(index, saved.outline, stamp: current); return }
            guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return }
            work.set(index, Self.shouldRead(data) ? FileOutline.read(path: path, data: data) : nil, stamp: current)
        }
        var outlines: [String: FileOutline] = [:]
        var skipped = 0
        var entries: [String: (stamp: String, outline: FileOutline?)] = [:]
        for (index, path) in sources.enumerated() {
            guard let result = work.results[index] else { continue }
            entries[path] = (result.stamp, result.outline)
            if let outline = result.outline { outlines[path] = outline } else { skipped += 1 }
        }
        cache.entries = entries
        let resolver = ModuleResolver(files: Set(sources), configs: configs)
        var linker = Linker(outlines: outlines, resolver: resolver)
        return (linker.link(fileCount: sources.count, skipped: skipped), cache)
    }

    /// Generated and minified files would bury the real code: over 1 MB, or long lines with almost no line breaks
    /// (bundler output such as `assets/index-BJT_3ywd.js` is often a single line of a few kilobytes).
    static func shouldRead(_ data: Data) -> Bool {
        guard data.count <= 1_000_000 else { return false }
        guard data.count > 500 else { return true }
        let newlines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        return data.count / max(newlines, 1) < 300
    }
}

private final class OutlineWork: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [(stamp: String, outline: FileOutline?)?]
    init(count: Int) { results = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ outline: FileOutline?, stamp: String) { lock.lock(); results[index] = (stamp, outline); lock.unlock() }
}

/// Resolves every use in every outline to a symbol, following names across files.
struct Linker {
    let outlines: [String: FileOutline]
    let resolver: ModuleResolver
    var symbols: [CodeSymbol] = []
    /// Symbol index of each file's top level, and of its definitions in outline order.
    var moduleSymbol: [String: Int] = [:]
    var definitionSymbols: [String: [Int]] = [:]
    /// Top-level functions and classes by name, per file; nested ones only where no top-level one has the name.
    var topLevel: [String: [String: Int]] = [:]
    /// Members of object literals: file → object → member → symbol.
    var objectMembers: [String: [String: [String: Int]]] = [:]
    var methods: [Int: [String: Int]] = [:]
    var bases: [Int: [Int]] = [:]
    var methodsByName: [String: [Int]] = [:]
    var bindingMemo: [String: Resolved?] = [:]
    /// Functions defined inside other functions, by file and name: outline offsets, with the body they are visible in.
    var nested: [String: [String: [(offset: Int, scope: ClosedRange<Int>)]]] = [:]
    /// Names declared more than once in a file (in different functions), to pick the declaration around a use.
    var repeatedAliases: [String: Set<String>] = [:]

    indirect enum Resolved: Equatable { case symbol(Int), instance(Int), module(String), object(String, String), external(String) }

    /// Method names too common to match by name alone.
    static let commonNames: Set<String> = ["get", "set", "map", "filter", "forEach", "push", "pop", "shift", "then", "catch", "finally",
        "call", "apply", "bind", "toString", "valueOf", "includes", "indexOf", "slice", "splice", "join", "split", "replace", "find",
        "some", "every", "reduce", "keys", "values", "entries", "has", "add", "delete", "clear", "send", "emit", "on", "off", "once",
        "log", "info", "warn", "error", "debug", "append", "extend", "update", "items", "copy", "format", "strip", "lower", "upper",
        "startswith", "endswith", "read", "write", "close", "open", "next", "json", "text", "trim", "concat", "sort", "test", "exec",
        "match", "length", "default", "remove", "insert", "pipe", "subscribe", "resolve", "reject", "all", "use", "run", "start", "stop",
        "init", "render", "setState", "dispatch", "fetch", "now", "parse", "stringify", "assign", "create", "save", "query", "execute",
        "first", "filter_by", "order_by", "commit", "flush", "refresh", "encode", "decode", "lstrip", "rstrip", "sleep", "wait"]

    init(outlines: [String: FileOutline], resolver: ModuleResolver) {
        self.outlines = outlines; self.resolver = resolver
        for path in outlines.keys.sorted() {
            let outline = outlines[path]!
            moduleSymbol[path] = symbols.count
            symbols.append(CodeSymbol(path: path, name: (path as NSString).lastPathComponent, container: nil, kind: .module, line: 1,
                                      endLine: max(outline.lineCount, 1)))
            var indices: [Int] = []
            for definition in outline.definitions { indices.append(symbols.count); symbols.append(definition.symbol) }
            definitionSymbols[path] = indices
            var nestedNames: [String: Int] = [:]
            var names: [String: Int] = [:]
            for (offset, definition) in outline.definitions.enumerated() {
                let symbol = definition.symbol
                let index = indices[offset]
                if symbol.kind == .method {
                    if let owner = outline.owningClass(of: offset), owner != offset {
                        methods[indices[owner], default: [:]][symbol.name] = methods[indices[owner]]?[symbol.name] ?? index
                        // Only class methods are guessed by name: object literal members (Vue `emits`, config
                        // tables) share names with everything.
                        methodsByName[symbol.name, default: []].append(index)
                    } else if let object = symbol.container {
                        objectMembers[path, default: [:]][object, default: [:]][symbol.name] = index
                    }
                } else if symbol.container == nil {
                    let nested = outline.definitions.indices.contains { other in
                        other != offset && outline.definitions[other].symbol.kind != .class && outline.definitions[other].body.contains(definition.body.lowerBound)
                            && outline.definitions[other].body.lowerBound < definition.body.lowerBound
                    }
                    if nested {
                        if nestedNames[symbol.name] == nil { nestedNames[symbol.name] = index }
                        if let parent = outline.enclosing(definition.body.lowerBound, excluding: offset) {
                            self.nested[path, default: [:]][symbol.name, default: []].append((offset, outline.definitions[parent].body))
                        }
                    }
                    else if names[symbol.name] == nil { names[symbol.name] = index }
                } else if let object = symbol.container {
                    objectMembers[path, default: [:]][object, default: [:]][symbol.name] = index
                }
            }
            topLevel[path] = nestedNames.merging(names) { _, top in top }
            var counts: [String: Int] = [:]
            for alias in outline.aliases { counts[alias.local, default: 0] += 1 }
            repeatedAliases[path] = Set(counts.filter { $0.value > 1 }.keys)
        }
    }

    mutating func link(fileCount: Int, skipped: Int) -> CallGraph {
        // Base classes, once all classes are known.
        for (path, outline) in outlines {
            for (offset, definition) in outline.definitions.enumerated() where definition.symbol.kind == .class {
                let index = definitionSymbols[path]![offset]
                bases[index] = definition.bases.compactMap { chain in
                    if case .symbol(let base)? = resolveChain(chain, in: path, enclosing: nil).resolved, symbols[base].kind == .class { return base }
                    return nil
                }
            }
        }
        var edges: [CallGraph.Edge] = []
        var seen: Set<String> = []
        var resolvedUses: [String: [(line: Int, chain: [String], target: Int)]] = [:]
        for path in outlines.keys.sorted() {
            let outline = outlines[path]!
            let enclosingUses = outline.enclosingDefinitions()
            for (useIndex, use) in outline.uses.enumerated() {
                let enclosing = enclosingUses[useIndex]
                let from = enclosing.map { definitionSymbols[path]![$0] } ?? moduleSymbol[path]!
                let (resolved, certain) = resolveChain(use.chain, in: path, enclosing: enclosing, token: use.token)
                var targets: [(Int, String?, Bool)] = []
                switch resolved {
                case .symbol(let index)?: targets = [(index, nil, certain)]
                case .instance(let index)?: if use.kind != .reference { targets = [(index, nil, certain)] }
                case .module(let module)?:
                    if use.kind != .reference, case .symbol(let index)? = resolveExport(module, "default", depth: 0) { targets = [(index, nil, certain)] }
                case .external(let name)?: if use.kind == .call { targets = [(-1, name, true)] }
                case .object?, nil:
                    if use.kind == .call, use.chain.count >= 2, let name = use.chain.last, !Self.commonNames.contains(name),
                       let candidates = methodsByName[name], candidates.count <= 3 {
                        targets = candidates.map { ($0, nil, false) }
                    }
                }
                for (to, external, sure) in targets {
                    if to == from { continue }
                    if use.kind == .reference, to >= 0, symbols[to].kind == .module { continue }
                    let key = "\(from)>\(to)>\(external ?? "")>\(use.line)>\(use.kind.rawValue)"
                    guard seen.insert(key).inserted else { continue }
                    let kind: CallLink.Kind = use.kind == .call ? .call : use.kind == .render ? .render : .reference
                    var arguments = use.kind == .call ? use.arguments : nil
                    // `Base.__init__(self, config)`: called on the class, the first argument is `self`.
                    if outline.language == .python, use.chain.count >= 2, to >= 0, symbols[to].kind == .method, arguments != nil,
                       case .symbol(let owner)? = resolveChain(Array(use.chain.dropLast()), in: path, enclosing: enclosing, token: use.token).resolved,
                       symbols[owner].kind == .class {
                        arguments!.positional -= 1
                        arguments!.unbound = true
                    }
                    edges.append(.init(from: from, to: to, external: external, line: use.line, certain: sure, kind: kind, path: path,
                                       arguments: arguments))
                    if to >= 0 { resolvedUses[path, default: []].append((use.line, use.chain, to)) }
                }
            }
        }
        var outgoing = Array(repeating: [Int](), count: symbols.count)
        var incoming = Array(repeating: [Int](), count: symbols.count)
        for (offset, edge) in edges.enumerated() {
            outgoing[edge.from].append(offset)
            if edge.to >= 0 { incoming[edge.to].append(offset) }
        }
        var byPath: [String: [Int]] = [:]
        for (index, symbol) in symbols.enumerated() { byPath[symbol.path, default: []].append(index) }
        return CallGraph(symbols: symbols, fileCount: fileCount, skippedFiles: skipped, edges: edges, outgoing: outgoing, incoming: incoming,
                         resolvedUses: resolvedUses, symbolsByPath: byPath, outlines: outlines, resolver: resolver)
    }

    // MARK: Resolution

    /// The binding of `name` as seen at `token`: a function nested in the function around it, or, for a name
    /// declared in several functions, the declaration around the use and nearest before it. Nil leaves it to
    /// `binding`.
    mutating func positionalBinding(_ name: String, in path: String, token: Int) -> Resolved? {
        guard let outline = outlines[path] else { return nil }
        if let candidates = nested[path]?[name],
           let visible = candidates.filter({ $0.scope.contains(token) }).max(by: { $0.scope.lowerBound < $1.scope.lowerBound }),
           let index = definitionSymbols[path]?[visible.offset] {
            return .symbol(index)
        }
        guard repeatedAliases[path]?.contains(name) == true else { return nil }
        let declared = outline.aliases.filter { $0.local == name }
        let scoped = declared.filter { alias in
            guard let scope = outline.enclosing(alias.token) else { return true }
            return outline.definitions[scope].body.contains(token)
        }
        guard let alias = (scoped.filter { $0.token < token }.max { $0.token < $1.token }) ?? scoped.first ?? declared.last else { return nil }
        var resolved = binding(alias.target[0], in: path, depth: 1)
        for segment in alias.target.dropFirst() { resolved = resolved.flatMap { member($0, segment, depth: 1) } }
        if alias.constructed {
            switch resolved {
            case .symbol(let index)? where symbols[index].kind == .class: resolved = .instance(index)
            case .instance?: break
            default: resolved = nil
            }
        }
        return resolved
    }

    mutating func resolveChain(_ chain: [String], in path: String, enclosing: Int?, token: Int? = nil) -> (resolved: Resolved?, certain: Bool) {
        guard let head = chain.first, let outline = outlines[path] else { return (nil, false) }
        var current: Resolved?
        switch head {
        case "this", "self", "cls":
            guard let owner = owningClass(path, enclosing) else { return (nil, false) }
            current = .instance(definitionSymbols[path]![owner])
        case "super":
            guard let owner = owningClass(path, enclosing), let base = bases[definitionSymbols[path]![owner]]?.first else { return (nil, false) }
            current = .instance(base)
        default:
            current = token.flatMap { positionalBinding(head, in: path, token: $0) } ?? binding(head, in: path, depth: 0)
        }
        for segment in chain.dropFirst() {
            guard let base = current else { break }
            current = member(base, segment, depth: 0)
        }
        return (current, true)
    }

    var owners: [String: Int?] = [:]
    mutating func owningClass(_ path: String, _ definition: Int?) -> Int? {
        guard let definition else { return nil }
        let key = "\(path)#\(definition)"
        if let known = owners[key] { return known }
        let owner = outlines[path]?.owningClass(of: definition)
        owners[key] = .some(owner)
        return owner
    }

    mutating func binding(_ name: String, in path: String, depth: Int) -> Resolved? {
        let key = path + "\u{0}" + name
        if let memo = bindingMemo[key] { return memo }
        guard depth < 12, let outline = outlines[path] else { return nil }
        bindingMemo[key] = .some(nil)  // a cycle resolves to nothing
        var result: Resolved?
        if let index = topLevel[path]?[name] { result = .symbol(index) }
        else if objectMembers[path]?[name] != nil { result = .object(path, name) }
        else if let alias = outline.aliases.last(where: { $0.local == name }) {
            if alias.target.first != name {
                var resolved = binding(alias.target[0], in: path, depth: depth + 1)
                for segment in alias.target.dropFirst() { resolved = resolved.flatMap { member($0, segment, depth: depth + 1) } }
                if alias.constructed {
                    switch resolved {
                    case .symbol(let index)? where symbols[index].kind == .class: resolved = .instance(index)
                    case .instance?: break
                    default: resolved = nil
                    }
                }
                result = resolved
            }
        } else if let entry = outline.imports.last(where: { $0.local == name }) {
            result = resolveImport(entry, from: path, depth: depth + 1)
        } else {
            for module in outline.starImports {
                if case .file(let file) = resolver.resolve(module, from: path, language: .python),
                   let found = resolveExport(file, name, depth: depth + 1) { result = found; break }
            }
        }
        bindingMemo[key] = .some(result)
        return result
    }

    mutating func resolveImport(_ entry: FileOutline.Import, from path: String, depth: Int) -> Resolved? {
        guard let outline = outlines[path] else { return nil }
        switch resolver.resolve(entry.module, from: path, language: outline.language) {
        case .external(let package):
            switch entry.imported {
            case .named(let name): return .external(package + "." + name)
            case .default, .namespace: return .external(package)
            }
        case .file(let file):
            switch entry.imported {
            case .namespace: return .module(file)
            case .default: return resolveExport(file, "default", depth: depth) ?? .module(file)
            case .named(let name): return resolveExport(file, name, depth: depth)
            }
        }
    }

    mutating func resolveExport(_ file: String, _ name: String, depth: Int) -> Resolved? {
        guard depth < 12 else { return nil }
        guard let outline = outlines[file] else {
            // A Python package folder without `__init__.py`: its submodules.
            if file.hasSuffix("__init__.py") { return submodule(file, name) }
            return nil
        }
        if outline.language == .python {
            return binding(name, in: file, depth: depth + 1) ?? (file.hasSuffix("__init__.py") ? submodule(file, name) : nil)
        }
        for entry in outline.exports where entry.exported == name {
            if let from = entry.from {
                guard case .file(let target) = resolver.resolve(from, from: file, language: .javaScript) else {
                    return .external(from + (entry.star ? "" : "." + (entry.local ?? name)))
                }
                if entry.star { return .module(target) }
                return resolveExport(target, entry.local ?? name, depth: depth + 1)
            }
            if let local = entry.local, let found = binding(local, in: file, depth: depth + 1) { return found }
        }
        if name == "default", objectMembers[file]?["default"] != nil { return .object(file, "default") }
        if name == "default", let index = topLevel[file]?["default"] { return .symbol(index) }
        for entry in outline.exports where entry.star && entry.exported == "*" {
            if let from = entry.from, case .file(let target) = resolver.resolve(from, from: file, language: .javaScript),
               let found = resolveExport(target, name, depth: depth + 1) { return found }
        }
        // A script with no exports at all (or CommonJS the patterns missed): its top-level names.
        if outline.exports.isEmpty { return binding(name, in: file, depth: depth + 1) }
        return nil
    }

    func submodule(_ initFile: String, _ name: String) -> Resolved? {
        let folder = (initFile as NSString).deletingLastPathComponent
        return resolver.pythonModule(ModuleResolver.join(folder, name)).map { .module($0) }
    }

    mutating func member(_ base: Resolved, _ name: String, depth: Int) -> Resolved? {
        switch base {
        case .module(let file): return resolveExport(file, name, depth: depth + 1)
        case .external(let package): return .external(package + "." + name)
        case .object(let file, let object): return objectMembers[file]?[object]?[name].map { .symbol($0) }
        case .symbol(let index), .instance(let index):
            guard symbols[index].kind == .class else { return nil }
            return classMember(index, name, depth: 0)
        }
    }

    /// A method of a class or its bases, or a member whose type is declared (`private svc: Service`, `self.repo = Repo()`).
    mutating func classMember(_ index: Int, _ name: String, depth: Int) -> Resolved? {
        guard depth < 6 else { return nil }
        if let method = methods[index]?[name] { return .symbol(method) }
        let symbol = symbols[index]
        if let type = outlines[symbol.path]?.memberTypes[symbol.name]?[name] {
            var resolved = binding(type[0], in: symbol.path, depth: 1)
            for segment in type.dropFirst() { resolved = resolved.flatMap { member($0, segment, depth: 1) } }
            if case .symbol(let typeIndex)? = resolved, symbols[typeIndex].kind == .class { return .instance(typeIndex) }
            return resolved
        }
        for base in bases[index] ?? [] { if let found = classMember(base, name, depth: depth + 1) { return found } }
        return nil
    }
}

extension GitRepository {
    /// Tracked and untracked-but-not-ignored files, the set the call map reads (`node_modules` and build output stay
    /// out through `.gitignore`).
    public func callMapFiles() async throws -> [String] {
        try runner().run(["ls-files", "-co", "--exclude-standard", "-z"], timeout: 30, stdoutLimit: 64 * 1_024 * 1_024).text
            .split(separator: "\0").map(String.init)
    }
}

/// What a change to one function reaches: how many places call it, from how many functions.
public struct CallImpact: Sendable, Equatable, Identifiable {
    public let symbol: CodeSymbol
    /// Call sites: every line that calls, renders or passes it.
    public let sites: Int
    public let callers: [String]
    /// Sites matched only by method name.
    public let uncertainSites: Int
    public var id: String { symbol.id }
}

extension CallGraph {
    /// The functions, methods and classes that hold `lines` (new-side line numbers) of `path`, innermost first
    /// within each, in file order. `gaps` are places where lines were only removed: they count when the lines on
    /// both sides sit in the same function, so deleting a whole function does not blame its neighbour. Top-level
    /// callbacks (`router.get("/x")`) are entry points nobody calls by name, and are left out.
    public func changedSymbols(path: String, lines: [Int], gaps: [Int] = []) -> [CodeSymbol] {
        let inFile = (symbolsByPath[path] ?? []).map { symbols[$0] }.filter { $0.kind != .module && !$0.name.contains("(") }
        func innermost(_ line: Int) -> CodeSymbol? {
            inFile.filter { $0.line <= line && line <= $0.endLine }.max { ($0.line, -$0.endLine) < ($1.line, -$1.endLine) }
        }
        var found: [CodeSymbol] = []
        for line in lines { if let symbol = innermost(line), !found.contains(symbol) { found.append(symbol) } }
        for gap in gaps {
            if let symbol = innermost(gap), innermost(gap - 1) == symbol, !found.contains(symbol) { found.append(symbol) }
        }
        return found.sorted { $0.line < $1.line }
    }

    public func impact(of symbol: CodeSymbol) -> CallImpact {
        let links = callers(of: symbol)
        return CallImpact(symbol: symbol, sites: links.reduce(0) { $0 + $1.siteLines.count },
                          callers: links.map(\.title),
                          uncertainSites: links.filter { !$0.certain }.reduce(0) { $0 + $1.siteLines.count })
    }
}

extension DiffHunk {
    /// New-side line numbers this hunk adds, and the new-side positions where it only removes lines (the line
    /// that now follows the removal).
    public var changedNewLines: (lines: [Int], gaps: [Int]) {
        guard let plus = header.range(of: #"\+(\d+)"#, options: .regularExpression),
              var line = Int(header[plus].dropFirst()) else { return ([], []) }
        var lines: [Int] = [], gaps: [Int] = []
        var removing = false
        for diffLine in self.lines {
            switch diffLine.kind {
            case .addition: lines.append(line); line += 1; removing = false
            case .deletion: if !removing { gaps.append(line) }; removing = true
            case .context: line += 1; removing = false
            case .meta: break
            }
        }
        return (lines, gaps)
    }
}

/// A function the change removed (deleted, or renamed: its old name is gone), and the places in other files that
/// still call it by that name. Those calls now point at nothing.
public struct RemovedCallImpact: Sendable, Equatable, Identifiable {
    public struct Site: Sendable, Equatable, Identifiable {
        public let path: String
        public let line: Int
        /// The function the call sits in.
        public let caller: String
        public let certain: Bool
        public var id: String { "\(path):\(line)" }
    }
    /// The function as it was, with its line in the earlier version.
    public let symbol: CodeSymbol
    /// The new name when the change looks like a rename: one function gone and one new in its place.
    public let renamedTo: String?
    public let sites: [Site]
    public var id: String { symbol.id }
}

extension CallGraph {
    /// Functions in `oldData` (the file at `oldPath` before the change) that the file at `path` no longer has, and
    /// who outside that file still calls them. The project is linked once more with the earlier version in place of
    /// the current one, so imports, renames and re-exports are followed as for any other call; callers that were
    /// already moved to a new name no longer reach the old one and drop out.
    public func removedImpacts(path: String?, oldPath: String, oldData: Data) -> [RemovedCallImpact] {
        guard let resolver, let old = FileOutline.read(path: oldPath, data: oldData) else { return [] }
        let current = path.flatMap { outlines[$0] }
        let now = Set(current?.definitions.map(\.symbol.qualifiedName) ?? [])
        let then = Set(old.definitions.map(\.symbol.qualifiedName))
        func counts(_ symbol: CodeSymbol) -> Bool { symbol.kind != .module && !symbol.name.contains("(") }
        let removed = old.definitions.map(\.symbol).filter { counts($0) && !now.contains($0.qualifiedName) }
        guard !removed.isEmpty else { return [] }
        // A rename: as many new functions as gone ones, in the same class, paired in file order.
        let added = (current?.definitions.map(\.symbol) ?? []).filter { counts($0) && !then.contains($0.qualifiedName) }
        var renames: [String: String] = [:]
        for container in Set(removed.map { $0.container ?? "" }) {
            let gone = removed.filter { ($0.container ?? "") == container }, new = added.filter { ($0.container ?? "") == container }
            if gone.count == new.count { for (a, b) in zip(gone, new) where a.kind == b.kind { renames[a.qualifiedName] = b.name } }
        }
        var swapped = outlines
        if let path, path != oldPath { swapped[path] = nil }
        swapped[oldPath] = old
        var linker = Linker(outlines: swapped, resolver: resolver.adding(oldPath))
        let before = linker.link(fileCount: fileCount, skipped: skippedFiles)
        return removed.compactMap { symbol in
            guard before.index(of: symbol) != nil else { return nil }
            let sites = before.callers(of: symbol).filter { $0.sitePath != oldPath && $0.sitePath != path }.flatMap { link in
                link.siteLines.map { RemovedCallImpact.Site(path: link.sitePath, line: $0, caller: link.title, certain: link.certain) }
            }
            return RemovedCallImpact(symbol: symbol, renamedTo: renames[symbol.qualifiedName], sites: sites)
        }
    }
}

/// A function whose parameters the change altered, and whether each call to it still fits the new list.
public struct SignatureImpact: Sendable, Equatable, Identifiable {
    public struct Site: Sendable, Equatable, Identifiable {
        public let path: String
        public let line: Int
        public let caller: String
        /// Why the call no longer fits (`少了 1 个参数（opts）`); nil when it fits.
        public let problem: String?
        public let certain: Bool
        public var id: String { "\(path):\(line)" }
    }
    public let symbol: CodeSymbol
    public let before: String
    public let after: String
    /// Calls that can be checked, fitting or not.
    public let sites: [Site]
    /// Calls with a spread (`f(...args)`, `f(*a, **k)`): the count cannot be told.
    public let unknown: Int
    public var broken: [Site] { sites.filter { $0.problem != nil } }
    public var id: String { symbol.id }
}

extension CallGraph {
    /// Functions in `path` whose parameters differ from the same function in `oldData` (the file before the
    /// change), with every current call checked against the new list. A changed `constructor` / `__init__` is
    /// checked against the calls that make the class (`new Order(…)`, `Order(…)`).
    public func signatureImpacts(path: String, oldData: Data, oldPath: String? = nil) -> [SignatureImpact] {
        guard let current = outlines[path], let old = FileOutline.read(path: oldPath ?? path, data: oldData) else { return [] }
        var result: [SignatureImpact] = []
        for definition in current.definitions {
            guard let after = definition.parameters, definition.symbol.kind != .module, !definition.symbol.name.contains("("),
                  let before = old.definitions.first(where: {
                      $0.symbol.qualifiedName == definition.symbol.qualifiedName && $0.symbol.kind == definition.symbol.kind
                  })?.parameters,
                  before.shape != after.shape,
                  let index = index(of: definition.symbol) else { continue }
            var targets = [index]
            if ["constructor", "__init__"].contains(definition.symbol.name), let owner = definition.symbol.container,
               let type = symbolsByPath[path]?.first(where: { symbols[$0].kind == .class && symbols[$0].name == owner }) {
                targets.append(type)
            }
            var sites: [SignatureImpact.Site] = [], unknown = 0
            var seen: Set<String> = []
            for target in targets {
                for edge in incoming[target].map({ edges[$0] }) where edge.kind == .call {
                    guard let arguments = edge.arguments, seen.insert("\(edge.path):\(edge.line)").inserted else { continue }
                    if arguments.spread { unknown += 1; continue }
                    let caller = symbols[edge.from]
                    sites.append(.init(path: edge.path, line: edge.line, caller: caller.kind == .module ? caller.name + " 顶层" : caller.qualifiedName,
                                       problem: after.problem(with: arguments), certain: edge.certain))
                }
            }
            sites.sort { ($0.problem == nil ? 1 : 0, $0.path, $0.line) < ($1.problem == nil ? 1 : 0, $1.path, $1.line) }
            result.append(SignatureImpact(symbol: definition.symbol, before: before.text, after: after.text, sites: sites, unknown: unknown))
        }
        return result
    }
}
