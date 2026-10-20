import XCTest
@testable import Folmi

@MainActor
final class PreviewRecoveryTests: XCTestCase {
    func testReadablePDFIsNeverDeclaredFailedWhenHelpTimeoutPasses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = QuickLookLoadState()
        let request = state.begin(url)
        XCTAssertEqual(state.phase, .loading)
        state.didRequest(request)
        XCTAssertEqual(state.phase, .requested)
        state.offerHelp(request)
        XCTAssertEqual(state.phase, .help)
        state.dismissNotice()
        XCTAssertTrue(state.noticeDismissed)
        state.offerHelp(request)
        XCTAssertTrue(state.noticeDismissed, "a late timer must not reopen dismissed help")
    }

    func testMissingDocumentRemainsFailedAndRetryChecksDiskAgain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = QuickLookLoadState()
        let missing = state.begin(url)
        XCTAssertEqual(state.phase, .failed("文件不存在或已被移动。"))
        state.didRequest(missing); state.offerHelp(missing)
        XCTAssertEqual(state.phase, .failed("文件不存在或已被移动。"))
        try Data([1, 2, 3]).write(to: url)
        let retry = state.begin(url)
        XCTAssertEqual(state.phase, .loading)
        state.offerHelp(missing)
        XCTAssertEqual(state.phase, .loading, "the previous attempt must not time out the retry")
        state.didRequest(retry)
        XCTAssertEqual(state.phase, .requested)
    }
}
