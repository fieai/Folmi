import XCTest
@testable import FolmiCore
@testable import Folmi

final class ReviewFlowTests: XCTestCase {
    private func diff(_ path: String, _ patch: String, area: ChangeArea = .working) -> FileDiff {
        FileDiff(file: FileChange(path: path, indexCode: ".", worktreeCode: "M"), area: area, rawPatch: patch,
                 hunks: Patch.hunks(patch), fingerprint: UUID().uuidString, isPartialSupported: true, notice: nil)
    }

    func testLineKeysSurviveMovesAndAreaChanges() {
        let a = diff("a.txt", "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n")
        let moved = diff("a.txt", "@@ -40,3 +40,3 @@\n other\n ctx\n-old\n+new\n", area: .staged)
        XCTAssertEqual(Set(ReviewProgress.lineKeys(a).values), Set(ReviewProgress.lineKeys(moved).values))
        let changed = diff("a.txt", "@@ -1,2 +1,2 @@\n ctx\n-old\n+newer\n")
        XCTAssertNotEqual(Set(ReviewProgress.lineKeys(a).values), Set(ReviewProgress.lineKeys(changed).values))
        let other = diff("b.txt", "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n")
        XCTAssertTrue(Set(ReviewProgress.lineKeys(a).values).isDisjoint(with: ReviewProgress.lineKeys(other).values))
    }

    func testRepeatedLinesGetDistinctKeys() {
        let d = diff("a.txt", "@@ -1,1 +1,3 @@\n+same\n+same\n ctx\n")
        XCTAssertEqual(Set(ReviewProgress.lineKeys(d).values).count, 2)
    }

    /// The same text added once in the index and once in the work tree: two lines to review, not one.
    func testRepeatedTextInBothAreasIsReviewedSeparatelyAndSurvivesStaging() {
        let staged = diff("a.txt", "@@ -1,1 +1,2 @@\n top\n+\n", area: .staged)
        let working = diff("a.txt", "@@ -5,1 +5,2 @@\n mid\n+\n")
        var ledger = ReviewLedger()
        XCTAssertEqual(ReviewTally.make([staged, working], ledger: ledger), ReviewTally(hunks: 2, seen: 0))
        // Seeing the staged one leaves the work-tree one unseen.
        ReviewProgress.hunkKeys(staged.hunks[0], in: ReviewProgress.lineKeys(staged)).forEach { ledger.insert($0) }
        XCTAssertEqual(ReviewTally.make([staged, working], ledger: ledger), ReviewTally(hunks: 2, seen: 1))
        // See the work-tree one too, then stage it: both lines now sit in the index, still seen.
        ReviewProgress.hunkKeys(working.hunks[0], in: ReviewProgress.lineKeys(working, staged: staged)).forEach { ledger.insert($0) }
        let merged = diff("a.txt", "@@ -1,1 +1,2 @@\n top\n+\n@@ -4,1 +5,2 @@\n mid\n+\n", area: .staged)
        XCTAssertEqual(ReviewTally.make([merged], ledger: ledger), ReviewTally(hunks: 2, seen: 2))
    }

    func testTallyAndLedgerLimit() {
        let d = diff("a.txt", "@@ -1,2 +1,2 @@\n-a\n+b\n@@ -10,2 +10,2 @@\n-c\n+d\n")
        var ledger = ReviewLedger()
        XCTAssertEqual(ReviewTally.make([d], ledger: ledger), ReviewTally(hunks: 2, seen: 0))
        let keys = ReviewProgress.lineKeys(d)
        ReviewProgress.hunkKeys(d.hunks[0], in: keys).forEach { ledger.insert($0) }
        XCTAssertEqual(ReviewTally.make([d], ledger: ledger).seen, 1)
        for index in 0..<(ReviewProgress.limit + 10) { ledger.insert("k\(index)") }
        XCTAssertEqual(ledger.order.count, ReviewProgress.limit)
        XCTAssertFalse(ledger.contains("k0")); XCTAssertTrue(ledger.contains("k\(ReviewProgress.limit + 9)"))
    }

    func testNewFileIsOneReviewItem() {
        let file = FileDiff(file: FileChange(path: "n.txt", indexCode: "?", worktreeCode: "?"), area: .working, rawPatch: "hello\n",
                            hunks: [], fingerprint: "f", isPartialSupported: false, notice: nil)
        var ledger = ReviewLedger()
        XCTAssertEqual(ReviewTally.make([file], ledger: ledger).hunks, 1)
        ledger.insert(ReviewProgress.fileKey(file)!)
        XCTAssertEqual(ReviewTally.make([file], ledger: ledger).remaining, 0)
    }

    func testSecretScanFindsKeysAndSensitiveFiles() {
        XCTAssertFalse(SecretScan.findings(in: "+let key = \"sk-abcdefghijklmnopqrstuvwxyz123\"").isEmpty)
        XCTAssertFalse(SecretScan.findings(in: "-----BEGIN OPENSSH PRIVATE KEY-----").isEmpty)
        XCTAssertFalse(SecretScan.findings(in: "API_KEY = 'abcdefghijklmnopqrstuvwxyz'").isEmpty)
        XCTAssertTrue(SecretScan.findings(in: "+let skip = true\n+// token count").isEmpty)
        XCTAssertTrue(SecretScan.isSensitivePath("config/.env")); XCTAssertTrue(SecretScan.isSensitivePath(".env.local"))
        XCTAssertFalse(SecretScan.isSensitivePath(".env.example")); XCTAssertFalse(SecretScan.isSensitivePath("env.swift"))
    }

    func testImportsLLMCommitEnv() {
        let text = """
        # comment
        COMMIT_LLM_BASE_URL=https://ark.cn-beijing.volces.com/api/coding
        COMMIT_LLM_MODEL="minimax-m3"
        COMMIT_LLM_API_KEY=ark-key\u{200B}
        COMMIT_LLM_API_FORMAT=anthropic
        """
        let imported = AISettings.importEnv(text)
        XCTAssertEqual(imported.provider?.baseURL, "https://ark.cn-beijing.volces.com/api/coding")
        XCTAssertEqual(imported.provider?.model, "minimax-m3")
        XCTAssertEqual(imported.provider?.kind, .anthropic)
        XCTAssertEqual(imported.key, "ark-key")
    }

    func testCleansCommitMessageFences() {
        XCTAssertEqual(FolmiModel.cleanCommitMessage("```\nfeat: add x\n\nbody\n```\n"), "feat: add x\n\nbody")
    }
}
