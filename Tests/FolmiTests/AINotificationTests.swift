import XCTest
@testable import FolmiCore
@testable import Folmi

@MainActor
final class AINotificationTests: XCTestCase {
    func testOnlyTurnsEndingAfterLaunchInTheBackgroundNotify() {
        let launched = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(AINotifier.shouldNotify(stopped: launched.addingTimeInterval(30), launched: launched, appActive: false))
        XCTAssertFalse(AINotifier.shouldNotify(stopped: launched.addingTimeInterval(30), launched: launched, appActive: true))
        // A turn read back from an old event log stays quiet.
        XCTAssertFalse(AINotifier.shouldNotify(stopped: launched.addingTimeInterval(-600), launched: launched, appActive: false))
    }

    func testMessageCountsHunksOrFilesAndShortensThePrompt() {
        var batch = AIBatch(id: "b", session: "s", prompt: String(repeating: "改", count: 50), started: Date())
        batch.paths = ["a.swift", "b.swift"]
        let hunks = AINotifier.message(batch: batch, remaining: 3, project: "demo")
        XCTAssertEqual(hunks.title, "Claude 改完了 · demo")
        XCTAssertTrue(hunks.body.hasSuffix("3 处等你验收"))
        XCTAssertTrue(hunks.body.contains("…"))
        batch.prompt = nil
        XCTAssertEqual(AINotifier.message(batch: batch, remaining: nil, project: "demo").body, "2 个文件等你验收")
        batch.agent = "codex"
        XCTAssertEqual(AINotifier.message(batch: batch, remaining: nil, project: "demo").title, "Codex 改完了 · demo")
    }

    func testNotificationCenterOnlyInsideTheApp() {
        XCTAssertFalse(AINotifier.available) // tests run outside an .app bundle: no notification center calls
    }
}
