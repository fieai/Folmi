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

    func callers(_ arguments: [String: Any]) throws -> String {
        let graph = try callGraph(try repository(arguments))
        let target = try symbol(in: graph, arguments)
        let links = graph.callers(of: target)
        var object = describe(target)
        object["callers"] = links.map { link -> [String: Any] in
            ["function": link.symbol.map { $0.kind == .module ? "\($0.name) (top level)" : $0.qualifiedName } ?? link.title,
             "file": link.sitePath, "lines": link.siteLines, "certain": link.certain, "how": link.kinds.map(\.rawValue)]
        }
        if links.isEmpty { object["note"] = "No callers found. That does not prove nobody uses it: dynamic calls are not seen." }
        return try json(object)
    }

    func callees(_ arguments: [String: Any]) throws -> String {
        let graph = try callGraph(try repository(arguments))
        let target = try symbol(in: graph, arguments)
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
