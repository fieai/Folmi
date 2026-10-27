import XCTest
@testable import FolmiCore

final class CodexHookEventsTests: XCTestCase {
    func testPatchCollectsAllChangesAndBothSidesOfMove() {
        let patch = """
        *** Begin Patch
        *** Add File: added.txt
        +hello
        *** Update File: old.txt
        *** Move to: nested/new.txt
        @@
        -before
        +after
        *** Delete File: removed.txt
        *** Update File: old.txt
        *** End Patch
        """
        XCTAssertEqual(AIEventStore.patchPaths(patch), ["added.txt", "old.txt", "nested/new.txt", "removed.txt"])
    }

    func testPathsCannotEscapeOrReadGitOrFollowLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertNil(AIEventStore.safeRelativePath("../secret", cwd: root, root: root))
        XCTAssertNil(AIEventStore.safeRelativePath(".git/config", cwd: root, root: root))
        XCTAssertNil(AIEventStore.safeRelativePath("nested/.git/config", cwd: root, root: root))
        XCTAssertNil(AIEventStore.safeRelativePath("escape/secret", cwd: root, root: root))
        XCTAssertNil(AIEventStore.safeRelativePath("dangling", cwd: root, root: root))
        XCTAssertEqual(AIEventStore.safeRelativePath("new.txt", cwd: root.appendingPathComponent("nested"), root: root), "nested/new.txt")
    }

    func testOldEventsDecodeAndCodexAgentSurvivesRoundTrip() throws {
        let old = Data(#"{"t":1,"kind":"start","session":"s","batch":"b"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AIEvent.self, from: old).agent)
        let event = AIEvent(t: 1, kind: .start, session: "s", batch: "b", agent: "codex")
        XCTAssertEqual(try JSONDecoder().decode(AIEvent.self, from: JSONEncoder().encode(event)), event)
    }

    func testHelperCapturesMultiFileTurnAndPreservesFirstPreimage() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let helper = products.appendingPathComponent("folmi-hook")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper not built next to tests")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try Data("original".utf8).write(to: root.appendingPathComponent("old.txt"))
        try Data("delete me".utf8).write(to: root.appendingPathComponent("removed.txt"))
        let patch = "*** Begin Patch\n*** Update File: old.txt\n*** Move to: moved.txt\n@@\n-original\n+changed\n*** Add File: added.txt\n+new\n*** Delete File: removed.txt\n*** End Patch"
        func invoke(_ mode: String, turn: String = "t1") throws {
            let process = Process(), input = Pipe()
            process.executableURL = helper; process.arguments = [mode, "--agent", "codex"]
            process.standardInput = input
            let payload: [String: Any] = ["session_id": "s", "turn_id": turn, "cwd": root.path, "prompt": "change files", "tool_name": "apply_patch", "tool_input": ["command": patch]]
            try process.run()
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try invoke("prompt"); try invoke("pre")
        try FileManager.default.moveItem(at: root.appendingPathComponent("old.txt"), to: root.appendingPathComponent("moved.txt"))
        try Data("changed".utf8).write(to: root.appendingPathComponent("moved.txt"))
        try Data("new".utf8).write(to: root.appendingPathComponent("added.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        try invoke("post"); try invoke("pre"); try invoke("stop")
        let pre = AIEventStore.batch("codex-s-t1", gitDir: git).appendingPathComponent("pre")
        let post = AIEventStore.post(batch: "codex-s-t1", gitDir: git)
        XCTAssertEqual(AIEventStore.keptPaths(pre), ["old.txt", "moved.txt", "added.txt", "removed.txt"])
        XCTAssertEqual(try String(contentsOf: pre.appendingPathComponent("old.txt"), encoding: .utf8), "original")
        XCTAssertTrue(AIEventStore.isAbsent("added.txt", in: pre))
        XCTAssertEqual(try String(contentsOf: post.appendingPathComponent("moved.txt"), encoding: .utf8), "changed")
        XCTAssertTrue(AIEventStore.isAbsent("removed.txt", in: post))
        let events = AIEventStore.parse(try Data(contentsOf: AIEventStore.events(gitDir: git))).events
        XCTAssertEqual(events.filter { $0.kind == .edit }.count, 4)
        XCTAssertEqual(events.last?.kind, .stop)
        XCTAssertTrue(events.allSatisfy { $0.agent == "codex" && $0.batch == "codex-s-t1" })
    }
    /// `stop --check`: a turn that renamed a function still called elsewhere is kept going once, in the same turn.
    func testStopCheckKeepsATurnThatBrokeCallsGoingOnce() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("folmi-hook")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper not built next to tests")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stop-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialize = Process()
        initialize.executableURL = URL(fileURLWithPath: "/usr/bin/git"); initialize.arguments = ["init", "-q"]; initialize.currentDirectoryURL = root
        try initialize.run(); initialize.waitUntilExit()
        let lib = root.appendingPathComponent("lib.ts")
        try Data("export function getOrder(id: string) { return id }\n".utf8).write(to: lib)
        try Data("import { getOrder } from './lib'\nexport function page() { return getOrder('1') }\n".utf8)
            .write(to: root.appendingPathComponent("page.ts"))
        @discardableResult
        func invoke(_ arguments: [String], _ extra: [String: Any] = [:]) throws -> String {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = helper; process.arguments = arguments
            process.standardInput = input; process.standardOutput = output
            var payload: [String: Any] = ["session_id": "s", "cwd": root.path, "prompt": "rename",
                                          "tool_name": "Edit", "tool_input": ["file_path": lib.path]]
            payload.merge(extra) { $1 }
            try process.run()
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        try invoke(["prompt"]); try invoke(["pre"])
        try Data("export function loadOrder(id: string) { return id }\n".utf8).write(to: lib)
        try invoke(["post"])
        let git = root.appendingPathComponent(".git")
        let events = { AIEventStore.parse((try? Data(contentsOf: AIEventStore.events(gitDir: git))) ?? Data()).events }
        let batch = try XCTUnwrap(events().last?.batch)

        // Codex's Interrupt runs `stop` too: never checked, the turn just ends.
        XCTAssertEqual(try invoke(["stop", "--check"], ["hook_event_name": "Interrupt"]), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AIEventStore.post(batch: batch, gitDir: git).path))
        try Data("export function getOrder(id: string) { return id }\n".utf8).write(to: lib)
        try invoke(["prompt"], ["prompt": "again"]); try invoke(["pre"])
        let second = try XCTUnwrap(events().last?.batch)
        try Data("export function loadOrder(id: string) { return id }\n".utf8).write(to: lib)

        let reply = try invoke(["stop", "--check"], ["hook_event_name": "Stop", "stop_hook_active": false])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any], reply)
        XCTAssertEqual(object["decision"] as? String, "block")
        XCTAssertTrue((object["reason"] as? String ?? "").contains("getOrder 改名为 loadOrder（lib.ts），旧名字还有 1 处在调用"), reply)
        XCTAssertTrue((object["reason"] as? String ?? "").contains("page.ts:2（page）"), reply)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AIEventStore.post(batch: second, gitDir: git).path), "the turn is not over")
        XCTAssertNotEqual(events().last?.kind, .stop)

        // The agent carries on: its edits stay in the same turn, and the next stop ends it whatever it did.
        try invoke(["post"], ["tool_input": ["file_path": root.appendingPathComponent("page.ts").path]])
        XCTAssertEqual(events().last?.batch, second)
        XCTAssertEqual(try invoke(["stop", "--check"], ["hook_event_name": "Stop", "stop_hook_active": true]), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AIEventStore.post(batch: second, gitDir: git).path))
        XCTAssertEqual(events().last?.kind, .stop)
        XCTAssertEqual(events().last?.batch, second)
    }

    func testAbsentSuffixFilesRoundTripWithoutTouchingTheirNeighbor() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("folmi-hook")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper not built next to tests")
        for operation in ["Update", "Add", "Delete"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("suffix-roundtrip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let neighbor = root.appendingPathComponent("foo"), edited = root.appendingPathComponent("foo.absent")
            try Data("untouched neighbor".utf8).write(to: neighbor)
            let original = operation == "Add" ? nil : Data("original suffix file".utf8)
            if let original { try original.write(to: edited) }
            let patch = "*** Begin Patch\n*** \(operation) File: foo.absent\n*** End Patch"
            func invoke(_ mode: String) throws {
                let process = Process(), input = Pipe()
                process.executableURL = helper; process.arguments = [mode, "--agent", "codex"]; process.standardInput = input
                let payload: [String: Any] = ["session_id": "s", "turn_id": "t", "cwd": root.path,
                                               "tool_name": "apply_patch", "tool_input": ["command": patch]]
                try process.run()
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
                try input.fileHandleForWriting.close(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }
            try invoke("prompt"); try invoke("pre")
            let after = operation == "Delete" ? nil : Data("changed suffix file".utf8)
            if let after { try after.write(to: edited) } else { try FileManager.default.removeItem(at: edited) }
            try invoke("post"); try invoke("stop")
            let batch = AIEventStore.batch("codex-s-t", gitDir: root.appendingPathComponent(".git"))
            let pre = batch.appendingPathComponent("pre"), post = batch.appendingPathComponent("post")
            for folder in [pre, post] {
                XCTAssertEqual(AIEventStore.keptPaths(folder), ["foo.absent"], operation)
                XCTAssertFalse(AIEventStore.hasAmbiguousLegacySnapshot(folder))
                XCTAssertFalse(AIEventStore.isAbsent("foo", in: folder))
            }
            XCTAssertEqual(AIEventStore.isAbsent("foo.absent", in: pre), original == nil)
            XCTAssertEqual(AIEventStore.isAbsent("foo.absent", in: post), after == nil)
            func restore(_ folder: URL) throws {
                for path in AIEventStore.keptPaths(folder) {
                    let data = AIEventStore.isAbsent(path, in: folder) ? nil : try Data(contentsOf: folder.appendingPathComponent(path))
                    try GitRepository.writeWorktreeFile(WorktreeFile(path: path, data: data, permissions: nil), root: root)
                }
            }
            try restore(pre)
            XCTAssertEqual(try? Data(contentsOf: edited), original, operation)
            XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "untouched neighbor")
            try restore(post)
            XCTAssertEqual(try? Data(contentsOf: edited), after, operation)
            XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "untouched neighbor")
        }
    }

    func testAmbiguousLegacySnapshotCannotBecomeRestorableOrBeRelabeled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-snapshot-\(UUID().uuidString)")
        let pre = root.appendingPathComponent("pre")
        try FileManager.default.createDirectory(at: pre, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("actual file or marker: unknowable".utf8).write(to: pre.appendingPathComponent("foo.absent"))
        try Data("unambiguous file".utf8).write(to: pre.appendingPathComponent("other.txt"))
        XCTAssertTrue(AIEventStore.hasAmbiguousLegacySnapshot(pre))
        XCTAssertTrue(AIEventStore.keptPaths(pre).isEmpty, "do not restore any subset of an ambiguous legacy turn")
        XCTAssertFalse(AIEventStore.isAbsent("foo", in: pre))
        XCTAssertThrowsError(try AIEventStore.prepareSnapshot(in: pre))
        XCTAssertEqual(try String(contentsOf: pre.appendingPathComponent("foo.absent"), encoding: .utf8), "actual file or marker: unknowable")
        try FileManager.default.removeItem(at: pre.appendingPathComponent("foo.absent"))
        XCTAssertFalse(AIEventStore.hasAmbiguousLegacySnapshot(pre))
        XCTAssertEqual(AIEventStore.keptPaths(pre), ["other.txt"], "legacy snapshots without ambiguous names remain readable")
    }

    func testPrivateTmpAliasRemainsLexicallyConsistentForMissingPaths() throws {
        let root = URL(fileURLWithPath: "/private/tmp/codex-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AIEventStore.safeRelativePath(root.appendingPathComponent(".codex/hooks.json").path, cwd: root, root: root), ".codex/hooks.json")
        XCTAssertEqual(AIEventStore.safeRelativePath(root.appendingPathComponent("new.txt").path, cwd: root, root: root), "new.txt")
        XCTAssertEqual(AIEventStore.locate(from: root)?.root.path, root.path)
        XCTAssertNil(AIEventStore.safeRelativePath(root.path + "/../outside.txt", cwd: root, root: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(AIEventStore.safeRelativePath(root.appendingPathComponent("escape/new.txt").path, cwd: root, root: root))
    }

}
