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
