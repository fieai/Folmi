import AppKit
import SwiftUI
import XCTest
@testable import FolmiCore
@testable import Folmi

/// What 逐个验收 and the wrap-up show on screen, read back with Vision (review-flow-optimization-v0.6).
final class ReviewScreenTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 8, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)"); throw FolmiFailure(message: description) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// A demo project with only `review.txt` changed: one edit in the work tree.
    @MainActor
    private func makeModel() async throws -> (FolmiModel, DemoRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ReviewScreen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let git = { (arguments: [String]) async throws in _ = try await CommandRunner.git(arguments, at: demo.root, environment: demo.environment) }
        try await git(["add", "-A"]); try await git(["commit", "-q", "-m", "demo state"])
        let file = demo.root.appendingPathComponent("review.txt")
        let lines = (1...30).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "--", "review.txt"]); try await git(["commit", "-q", "-m", "review base"])
        var edited = lines; edited[0] = "EDIT A"
        try (edited.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开项目") { !model.busy && model.snapshot != nil }
        await model.loadAllChanges()
        try await eventually("全部改动") { !model.allChangesLoading && model.allChanges.count == 1 }
        return (model, demo)
    }

    @MainActor
    private func show<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (window, host)
    }

    /// The bar names what ⏎ and ⌫ do to this change: a work-tree hunk is staged or discarded, not 「通过 / 不要」.
    @MainActor
    func testReviewBarNamesWhatTheKeysDo() async throws {
        let (model, _) = try await makeModel()
        for width in [CGFloat(420), 1100] {
            let (window, host) = show(AllChangesView(model: model), size: NSSize(width: width, height: 300))
            defer { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(nanoseconds: 500_000_000)
            // Progress and actions occupy two rows; read the full bar at both minimum and wide card widths.
            let shown = try ScreenText.read(host, top: 90, scale: 4).replacingOccurrences(of: " ", with: "")
            XCTAssertTrue(shown.contains("收下这处并暂存"), "width=\(width): \(shown)")
            XCTAssertTrue(shown.contains("丢弃这处"), "width=\(width): \(shown)")
            XCTAssertFalse(shown.contains("不要"), shown)
        }
    }

    /// Everything seen and staged with a message written: a plain ⏎ (the one that took the last change, or one
    /// pressed again) does not create a commit.
    @MainActor
    func testPlainReturnAfterTheLastChangeDoesNotCommit() async throws {
        let (model, demo) = try await makeModel()
        let diff = try XCTUnwrap(model.allChanges.first)
        model.stageFile(diff.file)
        try await eventually("暂存") { !model.busy }
        await model.loadAllChanges()
        try await eventually("暂存区") { !model.allChangesLoading && model.allChanges.allSatisfy { $0.area == .staged } }
        for staged in model.allChanges { model.markFileSeen(staged) }
        XCTAssertEqual(model.reviewTally.remaining, 0)
        model.draftMessage = "review"
        try await eventually("可以提交") { model.canCommit }
        let head = try await CommandRunner.git(["rev-parse", "HEAD"], at: demo.root, environment: demo.environment)

        let (window, host) = show(AllChangesView(model: model), size: NSSize(width: 1100, height: 600))
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        func returnKey() throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        }
        XCTAssertNotNil(window.firstResponder, "the review page takes the keys")
        window.sendEvent(try returnKey())
        try await Task.sleep(nanoseconds: 800_000_000)
        try await eventually("空闲") { !model.busy }
        let after = try await CommandRunner.git(["rev-parse", "HEAD"], at: demo.root, environment: demo.environment)
        XCTAssertEqual(after, head, "⏎ is not a commit")
        _ = host
    }

    /// A clean work tree with a stash waiting is not 「今天都收好了」: the wrap-up says a batch is put away.
    @MainActor
    func testWrapUpMentionsStashedChanges() async throws {
        let (model, demo) = try await makeModel()
        _ = try await CommandRunner.git(["stash", "push", "-u", "-m", "later"], at: demo.root, environment: demo.environment)
        try await model.reload()
        try await eventually("干净的工作区") { model.snapshot?.files.isEmpty == true }
        XCTAssertFalse(model.isAllDone)
        let (window, host) = show(DoneState(model: model), size: NSSize(width: 600, height: 420))
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        let shown = try ScreenText.read(host).replacingOccurrences(of: " ", with: "")
        XCTAssertFalse(shown.contains("今天都收好了"), shown)
        XCTAssertTrue(shown.contains("工作区已清空"), shown)
        XCTAssertTrue(shown.contains("查看暂放的改动…"), shown)
    }
}
