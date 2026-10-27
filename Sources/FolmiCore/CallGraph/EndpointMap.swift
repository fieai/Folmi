import Foundation

/// A route the back end declares, with the front-end requests that reach it.
public struct Endpoint: Sendable, Hashable, Identifiable {
    /// The linked project it is in; nil for the open one.
    public let project: String?
    /// Upper-case methods; empty: any.
    public let methods: [String]
    /// As declared: `/api/orders/:id`, `/orders/{id}`, `orders/<int:id>/`.
    public let path: String
    public let file: String
    public let line: Int
    /// The function that handles it, when the call map knows it.
    public let handler: CodeSymbol?
    /// Mounted under a prefix its file does not show; matches go by the end of the path and count as 可能.
    public let prefixUnknown: Bool
    public var id: String { "\(project ?? "")|\(file):\(line)|\(methods.joined(separator: ","))|\(path)" }
    public var methodLabel: String { methods.isEmpty ? "ANY" : methods.joined(separator: "/") }
    public var title: String { "\(methodLabel) \(path)" }
}

/// One front-end request: where it is, which function makes it, and how sure the match to its endpoint is.
public struct EndpointUse: Sendable, Hashable, Identifiable {
    public let project: String?
    public let method: String?
    /// With `*` where the URL is filled in at run time.
    public let path: String
    public let file: String
    public let line: Int
    public let caller: String
    /// Matched path by path; false when only the end of the path matched (an unknown prefix or base URL).
    public let certain: Bool
    public var id: String { "\(project ?? "")|\(file):\(line)|\(method ?? "")|\(path)" }
}

/// Back-end routes paired with front-end requests by method and path, across the open project and linked ones.
public struct EndpointMap: Sendable {
    public let endpoints: [Endpoint]
    /// Requests per endpoint id.
    public let uses: [String: [EndpointUse]]
    /// Requests no route matched: a path the back end does not have, or one it declares in a way not recognized.
    public let unmatched: [EndpointUse]

    public static let empty = EndpointMap(endpoints: [], uses: [:], unmatched: [])
    public var isEmpty: Bool { endpoints.isEmpty && unmatched.isEmpty }

    public func uses(of endpoint: Endpoint) -> [EndpointUse] { uses[endpoint.id] ?? [] }

    /// Endpoints whose handler holds any of `lines` (or a removal at `gaps`) in `path` of the open project: what a
    /// change to a handler reaches on the front end.
    public func endpoints(changedIn path: String, lines: [Int], gaps: [Int] = []) -> [Endpoint] {
        endpoints.filter { endpoint in
            guard endpoint.project == nil, endpoint.file == path else { return false }
            let range = endpoint.handler.map { $0.path == path ? $0.line...max($0.endLine, $0.line) : endpoint.line...endpoint.line }
                ?? endpoint.line...endpoint.line
            return lines.contains(where: range.contains) || gaps.contains { range.contains($0) && range.contains($0 - 1) }
        }
    }

    /// Reads the routes and requests in each project's call map and pairs them. `project` names a linked one.
    public static func build(_ sources: [(project: String?, graph: CallGraph)]) -> EndpointMap {
        var endpoints: [Endpoint] = []
        var requests: [(use: EndpointUse, segments: [String], open: Bool, based: Bool)] = []
        for (project, graph) in sources {
            for (path, outline) in graph.outlines.sorted(by: { $0.key < $1.key }) {
                for route in outline.routes {
                    endpoints.append(Endpoint(project: project, methods: route.methods, path: route.path, file: path, line: route.line,
                                              handler: handler(route, in: path, graph: graph), prefixUnknown: route.prefixUnknown))
                }
                for request in outline.requests {
                    guard let (segments, open) = EndpointPath.segments(request.path) else { continue }
                    let caller = graph.changedSymbols(path: path, lines: [request.line]).last.map(\.qualifiedName)
                        ?? (path as NSString).lastPathComponent + " 顶层"
                    requests.append((EndpointUse(project: project, method: request.method, path: EndpointPath.display(request.path), file: path,
                                                 line: request.line, caller: caller, certain: true), segments, open, request.based))
                }
            }
        }
        let routeSegments = endpoints.map { EndpointPath.segments($0.path)?.segments ?? [] }
        var uses: [String: [EndpointUse]] = [:], unmatched: [EndpointUse] = []
        for request in requests {
            var exact: [Int] = [], partial: [(Int, Int)] = []
            for (index, endpoint) in endpoints.enumerated() {
                if let method = request.use.method, !endpoint.methods.isEmpty, !endpoint.methods.contains(method) { continue }
                switch EndpointPath.match(request.segments, open: request.open, based: request.based, route: routeSegments[index],
                                          prefixUnknown: endpoint.prefixUnknown) {
                case .exact: exact.append(index)
                case .suffix(let overlap): partial.append((index, overlap))
                case .none: continue
                }
            }
            // Path for path wins; otherwise the longest matching end, at most three candidates.
            let best = partial.map(\.1).max()
            let chosen = !exact.isEmpty ? exact.map { ($0, true) } : partial.filter { $0.1 == best }.prefix(3).map { ($0.0, false) }
            if chosen.isEmpty { unmatched.append(request.use); continue }
            for (index, sure) in chosen {
                let use = request.use
                uses[endpoints[index].id, default: []].append(EndpointUse(project: use.project, method: use.method, path: use.path, file: use.file,
                                                                          line: use.line, caller: use.caller, certain: sure && chosen.count == 1))
            }
        }
        return EndpointMap(endpoints: endpoints, uses: uses, unmatched: unmatched)
    }

    /// The handler's symbol: a named function the call map resolves at the route's line, the decorated function
    /// below it, or the inline callback the call map names after the route (`app.get("/x")`).
    static func handler(_ route: RouteDecl, in path: String, graph: CallGraph) -> CodeSymbol? {
        let inFile = (graph.symbolsByPath[path] ?? []).map { graph.symbols[$0] }.filter { $0.kind != .module }
        if let name = route.handler {
            if let resolved = graph.symbol(path: path, line: route.line, word: name), resolved.name == name { return resolved }
            return inFile.filter { $0.name == name && $0.line >= route.line }.min { $0.line < $1.line }
                ?? inFile.first { $0.name == name }
        }
        return inFile.first { $0.line == route.line && $0.name.contains("(") }
    }
}

/// Paths reduced to segments for matching: parameters in any framework's spelling, and URL pieces filled in at run
/// time, become `*`.
enum EndpointPath {
    enum Match: Equatable { case exact, suffix(Int), none }

    /// Segments, and whether the path starts with a run-time piece (`${BASE}/orders`). Nil for an empty or
    /// all-unknown path.
    static func segments(_ raw: String) -> (segments: [String], open: Bool)? {
        var text = raw
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            text = text.firstIndex(of: "/").map { String(text[$0...]) } ?? "/"
        }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        let open = text.hasPrefix("*")
        let parts = text.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let segments = parts.enumerated().compactMap { index, part -> String? in
            if index == 0 && open && part == "*" { return nil }
            let parameter = part.hasPrefix(":") || part.contains("{") || part.contains("<") || (part.hasPrefix("[") && part.hasSuffix("]"))
                || part.contains("*")
            return parameter ? "*" : part
        }
        guard segments.contains(where: { $0 != "*" }) else { return nil }
        return (segments, open)
    }

    /// `open`: the request starts with a run-time piece; `based`: its client may add a base URL; `prefixUnknown`:
    /// the route is mounted under a prefix declared elsewhere. Path for path is exact only without any of those
    /// unknowns; otherwise one path ending as the other does is a `suffix` match (可能), scored by the literal segments
    /// that agree.
    static func match(_ request: [String], open: Bool, based: Bool, route: [String], prefixUnknown: Bool) -> Match {
        func same(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0 == $1 || $0 == "*" || $1 == "*" }
        }
        guard !route.isEmpty, !request.isEmpty else { return .none }
        if !open, !prefixUnknown, same(request[...], route[...]) { return .exact }
        let shorter = min(request.count, route.count)
        // Agreeing on parameters alone (`/items` against `/users/{id}`) says nothing: a literal segment must match.
        let literal = zip(request.suffix(shorter), route.suffix(shorter)).filter { $0 == $1 && $0 != "*" }.count
        guard same(request.suffix(shorter), route.suffix(shorter)), literal > 0 else { return .none }
        // The request is missing a front part: only a base URL can supply it. The route is: only a mount prefix.
        if request.count < route.count, !(open || based) { return .none }
        if request.count > route.count, !prefixUnknown { return .none }
        if request.count == route.count, !(open || prefixUnknown) { return .none }
        return .suffix(literal)
    }

    /// A request's path for showing: `*` pieces as `…`.
    static func display(_ raw: String) -> String { raw.replacingOccurrences(of: "*", with: "…") }
}
