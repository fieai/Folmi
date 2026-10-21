import XCTest
import FolmiCore
@testable import Folmi

/// 暂存 = 收下, kept honest: what entered the index without being accepted (an agent's or the terminal's `git add`)
/// is flagged, Folmi's own staging is not, accepting clears it, and committing it asks once.
final class UnreviewedStagedTests: XCTestCase {
    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("等待超时：\(description)"); throw FolmiFailure(message: description) }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    @MainActor
    func testStagedWithoutAcceptingIsFlaggedUntilAccepted() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Unreviewed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: settings) }
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开") { !model.busy && model.snapshot != nil }

        // The demo's README.md was staged with git, not accepted here.
        try await eventually("标出没验收的暂存") { model.unreviewedStaged["README.md"] != nil }

        // Staging from Folmi is the user's own 收下: Greeting.swift does not show up.
        let greeting = try XCTUnwrap(model.snapshot?.files.first { $0.path == "Sources/Greeting.swift" })
        model.stageFile(greeting)
        try await eventually("暂存") { !model.busy && model.snapshot?.files.first { $0.path == "Sources/Greeting.swift" }?.hasStaged == true }
        try await eventually("检查跟上") { model.commitCheck?.fingerprint == model.snapshot?.fingerprint }
        XCTAssertNil(model.unreviewedStaged["Sources/Greeting.swift"])
        XCTAssertNotNil(model.unreviewedStaged["README.md"])

        // Committing asks once while README.md is unaccepted.
        model.draftMessage = "提交"
        model.commit()
        XCTAssertTrue(model.errorMessage?.contains("没验收") == true, model.errorMessage ?? "")
        model.errorMessage = nil

        // 收下 the staged README on the review page clears it.
        await model.loadAllChanges()
        let readme = try XCTUnwrap(model.allChanges.first { $0.area == .staged && $0.file.path == "README.md" })
        XCTAssertEqual(model.allChanges.first?.file.path, "README.md", "没验收的暂存排在逐个验收最前")
        model.acceptFile(readme)
        try await eventually("收下") { !model.busy }
        XCTAssertTrue(model.unreviewedStaged.isEmpty, "\(model.unreviewedStaged)")
    }
}
