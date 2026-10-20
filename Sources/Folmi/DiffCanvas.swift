import AppKit
import FolmiCore
import SwiftUI

/// Metrics shared by the canvas and its SwiftUI wrapper.
enum DiffCanvasMetrics {
    static let rowHeight: CGFloat = 22
    static let bottomPadding: CGFloat = 12
    static let checkboxWidth: CGFloat = 24
    static let numberWidth: CGFloat = 47
    static let signWidth: CGFloat = 14
    static var textInset: CGFloat { checkboxWidth + numberWidth + signWidth + 4 }
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * rowHeight + bottomPadding }
}

/// Side-by-side rows for one hunk. The view is as tall as all its rows so the surrounding scroll view can scroll it,
/// but it keeps no drawing of its own: fixed-height tiles cover the visible area plus one tile on each side and are
/// recycled as they scroll out, so a scroll step paints at most a newly exposed tile.
/// Each side scrolls horizontally on its own (trackpad or Shift+wheel) while line numbers and checkboxes stay put.
final class DiffRowsCanvas: NSView {
    var rows: [AlignedDiffRow] = [] {
        didSet { rebuildUnified(); measureColumns(); clampOffsets(); followViewport(); redrawAll() }
    }
    /// One column (like `git diff`): context once with both line numbers, each change block's removed lines before
    /// its added ones. Selection, line IDs and staging are the same as side by side.
    var unified = false {
        didSet { if unified != oldValue { rebuildUnified(); measureColumns(); clampOffsets(); followViewport(); redrawAll() } }
    }
    struct UnifiedRow {
        let cell: AlignedDiffCell
        let oldNumber: Int?
        let newNumber: Int?
    }
    private(set) var unifiedRows: [UnifiedRow] = []
    var displayCount: Int { unified ? unifiedRows.count : rows.count }
    private func rebuildUnified() { unifiedRows = unified ? Self.unify(rows) : [] }

    /// A row that is the same line on both sides (context, or a note outside a change block).
    private static func isShared(_ row: AlignedDiffRow) -> Bool {
        guard let old = row.old, let new = row.new else { return false }
        return old.line.id == new.line.id && old.line.kind != .addition && old.line.kind != .deletion
    }
    static func unify(_ rows: [AlignedDiffRow]) -> [UnifiedRow] {
        var result: [UnifiedRow] = [], removed: [UnifiedRow] = [], added: [UnifiedRow] = []
        result.reserveCapacity(rows.count)
        func flush() { result += removed; result += added; removed.removeAll(); added.removeAll() }
        for row in rows {
            if isShared(row), let old = row.old, let new = row.new {
                flush()
                result.append(UnifiedRow(cell: new, oldNumber: old.lineNumber, newNumber: new.lineNumber))
            } else {
                if let old = row.old { removed.append(UnifiedRow(cell: old, oldNumber: old.lineNumber, newNumber: nil)) }
                if let new = row.new { added.append(UnifiedRow(cell: new, oldNumber: nil, newNumber: new.lineNumber)) }
            }
        }
        flush()
        return result
    }
    /// Rows a hunk takes in the chosen layout, without building them (the SwiftUI frame needs the height).
    static func displayCount(_ rows: [AlignedDiffRow], unified: Bool) -> Int {
        guard unified else { return rows.count }
        return rows.reduce(0) { $0 + (isShared($1) ? 1 : ($1.old == nil ? 0 : 1) + ($1.new == nil ? 0 : 1)) }
    }
    var rowsKey = ""
    var selected: Set<Int> = [] { didSet { if selected != oldValue { redrawAll() } } }
    var canSelect = false { didSet { if canSelect != oldValue { redrawAll() } } }
    var onToggle: ((Int) -> Void)?

    /// Horizontal text offset of the old (0) and new (1) side.
    private(set) var offsets: [CGFloat] = [0, 0]
    private var columns: [Int] = [0, 0]
    /// About 260 pt per tile: a newly exposed strip is cheap to paint and few tiles hold pixels at once.
    static let tileRows = 12
    static var tileHeight: CGFloat { CGFloat(tileRows) * DiffCanvasMetrics.rowHeight }
    private var tiles: [Int: DiffRowsPainter] = [:]
    /// A couple of reusable tiles (about 2 MB each) avoid creating views on every scroll step without holding much memory.
    private var spareTiles: [DiffRowsPainter] = []
    private weak var observedClip: NSClipView?

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let metaFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let numberFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let characterWidth: CGFloat = ("M" as NSString).size(withAttributes: [.font: font]).width

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }
    // Deliberately no draw(_:), updateLayer() or wantsUpdateLayer: a view that never draws gets no backing store.
    // Overriding them made AppKit sometimes allocate a texture for the full (clamped 16k px) height and clear it on
    // every scroll, which stalled scrolling for seconds.

    var columnWidth: CGFloat { unified ? bounds.width : max(0, (bounds.width - 1) / 2) }
    func columnOrigin(_ side: Int) -> CGFloat { side == 0 || unified ? 0 : columnWidth + 1 }
    func side(atX x: CGFloat) -> Int { unified || x < columnWidth + 0.5 ? 0 : 1 }
    func cell(row: Int, side: Int) -> AlignedDiffCell? {
        if unified { return unifiedRows.indices.contains(row) ? unifiedRows[row].cell : nil }
        guard rows.indices.contains(row) else { return nil }
        return side == 0 ? rows[row].old : rows[row].new
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        observedClip = enclosingScrollView?.contentView
        if let clip = observedClip {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(followViewport), name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(followViewport), name: NSView.frameDidChangeNotification, object: clip)
        }
        followViewport()
    }
    override func layout() {
        super.layout()
        clampOffsets()
        followViewport()
    }

    /// Live tiles, in canvas coordinates; for tests and accessibility of what is painted.
    var paintedRect: NSRect { tiles.values.reduce(NSRect.zero) { $0.isEmpty ? $1.frame : $0.union($1.frame) } }
    var liveTileCount: Int { tiles.count }

    /// Keeps tiles over the visible rows plus one tile above and below; tiles that leave are discarded with their pixels.
    /// Tiles that stay in range are not repainted.
    @objc func followViewport() {
        let visible = visibleRect.intersection(bounds)
        let height = Self.tileHeight
        guard !visible.isEmpty, !rows.isEmpty, bounds.height > 0 else {
            for index in Array(tiles.keys) { recycle(index) }
            return
        }
        let lastTile = max(0, Int(ceil(bounds.height / height)) - 1)
        let first = max(0, Int(floor((visible.minY - height) / height)))
        let last = min(lastTile, Int(floor((visible.maxY + height) / height)))
        for index in Array(tiles.keys) where index < first || index > last { recycle(index) }
        guard first <= last else { return }
        for index in first...last {
            let top = CGFloat(index) * height
            let frame = NSRect(x: 0, y: top, width: bounds.width, height: min(height, bounds.height - top))
            if let tile = tiles[index] {
                if tile.frame != frame { tile.frame = frame; tile.needsDisplay = true }
                continue
            }
            let tile = spareTiles.popLast() ?? DiffRowsPainter(frame: frame)
            tile.canvas = self
            tile.frame = frame
            if tile.superview !== self { addSubview(tile) }
            tile.needsDisplay = true
            tiles[index] = tile
        }
    }

    private func recycle(_ index: Int) {
        // Each tile holds a full-width bitmap, so only two leave-behind tiles are kept (detached from the view tree).
        guard let tile = tiles.removeValue(forKey: index) else { return }
        tile.removeFromSuperview()
        if spareTiles.count < 2 { spareTiles.append(tile) }
    }

    private func redrawAll() { tiles.values.forEach { $0.needsDisplay = true } }

    private func measureColumns() {
        // Monospaced: width in cells. CJK and other wide characters take two cells; tabs are drawn as four spaces.
        func cells(_ text: String) -> Int {
            var count = 0
            for scalar in text.unicodeScalars.prefix(SideBySideDisplayBudget.maximumLineUTF16) {
                count += scalar == "\t" ? 4 : (scalar.value >= 0x1100 ? 2 : 1)
            }
            return count
        }
        var old = 0, new = 0
        for row in rows {
            if let cell = row.old { old = max(old, cells(cell.line.text)) }
            if let cell = row.new { new = max(new, cells(cell.line.text)) }
        }
        columns = unified ? [max(old, new), max(old, new)] : [old, new]
    }

    func maximumOffset(_ side: Int) -> CGFloat {
        max(0, CGFloat(columns[side]) * Self.characterWidth + DiffCanvasMetrics.textInset + (unified ? DiffCanvasMetrics.numberWidth : 0)
            + 24 - columnWidth)
    }
    private func clampOffsets() {
        for side in 0...1 { offsets[side] = min(max(0, offsets[side]), maximumOffset(side)) }
    }

    func scrollHorizontally(side: Int, by delta: CGFloat) {
        let next = min(max(0, offsets[side] - delta), maximumOffset(side))
        guard next != offsets[side] else { return }
        offsets[side] = next
        redrawAll()
    }

    /// Row and side under a point in canvas coordinates.
    func hit(_ point: NSPoint) -> (row: Int, side: Int, inCheckbox: Bool)? {
        let row = Int(floor(point.y / DiffCanvasMetrics.rowHeight))
        guard row >= 0, row < displayCount else { return nil }
        let side = side(atX: point.x)
        let local = point.x - columnOrigin(side)
        return (row, side, local >= 0 && local < DiffCanvasMetrics.checkboxWidth)
    }

    func toggle(at point: NSPoint) {
        guard canSelect, let hit = hit(point), hit.inCheckbox, let cell = cell(row: hit.row, side: hit.side),
              cell.line.kind == .addition || cell.line.kind == .deletion else { return }
        onToggle?(cell.line.id)
    }

    func menu(at point: NSPoint) -> NSMenu? {
        guard let hit = hit(point), let cell = cell(row: hit.row, side: hit.side) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "复制这一行", action: #selector(copyLine(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = cell.line.text
        menu.addItem(item)
        if let number = cell.lineNumber {
            let reference = NSMenuItem(title: "复制行号 \(number)", action: #selector(copyLine(_:)), keyEquivalent: "")
            reference.target = self; reference.representedObject = String(number)
            menu.addItem(reference)
        }
        return menu
    }
    @objc private func copyLine(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func accessibilityLabel() -> String? { unified ? "统一差异，\(unifiedRows.count) 行" : "左右差异，\(rows.count) 行" }
}

/// Draws the rows that intersect its frame; it is moved over the visible part of the canvas.
final class DiffRowsPainter: NSView {
    weak var canvas: DiffRowsCanvas?
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Moving a tile must not repaint it; content changes call needsDisplay explicitly.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, !canvas.rows.isEmpty else { return }
        let height = DiffCanvasMetrics.rowHeight
        // Painter coordinates are canvas coordinates shifted by the painter's top.
        let top = frame.minY
        let first = max(0, Int(floor((dirtyRect.minY + top) / height)))
        let last = min(canvas.displayCount - 1, Int(floor((dirtyRect.maxY + top) / height)))
        guard first <= last else { return }
        let width = canvas.columnWidth
        if canvas.unified {
            for row in first...last {
                let line = canvas.unifiedRows[row]
                drawCell(line.cell, side: 0, x: 0, y: CGFloat(row) * height - top, width: width, canvas: canvas,
                         numbers: (line.oldNumber, line.newNumber))
            }
            return
        }
        for side in 0...1 {
            let x = canvas.columnOrigin(side)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x, y: dirtyRect.minY, width: width, height: dirtyRect.height).clip()
            for row in first...last {
                drawCell(canvas.cell(row: row, side: side), side: side, x: x, y: CGFloat(row) * height - top, width: width, canvas: canvas)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        ThemePalette.current.foreground.withAlphaComponent(0.18).setFill()
        NSRect(x: width, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    /// `numbers`: the unified layout's old and new line numbers, drawn in two columns before the sign.
    private func drawCell(_ cell: AlignedDiffCell?, side: Int, x: CGFloat, y: CGFloat, width: CGFloat, canvas: DiffRowsCanvas,
                          numbers: (old: Int?, new: Int?)? = nil) {
        let height = DiffCanvasMetrics.rowHeight
        let rowRect = NSRect(x: x, y: y, width: width, height: height)
        guard let cell else {
            ThemePalette.current.foreground.withAlphaComponent(0.035).setFill(); rowRect.fill(); return
        }
        let kind = cell.line.kind
        let changed = kind == .addition || kind == .deletion
        let isSelected = changed && canvas.selected.contains(cell.line.id)
        if isSelected { ThemePalette.current.accent.withAlphaComponent(0.2).setFill(); rowRect.fill() }
        else if kind == .addition { ThemePalette.current.added.withAlphaComponent(0.11).setFill(); rowRect.fill() }
        else if kind == .deletion { ThemePalette.current.removed.withAlphaComponent(0.10).setFill(); rowRect.fill() }

        if changed {
            let box = NSRect(x: x + 6.5, y: y + 5.5, width: 11, height: 11)
            let path = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
            let alpha: CGFloat = canvas.canSelect ? 1 : 0.4
            if isSelected {
                ThemePalette.current.accent.withAlphaComponent(alpha).setFill(); path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 2.5, y: box.midY)); check.line(to: NSPoint(x: box.minX + 4.7, y: box.maxY - 2.5))
                check.line(to: NSPoint(x: box.maxX - 2.2, y: box.minY + 2.8))
                check.lineWidth = 1.6; ThemePalette.current.onAccent.setStroke(); check.stroke()
            } else {
                ThemePalette.current.secondaryText.withAlphaComponent(0.55 * alpha).setStroke(); path.lineWidth = 1; path.stroke()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: DiffRowsCanvas.numberFont, .foregroundColor: ThemePalette.current.secondaryText]
        func drawNumber(_ number: Int?, column: CGFloat) {
            guard let number else { return }
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: x + DiffCanvasMetrics.checkboxWidth + column + 40 - size.width, y: y + (height - size.height) / 2),
                       withAttributes: attributes)
        }
        let shift = numbers == nil ? 0 : DiffCanvasMetrics.numberWidth
        if let numbers { drawNumber(numbers.old, column: 0); drawNumber(numbers.new, column: shift) }
        else { drawNumber(cell.lineNumber, column: 0) }
        let signX = x + DiffCanvasMetrics.checkboxWidth + DiffCanvasMetrics.numberWidth + shift
        if changed {
            let sign = (kind == .addition ? "+" : "−") as NSString
            sign.draw(at: NSPoint(x: signX + 2, y: y + 3),
                      withAttributes: [.font: DiffRowsCanvas.font, .foregroundColor: kind == .addition ? ThemePalette.current.added : ThemePalette.current.removed])
        }
        let textX = x + DiffCanvasMetrics.textInset + shift
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: textX, y: y, width: max(0, x + width - textX), height: height).clip()
        let text = SideBySideDisplayBudget.clippedText(cell.line.text).text as NSString
        let font = kind == .meta ? DiffRowsCanvas.metaFont : DiffRowsCanvas.font
        text.draw(at: NSPoint(x: textX - canvas.offsets[side], y: y + (height - font.boundingRectForFont.height) / 2 + 1),
                  withAttributes: [.font: font, .foregroundColor: kind == .meta ? ThemePalette.current.secondaryText : ThemePalette.current.foreground])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func canvasPoint(_ event: NSEvent) -> NSPoint? {
        guard let canvas else { return nil }
        return canvas.convert(event.locationInWindow, from: nil)
    }
    override func mouseDown(with event: NSEvent) {
        if let point = canvasPoint(event) { canvas?.toggle(at: point) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        canvasPoint(event).flatMap { canvas?.menu(at: $0) }
    }
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if abs(dx) > abs(dy), let canvas, let point = canvasPoint(event) {
            canvas.scrollHorizontally(side: canvas.side(atX: point.x), by: dx * (event.hasPreciseScrollingDeltas ? 1 : 8))
        } else {
            // Vertical scrolling belongs to the surrounding diff scroll view.
            super.scrollWheel(with: event)
        }
    }
    override func resetCursorRects() {
        guard let canvas, canvas.canSelect else { return }
        for side in canvas.unified ? 0...0 : 0...1 {
            addCursorRect(NSRect(x: canvas.columnOrigin(side), y: 0, width: DiffCanvasMetrics.checkboxWidth, height: bounds.height), cursor: .pointingHand)
        }
    }
}

struct DiffRowsView: NSViewRepresentable {
    let rows: [AlignedDiffRow]
    /// Changes whenever `rows` changes; comparing a key is cheaper than comparing 100,000 rows on every update.
    let rowsKey: String
    let selected: Set<Int>
    let canSelect: Bool
    var unified = false
    let onToggle: (Int) -> Void

    func makeNSView(context: Context) -> DiffRowsCanvas { DiffRowsCanvas(frame: .zero) }
    func updateNSView(_ canvas: DiffRowsCanvas, context: Context) {
        canvas.unified = unified
        if canvas.rowsKey != rowsKey { canvas.rowsKey = rowsKey; canvas.rows = rows }
        canvas.selected = selected
        canvas.canSelect = canSelect
        canvas.onToggle = onToggle
        canvas.window?.invalidateCursorRects(for: canvas)
    }
}
