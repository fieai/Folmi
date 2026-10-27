import Foundation

/// A route a back end declares: `app.get('/x', h)`, `@Get(':id')` under `@Controller('orders')`, `@app.get("/x")`,
/// `@bp.route("/x", methods=["POST"])`, Django's `path("x/<int:id>/", view)`, a Next.js `route.ts` or `pages/api` file.
struct RouteDecl: Sendable, Equatable {
    /// Upper-case; empty: any method.
    let methods: [String]
    /// As written, with its prefix when the file gives one (`@Controller('orders')`, `APIRouter(prefix=…)`).
    let path: String
    let line: Int
    /// The function that handles it, when it is named (`h`, the decorated `def`, the Nest method).
    let handler: String?
    /// The route is mounted under a prefix this file does not show (`app.use('/api', router)`, `include_router`,
    /// Django `include`), so its full path may be longer.
    let prefixUnknown: Bool
}

/// A request the front end makes: `fetch('/api/x')`, `axios.post(url)`, `api.get('/x')`, `useSWR('/api/x')`.
struct RequestCall: Sendable, Equatable {
    /// Upper-case; nil when it cannot be told.
    let method: String?
    /// String pieces as written, with `*` for whatever is filled in at run time (`${id}`, `+ id`).
    let path: String
    let line: Int
    /// Made through a client object (`api.get`, `http.post`) that may put a base URL in front.
    var based = false
}

/// Finds routes and requests in a file's tokens. Patterns, like the outliners: the common ways AI-written code
/// declares routes and calls them.
struct EndpointScanner {
    let tokens: [SourceToken]
    let path: String
    let language: SourceLanguage
    /// Exported function names (Next.js `export async function GET`).
    let exportedFunctions: [(name: String, line: Int)]

    static let methods: Set<String> = ["get", "post", "put", "patch", "delete", "head", "options", "all"]
    static let clientCallees: Set<String> = ["fetch", "$fetch", "ofetch", "useFetch", "useSWR", "useSWRImmutable", "ky"]
    static let clientObjects: Set<String> = ["axios", "request", "http", "client", "api", "$http", "$axios", "ky", "instance", "service",
                                             "fetcher", "httpClient", "apiClient", "superagent", "got"]
    static let routeObjects: Set<String> = ["app", "router", "server", "route", "routes", "r", "fastify", "koa", "express", "apiRouter"]

    func scan() -> (routes: [RouteDecl], requests: [RequestCall]) {
        switch language {
        case .javaScript: return javaScript()
        case .python: return (python(), [])
        }
    }

    // MARK: Pieces

    /// The `(` of a call, past TypeScript type arguments: `request<Order[]>(` gives the index of its `(`.
    func callParen(after index: Int) -> Int? {
        guard index < tokens.count else { return nil }
        if tokens[index].is("(") { return index }
        guard tokens[index].is("<") else { return nil }
        var depth = 0, i = index
        while i < tokens.count, i < index + 40 {
            let token = tokens[i]
            if token.is("<") { depth += 1 } else if token.is(">") { depth -= 1; if depth == 0 { return tokens[safe: i + 1]?.is("(") == true ? i + 1 : nil } }
            else if token.is(";") || token.is("{") || token.is("=>") || token.is("(") { return nil }
            i += 1
        }
        return nil
    }

    /// Index of the `)` matching the `(` at `open`.
    func closing(_ open: Int) -> Int? {
        var depth = 0, i = open
        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .punct {
                if ["(", "[", "{"].contains(token.text) { depth += 1 }
                else if [")", "]", "}"].contains(token.text) { depth -= 1; if depth == 0 { return i } }
            }
            i += 1
        }
        return nil
    }

    /// The arguments between `(` at `open` and its `)`, split at top-level commas.
    func arguments(_ open: Int) -> [Range<Int>]? {
        guard let close = closing(open) else { return nil }
        var result: [Range<Int>] = [], start = open + 1, depth = 0
        for i in (open + 1)..<close {
            let token = tokens[i]
            guard token.kind == .punct else { continue }
            if ["(", "[", "{"].contains(token.text) { depth += 1 } else if [")", "]", "}"].contains(token.text) { depth -= 1 }
            else if token.text == ",", depth == 0 { result.append(start..<i); start = i + 1 }
        }
        if start < close { result.append(start..<close) }
        return result
    }

    /// A URL from an argument: its string pieces in order, `*` for anything else (`${id}`, `+ id`, `BASE +`).
    /// Nil when it holds no string, or the string does not look like a path.
    func url(_ range: Range<Int>) -> String? {
        var text = "", sawString = false, lastWasHole = false
        for i in range {
            let token = tokens[i]
            switch token.kind {
            case .string: text += token.text; sawString = true; lastWasHole = false
            case .punct where ["+", "(", ")", "`"].contains(token.text): continue
            default:
                if !lastWasHole { text += "*"; lastWasHole = true }
            }
        }
        guard sawString else { return nil }
        // A template's holes come as identifiers between its string pieces.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("*/") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return trimmed
    }

    /// `key: 'value'` (or `key='value'` in Python) inside an argument: the string.
    func option(_ key: String, in range: Range<Int>) -> String? {
        for i in range where tokens[i].isIdentifier && tokens[i].text == key && i + 2 < range.upperBound {
            if tokens[i + 1].is(":") || tokens[i + 1].is("=") {
                if tokens[i + 2].kind == .string { return tokens[i + 2].text }
            }
        }
        return nil
    }

    /// The argument range after `key:` (an object's `url: …`).
    func optionRange(_ key: String, in range: Range<Int>) -> Range<Int>? {
        for i in range where tokens[i].isIdentifier && tokens[i].text == key && i + 1 < range.upperBound && tokens[i + 1].is(":") {
            var end = i + 2, depth = 0
            while end < range.upperBound {
                let token = tokens[end]
                if token.kind == .punct {
                    if ["(", "[", "{"].contains(token.text) { depth += 1 }
                    else if [")", "]", "}"].contains(token.text) { if depth == 0 { break }; depth -= 1 }
                    else if token.text == ",", depth == 0 { break }
                }
                end += 1
            }
            return (i + 2)..<end
        }
        return nil
    }

    // MARK: JavaScript

    func javaScript() -> (routes: [RouteDecl], requests: [RequestCall]) {
        var routes: [RouteDecl] = [], requests: [RequestCall] = []
        routes += nextRoutes()
        var controllerPrefix: String?
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            // NestJS: @Controller('orders') then @Get(':id') on a method.
            if token.is("@"), i + 2 < tokens.count, tokens[i + 1].isIdentifier, tokens[i + 2].is("(") {
                let name = tokens[i + 1].text
                let args = arguments(i + 2) ?? []
                let literal = args.first.flatMap { range in range.count == 1 && tokens[range.lowerBound].kind == .string ? tokens[range.lowerBound].text : nil }
                if name == "Controller" {
                    controllerPrefix = literal ?? (args.isEmpty ? "" : nil)
                } else if Self.methods.contains(name.lowercased()), name.first?.isUppercase == true, let prefix = controllerPrefix {
                    let handler = decoratedMethod(after: closing(i + 2) ?? i)
                    routes.append(RouteDecl(methods: name == "All" ? [] : [name.uppercased()], path: Self.join(prefix, literal ?? ""),
                                            // app.setGlobalPrefix('api') lives in main.ts.
                                            line: token.line, handler: handler, prefixUnknown: true))
                }
            }
            guard token.isIdentifier, i + 1 < tokens.count else { i += 1; continue }
            // obj.method('/x', …): a route or a request, by who is called and what follows the path.
            if Self.methods.contains(token.text), i >= 2, tokens[i - 1].is(".") || tokens[i - 1].is("?."), let paren = callParen(after: i + 1),
               tokens[i - 2].isIdentifier, let args = arguments(paren), let first = args.first, let path = url(first) {
                let receiver = tokens[i - 2].text
                if isRoute(receiver: receiver, args: args) {
                    // The last argument names the handler (`show`, `orders.show`); an inline function has no name.
                    let last = args[args.count - 1]
                    let named = args.count > 1 && last.allSatisfy { tokens[$0].isIdentifier || tokens[$0].is(".") }
                    routes.append(RouteDecl(methods: token.text == "all" ? [] : [token.text.uppercased()], path: path, line: token.line,
                                            handler: named ? tokens[last.upperBound - 1].text : nil,
                                            // An Express router is mounted with app.use('/prefix', router) elsewhere.
                                            prefixUnknown: receiver != "app" && receiver != "server" && receiver != "fastify"))
                } else {
                    requests.append(RequestCall(method: token.text == "all" ? nil : token.text.uppercased(), path: path, line: token.line,
                                                based: receiver != "axios"))
                }
                i += 2; continue
            }
            // fetch('/x', { method: 'POST' }), useSWR('/x'), axios({ url, method }), request({ url }).
            if let paren = callParen(after: i + 1), i == 0 || !tokens[i - 1].is("."), let args = arguments(paren), let first = args.first {
                // fetch('/x'), and a project's own request('/x', { method }) (umi, openapi-generated clients).
                if Self.clientCallees.contains(token.text) || Self.clientObjects.contains(token.text), !tokens[first.lowerBound].is("{"),
                   let path = url(first) {
                    let method = args.count > 1 ? option("method", in: args[1]) : nil
                    requests.append(RequestCall(method: method?.uppercased() ?? (token.text.hasPrefix("use") ? "GET" : (args.count > 1 ? nil : "GET")),
                                                path: path, line: token.line, based: !Self.clientCallees.contains(token.text)))
                } else if Self.clientObjects.contains(token.text), tokens[first.lowerBound].is("{"),
                          let range = optionRange("url", in: first), let path = url(range) {
                    requests.append(RequestCall(method: option("method", in: first)?.uppercased() ?? "GET", path: path, line: token.line,
                                                based: token.text != "axios"))
                }
            }
            i += 1
        }
        return (routes, requests)
    }

    func isRoute(receiver: String, args: [Range<Int>]) -> Bool {
        if Self.routeObjects.contains(receiver) || receiver.hasSuffix("Router") || receiver.hasSuffix("router") { return args.count >= 2 }
        let lower = receiver.lowercased()
        if Self.clientObjects.contains(receiver) || ["api", "client", "http", "request", "service"].contains(where: { lower.hasSuffix($0) }) {
            return false
        }
        // Unknown object: a function after the path is a handler; data or options make it a request.
        guard args.count >= 2, let start = tokens[safe: args[1].lowerBound] else { return false }
        return start.is("(") || (start.isIdentifier && ["async", "function"].contains(start.text))
    }

    /// The method a decorator sits on: past further decorators and modifiers, the name before `(`.
    func decoratedMethod(after index: Int) -> String? {
        var i = index + 1
        while i < tokens.count {
            if tokens[i].is("@"), i + 2 < tokens.count, tokens[i + 2].is("("), let close = closing(i + 2) { i = close + 1; continue }
            if tokens[i].is("@") { i += 2; continue }
            if tokens[i].isIdentifier, ["async", "public", "private", "protected", "static", "readonly"].contains(tokens[i].text) { i += 1; continue }
            if tokens[i].isIdentifier, i + 1 < tokens.count, tokens[i + 1].is("(") || tokens[i + 1].is("<") { return tokens[i].text }
            return nil
        }
        return nil
    }

    /// Next.js: `app/**/route.ts` exports GET / POST…; `pages/api/**` handles every method in its default export.
    func nextRoutes() -> [RouteDecl] {
        let parts = path.split(separator: "/").map(String.init)
        let file = (path as NSString).lastPathComponent, stem = (file as NSString).deletingPathExtension
        if stem == "route", let app = parts.lastIndex(of: "app") {
            let segments = parts[(app + 1)..<(parts.count - 1)].filter { !($0.hasPrefix("(") && $0.hasSuffix(")")) && !$0.hasPrefix("@") }
            let route = "/" + segments.joined(separator: "/")
            return exportedFunctions.filter { ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains($0.name) }
                .map { RouteDecl(methods: [$0.name], path: route, line: $0.line, handler: $0.name, prefixUnknown: false) }
        }
        if let pages = parts.lastIndex(of: "pages"), pages + 1 < parts.count, parts[pages + 1] == "api" {
            var segments = Array(parts[(pages + 1)..<(parts.count - 1)]) + [stem]
            if stem == "index" { segments.removeLast() }
            return [RouteDecl(methods: [], path: "/" + segments.joined(separator: "/"), line: 1, handler: nil, prefixUnknown: false)]
        }
        return []
    }

    // MARK: Python

    func python() -> [RouteDecl] {
        var routes: [RouteDecl] = []
        // `router = APIRouter(prefix="/orders")`, `bp = Blueprint("x", __name__, url_prefix="/x")`.
        var prefixes: [String: String] = [:]
        for i in 0..<tokens.count where tokens[i].isIdentifier && ["APIRouter", "Blueprint"].contains(tokens[i].text)
            && i >= 2 && tokens[i - 1].is("=") && tokens[i - 2].isIdentifier && i + 1 < tokens.count && tokens[i + 1].is("(") {
            if let args = arguments(i + 1), let whole = args.first.map({ $0.lowerBound..<(args.last!.upperBound) }) {
                prefixes[tokens[i - 2].text] = option("prefix", in: whole) ?? option("url_prefix", in: whole) ?? ""
            }
        }
        let django = (path as NSString).lastPathComponent == "urls.py"
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            // @app.get("/x"), @router.post(...), @bp.route("/x", methods=["POST"]), @app.api_route(...)
            if token.is("@"), i + 4 < tokens.count, tokens[i + 1].isIdentifier, tokens[i + 2].is("."), tokens[i + 3].isIdentifier,
               tokens[i + 4].is("("), let args = arguments(i + 4), let first = args.first, let raw = url(first) {
                let object = tokens[i + 1].text, verb = tokens[i + 3].text.lowercased()
                var methods: [String]?
                if Self.methods.contains(verb) { methods = verb == "all" ? [] : [verb.uppercased()] }
                else if ["route", "api_route"].contains(verb) {
                    let listed = args.dropFirst().flatMap { range -> [String] in
                        guard let at = range.first(where: { tokens[$0].isIdentifier && tokens[$0].text == "methods" }) else { return [] }
                        return (at..<range.upperBound).filter { tokens[$0].kind == .string }.map { tokens[$0].text.uppercased() }
                    }
                    methods = listed.isEmpty ? (verb == "route" ? ["GET"] : []) : listed
                }
                if let methods {
                    let prefix = prefixes[object]
                    routes.append(RouteDecl(methods: methods, path: Self.join(prefix ?? "", raw), line: token.line,
                                            handler: decoratedFunction(after: closing(i + 4) ?? i),
                                            // A router's own prefix is known; where it is included is not.
                                            prefixUnknown: object != "app"))
                }
            }
            // Django: path("orders/<int:id>/", views.detail) in urls.py.
            if django, token.isIdentifier, token.text == "path", i + 1 < tokens.count, tokens[i + 1].is("("), i == 0 || !tokens[i - 1].is("."),
               let args = arguments(i + 1), args.count >= 2, args[0].count == 1, tokens[args[0].lowerBound].kind == .string {
                let view = args[1]
                let names = view.filter { tokens[$0].isIdentifier }.map { tokens[$0].text }
                if names.first != "include" {
                    let handler = names.last == "as_view" ? names.dropLast().last : names.last
                    routes.append(RouteDecl(methods: [], path: "/" + tokens[args[0].lowerBound].text, line: token.line, handler: handler,
                                            prefixUnknown: true))
                }
            }
            i += 1
        }
        return routes
    }

    func decoratedFunction(after index: Int) -> String? {
        var i = index + 1
        while i < tokens.count {
            if tokens[i].isIdentifier, tokens[i].text == "def", i + 1 < tokens.count, tokens[i + 1].isIdentifier { return tokens[i + 1].text }
            if tokens[i].isIdentifier, tokens[i].text == "class" { return nil }
            i += 1
        }
        return nil
    }

    static func join(_ prefix: String, _ path: String) -> String {
        let left = prefix.hasPrefix("/") || prefix.isEmpty ? prefix : "/" + prefix
        if path.isEmpty { return left.isEmpty ? "/" : left }
        let right = path.hasPrefix("/") ? path : "/" + path
        return left.hasSuffix("/") ? String(left.dropLast()) + right : left + right
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
