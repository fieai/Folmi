import AppKit
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

/// The 远端 sheet on the demo with its disposable remote: shown with its address, removed and put back with ⌥⌘Z,
/// and a new one added.
final class RemotesFlowTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)"); throw FolmiFailure(message: description) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    @MainActor
    func testRemotesSheetShowsAddressAndRemoveUndoAdd() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-RemotesTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(settings)
        let demo = try await DemoRepository.create(remoteUpdates: true)
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目") { !model.busy && model.snapshot != nil }
        XCTAssertEqual(model.snapshot?.remotes, ["demo"])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: RemotesSheet(model: model))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await eventually("读出远端") { model.remoteList.map(\.name) == ["demo"] }
        try await Task.sleep(nanoseconds: 300_000_000)
        let shown = try ScreenText.read(hosting)
        XCTAssertTrue(shown.contains("demo"), "shown: \(shown)")
        XCTAssertTrue(shown.contains("当前分支跟踪"), "shown: \(shown)")
        XCTAssertTrue(shown.contains("remote.git") || shown.contains(".git"), "地址：\(shown)")

        let behind = model.snapshot?.behind
        model.askRemoveRemote("demo")
        try await eventually("准备删除") { model.remoteRemoval != nil }
        XCTAssertEqual(model.remoteRemoval?.trackingBranches, ["main"])
        model.removeRemote("demo")
        try await eventually("删除远端") { !model.busy && model.snapshot?.remotes == [] }
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.snapshot?.upstream)
        XCTAssertEqual(model.undoLabel, "删除远端 demo")

        model.undoGitOperation()
        try await eventually("撤销删除") { !model.busy && model.snapshot?.remotes == ["demo"] }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.upstream, "demo/main")
        XCTAssertEqual(model.snapshot?.behind, behind, "远端分支记录也回来了")

        model.addRemote("backup", url: "git@example.invalid:me/app.git")
        try await eventually("添加远端") { !model.busy && model.snapshot?.remotes.contains("backup") == true }
        XCTAssertNil(model.errorMessage)
        try await eventually("列表更新") { model.remoteList.map(\.name) == ["demo", "backup"] }
        XCTAssertEqual(model.undoLabel, "添加远端 backup")
    }
}
