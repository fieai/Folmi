import XCTest
@testable import FolmiCore
@testable import Folmi

final class CodexHooksTests: XCTestCase {

    func testProjectInstallIsIdempotentAndPreservesOtherHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = HooksInstaller.settingsURL(root, agent: .codex)
        try #"{"custom":"kept","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.write(to: config, atomically: true, encoding: .utf8)
        let helper = root.appendingPathComponent("source")
        try Data("helper".utf8).write(to: helper)
        let destination = root.appendingPathComponent("a'b/folmi-hook")
        for _ in 0..<2 { try HooksInstaller.install(root, agent: .codex, guarded: true, helper: helper, destination: destination) }
        XCTAssertTrue(HooksInstaller.status(root, agent: .codex).installed)
        XCTAssertTrue(HooksInstaller.status(root, agent: .codex).guarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HooksInstaller.settingsURL(root).path))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(object["custom"] as? String, "kept")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks["Stop"]?.count, 2)
        XCTAssertEqual((hooks["Interrupt"]?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 3)
        XCTAssertEqual(hooks["PreToolUse"]?.first?["matcher"] as? String, "apply_patch|Edit|Write")
        let command = try XCTUnwrap((hooks["PreToolUse"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(command.contains("'\\''"), "shell-quote apostrophes in the helper path")
        XCTAssertTrue(command.hasSuffix("pre --agent codex"))
        try HooksInstaller.uninstall(root, agent: .codex)
        XCTAssertFalse(HooksInstaller.status(root, agent: .codex).installed)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(after["custom"] as? String, "kept")
        XCTAssertEqual(((after["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 1)
    }
    func testMalformedOrSymlinkedProjectConfigIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = HooksInstaller.settingsURL(root, agent: .codex)
        let invalid = #"{"hooks":{"PreToolUse":"invalid user data"}}"#
        try invalid.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HooksInstaller.uninstall(root, agent: .codex))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), invalid)
        try FileManager.default.removeItem(at: config)
        let external = root.appendingPathComponent("external.json")
        try Data("{}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: external)
        XCTAssertThrowsError(try HooksInstaller.uninstall(root, agent: .codex))
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "{}")
    }

}
