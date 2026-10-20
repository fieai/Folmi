import XCTest
@testable import FolmiCore
@testable import Folmi

@MainActor
final class ReviewRiskTests: XCTestCase {
    private func diff(_ path: String, code: String = "M", added: [String] = [], removed: Int = 0) -> FileDiff {
        var lines: [DiffLine] = []
        for (index, text) in added.enumerated() { lines.append(DiffLine(id: index, text: text, kind: .addition)) }
        for index in 0..<removed { lines.append(DiffLine(id: 1_000 + index, text: "old \(index)", kind: .deletion)) }
        let hunk = DiffHunk(id: "h", header: "@@", lines: lines)
        return FileDiff(file: FileChange(path: path, indexCode: ".", worktreeCode: code), area: .working, rawPatch: "\(path)\(added)\(removed)",
                        hunks: [hunk], fingerprint: "f", isPartialSupported: true, notice: nil)
    }

    func testPathRules() {
        XCTAssertEqual(ReviewRiskRules.pathRisk(FileChange(path: ".env", indexCode: "?", worktreeCode: "?"), area: .working).level, .high)
        XCTAssertEqual(ReviewRiskRules.pathRisk(FileChange(path: "Tests/AppTests.swift", indexCode: ".", worktreeCode: "D"), area: .working).reasons, ["删了测试"])
        XCTAssertEqual(ReviewRiskRules.pathRisk(FileChange(path: "web/package.json", indexCode: ".", worktreeCode: "M"), area: .working).reasons, ["依赖变动"])
        XCTAssertEqual(ReviewRiskRules.pathRisk(FileChange(path: ".github/workflows/ci.yml", indexCode: "M", worktreeCode: "."), area: .staged).level, .caution)
        XCTAssertEqual(ReviewRiskRules.pathRisk(FileChange(path: "docs/guide.md", indexCode: ".", worktreeCode: "M"), area: .working).level, .none)
        XCTAssertTrue(ReviewRiskRules.isTestPath("src/user.spec.ts"))
        XCTAssertTrue(ReviewRiskRules.isTestPath("pkg/handler_test.go"))
        XCTAssertFalse(ReviewRiskRules.isTestPath("src/contest.swift"))
    }

    func testDiffRules() {
        XCTAssertEqual(ReviewRiskRules.assess(diff("app/config.js", added: ["const key = \"sk-abcdefghijklmnopqrstuvwx\""])).reasons, ["疑似密钥"])
        XCTAssertEqual(ReviewRiskRules.assess(diff("tests/test_api.py", added: ["x"], removed: 12)).level, .high)
        XCTAssertEqual(ReviewRiskRules.assess(diff("src/big.swift", removed: 120)).reasons, ["大段删除 120 行"])
        XCTAssertEqual(ReviewRiskRules.assess(diff("src/small.swift", added: ["a"], removed: 3)).level, .none)
    }

    func testOrderingIsStableWithinALevel() {
        let items = ["a", "risky", "b", "warn", "c"]
        let level: (String) -> ReviewRisk.Level = { $0 == "risky" ? .high : ($0 == "warn" ? .caution : .none) }
        XCTAssertEqual(ReviewRiskRules.ordered(items, level: level), ["risky", "warn", "a", "b", "c"])
    }
}
