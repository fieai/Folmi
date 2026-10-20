import XCTest
@testable import FolmiCore

final class LineDiffTests: XCTestCase {
    private typealias Change = LineDiff.Change

    func testBasicShapes() {
        XCTAssertEqual(LineDiff.changes(old: ["a", "b"], new: ["a", "b"]), [])
        XCTAssertEqual(LineDiff.changes(old: ["a", "c"], new: ["a", "b", "c"]), [Change(old: 1..<1, new: 1..<2)])
        XCTAssertEqual(LineDiff.changes(old: ["a", "b", "c"], new: ["a", "c"]), [Change(old: 1..<2, new: 1..<1)])
        XCTAssertEqual(LineDiff.changes(old: ["a", "b", "c"], new: ["a", "x", "c"]), [Change(old: 1..<2, new: 1..<2)])
        XCTAssertEqual(LineDiff.changes(old: [], new: ["a"]), [Change(old: 0..<0, new: 0..<1)])
        XCTAssertEqual(LineDiff.changes(old: ["a", "b", "c", "d", "e"], new: ["x", "b", "c", "d", "y", "e"]),
                       [Change(old: 0..<1, new: 0..<1), Change(old: 4..<4, new: 4..<5)])
    }

    func testRandomEditsRebuildNewTextAndKeepUnchangedLinesAligned() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let old = (0..<Int.random(in: 0...30, using: &generator)).map { _ in String(Int.random(in: 0...6, using: &generator)) }
            var new = old
            for _ in 0..<Int.random(in: 0...6, using: &generator) {
                switch Int.random(in: 0...2, using: &generator) {
                case 0: new.insert(String(Int.random(in: 0...9, using: &generator)), at: Int.random(in: 0...new.count, using: &generator))
                case 1 where !new.isEmpty: new.remove(at: Int.random(in: 0..<new.count, using: &generator))
                default: if !new.isEmpty { new[Int.random(in: 0..<new.count, using: &generator)] = "z" }
                }
            }
            let changes = LineDiff.changes(old: old, new: new)
            var rebuilt: [String] = [], cursor = 0
            for change in changes {
                XCTAssertGreaterThanOrEqual(change.old.lowerBound, cursor)
                rebuilt += old[cursor..<change.old.lowerBound]
                rebuilt += new[change.new]
                cursor = change.old.upperBound
                XCTAssertFalse(change.old.isEmpty && change.new.isEmpty)
            }
            rebuilt += old[cursor...]
            XCTAssertEqual(rebuilt, new, "old \(old) new \(new)")
        }
    }

    func testEditLimitFallsBackToOneChangeForTheDifferingMiddle() {
        let old = (0..<50).map { "o\($0)" }, new = (0..<50).map { "n\($0)" }
        XCTAssertEqual(LineDiff.changes(old: ["keep"] + old + ["end"], new: ["keep"] + new + ["end"], maxEdits: 10),
                       [Change(old: 1..<51, new: 1..<51)])
    }
}
