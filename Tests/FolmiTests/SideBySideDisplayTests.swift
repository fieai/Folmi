import XCTest
import FolmiCore
@testable import Folmi

final class SideBySideDisplayTests: XCTestCase {
    private func diff(_ hunks: [DiffHunk], raw: String = "original patch", untracked: Bool = false, partial: Bool = true) -> FileDiff {
        FileDiff(file: FileChange(path: "sample.js", indexCode: untracked ? "?" : ".", worktreeCode: untracked ? "?" : "M"),
                 area: .working, rawPatch: raw, hunks: hunks, fingerprint: "original fingerprint",
                 isPartialSupported: partial, notice: untracked ? "新文件请先按整个文件暂存。" : nil)
    }

    private func hunk(id: String = "first", offset: Int = 0, count: Int) -> DiffHunk {
        DiffHunk(id: id, header: "@@ -1,\(count) +1,\(count) @@",
                 lines: (0..<count).map { DiffLine(id: offset + $0, text: "line \($0)", kind: .context) })
    }

    func testOrdinaryDiffRetainsAllRowsOriginalIDsAndPartialActions() throws {
        let source = diff([DiffHunk(id: "first", header: "@@ -7 +9 @@", lines: [
            DiffLine(id: 40, text: "old", kind: .deletion), DiffLine(id: 41, text: "new", kind: .addition)
        ])])
        let plan = SideBySideDisplayBudget.plan(for: source)
        XCTAssertTrue(plan.partialAllowed)
        XCTAssertFalse(plan.isLimited)
        XCTAssertNil(plan.notice)
        XCTAssertEqual(plan.displayedRowCount, 1)
        XCTAssertEqual(plan.sections.first?.rows.first?.old?.line.id, 40)
        XCTAssertEqual(plan.sections.first?.rows.first?.new?.line.id, 41)
        XCTAssertEqual(plan.sections.first?.hunk, source.hunks.first)
        XCTAssertEqual(source.rawPatch, "original patch")
    }

    func testRowBudgetIsSharedAcrossHunksAndDisablesAllPartialActions() {
        let source = diff([hunk(count: 1_500), hunk(id: "second", offset: 2_000, count: 1_500)])
        let plan = SideBySideDisplayBudget.plan(for: source, maximumRows: 2_000)
        XCTAssertEqual(plan.sections.map { $0.rows.count }, [1_500, 500])
        XCTAssertEqual(plan.displayedRowCount, 2_000)
        XCTAssertTrue(plan.rowsLimited)
        XCTAssertFalse(plan.partialAllowed, "An earlier fully shown hunk must also lose its partial action when the file is truncated")
        XCTAssertNotNil(plan.notice)
        XCTAssertEqual(source.hunks[1].lines.count, 1_500)
        XCTAssertEqual(plan.sections[1].rows.last?.old?.line.id, 2_499)
    }

    func testLongReplacementStillPairsBothSidesBeforeClippingRows() throws {
        let removed = (0..<3_000).map { DiffLine(id: $0, text: "old \($0)", kind: .deletion) }
        let added = (0..<3_000).map { DiffLine(id: 10_000 + $0, text: "new \($0)", kind: .addition) }
        let source = diff([DiffHunk(id: "large", header: "@@ -1,3000 +1,3000 @@", lines: removed + added)])
        let plan = SideBySideDisplayBudget.plan(for: source, maximumRows: 2_000)
        let rows = try XCTUnwrap(plan.sections.first?.rows)
        XCTAssertEqual(rows.count, 2_000)
        XCTAssertEqual(rows.last?.old?.line.id, 1_999)
        XCTAssertEqual(rows.last?.new?.line.id, 11_999)
        XCTAssertEqual(rows.last?.old?.lineNumber, 2_000)
        XCTAssertEqual(rows.last?.new?.lineNumber, 2_000)
        XCTAssertFalse(plan.partialAllowed)
    }

    func testBudgetCountsAlignedRowsRatherThanPatchSourceTokens() {
        let removed = (0..<2_000).map { DiffLine(id: $0, text: "old", kind: .deletion) }
        let added = (0..<2_000).map { DiffLine(id: 10_000 + $0, text: "new", kind: .addition) }
        let plan = SideBySideDisplayBudget.plan(for: diff([DiffHunk(id: "full", header: "@@ -1,2000 +1,2000 @@", lines: removed + added)]), maximumRows: 2_000)
        XCTAssertEqual(plan.displayedRowCount, 2_000)
        XCTAssertFalse(plan.isLimited)
        XCTAssertTrue(plan.partialAllowed)
    }

    func testContextBetweenSkewedChangesNeverPairsUnrelatedLinesAtTheBoundary() throws {
        let removals = (0..<1_000).map { DiffLine(id: $0, text: "removed \($0)", kind: .deletion) }
        let anchor = DiffLine(id: 1_000, text: "anchor", kind: .context)
        let additions = (0..<1_100).map { DiffLine(id: 2_000 + $0, text: "added \($0)", kind: .addition) }
        let source = diff([DiffHunk(id: "skewed", header: "@@ -1,1001 +1,1101 @@", lines: removals + [anchor] + additions)])
        let plan = SideBySideDisplayBudget.plan(for: source, maximumRows: 2_000)
        let rows = try XCTUnwrap(plan.sections.first?.rows)
        XCTAssertEqual(rows.count, 2_000)
        XCTAssertNil(rows[999].new)
        XCTAssertEqual(rows[1_000].old?.line.id, anchor.id)
        XCTAssertEqual(rows[1_000].new?.line.id, anchor.id)
        XCTAssertNil(rows[1_001].old)
        XCTAssertEqual(rows[1_001].new?.line.text, "added 0")
        XCTAssertFalse(plan.partialAllowed)
    }

    func testMetadataConsumesPreviewSpaceWithoutChangingContentLineNumbers() throws {
        var lines: [DiffLine] = []
        for index in 0..<1_200 {
            lines.append(DiffLine(id: index * 2, text: "old \(index)", kind: .deletion))
            lines.append(DiffLine(id: index * 2 + 1, text: "\\ No newline at end of file", kind: .meta))
        }
        let plan = SideBySideDisplayBudget.plan(for: diff([DiffHunk(id: "metadata", header: "@@ -1,1200 +0,0 @@", lines: lines)]), maximumRows: 2_000)
        let rows = try XCTUnwrap(plan.sections.first?.rows)
        XCTAssertEqual(rows.count, 2_000)
        XCTAssertEqual(rows[1_998].old?.lineNumber, 1_000)
        XCTAssertNil(rows[1_999].old?.lineNumber)
        XCTAssertFalse(plan.partialAllowed)
    }

    func testClippedLineDisablesPartialActionsAndPreservesOriginalPatchAndLine() throws {
        let long = String(repeating: "x", count: 5_000)
        let source = diff([DiffHunk(id: "long", header: "@@ -1 +1 @@", lines: [DiffLine(id: 91, text: long, kind: .addition)])], raw: long)
        let plan = SideBySideDisplayBudget.plan(for: source)
        XCTAssertTrue(plan.textLimited)
        XCTAssertFalse(plan.partialAllowed)
        XCTAssertEqual(source.rawPatch, long)
        XCTAssertEqual(plan.sections.first?.rows.first?.new?.line.text, long)
        let visible = SideBySideDisplayBudget.clippedText(long)
        XCTAssertLessThanOrEqual(visible.text.utf16.count, 4_096)
        XCTAssertTrue(visible.text.hasSuffix("…"))
    }

    func testSurrogateBoundaryIsNotReplacedWithInvalidUnicode() {
        let input = String(repeating: "a", count: 4_094) + "😀" + "tail"
        let visible = SideBySideDisplayBudget.clippedText(input)
        XCTAssertTrue(visible.limited)
        XCTAssertFalse(visible.text.contains("�"))
        XCTAssertLessThanOrEqual(visible.text.utf16.count, 4_096)
        XCTAssertTrue(visible.text.hasSuffix("…"))
    }

    func testExpandedTabsAlsoRespectTheVisibleLineBudget() {
        let visible = SideBySideDisplayBudget.clippedText(String(repeating: "\t", count: 2_000))
        XCTAssertTrue(visible.limited)
        XCTAssertLessThanOrEqual(visible.text.utf16.count, 4_096)
        XCTAssertFalse(visible.text.contains("\t"))
    }

    func testMillionEmptyUntrackedLinesHaveABoundedPreviewWithoutChangingTheOriginal() {
        let raw = String(repeating: "\n", count: 1_000_000)
        let source = diff([], raw: raw, untracked: true, partial: false)
        let plan = SideBySideDisplayBudget.plan(for: source, maximumRows: 2_000)
        XCTAssertEqual(plan.displayedRowCount, 2_000)
        XCTAssertTrue(plan.rowsLimited)
        XCTAssertFalse(plan.partialAllowed)
        XCTAssertEqual(plan.untrackedRows.last?.new?.lineNumber, 2_000)
        XCTAssertEqual(source.rawPatch.utf8.count, 1_000_000)
    }

    func testExactlyAtTheRowAndTextBudgetDoesNotDisableSupportedActions() {
        let source = diff([hunk(count: 2_000)])
        let plan = SideBySideDisplayBudget.plan(for: source, maximumRows: 2_000)
        XCTAssertFalse(plan.isLimited)
        XCTAssertTrue(plan.partialAllowed)
        let line = SideBySideDisplayBudget.clippedText(String(repeating: "a", count: 4_096))
        XCTAssertFalse(line.limited)
        XCTAssertEqual(line.text.utf16.count, 4_096)
    }

    func testUnsupportedSmallDiffDoesNotGainPartialActions() {
        let plan = SideBySideDisplayBudget.plan(for: diff([hunk(count: 1)], partial: false))
        XCTAssertFalse(plan.isLimited)
        XCTAssertFalse(plan.partialAllowed)
    }
}
