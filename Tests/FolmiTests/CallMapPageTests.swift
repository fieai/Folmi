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

        let callee = try XCTUnwrap(model.callMap.graph?.callees(of: model.callMap.focus!).first?.symbol)
        model.focusCall(callee)
        XCTAssertEqual(model.callMap.focus?.name, "formatTotal")
        model.callMapBack()
        XCTAssertEqual(model.callMap.focus?.name, "loadInvoice")
        XCTAssertTrue(model.callMap.trail.isEmpty)

        model.leaveCallMap()
        XCTAssertNotEqual(model.content, .calls)
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
