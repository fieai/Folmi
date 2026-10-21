import XCTest
import FolmiCore
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

    /// Same test as the rail's 待看: uncommitted work or commits of its own; being behind (or ahead of an upstream it
    /// may not even have) is not something to look at.
    func testWorktreeNeedsAttentionMatchesTheRail() async {
        await MainActor.run {
            var row = ProjectBoard.Row(path: "/worktree", name: "Worktree")
            row.parent = "/project"; row.ahead = 0; row.behind = 409
            XCTAssertFalse(row.worktreeNeedsAttention)
            row.ownCommits = 1
            XCTAssertTrue(row.worktreeNeedsAttention)
            row.ownCommits = 0; row.aiRunning = true
            XCTAssertTrue(row.worktreeNeedsAttention)
        }
    }

    /// The open project's row follows the main window's state, so the two never disagree between board refreshes.
    func testOpenProjectRowFollowsTheWindow() async {
        await MainActor.run {
            let board = ProjectBoard()
            var stale = ProjectBoard.Row(path: "/p", name: "P")
            stale.ahead = 2; stale.changes = 3
            board.setRowsForTesting([stale])
            let snapshot = RepositorySnapshot(root: URL(fileURLWithPath: "/p"), branch: "master", head: "abc", files: [], commits: [], branches: [],
                                              remotes: ["origin"], fingerprint: "f", upstream: "origin/master", ahead: 0, behind: 0)
            board.patch(path: "/p", snapshot: snapshot, inReview: 0)
            XCTAssertEqual(board.rows.first?.ahead, 0)
            XCTAssertEqual(board.rows.first?.changes, 0)
            XCTAssertEqual(board.attentionCount, 0)
        }
    }
}
