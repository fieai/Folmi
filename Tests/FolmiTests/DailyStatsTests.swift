import XCTest
@testable import Folmi

final class DailyStatsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(offset) * 86_400) }

    func testCountsPerDayAndStreak() {
        var stats = DailyStats()
        stats.record(.accepted, now: day(0), calendar: calendar)
        stats.record(.accepted, count: 2, now: day(1), calendar: calendar)
        stats.record(.rejected, now: day(1), calendar: calendar)
        stats.record(.aiUndone, now: day(2), calendar: calendar)
        XCTAssertEqual(stats.days[DailyStats.dayKey(day(1), calendar: calendar)], DailyStats.Day(accepted: 2, rejected: 1, aiUndone: 0))
        XCTAssertEqual(stats.streak(now: day(2), calendar: calendar), 3)
        // Today nothing yet: the streak up to yesterday still counts; a gap ends it.
        XCTAssertEqual(stats.streak(now: day(3), calendar: calendar), 3)
        XCTAssertEqual(stats.streak(now: day(4), calendar: calendar), 0)
    }

    func testKeepsSixtyDays() {
        var stats = DailyStats()
        for offset in 0..<70 { stats.record(.accepted, now: day(offset), calendar: calendar) }
        XCTAssertEqual(stats.days.count, 60)
        XCTAssertNil(stats.days[DailyStats.dayKey(day(0), calendar: calendar)])
    }

    func testReviewKeysComeFirstOnTheReviewPage() {
        XCTAssertEqual(ShortcutGroup.all(reviewing: true).first?.title, "逐个验收")
        XCTAssertEqual(ShortcutGroup.all(reviewing: false).last?.title, "逐个验收")
    }
}

@MainActor
final class TourTests: XCTestCase {
    func testStepsTickOffFromTheirActions() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = FolmiModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace.json")))
        XCTAssertTrue(model.tour.done.isEmpty)
        model.showContent(.allChanges)
        model.showShortcuts = .held
        XCTAssertEqual(model.tour.done, [.review, .shortcuts])
        // Undo with nothing to undo does not count.
        model.undoGitOperation()
        XCTAssertFalse(model.tour.done.contains(.undo))
        model.dismissTour()
        model.completeTour(.accept)
        XCTAssertFalse(model.tour.done.contains(.accept), "a closed tour stays closed")
        XCTAssertFalse(model.showsTour)
    }
}
