import FolmiCore
import XCTest
@testable import Folmi

@MainActor
final class WorktreeRailTests: XCTestCase {
    private func status(_ path: String, branch: String?, changes: Int = 0, own: Int = 0, main: Bool = false) -> WorktreeStatus {
        WorktreeStatus(info: WorktreeInfo(path: path, branch: branch, head: "abcdef1234", isMain: main), changes: changes, ownCommits: own, modified: nil)
    }

    func testRailListsNoWorktreeRowsOnlyANoticeForTheOnesWithWork() {
        let main = ProjectPreferences(rootPath: "/repo/app", name: "app")
        let trees = [status("/repo/app", branch: "main", changes: 3, main: true),
                     status("/u/.codex/worktrees/1/app", branch: nil, changes: 2),
                     status("/u/.codex/worktrees/2/app", branch: "codex/fix", own: 1),
                     status("/u/.codex/worktrees/3/app", branch: nil),
                     status("/u/.codex/worktrees/4/app", branch: "codex/old")]
        let entries = RailEntry.entries(projects: [main], current: "/repo/app", worktrees: trees)
        XCTAssertEqual(entries.count, 2)
        guard case .worktreeNotice(let count, let agent) = entries[1] else { return XCTFail("expected the notice row") }
        XCTAssertEqual(count, 2, "the open folder and clean worktrees are not counted")
        XCTAssertEqual(agent, .codex)
    }

    func testNoNoticeWhenEveryOtherWorktreeIsClean() {
        let main = ProjectPreferences(rootPath: "/repo/app", name: "app")
        let entries = RailEntry.entries(projects: [main], current: "/repo/app",
                                        worktrees: [status("/repo/app", branch: "main", changes: 5, main: true), status("/w/a", branch: nil)])
        XCTAssertEqual(entries.count, 1)
    }
}
