import XCTest
@testable import Folmi

final class PaletteSpeedTests: XCTestCase {
    /// ⌘K must keep up with typing on a large project.
    func testRanking30kFilesPerKeystroke() {
        let paths = (0..<30_000).map { "Sources/module\($0 % 300)/sub\($0 % 17)/File\($0).swift" }
        let items = FolmiModel.staticPaletteItems(paths: paths, entries: [])
        let start = Date()
        for query in ["f", "fi", "fil", "file1", "file12", "mod sub"] { _ = PaletteRanking.rank(items, query: query, usage: PaletteUsage()) }
        let perKeystroke = Date().timeIntervalSince(start) / 6 * 1000
        print("palette ranking: \(Int(perKeystroke)) ms per keystroke (debug build)")
        XCTAssertLessThan(perKeystroke, 400)
    }
}
