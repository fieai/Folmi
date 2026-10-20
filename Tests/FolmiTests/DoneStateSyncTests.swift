import AppKit
import SwiftUI
import XCTest
@testable import FolmiCore
@testable import Folmi

final class DoneStateSyncTests: XCTestCase {
    @MainActor
    private func makeModel(ahead: Int, behind: Int) -> FolmiModel {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("DoneStateSync-\(UUID().uuidString)")
        let model = FolmiModel(store: WorkspaceStore(url: path.appendingPathComponent("workspace.json")))
        model.snapshot = RepositorySnapshot(root: path, branch: "main", head: "abc", files: [],
            commits: [CommitSummary(id: "abc", shortID: "abc", subject: "today", date: Date())],
            branches: ["main"], remotes: ["origin"], fingerprint: "sync", upstream: "origin/main", ahead: ahead, behind: behind)
        return model
    }

    /// A clean worktree behind upstream has work left; the wrap-up must expose Pull instead of a green done state.
    @MainActor
    func testCleanBehindWorkspaceOffersPullWithoutClaimingAllDone() async throws {
        let model = makeModel(ahead: 0, behind: 1)
        XCTAssertFalse(model.isAllDone)
        XCTAssertEqual(model.daySummary?.behind, 1)
        let host = NSHostingView(rootView: DoneState(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        let shown = try ScreenText.read(host).replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(shown.contains("工作区干净"), shown)
        XCTAssertTrue(shown.contains("1个提交待拉取"), shown)
        XCTAssertTrue(shown.contains("拉取"), shown)
        XCTAssertFalse(shown.contains("今天都收好了"), shown)
        XCTAssertFalse(shown.contains("都已推送"), shown)
    }

    @MainActor
    func testDivergedCleanWorkspaceRetainsBothSyncDirections() async {
        let model = makeModel(ahead: 2, behind: 3)
        XCTAssertFalse(model.isAllDone)
        XCTAssertEqual(model.daySummary?.unpushed, 2)
        XCTAssertEqual(model.daySummary?.behind, 3)
    }

    @MainActor
    func testCleanSynchronizedWorkspaceCanStillFinish() async {
        let model = makeModel(ahead: 0, behind: 0)
        XCTAssertTrue(model.isAllDone)
        XCTAssertEqual(model.daySummary?.behind, 0)
    }
}
