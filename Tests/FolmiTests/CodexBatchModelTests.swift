import XCTest
@testable import FolmiCore
@testable import Folmi

@MainActor
final class CodexBatchModelTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { throw FolmiFailure(message: "Codex batch did not settle") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testDeletedExecutableAndAbsentSuffixFileRestoreWithoutTouchingNeighbor() async throws {
        let demo = try await DemoRepository.create()
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("codex-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()); try? FileManager.default.removeItem(at: settings) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        model.aiSettings.autoCommitMessage = false
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually { !model.busy && model.snapshot != nil }
        let gitDir = try XCTUnwrap(AIEventStore.locate(from: demo.root)).gitDir
        let manager = FileManager.default
        let executable = demo.root.appendingPathComponent("tool.sh"), suffix = demo.root.appendingPathComponent("foo.absent")
        let neighbor = demo.root.appendingPathComponent("foo")
        let original = Data("#!/bin/sh\necho original\n".utf8)
        try original.write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("before\n".utf8).write(to: suffix)
        try Data("HUMAN NEIGHBOR\n".utf8).write(to: neighbor)
        let pre = AIEventStore.batch("codex-test", gitDir: gitDir).appendingPathComponent("pre")
        try AIEventStore.prepareSnapshot(in: pre)
        for path in ["tool.sh", "foo.absent"] { try manager.copyItem(at: demo.root.appendingPathComponent(path), to: pre.appendingPathComponent(path)) }
        try manager.removeItem(at: executable)
        try Data("after\n".utf8).write(to: suffix)
        try AIEventStore.snapshotTouched(batch: "codex-test", root: demo.root, gitDir: gitDir, into: AIEventStore.post(batch: "codex-test", gitDir: gitDir))
        let now = Date().timeIntervalSince1970
        let events = [AIEvent(t: now - 2, kind: .start, session: "codex-s", batch: "codex-test", prompt: "test", agent: "codex"),
                      AIEvent(t: now - 1, kind: .edit, session: "codex-s", batch: "codex-test", path: "tool.sh", tool: "apply_patch", agent: "codex"),
                      AIEvent(t: now - 1, kind: .edit, session: "codex-s", batch: "codex-test", path: "foo.absent", tool: "apply_patch", agent: "codex"),
                      AIEvent(t: now, kind: .stop, session: "codex-s", batch: "codex-test", agent: "codex"),
                      // The real Codex ACP adapter generates a title in a second, file-free session.
                      AIEvent(t: now + 0.01, kind: .start, session: "title-s", batch: "title-only", prompt: "Generate a title", agent: "codex"),
                      AIEvent(t: now + 0.02, kind: .stop, session: "title-s", batch: "title-only", agent: "codex")]
        try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n" }.joined()
            .write(to: AIEventStore.events(gitDir: gitDir), atomically: true, encoding: .utf8)
        model.readAIEvents()
        try await eventually { model.aiBatches.first { $0.id == "codex-test" }?.expected != nil }
        XCTAssertEqual(model.capsuleAgentTitle, "Codex")
        guard case .finished(_, _, "codex-test")? = model.capsule else { return XCTFail("A title-only turn must not hide the edited batch") }
        XCTAssertEqual(model.aiBatches.first { $0.id == "codex-test" }?.restorable, ["tool.sh", "foo.absent"])
        model.publishShared()
        let shared = try XCTUnwrap(FolmiShared.read(SharedReviewStatus.self, from: FolmiShared.status(gitDir: gitDir)))
        XCTAssertEqual(shared.latestBatch?.id, "codex-test", "MCP must report the file changes, not the adapter's title task")
        model.undoLatestAIBatch()
        try await eventually { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: executable), original)
        XCTAssertEqual((try manager.attributesOfItem(atPath: executable.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try String(contentsOf: suffix, encoding: .utf8), "before\n")
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "HUMAN NEIGHBOR\n")
        model.undoGitOperation()
        try await eventually { !model.busy }
        XCTAssertFalse(manager.fileExists(atPath: executable.path))
        XCTAssertEqual(try String(contentsOf: suffix, encoding: .utf8), "after\n")
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "HUMAN NEIGHBOR\n")
    }
}
