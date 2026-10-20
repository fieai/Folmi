import XCTest
@testable import FolmiCore

/// A bare remote, the clone under test (`repo`) and a second clone (`other`) that pushes commits to pull.
private final class SyncFixture {
    let base: URL
    let remote: URL
    let directory: URL
    let otherDirectory: URL
    let environment: [String: String]
    let repo: GitRepository
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-test-" + UUID().uuidString, isDirectory: true)
        remote = base.appendingPathComponent("remote.git"); directory = base.appendingPathComponent("repo")
        otherDirectory = base.appendingPathComponent("other")
        let home = base.appendingPathComponent("isolated-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        repo = GitRepository(url: directory, environment: environment)
        try run(base, ["init", "--bare", "--template=", "--initial-branch=main", remote.path])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "--template=", "--initial-branch=main"])
        configure(directory)
        try write("sample.txt", "one\ntwo\nthree\n"); try git(["add", "."]); try git(["commit", "-m", "Initial"])
        try git(["remote", "add", "origin", remote.path]); try git(["push", "-u", "origin", "main"])
        try run(base, ["clone", "--template=", remote.path, otherDirectory.path])
        configure(otherDirectory)
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    private func configure(_ dir: URL) {
        for pair in [["user.name", "Folmi Test"], ["user.email", "folmi@example.invalid"], ["core.hooksPath", "/dev/null"], ["commit.gpgsign", "false"]] {
            _ = try? run(dir, ["config"] + pair)
        }
    }
    @discardableResult func run(_ dir: URL, _ args: [String]) throws -> String { try GitProcess(directory: dir, environment: environment).run(args).text }
    @discardableResult func git(_ args: [String]) throws -> String { try run(directory, args) }
    @discardableResult func other(_ args: [String]) throws -> String { try run(otherDirectory, args) }
    func write(_ path: String, _ text: String, in dir: URL? = nil) throws {
        try Data(text.utf8).write(to: (dir ?? directory).appendingPathComponent(path))
    }
    func read(_ path: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) }
    func head() throws -> String { try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The other clone commits `text` to `path` and pushes.
    func remoteCommit(_ path: String, _ text: String, _ message: String) throws {
        try write(path, text, in: otherDirectory); try other(["add", "."]); try other(["commit", "-m", message]); try other(["push", "origin", "main"])
    }
    func fetch() throws { XCTAssertTrue(try GitRepository.fetch(root: directory, environment: environment)) }
}

final class SyncTests: XCTestCase {
    func testFetchWithoutRemoteDoesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GitProcess(directory: dir, environment: ["GIT_CONFIG_GLOBAL": "/dev/null"]).run(["init", "--template="])
        XCTAssertFalse(try GitRepository.fetch(root: dir, environment: ["GIT_CONFIG_GLOBAL": "/dev/null"]))
    }

    func testFetchCountsBehindAndFastForwardKeepsUnrelatedWorkAndUndoes() async throws {
        let f = try SyncFixture()
        try f.remoteCommit("remote.txt", "from remote\n", "Remote work")
        var snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.behind, 0)
        try f.fetch()
        snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.behind, 1)
        // Uncommitted work in a file the pull does not touch is carried through, staged and unstaged parts apart.
        try f.write("sample.txt", "one\ntwo\nthree\nstaged\n"); try f.git(["add", "sample.txt"])
        try f.write("sample.txt", "one\ntwo\nthree\nmine\n")
        let plan = try await f.repo.pullPlan()
        XCTAssertEqual(plan.behind, 1); XCTAssertEqual(plan.ahead, 0); XCTAssertNil(plan.blocked(.fastForward))
        XCTAssertNotNil(plan.blocked(.rebase), "rebase needs a clean tree")
        let before = try f.head()
        guard case let .done(from, to) = try await f.repo.pull(.fastForward, plan: plan) else { return XCTFail("expected done") }
        XCTAssertEqual(from, before)
        XCTAssertEqual(try f.read("remote.txt"), "from remote\n")
        XCTAssertEqual(try f.read("sample.txt"), "one\ntwo\nthree\nmine\n")
        let pulled = try await f.repo.load()
        XCTAssertEqual(pulled.behind, 0)
        // ⌘Z: branch and files back to before the pull, the uncommitted edit still there.
        let redo = try await f.repo.undo(.reset(restore: from, current: to, branch: "refs/heads/main"))
        XCTAssertEqual(try f.head(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("remote.txt").path))
        XCTAssertEqual(try f.read("sample.txt"), "one\ntwo\nthree\nmine\n")
        XCTAssertEqual(try f.git(["show", ":sample.txt"]), "one\ntwo\nthree\nstaged\n", "the staged part stays staged")
        _ = try await f.repo.undo(redo)
        XCTAssertEqual(try f.head(), to)
    }

    func testFastForwardRefusesOverlappingWorkWithoutChangingIt() async throws {
        let f = try SyncFixture()
        try f.remoteCommit("sample.txt", "one\nTWO\nthree\n", "Remote edit")
        try f.fetch()
        try f.write("sample.txt", "one\ntwo\nthree\nmine\n")
        let plan = try await f.repo.pullPlan(), before = try f.head()
        do { _ = try await f.repo.pull(.fastForward, plan: plan); XCTFail("expected refusal") }
        catch FolmiError.unsupported(let message) { XCTAssertTrue(message.contains("同一些文件")) }
        XCTAssertEqual(try f.head(), before)
        XCTAssertEqual(try f.read("sample.txt"), "one\ntwo\nthree\nmine\n")
    }

    func testDivergedBranchRebasesOrMerges() async throws {
        for kind in [GitRepository.PullKind.rebase, .merge] {
            let f = try SyncFixture()
            try f.remoteCommit("remote.txt", "r\n", "Remote work")
            try f.write("local.txt", "l\n"); try f.git(["add", "."]); try f.git(["commit", "-m", "Local work"])
            try f.fetch()
            let plan = try await f.repo.pullPlan()
            XCTAssertTrue(plan.diverged)
            XCTAssertNotNil(plan.blocked(.fastForward))
            guard case .done = try await f.repo.pull(kind, plan: plan) else { return XCTFail("expected done") }
            let snapshot = try await f.repo.load()
            XCTAssertEqual(snapshot.behind, 0); XCTAssertEqual(snapshot.ahead, kind == .rebase ? 1 : 2)
            XCTAssertNil(snapshot.operation)
            XCTAssertEqual(try f.read("remote.txt"), "r\n"); XCTAssertEqual(try f.read("local.txt"), "l\n")
            let parents = try f.git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count - 1
            XCTAssertEqual(parents, kind == .rebase ? 1 : 2)
        }
    }

    func testRebaseConflictCanBeAbortedOrContinued() async throws {
        let f = try SyncFixture()
        try f.remoteCommit("sample.txt", "one\nREMOTE\nthree\n", "Remote edit")
        try f.write("sample.txt", "one\nLOCAL\nthree\n"); try f.git(["commit", "-am", "Local edit"])
        let before = try f.head()
        try f.fetch()
        var plan = try await f.repo.pullPlan()
        guard case let .conflict(operation, files) = try await f.repo.pull(.rebase, plan: plan) else { return XCTFail("expected conflict") }
        XCTAssertEqual(operation, .rebase); XCTAssertEqual(files, ["sample.txt"])
        let stopped = try await f.repo.load()
        XCTAssertEqual(stopped.operation, .rebase)
        // A second pull is refused while one is in progress.
        do { _ = try await f.repo.pullPlan(); XCTFail("expected refusal") } catch {}
        let aborted = try await f.repo.abortOperation()
        XCTAssertEqual(aborted, .rebase)
        XCTAssertEqual(try f.head(), before)
        XCTAssertEqual(try f.read("sample.txt"), "one\nLOCAL\nthree\n")
        let clean = try await f.repo.load()
        XCTAssertNil(clean.operation)

        plan = try await f.repo.pullPlan()
        _ = try await f.repo.pull(.rebase, plan: plan)
        // Continuing with the conflict unresolved is refused.
        var snapshot = try await f.repo.load()
        do { _ = try await f.repo.continueRebase(expectedFingerprint: snapshot.fingerprint); XCTFail("expected refusal") } catch {}
        try f.write("sample.txt", "one\nBOTH\nthree\n"); try f.git(["add", "sample.txt"])
        snapshot = try await f.repo.load()
        let continued = try await f.repo.continueRebase(expectedFingerprint: snapshot.fingerprint)
        XCTAssertNil(continued)
        snapshot = try await f.repo.load()
        XCTAssertNil(snapshot.operation); XCTAssertEqual(snapshot.behind, 0); XCTAssertEqual(snapshot.ahead, 1)
        XCTAssertEqual(try f.git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines), "Local edit")
    }

    func testMergeConflictIsReportedAndAborts() async throws {
        let f = try SyncFixture()
        try f.remoteCommit("sample.txt", "one\nREMOTE\nthree\n", "Remote edit")
        try f.write("sample.txt", "one\nLOCAL\nthree\n"); try f.git(["commit", "-am", "Local edit"])
        let before = try f.head()
        try f.fetch()
        let plan = try await f.repo.pullPlan()
        guard case .conflict(.merge, _) = try await f.repo.pull(.merge, plan: plan) else { return XCTFail("expected conflict") }
        let snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.operation, .merge)
        XCTAssertTrue(snapshot.files.contains(where: \.isConflict))
        let abortedMerge = try await f.repo.abortOperation()
        XCTAssertEqual(abortedMerge, .merge)
        XCTAssertEqual(try f.head(), before)
        let after = try await f.repo.load()
        XCTAssertTrue(after.files.isEmpty)
    }

    func testStalePlanIsRefused() async throws {
        let f = try SyncFixture()
        try f.remoteCommit("a.txt", "a\n", "First")
        try f.fetch()
        let plan = try await f.repo.pullPlan()
        try f.remoteCommit("b.txt", "b\n", "Second")
        try f.fetch()
        do { _ = try await f.repo.pull(.fastForward, plan: plan); XCTFail("expected stale") }
        catch FolmiError.staleSnapshot {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("a.txt").path))
    }

    func testResetUndoRefusesWhenHeadMoved() async throws {
        let f = try SyncFixture()
        let first = try f.head()
        try f.write("x.txt", "x\n"); try f.git(["add", "."]); try f.git(["commit", "-m", "Second"])
        let second = try f.head()
        try f.write("y.txt", "y\n"); try f.git(["add", "."]); try f.git(["commit", "-m", "Third"])
        do { _ = try await f.repo.undo(.reset(restore: first, current: second, branch: "refs/heads/main")); XCTFail("expected refusal") } catch {}
        XCTAssertNotEqual(try f.head(), first)
    }

    func testResetUndoRefusesAnotherBranchAtTheSameCommit() async throws {
        let f = try SyncFixture()
        try f.remoteCommit("remote.txt", "from remote\n", "Remote work")
        try f.fetch()
        let plan = try await f.repo.pullPlan(), branch = try await f.repo.currentBranchRef()
        guard case let .done(from, to) = try await f.repo.pull(.fastForward, plan: plan) else { return XCTFail("expected done") }
        try f.git(["switch", "-c", "other"])
        do { _ = try await f.repo.undo(.reset(restore: from, current: to, branch: branch)); XCTFail("moved the wrong branch") } catch {}
        XCTAssertEqual(try f.head(), to, "other stays where it is")
        XCTAssertEqual(try f.read("remote.txt"), "from remote\n")
        try f.git(["switch", "main"])
        _ = try await f.repo.undo(.reset(restore: from, current: to, branch: branch))
        XCTAssertEqual(try f.head(), from)
    }
}
