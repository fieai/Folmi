import AppKit
import Vision
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

/// 调用关系 on the demo with a few TypeScript files added: the cursor on a call centers the function it means,
/// both views draw its callers and callees, and clicking through keeps a way back.
final class CallMapPageTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)"); throw FolmiFailure(message: description) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    @MainActor
    func testCursorCentersFunctionAndBothViewsShowCallers() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-CallMapTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let files = [
            "web/api.ts": "export function loadInvoice(id: string) { return formatTotal(id) }\nexport function formatTotal(id: string) { return id }\n",
            "web/page.ts": "import { loadInvoice as fetchInvoice } from './api'\nexport function showInvoicePage() {\n  return fetchInvoice('7')\n}\n",
        ]
        for (path, text) in files {
            let url = demo.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil }

        // The cursor on `fetchInvoice` (a renamed import) means loadInvoice.
        let page = files["web/page.ts"]!
        let location = (page as NSString).range(of: "fetchInvoice('7')").location + 2
        model.showCalls(path: "web/page.ts", text: page, location: location)
        XCTAssertEqual(model.content, .calls)
        try await eventually("认出光标处的函数") { model.callMap.focus != nil }
        XCTAssertEqual(model.callMap.focus?.qualifiedName, "loadInvoice")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CallMapPage(model: model).environment(\.folmiTheme, model.theme))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        var shown = try ScreenText.read(hosting)
        XCTAssertTrue(shown.contains("谁调用它"), "shown: \(shown)")
        XCTAssertTrue(shown.contains("showInvoicePage"), "shown: \(shown)")
        XCTAssertTrue(shown.contains("formatTotal"), "shown: \(shown)")

        model.callMap.mode = .graph
        try await Task.sleep(nanoseconds: 400_000_000)
        shown = try ScreenText.read(hosting)
        XCTAssertTrue(shown.contains("showInvoicePage") && shown.contains("formatTotal"), "graph: \(shown)")

        // Dragging the background moves the graph: pulled 500 points left, the callers column leaves the window.
        let left = { try ScreenText.read(hosting).contains("showInvoicePage") }
        XCTAssertTrue(try left())
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 60), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Queue the moves before mouseDown: AppKit may track the drag in a loop of its own.
        for x in stride(from: 680, through: 200, by: -40) { NSApp.postEvent(mouse(.leftMouseDragged, CGFloat(x)), atStart: false) }
        NSApp.postEvent(mouse(.leftMouseUp, 200), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, 700))
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            if event.windowNumber == window.windowNumber { window.sendEvent(event) }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterDrag = try ScreenText.read(hosting)
        XCTAssertFalse(afterDrag.contains("showInvoicePage"), "dragged left: \(afterDrag)")

        // The latest AI turn's functions carry 本轮改过 in the graph's legend and on the center in the header.
        model.callMap.turnChanged = [model.callMap.focus!.id]
        try await Task.sleep(nanoseconds: 300_000_000)
        shown = try ScreenText.read(hosting)
        XCTAssertGreaterThanOrEqual(shown.components(separatedBy: "本轮改过").count - 1, 2, "header tag and legend: \(shown)")

        let callee = try XCTUnwrap(model.callMap.graph?.callees(of: model.callMap.focus!).first?.symbol)
        model.focusCall(callee)
        XCTAssertEqual(model.callMap.focus?.name, "formatTotal")
        model.callMapBack()
        XCTAssertEqual(model.callMap.focus?.name, "loadInvoice")
        XCTAssertTrue(model.callMap.trail.isEmpty)

        // The path above the graph: a click goes back to that center and drops the ones after it.
        let caller = try XCTUnwrap(model.callMap.graph?.callers(of: model.callMap.focus!).first?.symbol)
        model.focusCall(callee); model.focusCall(caller)
        XCTAssertEqual(model.callMap.trail.map(\.name), ["loadInvoice", "formatTotal"])
        model.callMapJump(to: 0)
        XCTAssertEqual(model.callMap.focus?.name, "loadInvoice"); XCTAssertTrue(model.callMap.trail.isEmpty)

        model.leaveCallMap()
        XCTAssertNotEqual(model.content, .calls)
    }

    /// A Go file in a project indexed with CodeGraph: ⌃⌥H asks `codegraph` (a stand-in here) and shows its callers.
    @MainActor
    func testOtherLanguagesAskCodeGraph() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-CodeGraphTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let source = "package orders\n\nfunc LoadOrder(id string) {}\n"
        try Data(source.utf8).write(to: demo.root.appendingPathComponent("orders.go"))
        try FileManager.default.createDirectory(at: demo.root.appendingPathComponent(".codegraph"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: demo.root.appendingPathComponent(".codegraph/codegraph.db").path, contents: Data())
        let script = settings.appendingPathComponent("codegraph")
        try Data("""
        #!/bin/sh
        if [ "$1" = callers ]; then list='"callers":[{"name":"HandleOrder","kind":"function","filePath":"api/handler.go","startLine":12,"relationships":["calls"]}]'
        else list='"callees":[{"name":"QueryOrder","kind":"function","filePath":"db/orders.go","startLine":30,"relationships":["calls"]}]'; fi
        echo '{"targets":[{"name":"LoadOrder","kind":"function","filePath":"orders.go","startLine":3}],"ambiguous":false,'"$list"',"truncated":false}'
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil }
        model.callMap.codeGraphExecutable = script.path
        model.showCalls(path: "orders.go", text: source, location: (source as NSString).range(of: "LoadOrder").location + 2)
        try await eventually("CodeGraph 答复") { model.callMap.codeGraph != nil }
        XCTAssertEqual(model.callMap.codeGraph?.callers.map(\.name), ["HandleOrder"])
        XCTAssertEqual(model.callMap.codeGraph?.callees.map(\.path), ["db/orders.go"])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CallMapPage(model: model).environment(\.folmiTheme, model.theme))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        let shown = try ScreenText.read(hosting)
        // OCR reads small type loosely (HanaleOrder): the file names are enough.
        XCTAssertTrue(shown.contains("CodeGraph") && shown.contains("handler.go:12") && shown.contains("QueryOrder"), shown)

        // A click centers the caller; ⌫ / 后退 comes back to LoadOrder.
        model.showCodeGraph(name: "HandleOrder", file: "api/handler.go")
        try await eventually("以调用方为中心") { model.callMap.codeGraphTrail.count == 1 && !model.callMap.codeGraphLoading }
        model.codeGraphBack()
        try await eventually("后退") { model.callMap.codeGraphTrail.isEmpty && !model.callMap.codeGraphLoading }
        XCTAssertEqual(model.callMap.codeGraph?.target.name, "LoadOrder")
    }

    /// 接口: an Express route in the open project; its front end first in the same project, then in a linked one.
    @MainActor
    func testEndpointsPairHereAndAcrossLinkedProjects() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-EndpointTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let back = try await DemoRepository.create(), front = try await DemoRepository.create()
        cleanupURLs += [back.root.deletingLastPathComponent(), front.root.deletingLastPathComponent()]
        func write(_ root: URL, _ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(back.root, "server/app.js", "const app = require('express')()\nfunction showOrder(req, res) {\n  res.json({})\n}\napp.get('/api/orders/:id', showOrder)\n")
        try write(back.root, "server/admin.js", "export function audit() { return fetch(`/api/orders/${7}`) }\n")
        try write(front.root, "web/orders.ts", "export function loadOrder(id: string) {\n  return fetch(`/api/orders/${id}`)\n}\n")

        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(back.root, environment: back.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil }
        model.showCallMap()
        model.callMap.mode = .endpoints
        try await eventually("认出接口") { model.callMap.endpoints?.endpoints.isEmpty == false }
        let map = try XCTUnwrap(model.callMap.endpoints)
        let route = try XCTUnwrap(map.endpoints.first)
        XCTAssertEqual(route.title, "GET /api/orders/:id"); XCTAssertEqual(route.handler?.name, "showOrder")
        XCTAssertEqual(map.uses(of: route).map(\.caller), ["audit"])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CallMapPage(model: model).environment(\.folmiTheme, model.theme))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        var shown = try ScreenText.read(hosting)
        var flat = shown.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(flat.contains("/api/orders/") && flat.contains("1处调用"), shown)

        // The front end lives in another repository: linked, its request pairs too, marked with its project.
        model.setLinked(front.root.path, true)
        XCTAssertEqual(model.linkedProjects, [front.root.path])
        try await eventually("读关联项目") { (model.callMap.endpoints?.uses(of: route).count ?? 0) == 2 }
        let linked = try XCTUnwrap(model.callMap.endpoints?.uses(of: route).first { $0.project != nil })
        XCTAssertEqual(linked.caller, "loadOrder"); XCTAssertEqual(linked.file, "web/orders.ts")
        try await Task.sleep(nanoseconds: 300_000_000)
        shown = try ScreenText.read(hosting)
        flat = shown.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(flat.contains("2处调用") && flat.contains("关联项目（1）"), shown)

        // 影响 on a change inside the handler names the endpoint.
        model.showEndpoint(route)
        XCTAssertEqual(model.callMap.endpointFocus, route.id)
        XCTAssertEqual(model.callMap.endpoints?.endpoints(changedIn: "server/app.js", lines: [3]).map(\.title), ["GET /api/orders/:id"])
        model.setLinked(front.root.path, false)
        XCTAssertEqual(model.linkedProjects, [])
    }

    func testGraphRowsFollowTheBoxesTheyLinkTo() {
        // x calls b and y calls a: in the given order the two lines cross; untangled they do not.
        let order = CallGraphRows.untangle([0: ["x", "y"], 1: ["a", "b"], 2: ["c"]], links: [("x", "b"), ("y", "a"), ("a", "c"), ("b", "c")])
        XCTAssertEqual(order[0], ["y", "x"])
        XCTAssertEqual(order[1], ["a", "b"])
        let same = CallGraphRows.untangle([3: ["p", "q"], 4: ["r", "s"]], links: [("p", "r"), ("q", "s")])
        XCTAssertEqual(same[3], ["p", "q"]); XCTAssertEqual(same[4], ["r", "s"])
    }

    /// The wheel and two-finger swipes pan the 关系图 only while the pointer is over it; with ⌘ they zoom, within limits.
    @MainActor
    func testGraphViewportPansZoomsAndFits() throws {
        let viewport = CallGraphViewport()
        func wheel(_ dy: Int32, _ dx: Int32 = 0, command: Bool = false) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            if command { event.flags = .maskCommand }
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        XCTAssertFalse(viewport.handle(try wheel(30)), "not over the graph: the event goes on")
        viewport.hovering = true
        XCTAssertTrue(viewport.handle(try wheel(30, -20)))
        XCTAssertGreaterThan(viewport.offset.height, 0); XCTAssertLessThan(viewport.offset.width, 0)
        XCTAssertTrue(viewport.handle(try wheel(40, command: true)))
        XCTAssertGreaterThan(viewport.scale, 1)
        for _ in 0..<40 { viewport.zoom(by: 1.25) }
        XCTAssertEqual(viewport.scale, CallGraphViewport.scales.upperBound)
        viewport.reset(fitting: CGSize(width: 1150, height: 2000), in: CGSize(width: 900, height: 500))
        XCTAssertEqual(viewport.offset, .zero)
        XCTAssertEqual(viewport.scale, 0.3, "a tall graph shrinks to fit, but no further than 30%")
        viewport.reset(fitting: CGSize(width: 600, height: 300), in: CGSize(width: 900, height: 500))
        XCTAssertEqual(viewport.scale, 1, "a small graph stays at 100%")
    }

    /// 逐个验收: a changed TypeScript function gets an 影响 row with its caller count, which opens 调用关系.
    @MainActor
    func testReviewCardShowsHowManyPlacesCallTheChangedFunction() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ImpactTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let api = "export function loadInvoice(id: string) {\n  return id\n}\n"
        let files = [
            "web/api.ts": api,
            "web/page.ts": "import { loadInvoice as fetchInvoice } from './api'\nexport function showInvoicePage() {\n  const a = fetchInvoice('7')\n  return a + fetchInvoice('8')\n}\n",
        ]
        for (path, text) in files {
            let url = demo.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        _ = try await CommandRunner.git(["add", "web"], at: demo.root, environment: demo.environment)
        _ = try await CommandRunner.git(["commit", "-m", "web"], at: demo.root, environment: demo.environment)
        try Data(api.replacingOccurrences(of: "return id", with: "return id.trim()").utf8).write(to: demo.root.appendingPathComponent("web/api.ts"))

        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot?.files.contains { $0.path == "web/api.ts" } == true }
        model.showContent(.allChanges)
        try await eventually("读出全部改动") { !model.allChangesLoading && model.visibleAllChanges.contains { $0.file.path == "web/api.ts" } }
        await model.prepareCallImpacts(model.visibleAllChanges)
        let diff = try XCTUnwrap(model.visibleAllChanges.first { $0.file.path == "web/api.ts" })
        let impacts = try XCTUnwrap(model.callImpacts(for: diff))
        XCTAssertEqual(impacts.map(\.symbol.name), ["loadInvoice"])
        XCTAssertEqual(impacts.first?.sites, 2)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CallImpactRow(model: model, impacts: impacts).environment(\.folmiTheme, model.theme))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        // The capsule's text is drawn outside the layer tree ScreenText renders; read the view's own bitmap.
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        let shown = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let compact = shown.filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains("oadInvoice") && compact.contains("被2处调用"), "shown: \(shown)")

        model.showCallMap(for: impacts[0].symbol)
        XCTAssertEqual(model.content, .calls)
        XCTAssertEqual(model.callMap.focus?.name, "loadInvoice")
    }

    /// A function renamed only where it is defined: 影响 says how many places still call the old name, and lists them.
    @MainActor
    func testRenamedFunctionShowsCallsToTheOldName() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-RenameTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let api = "export function loadInvoice(id: string) {\n  return id\n}\n"
        let files = [
            "web/api.ts": api,
            "web/page.ts": "import { loadInvoice } from './api'\nexport function showInvoicePage() {\n  const a = loadInvoice('7')\n  return a + loadInvoice('8')\n}\n",
        ]
        for (path, text) in files {
            let url = demo.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        _ = try await CommandRunner.git(["add", "web"], at: demo.root, environment: demo.environment)
        _ = try await CommandRunner.git(["commit", "-m", "web"], at: demo.root, environment: demo.environment)
        try Data(api.replacingOccurrences(of: "loadInvoice", with: "fetchInvoiceById").utf8).write(to: demo.root.appendingPathComponent("web/api.ts"))

        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot?.files.contains { $0.path == "web/api.ts" } == true }
        model.showContent(.allChanges)
        try await eventually("读出全部改动") { !model.allChangesLoading && model.visibleAllChanges.contains { $0.file.path == "web/api.ts" } }
        await model.prepareCallImpacts(model.visibleAllChanges)
        let diff = try XCTUnwrap(model.visibleAllChanges.first { $0.file.path == "web/api.ts" })
        let removed = model.removedCallImpacts(for: diff)
        XCTAssertEqual(removed.map(\.symbol.name), ["loadInvoice"])
        XCTAssertEqual(removed.first?.renamedTo, "fetchInvoiceById")
        XCTAssertEqual(removed.first?.sites.map(\.line), [3, 4])
        XCTAssertEqual(model.callImpacts(for: diff)?.map(\.symbol.name), ["fetchInvoiceById"])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CallImpactRow(model: model, impacts: model.callImpacts(for: diff) ?? [], removed: removed)
            .environment(\.folmiTheme, model.theme))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        let shown = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").filter { !$0.isWhitespace }
        XCTAssertTrue(shown.contains("改名为") && shown.contains("旧名字还有2处在调用"), "shown: \(shown)")
    }

    /// A new required parameter: 影响 says how many calls were not updated, and why each does not fit.
    @MainActor
    func testChangedParametersShowCallsThatDidNotFollow() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ParamsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let api = "export function loadInvoice(id: string) {\n  return id\n}\n"
        let files = [
            "web/api.ts": api,
            "web/page.ts": "import { loadInvoice } from './api'\nexport function showInvoicePage() {\n  const a = loadInvoice('7')\n  return a + loadInvoice('8')\n}\n",
            "web/other.ts": "import { loadInvoice as load } from './api'\nexport const total = () => load('9', 'EUR')\n",
        ]
        for (path, text) in files {
            let url = demo.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        _ = try await CommandRunner.git(["add", "web"], at: demo.root, environment: demo.environment)
        _ = try await CommandRunner.git(["commit", "-m", "web"], at: demo.root, environment: demo.environment)
        try Data(api.replacingOccurrences(of: "(id: string)", with: "(id: string, currency: string)").utf8)
            .write(to: demo.root.appendingPathComponent("web/api.ts"))

        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot?.files.contains { $0.path == "web/api.ts" } == true }
        model.showContent(.allChanges)
        try await eventually("读出全部改动") { !model.allChangesLoading && model.visibleAllChanges.contains { $0.file.path == "web/api.ts" } }
        await model.prepareCallImpacts(model.visibleAllChanges)
        let diff = try XCTUnwrap(model.visibleAllChanges.first { $0.file.path == "web/api.ts" })
        let changed = try XCTUnwrap(model.signatureImpacts(for: diff).first)
        XCTAssertEqual(changed.before, "(id)"); XCTAssertEqual(changed.after, "(id, currency)")
        XCTAssertEqual(changed.sites.count, 3)
        XCTAssertEqual(changed.broken.map(\.line), [3, 4])
        XCTAssertEqual(changed.broken.first?.problem, "少了 1 个参数（currency）")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: CallImpactRow(model: model, impacts: [], signatures: [changed]).environment(\.folmiTheme, model.theme))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        let shown = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").filter { !$0.isWhitespace }
        XCTAssertTrue(shown.contains("参数") && shown.contains("2处调用没跟着改"), "shown: \(shown)")
    }
}
