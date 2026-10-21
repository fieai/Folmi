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

    /// The target branch moved on since the commit was made: the preview says so, 推送 rebases onto the remote's latest
    /// first and pushes the rebased commit, and the sheet closes once the push went through.
    @MainActor
    func testDeliveryRebasesOntoTheRemotesLatestAndCloses() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-DeliveryRebase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: settings) }
        let demo = try await DemoRepository.create(remoteUpdates: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        func git(_ arguments: [String]) async throws -> String {
            try await CommandRunner.git(arguments, at: demo.root, environment: demo.environment).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A clean tree with one local commit; the remote already has the teammate's commit on main.
        _ = try await git(["add", "-A"])
        _ = try await git(["commit", "--quiet", "-m", "本地改动"])
        let local = try await git(["rev-parse", "HEAD"])

        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(10)
        func settle() async throws { while model.busy || model.snapshot == nil { guard Date() < deadline else { throw FolmiFailure(message: "timeout: \(model.errorMessage ?? "")") }; try await Task.sleep(nanoseconds: 20_000_000) } }
        try await settle()
        model.deliveryKind = .push; model.deliveryRemote = "demo"; model.deliveryBranch = "main"
        model.showDelivery = true
        // One click: it stops before pushing, because the remote moved on.
        model.deliver()
        while model.deliveryPlan == nil { guard Date() < deadline, model.errorMessage == nil else { return XCTFail(model.errorMessage ?? "plan") }; try await Task.sleep(nanoseconds: 20_000_000) }
        try await settle()
        let plan = try XCTUnwrap(model.deliveryPlan, model.errorMessage ?? "")
        XCTAssertTrue(model.showDelivery, "远端有新提交时停下来，不直接推")
        let unchanged = try await git(["rev-parse", "HEAD"])
        XCTAssertEqual(unchanged, local)
        XCTAssertEqual(plan.behind, 1)
        XCTAssertEqual(plan.base?.name, "demo/main")
        XCTAssertTrue(model.deliveryCommandsText.hasPrefix("'/usr/bin/git' 'rebase' "), model.deliveryCommandsText)

        model.deliver()
        try await settle()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.showDelivery, "推送成功后关闭弹窗")
        let head = try await git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(head, local)
        let parent = try await git(["rev-parse", "HEAD^"]), pushed = try await git(["ls-remote", "demo", "refs/heads/main"])
        XCTAssertEqual(parent, plan.base?.commit, "本地提交挪到了远端最新之上")
        XCTAssertEqual(pushed.prefix(40), Substring(head))
    }

    /// Nothing new on the remote: one click plans and pushes, no separate preview.
    @MainActor
    func testPushIsOneClickWhenTheRemoteHasNothingNew() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-DeliveryOneClick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: settings) }
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(10)
        func settle() async throws { while model.busy || model.snapshot == nil { guard Date() < deadline else { throw FolmiFailure(message: "timeout") }; try await Task.sleep(nanoseconds: 20_000_000) } }
        try await settle()
        model.deliveryKind = .push; model.deliveryRemote = "demo"; model.deliveryBranch = "main"
        model.showDelivery = true
        XCTAssertNil(model.deliveryPlan)
        model.deliver()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await settle()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.showDelivery)
        let pushed = try await CommandRunner.git(["ls-remote", "demo", "refs/heads/main"], at: demo.root, environment: demo.environment)
        XCTAssertEqual(pushed.prefix(40), Substring(model.snapshot?.head ?? "-"))
    }

    @MainActor
    func testGerritReviewLinksAreReadFromPushOutput() {
        let output = "remote: Processing changes: refs: 1, new: 1\nremote:\nremote:   https://gerrit.example/c/algo/hr/+/4521 修复 [NEW]\nremote:\n"
        XCTAssertEqual(FolmiModel.reviewLinks(output), ["https://gerrit.example/c/algo/hr/+/4521"])
    }
}

/// Reviews pushed from Folmi are checked locally after each fetch: a conflict with the target's new tip shows, a
/// clean merge does not, and a review whose commit reached the branch stops being watched.
final class ReviewWatchTests: XCTestCase {
    @MainActor
    func testReviewWatchFindsConflictsLocally() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ReviewWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: settings) }
        let demo = try await DemoRepository.create(remoteUpdates: true)
        let parent = demo.root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        func git(_ arguments: [String], at directory: URL? = nil) async throws -> String {
            try await CommandRunner.git(arguments, at: directory ?? demo.root, environment: demo.environment).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The review: the local work committed on top of what main had before the teammate's commit.
        _ = try await git(["add", "-A"])
        _ = try await git(["commit", "--quiet", "-m", "本地改动\n\nChange-Id: I0123456789abcdef0123456789abcdef01234567"])
        let review = try await git(["rev-parse", "HEAD"])

        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(10)
        while model.busy || model.snapshot == nil { guard Date() < deadline else { return XCTFail("open") }; try await Task.sleep(nanoseconds: 20_000_000) }
        let root = try XCTUnwrap(model.repositoryURL)
        await model.watchReview(commit: review, remote: "demo", branch: "main", root: root)
        XCTAssertEqual(model.reviewWatches.first?.changeID, "I0123456789abcdef0123456789abcdef01234567")

        // The teammate's commit (docs/team.md) does not touch the review's files: no notice.
        _ = try await git(["fetch", "--quiet", "demo"])
        await model.checkReviewWatches(root: root)
        XCTAssertNotNil(model.reviewWatches.first?.checkedBase)
        XCTAssertTrue(model.conflictingReviews.isEmpty)

        // Now main changes the same line of Greeting.swift.
        let teammate = parent.appendingPathComponent("teammate2", isDirectory: true)
        _ = try await git(["clone", "--quiet", "--branch", "main", parent.appendingPathComponent("demo-remote.git").path, teammate.path], at: parent)
        let greeting = teammate.appendingPathComponent("Sources/Greeting.swift")
        try (try String(contentsOf: greeting, encoding: .utf8)).replacingOccurrences(of: "Hello,", with: "Howdy,").write(to: greeting, atomically: true, encoding: .utf8)
        _ = try await git(["commit", "--quiet", "-am", "同事改了问候语"], at: teammate)
        _ = try await git(["push", "--quiet", "origin", "main"], at: teammate)
        _ = try await git(["fetch", "--quiet", "demo"])
        await model.checkReviewWatches(root: root)
        XCTAssertEqual(model.conflictingReviews.first?.conflicts, ["Sources/Greeting.swift"])

        // The review lands (its commit merged into main): no longer watched.
        _ = try await git(["pull", "--quiet", "--no-rebase", "-X", "ours", "--no-edit", demo.root.path, "main"], at: teammate)
        _ = try await git(["push", "--quiet", "origin", "main"], at: teammate)
        _ = try await git(["fetch", "--quiet", "demo"])
        await model.checkReviewWatches(root: root)
        XCTAssertTrue(model.reviewWatches.isEmpty)
    }
}
