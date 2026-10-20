import XCTest
@testable import FolmiCore

final class DiffAlignmentTests: XCTestCase {
    private func hunk(_ lines: [(DiffLineKind, String)]) -> DiffHunk {
        hunk("@@ -10,4 +20,4 @@", lines)
    }

    private func hunk(_ header: String, _ lines: [(DiffLineKind, String)]) -> DiffHunk {
        DiffHunk(id: "same-hunk-id", header: header,
                 lines: lines.enumerated().map { DiffLine(id: 100 + $0.offset, text: $0.element.1, kind: $0.element.0) })
    }

    func testContextHasIndependentOldAndNewNumbers() {
        let rows = DiffAlignment.rows(in: hunk([(.context, "one"), (.context, "two")]))
        XCTAssertEqual(rows.compactMap { $0.old?.lineNumber }, [10, 11])
        XCTAssertEqual(rows.compactMap { $0.new?.lineNumber }, [20, 21])
        XCTAssertEqual(rows.map { $0.old?.line.id }, [100, 101])
        XCTAssertEqual(rows.map { $0.new?.line.id }, [100, 101])
    }

    func testPureAdditionLeavesOldCellsEmptyAndCountsOnlyNewLines() {
        let rows = DiffAlignment.rows(in: hunk("@@ -0,0 +1,2 @@", [(.addition, "一"), (.addition, "二")]))
        XCTAssertTrue(rows.allSatisfy { $0.old == nil })
        XCTAssertEqual(rows.compactMap { $0.new?.lineNumber }, [1, 2])
        XCTAssertEqual(rows.compactMap { $0.new?.line.text }, ["一", "二"])
    }

    func testPureDeletionLeavesNewCellsEmpty() {
        let rows = DiffAlignment.rows(in: hunk("@@ -1,2 +0,0 @@", [(.deletion, "one"), (.deletion, "two")]))
        XCTAssertTrue(rows.allSatisfy { $0.new == nil })
        XCTAssertEqual(rows.compactMap { $0.old?.lineNumber }, [1, 2])
    }

    func testReplacementPairsInOrderWithExtraAddedLine() {
        let input = hunk([(.context, "before"), (.deletion, "old A"), (.deletion, "old B"),
                          (.addition, "new A"), (.addition, "new B"), (.addition, "new C"), (.context, "after")])
        let rows = DiffAlignment.rows(in: input)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[1].old?.line.text, "old A")
        XCTAssertEqual(rows[1].new?.line.text, "new A")
        XCTAssertEqual(rows[2].old?.line.text, "old B")
        XCTAssertEqual(rows[2].new?.line.text, "new B")
        XCTAssertNil(rows[3].old)
        XCTAssertEqual(rows[3].new?.line.text, "new C")
        XCTAssertEqual(rows[4].old?.lineNumber, 13)
        XCTAssertEqual(rows[4].new?.lineNumber, 24)
        XCTAssertEqual(rows[1].old?.line.id, 101)
        XCTAssertEqual(rows[1].new?.line.id, 103)
    }

    func testReplacementPairsInOrderWithExtraDeletedLine() {
        let rows = DiffAlignment.rows(in: hunk([(.deletion, "A"), (.deletion, "B"), (.addition, "C"), (.context, "same")]))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].old?.line.text, "A")
        XCTAssertEqual(rows[0].new?.line.text, "C")
        XCTAssertEqual(rows[1].old?.line.text, "B")
        XCTAssertNil(rows[1].new)
        XCTAssertEqual(rows[2].old?.lineNumber, 12)
        XCTAssertEqual(rows[2].new?.lineNumber, 21)
    }

    func testContextSeparatesUnrelatedChanges() {
        let rows = DiffAlignment.rows(in: hunk([(.deletion, "removed"), (.context, "anchor"), (.addition, "added")]))
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0].new)
        XCTAssertEqual(rows[1].old?.line.text, "anchor")
        XCTAssertEqual(rows[1].new?.line.text, "anchor")
        XCTAssertNil(rows[2].old)
        XCTAssertEqual(rows[2].new?.line.text, "added")
        XCTAssertEqual(rows[1].old?.lineNumber, 11)
        XCTAssertEqual(rows[1].new?.lineNumber, 20)
    }

    func testMissingCountsAndHeaderSuffixAreAccepted() {
        let rows = DiffAlignment.rows(in: hunk("@@ -7 +19 @@ func example()", [(.deletion, "old"), (.addition, "new")]))
        XCTAssertEqual(rows.first?.old?.lineNumber, 7)
        XCTAssertEqual(rows.first?.new?.lineNumber, 19)
    }

    func testMalformedHeaderDoesNotInventLineNumbersOrDiscardContent() {
        let rows = DiffAlignment.rows(in: hunk("not a valid header", [(.context, "same"), (.addition, "new")]))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.old?.lineNumber == nil && $0.new?.lineNumber == nil })
        XCTAssertEqual(rows[1].new?.line.id, 101)
    }

    func testEmptyHunkProducesNoRows() {
        XCTAssertTrue(DiffAlignment.rows(in: hunk([])).isEmpty)
    }

    func testNoNewlineAnnotationsRemainOnTheirOwnSideAndDoNotConsumeNumbers() {
        let marker = "\\ No newline at end of file"
        let input = hunk("@@ -1,2 +1,2 @@", [(.deletion, "old"), (.meta, marker),
                                                       (.addition, "new"), (.meta, marker), (.context, "after")])
        let rows = DiffAlignment.rows(in: input)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].old?.line.id, 100)
        XCTAssertEqual(rows[0].new?.line.id, 102)
        XCTAssertEqual(rows[1].old?.line.id, 101)
        XCTAssertEqual(rows[1].new?.line.id, 103)
        XCTAssertNil(rows[1].old?.lineNumber)
        XCTAssertNil(rows[1].new?.lineNumber)
        XCTAssertEqual(rows[2].old?.lineNumber, 2)
        XCTAssertEqual(rows[2].new?.lineNumber, 2)
    }

    func testAnnotationOnOnlyOneReplacementSideDoesNotShiftNextContent() {
        let input = hunk([(.deletion, "old A"), (.meta, "\\ No newline at end of file"), (.deletion, "old B"),
                          (.addition, "new A"), (.addition, "new B")])
        let rows = DiffAlignment.rows(in: input)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].new?.line.text, "new A")
        XCTAssertNil(rows[1].new)
        XCTAssertEqual(rows[2].old?.line.text, "old B")
        XCTAssertEqual(rows[2].new?.line.text, "new B")
        XCTAssertEqual(rows[2].old?.lineNumber, 11)
        XCTAssertEqual(rows[2].new?.lineNumber, 21)
    }

    func testContextAnnotationDoesNotBecomeAnEditableLine() {
        let rows = DiffAlignment.rows(in: hunk([(.context, "same"), (.meta, "\\ No newline at end of file"), (.context, "next")]))
        XCTAssertEqual(rows[1].old?.line.kind, .meta)
        XCTAssertNil(rows[1].old?.lineNumber)
        XCTAssertEqual(rows[2].old?.lineNumber, 11)
        XCTAssertEqual(rows[2].new?.lineNumber, 21)
    }

    func testUnicodeEmptyAndWhitespaceContentAndSourceIDsArePreserved() {
        let input = hunk([(.deletion, ""), (.deletion, "\t  "), (.addition, "👩🏽‍💻 中文 é"), (.addition, "")])
        let rows = DiffAlignment.rows(in: input)
        XCTAssertEqual(rows.compactMap { $0.old?.line.text }, ["", "\t  "])
        XCTAssertEqual(rows.compactMap { $0.new?.line.text }, ["👩🏽‍💻 中文 é", ""])
        XCTAssertEqual(Set(rows.flatMap { [$0.old?.line.id, $0.new?.line.id].compactMap { $0 } }), Set(input.lines.map(\.id)))
    }

    func testHunksWithTheSameIdentifierHaveIndependentNumbersAndRows() {
        let first = hunk("@@ -3 +5 @@", [(.deletion, "A"), (.addition, "B")])
        let second = hunk("@@ -90 +100 @@", [(.deletion, "C"), (.addition, "D")])
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(DiffAlignment.rows(in: first).first?.old?.lineNumber, 3)
        XCTAssertEqual(DiffAlignment.rows(in: second).first?.old?.lineNumber, 90)
        XCTAssertEqual(DiffAlignment.rows(in: second).first?.new?.lineNumber, 100)
    }

    func testRealGitDiffReconstructsBothSidesAndAlignedSelectionStagesOnlyThatSide() async throws {
        let fixture = try AlignmentGitFixture()
        let original = "before\nold A\nold B\nafter\n"
        let working = "before\nnew A\nnew B\nnew C\nafter\n"
        try fixture.write(original)
        try fixture.git(["add", "--", "example.py"])
        try fixture.git(["commit", "-m", "Initial"])
        try fixture.write(working)
        let snapshot = try await fixture.repo.load()
        let file = try XCTUnwrap(snapshot.files.first)
        let diff = try await fixture.repo.diff(for: file, area: .working)
        let hunk = try XCTUnwrap(diff.hunks.first)
        let rows = DiffAlignment.rows(in: hunk)
        XCTAssertEqual(content(rows.compactMap(\.old)), original)
        XCTAssertEqual(content(rows.compactMap(\.new)), working)
        let replacement = try XCTUnwrap(rows.first { $0.new?.line.text == "new A" })
        let selectedID = try XCTUnwrap(replacement.new?.line.id)
        XCTAssertNotEqual(selectedID, replacement.old?.line.id)
        try await fixture.repo.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: [selectedID])
        XCTAssertEqual(try fixture.git(["show", ":example.py"]), "before\nold A\nold B\nnew A\nafter\n")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("example.py"), encoding: .utf8), working)
    }

    private func content(_ cells: [AlignedDiffCell]) -> String {
        cells.filter { $0.line.kind != .meta }.map { $0.line.text + "\n" }.joined()
    }
}

private final class AlignmentGitFixture {
    let temporary: URL
    let root: URL
    let environment: [String: String]
    let repo: GitRepository

    init() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-alignment-" + UUID().uuidString)
        root = temporary.appendingPathComponent("demo-repository")
        let home = temporary.appendingPathComponent("isolated-home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        repo = GitRepository(url: root, environment: environment)
        try git(["init", "--template=", "--initial-branch=main"])
        try git(["config", "user.name", "Alignment Demo"])
        try git(["config", "user.email", "alignment@example.invalid"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try git(["config", "commit.gpgsign", "false"])
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    @discardableResult func git(_ arguments: [String]) throws -> String {
        try GitProcess(directory: root, environment: environment).run(arguments).text
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent("example.py"))
    }
}
