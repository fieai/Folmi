import XCTest
@testable import Folmi

final class TerrazzoCompletionTests: XCTestCase {
    private func snapshot(project: String = "one", enabled: Bool = true, acceptance: UUID? = nil,
                          keys: Set<String> = [], total: Int = 2, remaining: Int = 2,
                          loading: Bool = false, busy: Bool = false,
                          completeList: Bool = true) -> TerrazzoCompletionFeedback.Snapshot {
        .init(project: project, enabled: enabled, acceptance: acceptance, reviewedKeys: keys,
              total: total, remaining: remaining, loading: loading, busy: busy, completeList: completeList)
    }

    func testNewSuccessfulAcceptanceCompletesOnceAfterReloadSettles() {
        var feedback = TerrazzoCompletionFeedback()
        let acceptance = UUID()
        XCTAssertFalse(feedback.observe(snapshot()))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0,
                                                loading: true, busy: true)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0, busy: true)))
        let complete = snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0)
        XCTAssertTrue(feedback.observe(complete))
        XCTAssertFalse(feedback.observe(complete))
    }

    func testOpeningCompletedReviewAndSwitchingProjectsDoNotCelebrate() {
        var feedback = TerrazzoCompletionFeedback()
        XCTAssertFalse(feedback.observe(snapshot(acceptance: UUID(), keys: ["a", "b"], remaining: 0)))
        XCTAssertFalse(feedback.observe(snapshot(project: "two")))
        XCTAssertFalse(feedback.observe(snapshot(project: "one", acceptance: UUID(), keys: ["a", "b"], remaining: 0)))
    }

    func testFailureAndExternalCompletionDoNotArmFeedback() {
        var feedback = TerrazzoCompletionFeedback()
        XCTAssertFalse(feedback.observe(snapshot()))
        XCTAssertFalse(feedback.observe(snapshot(busy: true)))
        XCTAssertFalse(feedback.observe(snapshot()))
        XCTAssertFalse(feedback.observe(snapshot(keys: ["a", "b"], remaining: 0)))
    }

    func testIntermediatePartialLoadCannotCelebrate() {
        var feedback = TerrazzoCompletionFeedback()
        let acceptance = UUID()
        XCTAssertFalse(feedback.observe(snapshot()))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a"], total: 1, remaining: 0, loading: true)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a"], remaining: 1)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a"], remaining: 1)))
        XCTAssertTrue(feedback.observe(snapshot(acceptance: UUID(), keys: ["a", "b"], remaining: 0)))
    }

    func testTruncatedOrFailedListAndEmptyListDoNotCelebrate() {
        for total in [0, 2] {
            var feedback = TerrazzoCompletionFeedback()
            let acceptance = UUID()
            XCTAssertFalse(feedback.observe(snapshot()))
            XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], total: total,
                                                    remaining: 0, completeList: total == 0)))
            XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0)))
        }
    }

    func testRepeatedAcceptanceWithoutNewReviewedKeysDoesNotCelebrate() {
        var feedback = TerrazzoCompletionFeedback()
        XCTAssertFalse(feedback.observe(snapshot(keys: ["a"], remaining: 1)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: UUID(), keys: ["a"], remaining: 0)))
    }

    func testOtherThemesAndEnablingThemeOnFinishedReviewDoNotCelebrate() {
        var feedback = TerrazzoCompletionFeedback()
        let acceptance = UUID()
        XCTAssertFalse(feedback.observe(snapshot(enabled: false)))
        XCTAssertFalse(feedback.observe(snapshot(enabled: false, acceptance: acceptance, keys: ["a", "b"], remaining: 0)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0)))
    }

    func testSwitchingProjectDropsAnAcceptanceWaitingForReload() {
        var feedback = TerrazzoCompletionFeedback()
        let acceptance = UUID()
        XCTAssertFalse(feedback.observe(snapshot()))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0, busy: true)))
        XCTAssertFalse(feedback.observe(snapshot(project: "two", acceptance: acceptance, keys: ["a", "b"], remaining: 0)))
        XCTAssertFalse(feedback.observe(snapshot(project: "one", acceptance: acceptance, keys: ["a", "b"], remaining: 0)))
    }

    func testFinalEmptyFileGetsItsStagedKeyAfterAcceptanceAndReload() {
        var feedback = TerrazzoCompletionFeedback()
        let acceptance = UUID()
        XCTAssertFalse(feedback.observe(snapshot(total: 1, remaining: 1)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, total: 1, remaining: 1, busy: true)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, total: 1, remaining: 1, loading: true, busy: true)))
        // acceptFile's after callback marks the newly loaded staged file before mutate clears busy.
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["staged-empty"], total: 1, remaining: 0, busy: true)))
        XCTAssertTrue(feedback.observe(snapshot(acceptance: acceptance, keys: ["staged-empty"], total: 1, remaining: 0)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["staged-empty"], total: 1, remaining: 0)))
    }

    func testLedgerPublishedBeforeAcceptanceStillUsesPreActionBaseline() {
        var feedback = TerrazzoCompletionFeedback()
        let acceptance = UUID()
        XCTAssertFalse(feedback.observe(snapshot()))
        XCTAssertFalse(feedback.observe(snapshot(keys: ["a", "b"], remaining: 0, busy: true)))
        XCTAssertFalse(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0, busy: true)))
        XCTAssertTrue(feedback.observe(snapshot(acceptance: acceptance, keys: ["a", "b"], remaining: 0)))
    }
}
