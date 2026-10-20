import AppKit
import SwiftUI
import XCTest
@testable import FolmiCore
@testable import Folmi

/// The commit box says what stays out of the commit, and 逐个验收 offers 「回到当前处」 once the current change is
/// scrolled away (⏎ / ⌫ then scroll back instead of acting on it).
final class CommitScopeTests: XCTestCase {
    private var cleanupURLs: [URL] = []
    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    func testExclusionSplitsLeftOutAndPartialFiles() {
        let files = [
            FileChange(path: "staged.swift", indexCode: "M", worktreeCode: "."),
            FileChange(path: "src/only-disk.swift", indexCode: ".", worktreeCode: "M"),
            FileChange(path: "new.md", indexCode: "?", worktreeCode: "?"),
            FileChange(path: "half.swift", indexCode: "M", worktreeCode: "M"),
            FileChange(path: "conflict.swift", indexCode: "U", worktreeCode: "U"),
        ]
        let exclusion = CommitExclusion.make(files)
        XCTAssertEqual(exclusion.leftOut, ["src/only-disk.swift", "new.md"])
        XCTAssertEqual(exclusion.partial, ["half.swift"])
        XCTAssertEqual(exclusion.lines, ["本次不包含：工作区 2 个文件（only-disk.swift、new.md）",
                                         "1 个文件只提交已暂存的部分，其余留在工作区（half.swift）"])
        XCTAssertTrue(CommitExclusion.make([files[0]]).isEmpty)
    }

    func testExclusionNamesAtMostTwoFiles() {
        let files = ["a", "b", "c"].map { FileChange(path: $0, indexCode: ".", worktreeCode: "M") }
        XCTAssertEqual(CommitExclusion.make(files).lines, ["本次不包含：工作区 3 个文件（a、b 等）"])
    }

    func testViewportPlace() {
        let band: ClosedRange<CGFloat> = 40...400
        XCTAssertEqual(ReviewViewport.place(of: CGRect(x: 0, y: 100, width: 10, height: 50), visible: band), .visible)
        XCTAssertEqual(ReviewViewport.place(of: CGRect(x: 0, y: -200, width: 10, height: 245), visible: band), .above)
        XCTAssertEqual(ReviewViewport.place(of: CGRect(x: 0, y: 392, width: 10, height: 50), visible: band), .below)
        // A long hunk that still fills the page is in view.
        XCTAssertEqual(ReviewViewport.place(of: CGRect(x: 0, y: -500, width: 10, height: 2000), visible: band), .visible)
        // Not measured yet: never block the keys.
        XCTAssertEqual(ReviewViewport.place(of: CGRect(x: 0, y: -900, width: 10, height: 5), visible: 0...0), .visible)
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 8, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)"); throw FolmiFailure(message: description) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// A demo project whose `review.txt` (300 lines) has edits far apart, so each is its own hunk.
    @MainActor
    private func makeModel(extraStaged: Bool) async throws -> (FolmiModel, DemoRepository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-CommitScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        let git = { (arguments: [String]) async throws in _ = try await CommandRunner.git(arguments, at: demo.root, environment: demo.environment) }
        try await git(["add", "-A"]); try await git(["commit", "-q", "-m", "demo state"])
        let file = demo.root.appendingPathComponent("review.txt")
        let lines = (1...300).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "--", "review.txt"]); try await git(["commit", "-q", "-m", "review base"])
        var edited = lines
        for index in [0, 100, 200, 299] { edited[index] = "EDIT \(index)" }
        try (edited.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        if extraStaged {
            try "staged\n".write(to: demo.root.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
            try await git(["add", "--", "staged.txt"])
        }
        let model = FolmiModel(store: WorkspaceStore(url: directory.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开项目") { !model.busy && model.snapshot != nil }
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

    @MainActor
    func testCommitBoxSaysWhatStaysOut() async throws {
        let (model, _) = try await makeModel(extraStaged: true)
        try await eventually("暂存区有文件") { model.stagedCount == 1 }
        let (window, host) = show(CommitSection(model: model).frame(width: 420), size: NSSize(width: 420, height: 320))
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 500_000_000)
        let shown = try ScreenText.read(host, scale: 4).replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(shown.contains("本次不包含"), shown)
        XCTAssertTrue(shown.contains("review.txt"), shown)
    }

    @MainActor
    func testScrollingAwayOffersBackToCurrentAndReturnDoesNotAct() async throws {
        let (model, _) = try await makeModel(extraStaged: false)
        await model.loadAllChanges()
        try await eventually("全部改动") { !model.allChangesLoading && model.allChanges.first?.hunks.count == 4 }
        let (window, host) = show(AllChangesView(model: model), size: NSSize(width: 1100, height: 360))
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(try ScreenText.read(host, scale: 3).contains("回到当前处"))

        let scroll = try XCTUnwrap(Self.scrollViews(in: host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        let bottom = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bottom)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds: 600_000_000)
        let shown = try ScreenText.read(host, scale: 3).replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(shown.contains("回到当前处"), shown)

        // ⏎ while the current change is out of view scrolls back; nothing gets staged.
        window.makeFirstResponder(host)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(event)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(model.stagedCount, 0)
        XCTAssertFalse(try ScreenText.read(host, scale: 3).replacingOccurrences(of: " ", with: "").contains("回到当前处"))
    }

    @MainActor
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
