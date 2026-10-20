import XCTest
@testable import FolmiCore

final class WhitespaceHunkTests: XCTestCase {
    private func hunk(_ lines: [(DiffLineKind, String)]) -> DiffHunk {
        DiffHunk(id: "h", header: "@@", lines: lines.enumerated().map { DiffLine(id: $0.offset, text: $0.element.1, kind: $0.element.0) })
    }

    func testReindentAndRewrapCountAsWhitespaceOnly() {
        XCTAssertTrue(hunk([(.context, "if x {"), (.deletion, "  call()"), (.addition, "    call()")]).isWhitespaceOnly)
        XCTAssertTrue(hunk([(.deletion, "a(b, c)"), (.addition, "a(b,"), (.addition, "  c)")]).isWhitespaceOnly)
    }

    func testRealChangesAndPureContextAreNot() {
        XCTAssertFalse(hunk([(.deletion, "  call()"), (.addition, "  call(1)")]).isWhitespaceOnly)
        XCTAssertFalse(hunk([(.addition, "new line")]).isWhitespaceOnly)
        XCTAssertFalse(hunk([(.context, "same")]).isWhitespaceOnly)
    }
}
