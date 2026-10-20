import SwiftUI
import XCTest
@testable import Folmi

final class WelcomeMarkTests: XCTestCase {
    func testMarkPartsMatchTheBundledRig() throws {
        let url = try XCTUnwrap(AppResources.folder("Brand")?.appendingPathComponent("Mascot/folmi-mascot.svg"))
        let svg = try String(contentsOf: url, encoding: .utf8)
        for data in [FolmiMark.bodyData, FolmiMark.tailData, FolmiMark.earData, FolmiMark.earCreaseData,
                     FolmiMark.highlightData, FolmiMark.accentData] {
            XCTAssertTrue(svg.contains("d=\"\(data)\""), "out of sync with folmi-mascot.svg: \(data.prefix(24))…")
        }
    }

    func testPathReaderBuildsTheRigShapes() {
        let body = FolmiMark.body.boundingRect
        XCTAssertEqual(body.minX, 175, accuracy: 1)
        XCTAssertEqual(body.minY, 61, accuracy: 1)
        XCTAssertEqual(body.maxX, 408, accuracy: 1)
        XCTAssertEqual(body.maxY, 351, accuracy: 1)
        XCTAssertTrue(FolmiMark.silhouette.contains(CGPoint(x: 274, y: 300)), "the stem is filled")
        XCTAssertFalse(FolmiMark.silhouette.contains(CGPoint(x: 400, y: 400)), "the space right of the tail is empty")
        // Implicit line-tos after a move, and relative-free multi-command strings.
        XCTAssertEqual(SVGPathData.path("M0 0 10 0 10 10Z").boundingRect, CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(FolmiMark.accent.boundingRect.minY, 49, accuracy: 0.5)
    }

    func testFittingKeepsTheWholeMarkInside() {
        let size = CGSize(width: 160, height: 140)
        let rect = FolmiMark.silhouette.boundingRect.applying(FolmiMark.fit(size))
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
    }

    func testGreetingStartsHiddenAndEndsAtRest() {
        XCTAssertEqual(FolmiGreeting.pose(at: 0).opacity, 0)
        XCTAssertEqual(FolmiGreeting.pose(at: FolmiGreeting.duration), .rest)
        XCTAssertEqual(FolmiGreeting.pose(at: .infinity), .rest)
        XCTAssertLessThan(FolmiGreeting.pose(at: 1.1).blink, 0.5, "it blinks once")
        XCTAssertNotEqual(FolmiGreeting.pose(at: 1.35).tail, 0, "it waves its tail")
        XCTAssertGreaterThan(FolmiGreeting.pose(at: 1.71).accent, 0.9, "a spark flashes at the end")
    }

    func testGazeFollowsThePointerWithinReach() {
        XCTAssertEqual(FolmiGreeting.gaze(toward: nil), .zero)
        let right = FolmiGreeting.gaze(toward: CGPoint(x: 1000, y: FolmiMark.eyesAnchor.y))
        XCTAssertEqual(right.width, 7, accuracy: 0.001)
        XCTAssertEqual(right.height, 0, accuracy: 0.001)
    }

    func testTraceDrawsTheOutlineThenInksIt() {
        let start = ZincTrace.frame(at: 0)
        XCTAssertEqual(start.trace, 0)
        XCTAssertEqual(start.fill, 0)
        XCTAssertEqual(start.pen, 1)
        var last = 0.0
        for step in 0...15 {
            let trace = ZincTrace.frame(at: Double(step) * 0.1).trace
            XCTAssertGreaterThanOrEqual(trace, last)
            last = trace
        }
        XCTAssertEqual(last, 1)
        XCTAssertEqual(Set(stride(from: 1.5, to: 1.8, by: 0.02).map { ZincTrace.frame(at: $0).fill }), [0, 1.0 / 3, 2.0 / 3, 1],
                       "the ink lands in hard steps")
        XCTAssertEqual(ZincTrace.frame(at: ZincTrace.duration), .rest)
        XCTAssertEqual(ZincTrace.frame(at: .infinity), .rest)
    }

    func testBricksFormTheMarkAndLandInWholeCells() {
        let size = PixelBricks.standardSize
        let bricks = PixelBricks.bricks(in: size)
        XCTAssertEqual(bricks, PixelBricks.cachedBricks(in: size))
        XCTAssertTrue((100...400).contains(bricks.count), "\(bricks.count) bricks")
        XCTAssertEqual(bricks.filter(\.ink).count, 2, "one ink brick per eye")
        let rows = Int(size.height / PixelBricks.cell)
        let top = bricks.min { $0.row < $1.row }!, bottom = bricks.max { $0.row < $1.row }!
        XCTAssertLessThan(PixelBricks.delay(bottom, rows: rows), PixelBricks.delay(top, rows: rows), "bottom rows land first")
        XCTAssertNil(PixelBricks.lift(top, rows: rows, at: 0), "a brick is not drawn before it enters")
        for brick in bricks {
            XCTAssertEqual(PixelBricks.lift(brick, rows: rows, at: PixelBricks.duration), 0, "every brick has landed")
        }
    }

    func testRecentRowsReadTheBranchFromHead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("welcome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        XCTAssertNil(WelcomeRecents.branch(at: root.appendingPathComponent("missing").path))
        try "ref: refs/heads/feat/brand\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WelcomeRecents.branch(at: root.path), "feat/brand")
        try "3cd77a7d1234\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WelcomeRecents.branch(at: root.path), "3cd77a7")

        let worktree = root.appendingPathComponent("wt")
        let linked = root.appendingPathComponent("linked-git")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: linked.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(linked.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WelcomeRecents.branch(at: worktree.path), "main")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(WelcomeRecents.abbreviated(home + "/Projects/a"), "~/Projects/a")
        XCTAssertEqual(WelcomeRecents.abbreviated("/tmp/a"), "/tmp/a")
    }
}
