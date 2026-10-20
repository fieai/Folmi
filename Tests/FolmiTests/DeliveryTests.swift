import SwiftUI
import XCTest
import FolmiCore
@testable import Folmi

final class DeliveryTests: XCTestCase {
    func testDemoAndPushToDisposableBareRemote() async throws {
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let repository = GitRepository(url: demo.root, environment: demo.environment)
        let state = try await repository.load()
        XCTAssertEqual(state.branch, "main")
        XCTAssertEqual(state.files.count, 3)
        XCTAssertTrue(state.files.contains { $0.path == "README.md" && $0.hasWorking && $0.hasStaged })
        let output = try await CommandRunner.git(["push", "--", "demo", "HEAD:refs/heads/main"], at: demo.root, environment: demo.environment)
        XCTAssertFalse(output.contains("fatal:"))
        let remote = demo.root.deletingLastPathComponent().appendingPathComponent("demo-remote.git")
        let pushed = try await CommandRunner.git(["--git-dir", remote.path, "rev-parse", "refs/heads/main"], at: demo.root, environment: demo.environment)
        XCTAssertEqual(pushed.trimmingCharacters(in: .whitespacesAndNewlines), state.head)
        let after = try await repository.load()
        XCTAssertEqual(after.fingerprint, state.fingerprint, "推送不能顺带暂存或提交工作区")
    }

    func testLiteralScriptArgumentsAndFailureOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ArgTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = "a b;$(touch SHOULD_NOT_EXIST)`touch ALSO_NOT_EXIST`"
        let command = DeliveryCommand(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal])
        let result = try await CommandRunner.run(command, at: root)
        XCTAssertEqual(result.output, literal)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        let failed = try await CommandRunner.run(DeliveryCommand(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["not-a-command"]), at: root,
                                                 environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"])
        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(failed.error.contains("not a git command"))
    }

    @MainActor
    func testDeliveryTargetsAndArgumentsAreExplicit() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-DeliveryTest-\(UUID().uuidString)/workspace.json")
        let model = FolmiModel(store: WorkspaceStore(url: config))
        model.snapshot = RepositorySnapshot(root: URL(fileURLWithPath: "/tmp/placeholder"), branch: "feature", head: "abc", files: [], commits: [], branches: [], remotes: ["origin"], fingerprint: "snapshot")
        model.deliveryRemote = "origin"
        XCTAssertThrowsError(try model.makeDelivery(), "不能自动猜测交付目标分支")
        model.deliveryBranch = "main"
        XCTAssertEqual(try model.makeDelivery().arguments, ["push", "--", "origin", "HEAD:refs/heads/main"])
        model.deliveryKind = .gerrit
        XCTAssertEqual(try model.makeDelivery().arguments, ["push", "--", "origin", "HEAD:refs/for/main"])
        model.deliveryBranch = "main:other"
        XCTAssertThrowsError(try model.makeDelivery())
        model.deliveryBranch = "main"
        model.deliveryRemote = "https://unconfigured.invalid/repo"
        XCTAssertThrowsError(try model.makeDelivery(), "推送必须使用当前仓库已有的远程名称")
    }

    /// The plan opens at its start: where it goes and the git command's beginning are on screen without scrolling.
    @MainActor
    func testPushPlanIsReadableWithoutScrolling() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-PlanView-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: settings) }
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(8)
        while model.busy || model.snapshot == nil { guard Date() < deadline else { return XCTFail("open") }; try await Task.sleep(nanoseconds: 20_000_000) }
        model.deliveryKind = .push; model.deliveryRemote = "demo"; model.deliveryBranch = "main"
        // Shown first with the placeholder, then the plan arrives, as when 预览命令 is pressed in the open sheet.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: DeliverySheet(model: model))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        model.preflightDelivery()
        while model.deliveryPlan == nil { guard Date() < deadline.addingTimeInterval(4) else { return XCTFail("plan: \(model.errorMessage ?? "")") }; try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 600_000_000)
        let shown = try ScreenText.read(hosting).replacingOccurrences(of: " ", with: "")
        let plan = try XCTUnwrap(model.deliveryPlan)
        XCTAssertTrue(shown.contains("项目"), shown)
        XCTAssertTrue(shown.contains("refs/heads/main\n"), "the branch row: \(shown)")
        // The ends of the long lines are on screen too: nothing is cut off to the right.
        XCTAssertTrue(shown.contains(plan.root.lastPathComponent), "folder name: \(shown)")
        XCTAssertTrue(shown.contains("refs/heads/main'"), "the refspec at the end of the command: \(shown)")
    }
}
