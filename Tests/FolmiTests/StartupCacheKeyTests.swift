import XCTest
@testable import Folmi

final class StartupCacheKeyTests: XCTestCase {
    /// Git reports a temp repository as /private/var/…; a standardized URL of the same existing folder drops /private.
    /// Both spellings must find the same cached snapshot, or demo projects never start from the cache.
    func testPrivateAndStandardizedSpellingsShareAKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolved = folder.resolvingSymlinksInPath().path
        let withPrivate = resolved.hasPrefix("/private/") ? resolved : "/private" + resolved
        let standardized = URL(fileURLWithPath: withPrivate).standardizedFileURL.path
        XCTAssertEqual(SnapshotCache.key(withPrivate), SnapshotCache.key(standardized))
    }
}
