import XCTest
@testable import FolmiCore

/// The call map on a small front-end + back-end project: names followed through renames, re-exports, path aliases,
/// CommonJS, namespace imports, `this` / `self` member types, and Python packages.
final class CallGraphTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-calls-" + UUID().uuidString, isDirectory: true)
        let files: [String: String] = [
            "web/tsconfig.json": """
            {
              // path aliases
              "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["src/*"], }, },
            }
            """,
            "web/package.json": #"{ "name": "web" }"#,
            "web/src/lib/http.ts": """
            /** request(url) is documented here, not called */
            export function http(url: string): Promise<Response> {
              const note = "http(not a call)"
              return fetch(url)
            }
            """,
            "web/src/api/orders.ts": """
            import { http as request } from '@/lib/http'
            export async function getOrder(id: string) {
              return request(`/api/orders/${encodeURIComponent(id)}`)
            }
            export const listOrders = async (): Promise<Order[]> => request('/api/orders')
            """,
            "web/src/api/index.ts": """
            export * from './orders'
            export { getOrder as fetchOrder } from './orders'
            """,
            "web/src/components/OrderSummary.jsx": """
            export default function OrderSummary({ id }) { return null }
            """,
            "web/src/pages/OrderPage.tsx": """
            import * as api from '../api'
            import { fetchOrder } from '@/api'
            import Summary from '@/components/OrderSummary'
            import { useEffect, useCallback } from 'react'
            const load = api.getOrder
            export default function OrderPage({ id }) {
              useEffect(() => { load(id) }, [id])
              const refresh = () => fetchOrder(id)
              const reload = useCallback(async () => { await refresh() }, [])
              return <div onClick={refresh} onDoubleClick={reload}><Summary id={id} /></div>
            }
            """,
            "web/src/services/orderService.ts": """
            import { http } from '../lib/http'
            export class OrderRepo {
              find(id: string) { return http('/orders/' + id) }
            }
            export class OrderService {
              constructor(private readonly repo: OrderRepo) {}
              async load(id: string) { return this.repo.find(id) }
            }
            export class CachedService extends OrderService {
              async load(id: string) { return super.load(id) }
            }
            const svc = new OrderService(new OrderRepo())
            export const boot = () => svc.load('1')
            """,
            "server/util.js": """
            function slugify(s) { return s.toLowerCase() }
            module.exports = { slugify, toSlug: slugify }
            """,
            "server/app.js": """
            const { toSlug } = require('./util')
            const util = require('./util')
            function handler(req) {
              util.slugify(req.path)
              return toSlug(req.path)
            }
            app.get('/x', handler)
            app.post('/orders/:id', async (req, res) => { res.json(toSlug(req.params.id)) })
            """,
            "backend/app/models.py": """
            class Order:
                pass
            """,
            "backend/app/db.py": """
            def get_session():
                return None
            """,
            "backend/app/services/orders.py": """
            from ..db import get_session as open_session
            from app.models import Order as OrderModel


            class OrderRepo:
                def find(self, id):
                    '''find(id) in a docstring is not a call'''
                    session = open_session()
                    return OrderModel()


            class OrderService:
                def __init__(self, repo: OrderRepo):
                    self.repo = repo

                def load(self, id):
                    return self.repo.find(id)


            def make_service():
                return OrderService(OrderRepo())
            """,
            "backend/app/api.py": """
            import app.services.orders as orders_mod
            from .services.orders import make_service
            from .services import orders
            build = make_service


            def get_order(id):
                svc = build()
                orders_mod.make_service()
                return orders.OrderService(None)
            """,
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func graph() throws -> CallGraph {
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter {
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &folder) && !folder.boolValue
        }
        return CallGraph.build(root: root, files: files, cache: CallGraphCache()).0
    }

    private func symbol(_ graph: CallGraph, _ name: String, in path: String) throws -> CodeSymbol {
        try XCTUnwrap(graph.symbols.first { $0.qualifiedName == name && $0.path == path }, "\(name) in \(path)")
    }

    private func titles(_ links: [CallLink]) -> Set<String> { Set(links.map(\.title)) }

    func testJavaScriptAliasesReExportsAndPathAliases() throws {
        let graph = try graph()
        let http = try symbol(graph, "http", in: "web/src/lib/http.ts")
        // `import { http as request }` through the `@/` path alias; the comment and string mentions are not calls.
        XCTAssertEqual(titles(graph.callers(of: http)), ["getOrder", "listOrders", "OrderRepo.find"])
        XCTAssertEqual(graph.callers(of: http).first { $0.title == "getOrder" }?.siteLines, [3])
        XCTAssertEqual(titles(graph.callees(of: http)), [], "globals such as fetch are left out")

        let getOrder = try symbol(graph, "getOrder", in: "web/src/api/orders.ts")
        // `const load = api.getOrder` (namespace import of a barrel with `export *`) and `fetchOrder`
        // (`export { getOrder as fetchOrder }` through `@/api`).
        XCTAssertEqual(titles(graph.callers(of: getOrder)), ["OrderPage", "refresh"])

        let page = try symbol(graph, "OrderPage", in: "web/src/pages/OrderPage.tsx")
        let downstream = graph.callees(of: page)
        XCTAssertTrue(titles(downstream).isSuperset(of: ["getOrder", "refresh", "OrderSummary", "react.useEffect"]), "\(titles(downstream))")
        XCTAssertEqual(downstream.first { $0.title == "OrderSummary" }?.kinds, [.render])
        XCTAssertEqual(downstream.first { $0.title == "refresh" }?.kinds, [.reference])
        let refresh = try symbol(graph, "refresh", in: "web/src/pages/OrderPage.tsx")
        XCTAssertEqual(titles(graph.callers(of: refresh)), ["OrderPage", "reload"], "useCallback wrapped, named after its variable")

        // The cursor on `load(id)` means getOrder.
        XCTAssertEqual(graph.symbol(path: "web/src/pages/OrderPage.tsx", line: 7, word: "load"), getOrder)
        XCTAssertEqual(graph.symbol(path: "web/src/api/orders.ts", line: 3, word: nil), getOrder)
    }

    func testMembersThroughThisSuperAndTypedParameters() throws {
        let graph = try graph()
        let path = "web/src/services/orderService.ts"
        let find = try symbol(graph, "OrderRepo.find", in: path)
        XCTAssertEqual(titles(graph.callers(of: find)), ["OrderService.load"], "constructor(private readonly repo: OrderRepo)")
        let load = try symbol(graph, "OrderService.load", in: path)
        XCTAssertEqual(titles(graph.callers(of: load)), ["CachedService.load", "boot"], "super.load and const svc = new OrderService()")
        XCTAssertTrue(titles(graph.callees(of: try symbol(graph, "orderService.ts", in: path))).isSuperset(of: ["OrderService", "OrderRepo"]))
    }

    func testCommonJSAndRouteCallbacks() throws {
        let graph = try graph()
        let slugify = try symbol(graph, "slugify", in: "server/util.js")
        XCTAssertEqual(titles(graph.callers(of: slugify)), ["handler", "app.post(\"/orders/:id\")"])
        let handler = try symbol(graph, "handler", in: "server/app.js")
        XCTAssertEqual(graph.callers(of: handler).map(\.title), ["app.js"])
        XCTAssertEqual(graph.callers(of: handler).first?.kinds, [.reference])
    }

    func testPythonImportsAliasesAndSelfMembers() throws {
        let graph = try graph()
        let path = "backend/app/services/orders.py"
        let find = try symbol(graph, "OrderRepo.find", in: path)
        XCTAssertEqual(titles(graph.callers(of: find)), ["OrderService.load"], "self.repo = repo with repo: OrderRepo")
        XCTAssertEqual(titles(graph.callees(of: find)), ["get_session", "Order"], "renamed imports; the docstring is not a call")
        let make = try symbol(graph, "make_service", in: path)
        XCTAssertEqual(titles(graph.callers(of: make)), ["get_order"], "build = make_service, import … as orders_mod")
        let api = try symbol(graph, "get_order", in: "backend/app/api.py")
        XCTAssertTrue(titles(graph.callees(of: api)).contains("OrderService"), "from .services import orders; orders.OrderService")
        XCTAssertEqual(graph.search("order").first?.name, "Order")
    }

    func testChangedLinesNameTheFunctionsAndTheirCallers() throws {
        let graph = try graph()
        let path = "web/src/services/orderService.ts"
        // Lines 3 and 7: inside OrderRepo.find and OrderService.load; line 12 is a top-level statement.
        let changed = graph.changedSymbols(path: path, lines: [3, 7, 12])
        XCTAssertEqual(changed.map(\.qualifiedName), ["OrderRepo.find", "OrderService.load"])
        XCTAssertEqual(graph.impact(of: changed[1]).sites, 2)
        XCTAssertEqual(Set(graph.impact(of: changed[1]).callers), ["CachedService.load", "boot"])
        // A removal between two functions blames neither; one inside a function blames it.
        XCTAssertEqual(graph.changedSymbols(path: path, lines: [], gaps: [5]).map(\.qualifiedName), [])
        XCTAssertEqual(graph.changedSymbols(path: "server/app.js", lines: [], gaps: [5]).map(\.qualifiedName), ["handler"])
        // Route callbacks are entry points: no 影响 for them.
        XCTAssertEqual(graph.changedSymbols(path: "server/app.js", lines: [8]).map(\.name), [])

        let hunk = DiffHunk(id: "h", header: "@@ -10,4 +10,5 @@ class A", lines: [
            DiffLine(id: 1, text: "a", kind: .context), DiffLine(id: 2, text: "b", kind: .deletion), DiffLine(id: 3, text: "c", kind: .deletion),
            DiffLine(id: 4, text: "d", kind: .context), DiffLine(id: 5, text: "e", kind: .addition), DiffLine(id: 6, text: "f", kind: .addition),
            DiffLine(id: 7, text: "g", kind: .context)])
        XCTAssertEqual(hunk.changedNewLines.lines, [12, 13])
        XCTAssertEqual(hunk.changedNewLines.gaps, [11])
    }

    func testRemovedAndRenamedFunctionsListWhoStillCallsTheOldName() throws {
        let path = "web/src/api/orders.ts"
        let old = try Data(contentsOf: root.appendingPathComponent(path))
        // Renamed in its file only: the page still calls it as `load` (const load = api.getOrder) and `fetchOrder`.
        let renamed = String(decoding: old, as: UTF8.self).replacingOccurrences(of: "function getOrder", with: "function loadOrder")
        try Data(renamed.utf8).write(to: root.appendingPathComponent(path))
        var graph = try graph()
        let impacts = graph.removedImpacts(path: path, oldPath: path, oldData: old)
        XCTAssertEqual(impacts.map(\.symbol.name), ["getOrder"])
        XCTAssertEqual(impacts.first?.renamedTo, "loadOrder")
        XCTAssertEqual(impacts.first?.sites.map(\.caller).sorted(), ["OrderPage", "refresh"])
        XCTAssertEqual(impacts.first?.sites.map(\.path), ["web/src/pages/OrderPage.tsx", "web/src/pages/OrderPage.tsx"])
        XCTAssertEqual(graph.removedImpacts(path: path, oldPath: path, oldData: Data(renamed.utf8)), [], "nothing removed")

        // The callers moved to the new name: nothing left on the old one.
        let page = "web/src/pages/OrderPage.tsx", index = "web/src/api/index.ts"
        for file in [page, index] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8).replacingOccurrences(of: "getOrder", with: "loadOrder")
            try Data(text.utf8).write(to: root.appendingPathComponent(file))
        }
        graph = try self.graph()
        XCTAssertEqual(graph.removedImpacts(path: path, oldPath: path, oldData: old).first?.sites, [])

        // A Python function deleted with its file still imported elsewhere.
        let python = "backend/app/services/orders.py"
        let before = try Data(contentsOf: root.appendingPathComponent(python))
        try FileManager.default.removeItem(at: root.appendingPathComponent(python))
        graph = try self.graph()
        let gone = graph.removedImpacts(path: nil, oldPath: python, oldData: before)
        let make = try XCTUnwrap(gone.first { $0.symbol.name == "make_service" })
        XCTAssertNil(make.renamedTo)
        // `svc = build()` (build = make_service) and `orders_mod.make_service()`.
        XCTAssertEqual(make.sites.map(\.caller), ["get_order", "get_order"])
        XCTAssertEqual(make.sites.first?.path, "backend/app/api.py")
    }

    private func change(_ path: String, _ from: String, _ to: String) throws -> Data {
        let url = root.appendingPathComponent(path)
        let old = try Data(contentsOf: url)
        let text = String(decoding: old, as: UTF8.self)
        XCTAssertTrue(text.contains(from), from)
        try Data(text.replacingOccurrences(of: from, with: to).utf8).write(to: url)
        return old
    }

    func testChangedParametersCheckEveryCall() throws {
        let orders = "web/src/api/orders.ts"
        var old = try change(orders, "getOrder(id: string)", "getOrder(id: string, opts: Options)")
        var graph = try graph()
        var impact = try XCTUnwrap(graph.signatureImpacts(path: orders, oldData: old).first)
        XCTAssertEqual(impact.symbol.name, "getOrder")
        XCTAssertEqual(impact.before, "(id)"); XCTAssertEqual(impact.after, "(id, opts)")
        // Both calls go through renames: `load(id)` (const load = api.getOrder) and `fetchOrder(id)` (re-export).
        XCTAssertEqual(impact.broken.map(\.caller).sorted(), ["OrderPage", "refresh"])
        XCTAssertEqual(impact.broken.first?.problem, "少了 1 个参数（opts）")

        _ = try change(orders, "opts: Options", "opts?: Options")
        graph = try self.graph()
        impact = try XCTUnwrap(graph.signatureImpacts(path: orders, oldData: old).first)
        XCTAssertEqual(impact.after, "(id, opts?)")
        XCTAssertEqual(impact.sites.count, 2); XCTAssertEqual(impact.broken, [])
        XCTAssertEqual(graph.signatureImpacts(path: orders, oldData: try Data(contentsOf: root.appendingPathComponent(orders))), [], "unchanged")

        // A constructor's new parameter: `new OrderService(new OrderRepo())` no longer fits.
        let service = "web/src/services/orderService.ts"
        old = try change(service, "constructor(private readonly repo: OrderRepo) {}", "constructor(private readonly repo: OrderRepo, private clock: Clock) {}")
        graph = try self.graph()
        impact = try XCTUnwrap(graph.signatureImpacts(path: service, oldData: old).first)
        XCTAssertEqual(impact.symbol.qualifiedName, "OrderService.constructor")
        XCTAssertEqual(impact.broken.map(\.caller), ["orderService.ts 顶层"])

        // Python: a keyword-only parameter, and a call by keyword that still fits.
        let python = "backend/app/services/orders.py"
        old = try change(python, "def find(self, id):", "def find(self, id, *, deep):")
        graph = try self.graph()
        impact = try XCTUnwrap(graph.signatureImpacts(path: python, oldData: old).first)
        XCTAssertEqual(impact.after, "(id, *, deep)")
        XCTAssertEqual(impact.broken.map(\.caller), ["OrderService.load"])
        XCTAssertEqual(impact.broken.first?.problem, "少了参数 deep")
        _ = try change(python, "return self.repo.find(id)", "return self.repo.find(id, deep=True)")
        graph = try self.graph()
        XCTAssertEqual(try XCTUnwrap(graph.signatureImpacts(path: python, oldData: old).first).broken, [])

        let params = CodeParameters.pythonForTests(["id"], keywordOnly: ["deep"])
        XCTAssertEqual(params.problem(with: CallArguments(positional: 1, keywords: ["depth"])), "没有叫 depth 的参数")
        XCTAssertEqual(params.problem(with: CallArguments(positional: 3, keywords: [])), "多了 2 个参数")
        XCTAssertNil(params.problem(with: CallArguments(positional: 0, keywords: [], spread: true)))
    }

    /// The end-of-turn check reads the turn's own snapshot: a rename and a new parameter that left calls behind.
    func testTurnCheckListsCallsTheTurnLeftBroken() throws {
        let pre = root.appendingPathComponent(".turn/pre", isDirectory: true)
        try AIEventStore.prepareSnapshot(in: pre)
        func keep(_ path: String) throws {
            let target = pre.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent(path), to: target)
        }
        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: root.path)).filter { !$0.hasPrefix(".turn") }
        let orders = "web/src/api/orders.ts", python = "backend/app/services/orders.py"
        try keep(orders); try keep(python)
        // Kept as it was: nothing to report for it.
        try keep("web/src/lib/http.ts")
        // Added by the turn: nothing before it to compare with.
        let added = AIEventStore.snapshotAbsentMarker("web/src/new.ts", in: pre)
        try FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: added.path, contents: nil)
        XCTAssertEqual(TurnCallCheck.problems(root: root, files: files, pre: pre), [], "an unchanged turn breaks nothing")

        _ = try change(orders, "function getOrder", "function loadOrder")
        _ = try change(python, "def find(self, id):", "def find(self, id, *, deep):")
        let problems = TurnCallCheck.problems(root: root, files: files, pre: pre)
        XCTAssertEqual(problems.map(\.summary), [
            "OrderRepo.find（backend/app/services/orders.py）的参数 (id) → (id, *, deep)，1 处调用没跟着改",
            "getOrder 改名为 loadOrder（web/src/api/orders.ts），旧名字还有 2 处在调用",
        ])
        XCTAssertEqual(problems[0].sites.count, 1)
        XCTAssertTrue(problems[0].sites[0].hasSuffix("（OrderService.load）：少了参数 deep"), problems[0].sites[0])
        XCTAssertTrue(problems[1].sites.allSatisfy { $0.hasPrefix("web/src/pages/OrderPage.tsx:") })
        let message = try XCTUnwrap(TurnCallCheck.message(problems))
        XCTAssertTrue(message.contains("- getOrder 改名为 loadOrder"))
        XCTAssertTrue(message.contains("不用改"), "the agent may leave an intended change as it is")

        // Out of time: the rest goes unchecked rather than holding the agent up.
        var clock = Date()
        let late = TurnCallCheck.problems(root: root, files: files, pre: pre, now: { clock += 60; return clock })
        XCTAssertEqual(late, [])
    }

    func testUnchangedFilesComeFromTheCache() throws {
        let files = ["web/src/lib/http.ts", "web/src/api/orders.ts", "web/tsconfig.json"]
        let (first, cache) = CallGraph.build(root: root, files: files, cache: CallGraphCache())
        try Data("garbage that would not parse the same".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        let (second, _) = CallGraph.build(root: root, files: files, cache: cache)
        XCTAssertEqual(first.symbols, second.symbols)
        XCTAssertEqual(first.fileCount, 2)
    }
}
