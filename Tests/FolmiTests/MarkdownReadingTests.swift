import AppKit
import XCTest
@testable import Folmi

/// Reading typography preferences and image tools.
@MainActor
final class MarkdownReadingTests: XCTestCase {
    // MARK: Typography

    func testReadingPreferencesDecodeWithFallbacks() throws {
        let json = #"{"version":1,"markdownFontFamily":"serif","markdownFontSize":99,"markdownReadingWidth":860,"markdownOutlineWidth":5}"#
        let preferences = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.markdownFontFamily, "serif")
        XCTAssertEqual(preferences.markdownFontSize, 16, "out of range falls back")
        XCTAssertEqual(preferences.markdownReadingWidth, 860)
        XCTAssertEqual(preferences.markdownOutlineWidth, MarkdownOutlineWidth.minimum)
        let old = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"version":1}"#.utf8))
        XCTAssertEqual(old.markdownReadingWidth, 720)
        XCTAssertEqual(old.markdownFontFamily, "")
    }

    // MARK: Images

    func testImageAddressRangeSkipsBracketsAndTitle() {
        func target(_ line: String) -> String? {
            let text = "前\n" + line + "\n后"
            let range = (text as NSString).range(of: line)
            return MarkdownImageSource.targetRange(in: text, line: range).map { (text as NSString).substring(with: $0) }
        }
        XCTAssertEqual(target("![图](assets/a.png)"), "assets/a.png")
        XCTAssertEqual(target("![图 [x]](img/a%20b.png \"标题\")"), "img/a%20b.png")
        XCTAssertEqual(target("![](<my pic.png>)"), "my pic.png")
        XCTAssertEqual(target("- ![](a_(1).png)"), "a_(1).png")
        XCTAssertNil(target("普通文字"))
        XCTAssertNil(target("![没有地址]"))
    }



}
