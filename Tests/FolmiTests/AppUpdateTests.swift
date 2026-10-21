import CryptoKit
import XCTest
@testable import Folmi

final class AppUpdateTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, assets: [String]? = nil) -> [String: Any] {
        let dmg = "Folmi-\(tag)-macOS-arm64-SIGNED-NOT-NOTARIZED-BETA.dmg"
        return ["tag_name": tag, "draft": draft, "prerelease": true, "html_url": "https://github.com/fieai/Folmi/releases/tag/\(tag)",
                "body": "## 下载\n\n表格\n\n## 这一版有什么\n\n- 新增 \(tag)\n",
                "assets": (assets ?? [dmg, dmg + ".sha256"]).map { ["name": $0, "browser_download_url": "https://example.com/\($0)"] }]
    }

    func testVersionComparison() {
        XCTAssertTrue(AppUpdateCheck.isNewer("0.8.0", than: "0.7.0"))
        XCTAssertTrue(AppUpdateCheck.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(AppUpdateCheck.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(AppUpdateCheck.isNewer("0.7.0", than: "0.7.0"))
        XCTAssertFalse(AppUpdateCheck.isNewer("0.6.9", than: "0.7.0"))
        XCTAssertFalse(AppUpdateCheck.isNewer("0.8", than: "0.7.0"))
        XCTAssertFalse(AppUpdateCheck.isNewer("0.8.0-beta", than: "0.7.0"))
    }

    func testPicksHighestCompleteReleaseIncludingPrereleases() throws {
        let list = [release("v0.7.0"), release("v0.9.0", draft: true), release("v0.10.0"),
                    release("v0.11.0", assets: ["Folmi-v0.11.0.dmg"]), release("nightly")]
        let newest = try XCTUnwrap(AppUpdateCheck.newestRelease(from: JSONSerialization.data(withJSONObject: list)))
        XCTAssertEqual(newest.version, "0.10.0")
        XCTAssertEqual(newest.dmgURL.lastPathComponent, "Folmi-v0.10.0-macOS-arm64-SIGNED-NOT-NOTARIZED-BETA.dmg")
        XCTAssertEqual(newest.checksumURL.lastPathComponent, newest.dmgURL.lastPathComponent + ".sha256")
        XCTAssertEqual(newest.notes, "- 新增 v0.10.0")
        XCTAssertNil(AppUpdateCheck.newestRelease(from: Data("{}".utf8)))
    }

    func testChecksum() {
        let data = Data("folmi".utf8)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(AppUpdateCheck.checksumMatches("\(hex.uppercased())  Folmi.dmg\n", data: data))
        XCTAssertFalse(AppUpdateCheck.checksumMatches("\(hex)  Folmi.dmg", data: Data("other".utf8)))
        XCTAssertFalse(AppUpdateCheck.checksumMatches("", data: data))
    }

    @MainActor func testTestBundleNeverUpdatesItself() {
        let updater = AppUpdater()
        XCTAssertFalse(updater.enabled)
        XCTAssertNotNil(updater.installBlocker)
    }
}
