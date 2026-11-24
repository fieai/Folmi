import XCTest
@testable import FolmiCore

private final class UndoFixture {
    let directory: URL
    let home: URL
    let environment: [String: String]
    let repo: GitRepository
    init(directoryName: String = "repo") throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-test-" + UUID().uuidString, isDirectory: true)
        directory = temp.appendingPathComponent(directoryName, isDirectory: true)
        home = temp.appendingPathComponent("isolated-home", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        repo = GitRepository(url: directory, environment: environment)
        _ = try git(["init", "--template=", "--initial-branch=main"])
        _ = try git(["config", "user.name", "Folmi Test"])
        _ = try git(["config", "user.email", "folmi@example.invalid"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["config", "commit.gpgsign", "false"])
    }
    deinit { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    @discardableResult func git(_ args: [String]) throws -> String { try GitProcess(directory: directory, environment: environment).run(args).text }
    func write(_ path: String, _ text: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) }
    func initial(_ path: String = "sample.txt", _ text: String = "one\ntwo\nthree\nfour\nfive\nsix\n") throws {
        try write(path, text); try git(["add", "--", path]); try git(["commit", "-m", "Initial"])
    }
    func index(_ path: String = "sample.txt") throws -> String { try git(["show", ":" + path]) }
}


final class UndoStepTests: XCTestCase {
    func testDiscardFilesRestoresIndexVersionsAndUndoRestoresBytesModesAndLinks() async throws {
        let f = try UndoFixture()
        let long = (1...2100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try f.initial("long.txt", long)
        try f.write("delete.txt", "keep in Git\n")
        try f.write("mode.sh", "#!/bin/sh\n")
        let binary = f.directory.appendingPathComponent("blob.bin")
        try Data([0, 1, 2]).write(to: binary)
        try f.git(["add", "."]); try f.git(["commit", "-m", "Files"])

        let staged = long.replacingOccurrences(of: "line 2000", with: "staged")
        try f.write("long.txt", staged); try f.git(["add", "long.txt"])
        try f.write("long.txt", staged + "work\n")
        try Data([0, 3, 4]).write(to: binary)
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("delete.txt"))
        let mode = f.directory.appendingPathComponent("mode.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: mode.path)
        let link = f.directory.appendingPathComponent("new.link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")

        let before = try await f.repo.load()
        let undo = try await f.repo.discardFiles(before.files.filter(\.hasWorking), expectedFingerprint: before.fingerprint)
        let after = try await f.repo.load()
        XCTAssertEqual(after.files.map(\.path), ["long.txt"])
        XCTAssertEqual(try f.read("long.txt"), staged)
        XCTAssertEqual(try f.index("long.txt"), staged)
        XCTAssertEqual(try Data(contentsOf: binary), Data([0, 1, 2]))
        XCTAssertEqual(try f.read("delete.txt"), "keep in Git\n")
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))

        _ = try await f.repo.undo(undo)
        XCTAssertEqual(try f.read("long.txt"), staged + "work\n")
        XCTAssertEqual(try Data(contentsOf: binary), Data([0, 3, 4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("delete.txt").path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: mode.path)[.posixPermissions] as? Int, 0o751)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing")
    }

    func testDiscardFilesRejectsChangesMadeAfterConfirmationWasRequested() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.write("sample.txt", "discard\n"); try f.write("new.txt", "original\n")
        let snapshot = try await f.repo.load()
        try f.write("new.txt", "changed again\n")
        do {
            _ = try await f.repo.discardFiles(snapshot.files, expectedFingerprint: snapshot.fingerprint)
            XCTFail("discarded changes added after the preview")
        } catch FolmiError.staleSnapshot {}
        XCTAssertEqual(try f.read("sample.txt"), "discard\n")
        XCTAssertEqual(try f.read("new.txt"), "changed again\n")
    }

    func testDiscardLargeBinaryAndUndoRestoresIt() async throws {
        let f = try UndoFixture()
        try f.initial("asset.bin", "small baseline\n")
        let path = f.directory.appendingPathComponent("asset.bin")
        let size = 33 * 1024 * 1024
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([7, 0, 9]))
        try handle.close()
        let snapshot = try await f.repo.load()
        let undo = try await f.repo.discardFiles(snapshot.files, expectedFingerprint: snapshot.fingerprint)
        XCTAssertEqual(try f.read("asset.bin"), "small baseline\n")
        let redo = try await f.repo.undo(undo)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int, size)
        let restored = try FileHandle(forReadingFrom: path)
        XCTAssertEqual(try restored.read(upToCount: 3), Data([7, 0, 9]))
        try restored.close()
        _ = try await f.repo.undo(redo)
        XCTAssertEqual(try f.read("asset.bin"), "small baseline\n")
    }

    func testDiscardWorkingRenameRestoresIndexPathAndUndoRestoresIntentToAdd() async throws {
        let f = try UndoFixture(); try f.initial()
        let source = f.directory.appendingPathComponent("sample.txt"), destination = f.directory.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: source, to: destination)
        try f.git(["add", "-N", "moved.txt"])
        let before = try await f.repo.load()
        let rename = try XCTUnwrap(before.files.first)
        XCTAssertEqual(rename.worktreeCode, "R")
        let undo = try await f.repo.discardFiles([rename], expectedFingerprint: before.fingerprint)
        let discarded = try await f.repo.load()
        XCTAssertTrue(discarded.files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let redo = try await f.repo.undo(undo)
        let restored = try await f.repo.load()
        XCTAssertEqual(restored.files, before.files)
        _ = try await f.repo.undo(redo)
        let redone = try await f.repo.load()
        XCTAssertTrue(redone.files.isEmpty)
    }

    func testStopTrackingAddsLiteralIgnoreRuleAndUndoPreservesWorktree() async throws {
        let f = try UndoFixture(), path = "cache[1].txt"
        try f.initial(path, "committed\n")
        try f.write(path, "in progress\n")
        let before = try await f.repo.load()
        let undo = try await f.repo.stopTracking(path, expectedFingerprint: before.fingerprint)
        let after = try await f.repo.load()
        XCTAssertEqual(after.files.first { $0.path == path }?.indexCode, "D")
        XCTAssertEqual(try f.read(path), "in progress\n")
        let ignored = ["ls-files", "--others", "--ignored", "--exclude-standard", "--", path]
        XCTAssertEqual(try f.git(ignored), path + "\n")
        let redo = try await f.repo.undo(undo)
        XCTAssertEqual(try f.index(path), "committed\n")
        XCTAssertEqual(try f.read(path), "in progress\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(".gitignore").path))
        _ = try await f.repo.undo(redo)
        XCTAssertEqual(try f.git(ignored), path + "\n")
    }

    func testSwitchCreatesTrackingBranchAndUndoRestoresPreviousPosition() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.git(["remote", "add", "origin", "unused-local-remote"])
        try f.git(["update-ref", "refs/remotes/origin/team/topic", "HEAD"])
        try f.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/team/topic"])
        try f.write("sample.txt", "local work\n")
        let before = try await f.repo.load()
        XCTAssertEqual(before.remoteBranches?.map(\.id), ["origin/team/topic"])
        let remote = try XCTUnwrap(before.remoteBranches?.first)
        let plan = try await f.repo.prepareBranchSwitch(.remote(remote, name: remote.name), expectedFingerprint: before.fingerprint)
        XCTAssertNil(plan.blocker)
        let undo = try await f.repo.checkout(plan)
        let after = try await f.repo.load()
        XCTAssertEqual(after.branch, "team/topic")
        XCTAssertEqual(after.upstream, remote.id)
        XCTAssertEqual(try f.read("sample.txt"), "local work\n")
        let redo = try await f.repo.undo(undo)
        let restored = try await f.repo.load()
        XCTAssertEqual(restored.branch, "main")
        XCTAssertEqual(restored.branches, ["main"])
        _ = try await f.repo.undo(redo)
        let redone = try await f.repo.load()
        XCTAssertEqual(redone.upstream, remote.id)
    }

    func testBranchSwitchPreviewsConflictAndWorksOnceChangesAreStashed() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.git(["switch", "-c", "topic"])
        try f.write("sample.txt", "topic\n"); try f.git(["commit", "-am", "Topic"])
        try f.git(["switch", "main"]); try f.write("sample.txt", "draft\n")
        let before = try await f.repo.load()
        let plan = try await f.repo.prepareBranchSwitch(.local("topic"), expectedFingerprint: before.fingerprint)
        XCTAssertTrue(plan.canStash)
        XCTAssertTrue(plan.blocker?.contains("sample.txt") == true)
        XCTAssertEqual(try f.read("sample.txt"), "draft\n")
        let entry = try await f.repo.stashAll(message: "draft", expectedFingerprint: before.fingerprint)
        let clean = try await f.repo.load()
        let switchUndo = try await f.repo.checkout(plan, afterStashing: clean.fingerprint)
        XCTAssertEqual(try f.read("sample.txt"), "topic\n")
        _ = try await f.repo.undo(switchUndo)
        _ = try await f.repo.undo(.stash(.pop(object: entry.id)))
        XCTAssertEqual(try f.read("sample.txt"), "draft\n")
    }

    func testHistorySearchFindsOlderCommitBodiesInOtherBranches() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.git(["switch", "-c", "topic"])
        try f.git(["commit", "--allow-empty", "-m", "Details", "-m", "Rare [TOKEN]"])
        try f.git(["commit", "--allow-empty", "-m", "Newer tip"])
        try f.git(["switch", "main"])
        let initial = try await f.repo.history(limit: 1)
        XCTAssertFalse(initial.contains { $0.subject == "Details" })
        let all = try await f.repo.history(limit: 1, search: "[token]")
        XCTAssertEqual(all.map(\.subject), ["Details"])
        let current = try await f.repo.history(scope: .currentBranch, search: "[token]")
        XCTAssertTrue(current.isEmpty)
    }

    func testDiscardHunkRemovesOnlyThatHunkAndUndoBringsItBack() async throws {
        let f = try UndoFixture()
        try f.initial("sample.txt", (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n")
        var lines = (1...30).map { "line \($0)" }
        lines[1] = "CHANGED 2"; lines[27] = "CHANGED 28"
        try f.write("sample.txt", lines.joined(separator: "\n") + "\n")
        let snapshot = try await f.repo.load(), file = try XCTUnwrap(snapshot.files.first)
        let diff = try await f.repo.diff(for: file, area: .working, snapshotFingerprint: snapshot.fingerprint)
        XCTAssertEqual(diff.hunks.count, 2)
        let step = try await f.repo.discard(diff: diff, hunkID: diff.hunks[0].id)
        let after = try f.read("sample.txt")
        XCTAssertTrue(after.contains("line 2\n")); XCTAssertTrue(after.contains("CHANGED 28"))
        let redo = try await f.repo.undo(step)
        XCTAssertEqual(try f.read("sample.txt"), lines.joined(separator: "\n") + "\n")
        _ = try await f.repo.undo(redo)
        XCTAssertEqual(try f.read("sample.txt"), after)
    }

    func testDiscardKeepsByteOrderMark() async throws {
        let f = try UndoFixture()
        try f.initial("sample.txt", "\u{FEFF}one\ntwo\nthree\n")
        try f.write("sample.txt", "\u{FEFF}one\nTWO\nthree\n")
        let snapshot = try await f.repo.load(), file = try XCTUnwrap(snapshot.files.first)
        let diff = try await f.repo.diff(for: file, area: .working, snapshotFingerprint: snapshot.fingerprint)
        _ = try await f.repo.discard(diff: diff, hunkID: XCTUnwrap(diff.hunks.first).id)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("sample.txt")), Data("\u{FEFF}one\ntwo\nthree\n".utf8))
    }

    func testDiscardRefusesStaleView() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.write("sample.txt", "one\nTWO\nthree\nfour\nfive\nsix\n")
        let snapshot = try await f.repo.load(), file = try XCTUnwrap(snapshot.files.first)
        let diff = try await f.repo.diff(for: file, area: .working, snapshotFingerprint: snapshot.fingerprint)
        try f.write("sample.txt", "one\nTWO\nthree\nFOUR\nfive\nsix\n")
        do { _ = try await f.repo.discard(diff: diff, hunkID: diff.hunks[0].id); XCTFail("stale view was applied") }
        catch FolmiError.staleSnapshot {}
        XCTAssertEqual(try f.read("sample.txt"), "one\nTWO\nthree\nFOUR\nfive\nsix\n")
    }

    func testIndexUndoRestoresEntryAndRemovesNewOne() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.write("sample.txt", "changed\n"); try f.write("new.txt", "new\n")
        let before = try await f.repo.captureIndex(["sample.txt", "new.txt"])
        try f.git(["add", "--", "sample.txt", "new.txt"])
        XCTAssertEqual(try f.index("sample.txt"), "changed\n")
        let redo = try await f.repo.undo(before)
        XCTAssertEqual(try f.index("sample.txt"), "one\ntwo\nthree\nfour\nfive\nsix\n")
        XCTAssertTrue(try f.git(["ls-files", "--", "new.txt"]).isEmpty)
        _ = try await f.repo.undo(redo)
        XCTAssertEqual(try f.index("new.txt"), "new\n")
    }

    func testHeadUndoIsSoftAndRedoable() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.write("sample.txt", "second\n"); try f.git(["add", "--", "sample.txt"])
        let snapshot = try await f.repo.load()
        let before = try await f.repo.currentHead()
        let head = try await f.repo.commit(message: "Second", amend: false, expectedFingerprint: snapshot.fingerprint)
        let redo = try await f.repo.undo(.head(restore: before, current: head, branch: "refs/heads/main"))
        let current = try await f.repo.currentHead()
        XCTAssertEqual(current, before)
        XCTAssertEqual(try f.index("sample.txt"), "second\n", "the committed content stays staged")
        _ = try await f.repo.undo(redo)
        let again = try await f.repo.currentHead()
        XCTAssertEqual(again, head)
        // A HEAD that moved since is not moved back.
        do { _ = try await f.repo.undo(.head(restore: before, current: before, branch: "refs/heads/main")); XCTFail("moved a ref that changed") } catch {}
    }

    func testHeadUndoRefusesAnotherBranchAtTheSameCommit() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.write("sample.txt", "second\n"); try f.git(["add", "--", "sample.txt"])
        let snapshot = try await f.repo.load()
        let before = try await f.repo.currentHead(), branch = try await f.repo.currentBranchRef()
        XCTAssertEqual(branch, "refs/heads/main")
        let head = try await f.repo.commit(message: "Second", amend: false, expectedFingerprint: snapshot.fingerprint)
        // `other` points at the same commit as main; undo recorded on main must not move it.
        try f.git(["switch", "-c", "other"])
        do { _ = try await f.repo.undo(.head(restore: before, current: head, branch: branch)); XCTFail("moved the wrong branch") }
        catch FolmiError.unsupported(let message) { XCTAssertTrue(message.contains("main")) }
        XCTAssertEqual(try f.git(["rev-parse", "other"]).trimmingCharacters(in: .whitespacesAndNewlines), head)
        XCTAssertEqual(try f.git(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), head)
        // Back on main it works, and moves main.
        try f.git(["switch", "main"])
        _ = try await f.repo.undo(.head(restore: before, current: head, branch: branch))
        XCTAssertEqual(try f.git(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), before)
        XCTAssertEqual(try f.git(["rev-parse", "other"]).trimmingCharacters(in: .whitespacesAndNewlines), head)
    }

    func testUndoOfFirstCommitLeavesIndex() async throws {
        let f = try UndoFixture()
        try f.write("a.txt", "a\n"); try f.git(["add", "--", "a.txt"])
        let snapshot = try await f.repo.load()
        let head = try await f.repo.commit(message: "First", amend: false, expectedFingerprint: snapshot.fingerprint)
        _ = try await f.repo.undo(.head(restore: nil, current: head, branch: "refs/heads/main"))
        let current = try await f.repo.currentHead()
        XCTAssertNil(current)
        XCTAssertEqual(try f.index("a.txt"), "a\n")
    }

    func testSnapshotReportsAheadOfUpstreamAndDates() async throws {
        let f = try UndoFixture(); try f.initial()
        try f.git(["branch", "base"]); try f.git(["branch", "--set-upstream-to=base"])
        try f.write("sample.txt", "x\n"); try f.git(["commit", "-am", "Ahead"])
        let snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.upstream, "base"); XCTAssertEqual(snapshot.ahead, 1); XCTAssertEqual(snapshot.behind, 0)
        XCTAssertNotNil(snapshot.commits.first?.date)
        let decoded = try JSONDecoder().decode(RepositorySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.fingerprint, snapshot.fingerprint); XCTAssertEqual(decoded.files, snapshot.files)
    }

    func testPathsOutsideTheWorkTreeAreRefused() async throws {
        let f = try UndoFixture(); try f.initial()
        do { _ = try await f.repo.captureWorktree(["../outside.txt"]); XCTFail("escaped the work tree") } catch {}
    }
}
