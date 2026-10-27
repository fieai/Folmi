import XCTest
@testable import FolmiCore

/// 接口: routes in Express, NestJS, Next.js, FastAPI, Flask and Django, paired with fetch / axios requests.
final class EndpointTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-endpoints-" + UUID().uuidString, isDirectory: true)
        let files: [String: String] = [
            "web/src/api.ts": """
            import axios from 'axios'
            const api = axios.create({ baseURL: '/api' })
            export function getOrder(id: string) { return fetch(`/api/orders/${id}`) }
            export function payOrder(id: string) { return axios.post('/api/orders/' + id + '/pay', { amount: 1 }) }
            export function listItems() { return api.get('/items') }
            export function ghost() { return fetch('/api/nothing-here', { method: 'DELETE' }) }
            export function loadUser(id: number) { return fetch(`/api/users/${id}?full=1`) }
            export function loadCart(id: string) { return fetch(`/api/carts/${id}`) }
            export function invoice(id: string) { return axios({ url: `/api/invoices/${id}`, method: 'get' }) }
            export async function profiles() { return request<Profile[]>({ url: '/profiles/1/', method: 'GET', params }) }
            export async function payAgain(id: string) { return request<Order>(`/api/orders/${id}/pay`, { method: 'POST', ...(options || {}) }) }
            """,
            "server/app.js": """
            const express = require('express')
            const app = express()
            const router = express.Router()
            function showOrder(req, res) {
              res.json({})
            }
            app.get('/api/orders/:id', showOrder)
            app.post('/api/orders/:id/pay', async (req, res) => { res.json({}) })
            router.get('/items', (req, res) => res.json([]))
            app.use('/api', router)
            """,
            "server/invoices.controller.ts": """
            @Controller('invoices')
            export class InvoicesController {
              @Get(':id')
              findOne(@Param('id') id: string) { return id }
            }
            """,
            "web/app/api/carts/[id]/route.ts": """
            export async function GET(request: Request) { return Response.json({}) }
            """,
            "backend/users.py": """
            from fastapi import APIRouter
            router = APIRouter(prefix="/users")

            @router.get("/{user_id}")
            def read_user(user_id: int):
                return {}
            """,
            "backend/reports.py": """
            from flask import Blueprint
            bp = Blueprint("reports", __name__, url_prefix="/reports")

            @bp.route("/<int:rid>", methods=["GET", "DELETE"])
            def report(rid):
                return ""
            """,
            "backend/urls.py": """
            from django.urls import path, include
            from . import views
            urlpatterns = [
                path("profiles/<int:pk>/", views.profile_detail),
                path("admin/", include("admin.urls")),
            ]
            """,
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func map() throws -> (EndpointMap, CallGraph) {
        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: root.path))
        let graph = CallGraph.build(root: root, files: files, cache: CallGraphCache()).0
        return (EndpointMap.build([(nil, graph)]), graph)
    }
    private func endpoint(_ map: EndpointMap, _ title: String) throws -> Endpoint {
        try XCTUnwrap(map.endpoints.first { $0.title == title }, "\(title) in \(map.endpoints.map(\.title))")
    }

    func testRoutesInEachFramework() throws {
        let (map, _) = try map()
        XCTAssertEqual(Set(map.endpoints.map(\.title)), [
            "GET /api/orders/:id", "POST /api/orders/:id/pay", "GET /items", "GET /invoices/:id", "GET /api/carts/[id]",
            "GET /users/{user_id}", "GET/DELETE /reports/<int:rid>", "ANY /profiles/<int:pk>/",
        ])
        XCTAssertEqual(try endpoint(map, "GET /api/orders/:id").handler?.name, "showOrder")
        XCTAssertEqual(try endpoint(map, "POST /api/orders/:id/pay").handler?.name, "app.post(\"/api/orders/:id/pay\")", "inline callback")
        XCTAssertEqual(try endpoint(map, "GET /invoices/:id").handler?.qualifiedName, "InvoicesController.findOne")
        XCTAssertEqual(try endpoint(map, "GET /users/{user_id}").handler?.name, "read_user")
        XCTAssertEqual(try endpoint(map, "GET/DELETE /reports/<int:rid>").handler?.name, "report")
        XCTAssertEqual(try endpoint(map, "GET /api/carts/[id]").handler?.name, "GET")
    }

    func testRequestsPairWithRoutes() throws {
        let (map, _) = try map()
        func callers(_ title: String) throws -> [String] {
            try map.uses(of: endpoint(map, title)).map { "\($0.caller)\($0.certain ? "" : " 可能")" }
        }
        XCTAssertEqual(try callers("GET /api/orders/:id"), ["getOrder"], "template literal")
        XCTAssertEqual(try callers("POST /api/orders/:id/pay"), ["payOrder", "payAgain"], "string + id + string; request<T>(url, { method })")
        XCTAssertEqual(try callers("GET /api/carts/[id]"), ["loadCart"], "Next.js dynamic segment")
        XCTAssertEqual(try callers("GET /items"), ["listItems 可能"], "a base URL and a mounted router: only the end matches")
        XCTAssertEqual(try callers("GET /users/{user_id}"), ["loadUser 可能"], "query string dropped; router included elsewhere")
        XCTAssertEqual(try callers("GET /invoices/:id"), ["invoice 可能"], "axios({ url, method }) and a Nest global prefix")
        XCTAssertEqual(try callers("ANY /profiles/<int:pk>/"), ["profiles 可能"], "request<T>({ url, method }); Django include()")
        XCTAssertEqual(map.unmatched.map(\.caller), ["ghost"])
        XCTAssertEqual(map.unmatched.first?.method, "DELETE")
    }

    func testChangedHandlerNamesItsEndpoint() throws {
        let (map, _) = try map()
        XCTAssertEqual(map.endpoints(changedIn: "server/app.js", lines: [5]).map(\.title), ["GET /api/orders/:id"], "inside showOrder")
        XCTAssertEqual(map.endpoints(changedIn: "server/app.js", lines: [8]).map(\.title), ["POST /api/orders/:id/pay"])
        XCTAssertEqual(map.endpoints(changedIn: "server/app.js", lines: [10]), [], "app.use is not a route")
    }

    func testPathsMatchAcrossSpellings() {
        XCTAssertEqual(EndpointPath.segments("https://x.dev/api/orders/*?a=1")?.segments, ["api", "orders", "*"])
        XCTAssertEqual(EndpointPath.segments("*/orders")?.open, true)
        XCTAssertNil(EndpointPath.segments("/*"))
        let route = EndpointPath.segments("/orders/<int:id>/")!.segments
        XCTAssertEqual(EndpointPath.match(["orders", "*"], open: false, based: false, route: route, prefixUnknown: false), .exact)
        XCTAssertEqual(EndpointPath.match(["orders"], open: false, based: false, route: route, prefixUnknown: false), .none)
        XCTAssertEqual(EndpointPath.match(["v2", "orders", "*"], open: false, based: false, route: route, prefixUnknown: false), .none,
                       "a longer request needs a route whose prefix is unknown")
    }
}
