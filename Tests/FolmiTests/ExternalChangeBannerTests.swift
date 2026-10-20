import AppKit
import SwiftUI
import XCTest
@testable import Folmi

/// 「这个文件刚被其他程序修改」 takes its own row: the first line of the file stays readable under it.
final class ExternalChangeBannerTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }
    @MainActor
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @MainActor
    func testNoticeDoesNotCoverTheFirstLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Banner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        var created: Result<DemoRepository, Error>?
        Task { do { created = .success(try await DemoRepository.create()) } catch { created = .failure(error) } }
        while created == nil { spin(0.05) }
        let demo = try XCTUnwrap(created).get()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(8)
        while model.busy || model.snapshot == nil { guard Date() < deadline else { return XCTFail("open") }; spin(0.05) }
        model.editPath("Notes.txt")
        while model.busy { spin(0.05) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: FolmiView(model: model))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        spin(1.0)
        let workspace = try XCTUnwrap(model.editorWorkspace)
        // Another program rewrites the file; the clean editor reloads it and shows the notice.
        try "外部写入的第一行\n第二行\n".write(to: demo.root.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(workspace.reloadCleanDocuments(), ["Notes.txt"])
        spin(0.8)
        let shown = try ScreenText.read(hosting)
        XCTAssertTrue(shown.contains("其他程序修改"), "the notice: \(shown)")
        XCTAssertTrue(shown.contains("第一行"), "the first line under the notice: \(shown)")
    }
}
