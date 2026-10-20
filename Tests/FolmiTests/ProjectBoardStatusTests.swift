import XCTest
@testable import Folmi

final class ProjectBoardStatusTests: XCTestCase {
    func testCleanWorkspaceBehindUpstreamNeedsAttention() async {
        await MainActor.run {
            var row = ProjectBoard.Row(path: "/project", name: "Project")
            row.ahead = 0; row.behind = 3
            XCTAssertTrue(row.needsAttention)
            XCTAssertFalse(row.isTrackingSynchronized)
            XCTAssertEqual(row.statusSummary, "工作区干净 · 待拉取 3 个提交")
        }
    }

    func testCleanWorkspaceWithoutUpstreamDoesNotClaimSynchronization() async {
        await MainActor.run {
            var row = ProjectBoard.Row(path: "/project", name: "Project")
            XCTAssertFalse(row.isTrackingSynchronized)
            XCTAssertEqual(row.statusSummary, "工作区干净 · 未设置上游分支")
            row.upstream = "origin/deleted"
            XCTAssertEqual(row.statusSummary, "工作区干净 · 未取得上游比较")
        }
    }

    func testWorkspaceAndTrackingStatusAreIndependent() async {
        await MainActor.run {
            var row = ProjectBoard.Row(path: "/project", name: "Project")
            row.ahead = 0; row.behind = 0
            XCTAssertTrue(row.isTrackingSynchronized)
            XCTAssertFalse(row.needsAttention)
            row.changes = 2
            XCTAssertTrue(row.needsAttention)
            XCTAssertEqual(row.statusSummary, "2 个文件有改动 · 与本地追踪分支一致")
            row.ahead = 1; row.behind = 4
            XCTAssertEqual(row.statusSummary, "2 个文件有改动 · 待推送 1 个提交，待拉取 4 个提交")
        }
    }
}
