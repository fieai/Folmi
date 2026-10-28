import XCTest
@testable import Folmi

final class DeliveryKindMemoryTests: XCTestCase {
    func testPushSheetStartsWhereTheLastPushWent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-kind-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        var settings = ProjectPreferences(rootPath: root.path, name: "x")

        XCTAssertEqual(FolmiModel.startingDeliveryKind(settings, root: root), .push, "never pushed, no Gerrit hook")
        try "#!/bin/sh\n# adds Change-Id\n".write(to: hooks.appendingPathComponent("commit-msg"), atomically: true, encoding: .utf8)
        XCTAssertEqual(FolmiModel.startingDeliveryKind(settings, root: root), .gerrit, "Gerrit's commit-msg hook")

        settings.lastDeliveryKind = .push
        XCTAssertEqual(FolmiModel.startingDeliveryKind(settings, root: root), .push, "what was used last wins")
        settings.lastDeliveryKind = .script
        XCTAssertEqual(FolmiModel.startingDeliveryKind(settings, root: root), .gerrit, "a script needs its profile; it is not a starting point")

        // Saved and read back; an older settings file without it still reads.
        settings.lastDeliveryKind = .gerrit
        let decoded = try JSONDecoder().decode(ProjectPreferences.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.lastDeliveryKind, .gerrit)
        let old = try JSONDecoder().decode(ProjectPreferences.self, from: Data(#"{"rootPath":"/x"}"#.utf8))
        XCTAssertNil(old.lastDeliveryKind)
    }
}
