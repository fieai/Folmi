import Foundation

/// The call map over MCP: the same reading as 调用关系 and 影响 in the app, for the agent to check before and after
/// it changes a function.
extension MCPServer {
    /// Past this many source files one tool call would keep the agent waiting too long.
    static let callMapFileLimit = 20_000
    /// change_impact links the project once per file; past these the rest is listed as not checked.
    static let impactFileLimit = 20
    static let impactBudget: TimeInterval = 30
    static let siteLimit = 30

    func callGraph(_ repo: (root: URL, gitDir: URL)) throws -> CallGraph {
        let files = try GitProcess(directory: repo.root, environment: [:])
            .run(["ls-files", "-co", "--exclude-standard", "-z"], timeout: 30, stdoutLimit: 64 * 1_024 * 1_024).text
            .split(separator: "\0").map(String.init)
        let sources = files.filter { SourceLanguage.of(path: $0) != nil }.count
        guard sources > 0 else { throw Failure(message: "No JavaScript, TypeScript or Python files: the call map reads only those.") }
        guard sources <= Self.callMapFileLimit else {
            throw Failure(message: "\(sources) source files: too many to read for one call (the limit is \(Self.callMapFileLimit)).")
        }
        if callCacheRoot != repo.root.path { callCache = CallGraphCache(); callCacheRoot = repo.root.path }
        let (graph, cache) = CallGraph.build(root: repo.root, files: files, cache: callCache)
        callCache = cache
        return graph
    }

    /// The function the arguments name; several with that name need `file` to tell them apart.
    func symbol(in graph: CallGraph, _ arguments: [String: Any]) throws -> CodeSymbol {
        guard let name = (arguments["function"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw Failure(message: "`function` is required.")
        }
        let file = (arguments["file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let found = graph.symbols.filter {
            $0.kind != .module && ($0.qualifiedName == name || $0.name == name) && (file == nil || $0.path == file)
        }
        if found.count == 1 { return found[0] }
        if found.isEmpty {
            // A misspelt name (`getOrdr`) still finds its function by the first two thirds.
            var near = graph.search(name, limit: 5).filter { $0.kind != .module }
            if near.isEmpty { near = graph.search(String(name.prefix(max(3, name.count * 2 / 3))), limit: 5).filter { $0.kind != .module } }
            let similar = near.map { "\($0.qualifiedName) (\($0.path):\($0.line))" }
            throw Failure(message: "No function named \(name)\(file.map { " in \($0)" } ?? "")."
                          + (similar.isEmpty ? "" : " Similar: " + similar.joined(separator: ", ")))
        }
        throw Failure(message: "Several functions are named \(name); pass `file`: "
                      + found.map { "\($0.qualifiedName) (\($0.path):\($0.line))" }.joined(separator: ", "))
    }

    private func describe(_ symbol: CodeSymbol) -> [String: Any] {
        ["function": symbol.qualifiedName, "file": symbol.path, "line": symbol.line, "kind": symbol.kind.rawValue]
    }

    /// Other languages go to CodeGraph when the user has it and has indexed the project: a `file` the call map does
    /// not read, or a name it does not know.
    func ownOrCodeGraph(_ direction: CodeGraphTool.Direction, _ arguments: [String: Any],
                        own: (CallGraph, CodeSymbol) throws -> String) throws -> String {
        let repo = try repository(arguments)
        let file = (arguments["file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let indexed = CodeGraphTool.isIndexed(repo.root)
        if indexed, let file, SourceLanguage.of(path: file) == nil { return try codeGraph(direction, arguments, repo: repo) }
        do {
            let graph = try callGraph(repo)
            return try own(graph, try symbol(in: graph, arguments))
        } catch where indexed {
            guard let answer = try? codeGraph(direction, arguments, repo: repo) else { throw error }
            return answer
        }
    }

    func codeGraph(_ direction: CodeGraphTool.Direction, _ arguments: [String: Any], repo: (root: URL, gitDir: URL)) throws -> String {
        guard let name = (arguments["function"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw Failure(message: "`function` is required.")
        }
        guard let executable = locateCodeGraph() else { throw Failure(message: "The project has a CodeGraph index, but no `codegraph` command was found.") }
        guard let calls = try CodeGraphTool.calls(direction, of: name, file: arguments["file"] as? String, root: repo.root, executable: executable) else {
            throw Failure(message: "No function named \(name) in Folmi's call map or in CodeGraph.")
        }
        func row(_ node: CodeGraphTool.Node) -> [String: Any] {
            ["function": node.name, "kind": node.kind, "file": node.path, "line": node.line, "how": node.relationships]
        }
        var object = row(calls.target)
        object["source"] = "CodeGraph (its own index; lines are where each function is defined)"
        object[direction.rawValue] = (calls.callers ?? calls.callees ?? []).map(row)
        if calls.ambiguous { object["note"] = "Several definitions share the name; the list is all of them together. Pass `file` to pick one." }
        if calls.truncated { object["truncated"] = true }
        return try json(object)
    }

    func callers(_ arguments: [String: Any]) throws -> String {
        try ownOrCodeGraph(.callers, arguments) { graph, target in try self.ownCallers(graph, target) }
    }

    func callees(_ arguments: [String: Any]) throws -> String {
        try ownOrCodeGraph(.callees, arguments) { graph, target in try self.ownCallees(graph, target) }
    }

    private func ownCallers(_ graph: CallGraph, _ target: CodeSymbol) throws -> String {
        let links = graph.callers(of: target)
        var object = describe(target)
        object["callers"] = links.map { link -> [String: Any] in
            ["function": link.symbol.map { $0.kind == .module ? "\($0.name) (top level)" : $0.qualifiedName } ?? link.title,
             "file": link.sitePath, "lines": link.siteLines, "certain": link.certain, "how": link.kinds.map(\.rawValue)]
        }
        if links.isEmpty { object["note"] = "No callers found. That does not prove nobody uses it: dynamic calls are not seen." }
        return try json(object)
    }

    private func ownCallees(_ graph: CallGraph, _ target: CodeSymbol) throws -> String {
        var object = describe(target)
        object["calls"] = graph.callees(of: target).map { link -> [String: Any] in
            var row: [String: Any] = ["function": link.title, "lines": link.siteLines, "certain": link.certain,
                                      "how": link.kinds.map(\.rawValue)]
            if let symbol = link.symbol { row["definedIn"] = "\(symbol.path):\(symbol.line)" } else { row["external"] = true }
            return row
        }
        return try json(object)
    }

    func changeImpact(_ arguments: [String: Any]) throws -> String {
        let repo = try repository(arguments)
        let git = GitProcess(directory: repo.root, environment: [:])
        guard (try? git.run(["rev-parse", "--verify", "-q", "HEAD"])) != nil else {
            throw Failure(message: "No commits yet: there is nothing to compare the changes with.")
        }
        var changed = try git.run(["diff", "--name-only", "-z", "--no-renames", "HEAD"]).text.split(separator: "\0").map(String.init)
            .filter { SourceLanguage.of(path: $0) != nil }
        if let only = arguments["paths"] as? [String] { changed = changed.filter { only.contains($0) } }
        guard !changed.isEmpty else { return try json(["repository": repo.root.path, "comparedWith": "HEAD", "files": [],
                                                      "summary": "No changed JavaScript, TypeScript or Python files."]) }
        let graph = try callGraph(repo)
        let endpointMap = EndpointMap.build([(nil, graph)])
        let start = now()
        var files: [[String: Any]] = [], unchecked: [String] = []
        var broken = 0, misfits = 0
        for path in changed {
            guard files.count < Self.impactFileLimit, now().timeIntervalSince(start) < Self.impactBudget else { unchecked.append(path); continue }
            let exists = FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(path).path)
            // A file still there but too large or minified to read would look as if all its functions were gone.
            if exists, graph.outlines[path] == nil { unchecked.append(path); continue }
            let old = try? git.run(["show", "HEAD:" + path], stdoutLimit: 1_000_000).stdout
            var row: [String: Any] = ["file": path]
            if !exists { row["deleted"] = true }
            if let old {
                let removed = graph.removedImpacts(path: exists ? path : nil, oldPath: path, oldData: old).filter { !$0.sites.isEmpty }
                broken += removed.reduce(0) { $0 + $1.sites.filter(\.certain).count }
                if !removed.isEmpty {
                    row["removedButStillCalled"] = removed.map { item -> [String: Any] in
                        var entry: [String: Any] = ["function": item.symbol.qualifiedName,
                                                    "stillCalledFrom": item.sites.prefix(Self.siteLimit).map {
                                                        ["file": $0.path, "line": $0.line, "caller": $0.caller, "certain": $0.certain]
                                                    }]
                        if let renamed = item.renamedTo { entry["renamedTo"] = renamed }
                        return entry
                    }
                }
                if exists {
                    let signatures = graph.signatureImpacts(path: path, oldData: old)
                    misfits += signatures.reduce(0) { $0 + $1.broken.filter(\.certain).count }
                    if !signatures.isEmpty {
                        row["parameterChanges"] = signatures.map { item -> [String: Any] in
                            var entry: [String: Any] = ["function": item.symbol.qualifiedName, "before": item.before, "after": item.after,
                                                        "callsThatDoNotFit": item.broken.prefix(Self.siteLimit).map {
                                                            ["file": $0.path, "line": $0.line, "caller": $0.caller,
                                                             "problem": $0.problem ?? "", "certain": $0.certain]
                                                        },
                                                        "callsThatFit": item.sites.count - item.broken.count]
                            if item.unknown > 0 { entry["spreadCallsNotChecked"] = item.unknown }
                            return entry
                        }
                    }
                }
            }
            if exists {
                let diff = try git.run(["diff", "-U0", "--no-color", "--no-ext-diff", "HEAD", "--", path]).text
                let (lines, gaps) = Self.newSideChanges(diff)
                let symbols = graph.changedSymbols(path: path, lines: lines, gaps: gaps)
                let endpoints = endpointMap.endpoints(changedIn: path, lines: lines, gaps: gaps)
                if !endpoints.isEmpty {
                    row["changedEndpoints"] = endpoints.map { endpoint -> [String: Any] in
                        ["endpoint": endpoint.title, "line": endpoint.line,
                         "calledFromFrontEnd": endpointMap.uses(of: endpoint).prefix(Self.siteLimit).map {
                             ["function": $0.caller, "file": $0.file, "line": $0.line, "request": "\($0.method ?? "?") \($0.path)", "certain": $0.certain]
                         }]
                    }
                }
                if !symbols.isEmpty {
                    row["changedFunctions"] = symbols.map { symbol -> [String: Any] in
                        let links = graph.callers(of: symbol)
                        return ["function": symbol.qualifiedName, "line": symbol.line,
                                "calledFrom": links.prefix(Self.siteLimit).map {
                                    ["function": $0.title, "file": $0.sitePath, "lines": $0.siteLines, "certain": $0.certain]
                                }]
                    }
                }
            }
            files.append(row)
        }
        var object: [String: Any] = ["repository": repo.root.path, "comparedWith": "HEAD (staged and not staged together)", "files": files]
        if !unchecked.isEmpty { object["notChecked"] = unchecked }
        object["summary"] = broken + misfits == 0
            ? "No call is left pointing at a removed function or passing arguments that do not fit."
            : "\(broken) call(s) still use a removed or renamed name; \(misfits) call(s) do not fit changed parameters. Fix them, or tell the user why they are fine."
        return try json(object)
    }

    func endpoints(_ arguments: [String: Any]) throws -> String {
        let map = EndpointMap.build([(nil, try callGraph(try repository(arguments)))])
        let filter = (arguments["filter"] as? String)?.lowercased() ?? ""
        let shown = map.endpoints.filter { filter.isEmpty || $0.title.lowercased().contains(filter) }
        func use(_ use: EndpointUse) -> [String: Any] {
            ["request": "\(use.method ?? "?") \(use.path)", "function": use.caller, "file": use.file, "line": use.line, "certain": use.certain]
        }
        return try json([
            "endpoints": shown.prefix(200).map { endpoint -> [String: Any] in
                var row: [String: Any] = ["endpoint": endpoint.title, "file": endpoint.file, "line": endpoint.line,
                                          "calledFrom": map.uses(of: endpoint).prefix(Self.siteLimit).map(use)]
                if let handler = endpoint.handler { row["handler"] = handler.qualifiedName }
                if endpoint.prefixUnknown { row["mountedUnderUnknownPrefix"] = true }
                return row
            },
            "requestsWithNoRoute": filter.isEmpty ? map.unmatched.prefix(100).map(use) : [],
        ])
    }

    /// From `git diff -U0`: the new-side lines each hunk adds, and where a hunk only removes (the line after it).
    static func newSideChanges(_ diff: String) -> (lines: [Int], gaps: [Int]) {
        var lines: [Int] = [], gaps: [Int] = []
        for header in diff.split(separator: "\n") where header.hasPrefix("@@") {
            guard let match = header.firstMatch(of: /\+(\d+)(?:,(\d+))?/), let start = Int(match.1) else { continue }
            let count = match.2.flatMap { Int($0) } ?? 1
            if count > 0 { lines += Array(start..<(start + count)) } else { gaps.append(start + 1) }
        }
        return (lines, gaps)
    }
}
