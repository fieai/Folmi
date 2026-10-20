import AppKit
import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

final class DiffCanvasTests: XCTestCase {
    private func rows(_ count: Int) -> [AlignedDiffRow] {
        (0..<count).map { index in
            switch index % 3 {
            case 0: return AlignedDiffRow(id: index, old: AlignedDiffCell(line: DiffLine(id: index, text: "same \(index)", kind: .context), lineNumber: index + 1),
                                          new: AlignedDiffCell(line: DiffLine(id: index, text: "same \(index)", kind: .context), lineNumber: index + 1))
            case 1: return AlignedDiffRow(id: index, old: AlignedDiffCell(line: DiffLine(id: index, text: "old \(index)", kind: .deletion), lineNumber: index + 1), new: nil)
            default: return AlignedDiffRow(id: index, old: nil,
                                           new: AlignedDiffCell(line: DiffLine(id: index, text: String(repeating: "宽", count: 200), kind: .addition), lineNumber: index + 1))
            }
        }
    }

    @MainActor
    private func host(_ canvas: DiffRowsCanvas, rows count: Int) -> (NSWindow, NSScrollView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        scroll.hasVerticalScroller = true
        canvas.frame = NSRect(x: 0, y: 0, width: 880, height: DiffCanvasMetrics.height(rows: count))
        let document = FlippedView(frame: canvas.frame)
        document.addSubview(canvas)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        canvas.viewDidMoveToWindow()
        return (window, scroll)
    }

    @MainActor
    func testPainterStaysViewportSizedDeepInsideAHugeHunk() throws {
        let canvas = DiffRowsCanvas(frame: .zero)
        canvas.rows = rows(50_000)
        let (window, scroll) = host(canvas, rows: 50_000)
        defer { window.close() }
        let tile = DiffRowsCanvas.tileHeight
        XCTAssertGreaterThan(canvas.liveTileCount, 0)
        XCTAssertLessThanOrEqual(canvas.liveTileCount, Int(ceil(600 / tile)) + 3)

        let target = DiffCanvasMetrics.height(rows: 50_000) - 600
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        canvas.followViewport()
        let painted = canvas.paintedRect
        XCTAssertLessThanOrEqual(painted.minY, target)
        XCTAssertGreaterThanOrEqual(painted.maxY, min(canvas.bounds.height, target + 600) - 1)
        XCTAssertLessThanOrEqual(canvas.liveTileCount, Int(ceil(600 / tile)) + 3)
        XCTAssertEqual(canvas.subviews.count, canvas.liveTileCount, "scrolled-out tiles are dropped with their pixels")

        // A one-row scroll keeps every tile in place, so nothing needs repainting.
        let before = canvas.subviews.compactMap { $0 as? DiffRowsPainter }.map(\.frame)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target - DiffCanvasMetrics.rowHeight))
        canvas.followViewport()
        let after = canvas.subviews.compactMap { $0 as? DiffRowsPainter }.map(\.frame)
        XCTAssertGreaterThanOrEqual(Set(before.map(\.minY)).intersection(after.map(\.minY)).count, before.count - 1, "a one-row scroll keeps the tiles")

        // The tiles really draw the deep rows: an addition row on the new side gets a green tint.
        let additionRow = (Int(painted.minY / DiffCanvasMetrics.rowHeight)...).first { $0 % 3 == 2 }!
        let rowY = CGFloat(additionRow) * DiffCanvasMetrics.rowHeight + 11
        let painter = try XCTUnwrap(canvas.subviews.compactMap { $0 as? DiffRowsPainter }.first { !$0.isHidden && $0.frame.minY <= rowY && $0.frame.maxY > rowY })
        let bitmap = try XCTUnwrap(painter.bitmapImageRepForCachingDisplay(in: painter.bounds))
        painter.cacheDisplay(in: painter.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / painter.bounds.height
        let x = Int((canvas.columnOrigin(1) + DiffCanvasMetrics.textInset - 10) * scale)
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: Int((rowY - painter.frame.minY) * scale))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.alphaComponent, 0.01)
        XCTAssertGreaterThan(color.greenComponent, color.redComponent)
    }

    @MainActor
    func testCheckboxClicksToggleOnlyChangedLinesWhenAllowed() {
        let canvas = DiffRowsCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        canvas.rows = rows(6)
        var toggled: [Int] = []
        canvas.onToggle = { toggled.append($0) }
        let rowY = { (row: Int) in CGFloat(row) * DiffCanvasMetrics.rowHeight + 10 }
        canvas.toggle(at: NSPoint(x: 10, y: rowY(1)))
        XCTAssertEqual(toggled, [], "selection disabled")
        canvas.canSelect = true
        canvas.toggle(at: NSPoint(x: 10, y: rowY(1)))                          // old side deletion
        canvas.toggle(at: NSPoint(x: canvas.columnOrigin(1) + 10, y: rowY(2))) // new side addition
        canvas.toggle(at: NSPoint(x: 10, y: rowY(0)))                          // context
        canvas.toggle(at: NSPoint(x: canvas.columnOrigin(1) + 10, y: rowY(1))) // empty new cell
        canvas.toggle(at: NSPoint(x: 200, y: rowY(4)))                         // text, not checkbox
        XCTAssertEqual(toggled, [1, 2])
        XCTAssertNotNil(canvas.menu(at: NSPoint(x: 200, y: rowY(0))))
    }

    @MainActor
    func testUnifiedPutsRemovedLinesBeforeAddedOnesWithBothNumbers() {
        func cell(_ id: Int, _ text: String, _ kind: DiffLineKind, _ number: Int) -> AlignedDiffCell {
            AlignedDiffCell(line: DiffLine(id: id, text: text, kind: kind), lineNumber: number)
        }
        // A context line, then a replaced pair and an extra addition, then context again.
        let aligned = [
            AlignedDiffRow(id: 0, old: cell(0, "a", .context, 1), new: cell(0, "a", .context, 1)),
            AlignedDiffRow(id: 1, old: cell(1, "b", .deletion, 2), new: cell(3, "B", .addition, 2)),
            AlignedDiffRow(id: 2, old: cell(2, "c", .deletion, 3), new: cell(4, "C", .addition, 3)),
            AlignedDiffRow(id: 3, old: nil, new: cell(5, "D", .addition, 4)),
            AlignedDiffRow(id: 4, old: cell(6, "e", .context, 4), new: cell(6, "e", .context, 5)),
        ]
        let unified = DiffRowsCanvas.unify(aligned)
        XCTAssertEqual(unified.map(\.cell.line.text), ["a", "b", "c", "B", "C", "D", "e"])
        XCTAssertEqual(unified.map(\.oldNumber), [1, 2, 3, nil, nil, nil, 4])
        XCTAssertEqual(unified.map(\.newNumber), [1, nil, nil, 2, 3, 4, 5])
        XCTAssertEqual(DiffRowsCanvas.displayCount(aligned, unified: true), unified.count)
        XCTAssertEqual(DiffRowsCanvas.displayCount(aligned, unified: false), aligned.count)

        let canvas = DiffRowsCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        canvas.rows = aligned
        canvas.unified = true
        canvas.canSelect = true
        XCTAssertEqual(canvas.columnWidth, 800, "one column takes the full width")
        var toggled: [Int] = []
        canvas.onToggle = { toggled.append($0) }
        let rowY = { (row: Int) in CGFloat(row) * DiffCanvasMetrics.rowHeight + 10 }
        canvas.toggle(at: NSPoint(x: 10, y: rowY(1)))   // "b" deletion
        canvas.toggle(at: NSPoint(x: 10, y: rowY(5)))   // "D" addition
        canvas.toggle(at: NSPoint(x: 10, y: rowY(6)))   // context
        XCTAssertEqual(toggled, [1, 5], "line IDs stay the same as side by side, so staging is unchanged")
        canvas.unified = false
        XCTAssertEqual(canvas.displayCount, aligned.count)
    }

    @MainActor
    func testEachSideScrollsHorizontallyOnItsOwnWithinItsContent() {
        let canvas = DiffRowsCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        canvas.rows = rows(6)
        canvas.scrollHorizontally(side: 1, by: -300)
        XCTAssertEqual(canvas.offsets[1], 300)
        XCTAssertEqual(canvas.offsets[0], 0)
        canvas.scrollHorizontally(side: 1, by: -1_000_000)
        XCTAssertEqual(canvas.offsets[1], canvas.maximumOffset(1))
        canvas.scrollHorizontally(side: 0, by: -1_000_000)
        XCTAssertEqual(canvas.offsets[0], canvas.maximumOffset(0))
        XCTAssertLessThan(canvas.maximumOffset(0), canvas.maximumOffset(1), "wide CJK text on the new side scrolls further")
        canvas.scrollHorizontally(side: 1, by: 1_000_000)
        XCTAssertEqual(canvas.offsets[1], 0)
    }

    @MainActor
    func testLargeHunkFitsTheDefaultBudgetAndKeepsPartialActions() {
        let lines = (0..<30_000).flatMap { [DiffLine(id: $0 * 2, text: "old \($0)", kind: .deletion), DiffLine(id: $0 * 2 + 1, text: "new \($0)", kind: .addition)] }
        let hunk = DiffHunk(id: "big", header: "@@ -1,30000 +1,30000 @@", lines: lines)
        let diff = FileDiff(file: FileChange(path: "big.txt", indexCode: ".", worktreeCode: "M"), area: .working, rawPatch: "x",
                            hunks: [hunk], fingerprint: "big-1", isPartialSupported: true, notice: nil)
        let plan = SideBySideDisplayBudget.cachedPlan(for: diff)
        XCTAssertEqual(plan.displayedRowCount, 30_000)
        XCTAssertFalse(plan.isLimited)
        XCTAssertTrue(plan.partialAllowed)
        XCTAssertEqual(SideBySideDisplayBudget.cachedPlan(for: diff).displayedRowCount, 30_000)
    }
}

extension DiffCanvasTests {
    @MainActor
    func testCanvasInsideTheSwiftUIDiffFollowsItsScrollView() throws {
        let lines = (0..<3_000).map { DiffLine(id: $0, text: "added \($0)", kind: .addition) }
        let diff = FileDiff(file: FileChange(path: "a.txt", indexCode: ".", worktreeCode: "M"), area: .working, rawPatch: "x",
                            hunks: [DiffHunk(id: "h", header: "@@ -0,0 +1,3000 @@", lines: lines)], fingerprint: "swiftui-1",
                            isPartialSupported: true, notice: nil)
        let view = SideBySideDiff(diffs: [diff], selectedLines: [:], busy: false, onToggleLine: { _, _ in }, onApplyHunk: { _, _ in },
                                  onApplySelection: { _, _ in }, onStageFile: { _ in }, onUnstageFile: { _ in }, onEditFile: { _ in })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func find(_ view: NSView) -> DiffRowsCanvas? { (view as? DiffRowsCanvas) ?? view.subviews.lazy.compactMap(find).first }
        let canvas = try XCTUnwrap(find(host))
        let scroll = try XCTUnwrap(canvas.enclosingScrollView)
        XCTAssertEqual(canvas.frame.height, DiffCanvasMetrics.height(rows: 3_000), accuracy: 1)
        XCTAssertGreaterThan(canvas.liveTileCount, 0)
        XCTAssertLessThan(canvas.paintedRect.height, 2_000)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let visible = canvas.visibleRect
        XCTAssertFalse(visible.isEmpty)
        XCTAssertLessThanOrEqual(canvas.paintedRect.minY, visible.minY)
        XCTAssertGreaterThanOrEqual(canvas.paintedRect.maxY, visible.maxY - 1)
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
