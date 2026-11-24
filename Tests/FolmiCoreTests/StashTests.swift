import XCTest
@testable import FolmiCore

private final class StashFixture {
    let base: URL
    let directory: URL
    let environment: [String: String]
    let repo: GitRepository
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-test-" + UUID().uuidString, isDirectory: true)
        directory = base.appendingPathComponent("repo")
        let home = base.appendingPathComponent("isolated-home")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        repo = GitRepository(url: directory, environment: environment)
        try git(["init", "--template=", "--initial-branch=main"])
        for pair in [["user.name", "Folmi Test"], ["user.email", "folmi@example.invalid"], ["core.hooksPath", "/dev/null"], ["commit.gpgsign", "false"]] {
            try git(["config"] + pair)
        }
        try write("sample.txt", "one\ntwo\nthree\n"); try git(["add", "."]); try git(["commit", "-m", "Initial"])
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    @discardableResult func git(_ args: [String]) throws -> String { try GitProcess(directory: directory, environment: environment).run(args).text }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: directory.appendingPathComponent(path)) }
    func read(_ path: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) }
    func fingerprint() async throws -> String { try await repo.load().fingerprint }
}

final class StashTests: XCTestCase {
    func testWorkingOnlyStashKeepsIndexEvenForTwoVersionsOfSameFile() async throws {
        let f = try StashFixture()
        try f.write("staged.txt", "staged new file\n"); try f.git(["add", "staged.txt"])
        try f.write("sample.txt", "one\nTWO\nthree\n"); try f.git(["add", "sample.txt"])
        try f.write("sample.txt", "one\nTWO\nthree\nfour\n")
        try f.write("draft.txt", "not tracked\n")
        let staged = try f.git(["diff", "--cached"])
        let entry = try await f.repo.stashWorking(message: "接着写", expectedFingerprint: try await f.fingerprint())
        XCTAssertEqual(entry.message, "接着写")
        XCTAssertEqual(try f.git(["diff", "--cached"]), staged)
        XCTAssertTrue(try f.git(["diff"]).isEmpty)
        XCTAssertFalse(f.exists("draft.txt"))
        let plans = try await f.repo.stashRestorePlans([entry.id])
        let plan = try XCTUnwrap(plans[entry.id])
        XCTAssertNil(plan.blocker)
        XCTAssertEqual(plan.files.map(\.id), ["draft.txt", "sample.txt"])
        let diff = try await f.repo.stashDiff(XCTUnwrap(plan.files.last))
        XCTAssertTrue(diff.rawPatch.contains("+four"))
        XCTAssertFalse(diff.rawPatch.contains("+TWO"))
        let undo = try await f.repo.popStash(entry.id, expectedFingerprint: try await f.fingerprint())
        XCTAssertEqual(try f.git(["diff", "--cached"]), staged)
        XCTAssertEqual(try f.read("sample.txt"), "one\nTWO\nthree\nfour\n")
        XCTAssertEqual(try f.read("draft.txt"), "not tracked\n")
        _ = try await f.repo.undo(undo)
        let restashed = try await f.repo.stashes()
        XCTAssertEqual(restashed.map(\.id), [entry.id])
        XCTAssertEqual(try f.git(["diff", "--cached"]), staged)
        XCTAssertFalse(f.exists("draft.txt"))
    }

    func testPopWithDisjointWorkingAndStagedChangesCanBeUndoneAndRedone() async throws {
        let f = try StashFixture()
        try f.write("other.txt", "base\n"); try f.git(["add", "other.txt"]); try f.git(["commit", "-m", "Other"])
        try f.write("sample.txt", "stash content\n"); try f.git(["add", "sample.txt"])
        try f.write("added.txt", "new in stash\n")
        let entry = try await f.repo.stashAll(message: "stash", expectedFingerprint: try await f.fingerprint())
        try f.write("other.txt", "staged unrelated\n"); try f.git(["add", "other.txt"])
        try f.write("other.txt", "unstaged unrelated\n")
        let undo = try await f.repo.popStash(entry.id, expectedFingerprint: try await f.fingerprint())
        XCTAssertEqual(try f.git(["show", ":sample.txt"]), "stash content\n")
        XCTAssertEqual(try f.read("added.txt"), "new in stash\n")
        XCTAssertEqual(try f.read("other.txt"), "unstaged unrelated\n")
        XCTAssertEqual(try f.git(["show", ":other.txt"]), "staged unrelated\n")
        let redo = try await f.repo.undo(undo)
        XCTAssertEqual(try f.read("sample.txt"), "one\ntwo\nthree\n")
        XCTAssertFalse(f.exists("added.txt"))
        XCTAssertEqual(try f.read("other.txt"), "unstaged unrelated\n")
        XCTAssertEqual(try f.git(["show", ":other.txt"]), "staged unrelated\n")
        _ = try await f.repo.undo(redo)
        XCTAssertEqual(try f.git(["show", ":sample.txt"]), "stash content\n")
        XCTAssertEqual(try f.read("other.txt"), "unstaged unrelated\n")
    }

    func testStashAllKeepsUntrackedAndStagedAndPopsBack() async throws {
        let f = try StashFixture()
        try f.write("sample.txt", "one\nTWO\nthree\n"); try f.git(["add", "sample.txt"])
        try f.write("sample.txt", "one\nTWO\nthree\nfour\n")
        try f.write("new.txt", "untracked\n")
        let entry = try await f.repo.stashAll(message: "半成品", expectedFingerprint: try await f.fingerprint())
        XCTAssertEqual(entry.message, "半成品"); XCTAssertEqual(entry.branch, "main")
        var snapshot = try await f.repo.load()
        XCTAssertTrue(snapshot.files.isEmpty); XCTAssertEqual(snapshot.stashCount, 1)
        XCTAssertFalse(f.exists("new.txt"))
        let files = try await f.repo.stashFiles(entry.id)
        XCTAssertEqual(files, ["new.txt", "sample.txt"])

        try await f.repo.popStash(entry.id, expectedFingerprint: snapshot.fingerprint)
        snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.stashCount, 0)
        XCTAssertEqual(try f.read("sample.txt"), "one\nTWO\nthree\nfour\n")
        XCTAssertEqual(try f.git(["show", ":sample.txt"]), "one\nTWO\nthree\n", "staged part is staged again")
        XCTAssertEqual(try f.read("new.txt"), "untracked\n")
    }

    func testStashRefusesStaleViewAndEmptyTree() async throws {
        let f = try StashFixture()
        let clean = try await f.fingerprint()
        do { _ = try await f.repo.stashAll(message: "", expectedFingerprint: clean); XCTFail("nothing to stash") } catch {}
        try f.write("sample.txt", "changed\n")
        do { _ = try await f.repo.stashAll(message: "", expectedFingerprint: clean); XCTFail("stale") }
        catch FolmiError.staleSnapshot {}
        XCTAssertEqual(try f.read("sample.txt"), "changed\n")
    }

    func testPopRefusesOverTrackedChangesAndKeepsStashOnConflict() async throws {
        let f = try StashFixture()
        try f.write("sample.txt", "one\nmine\nthree\n")
        let entry = try await f.repo.stashAll(message: "mine", expectedFingerprint: try await f.fingerprint())
        try f.write("sample.txt", "other edit\n")
        do { try await f.repo.popStash(entry.id, expectedFingerprint: try await f.fingerprint()); XCTFail("expected refusal") } catch {}
        XCTAssertEqual(try f.read("sample.txt"), "other edit\n")
        // HEAD moves on with a clashing commit: the stash conflicts and stays listed.
        try f.write("sample.txt", "one\ntheirs\nthree\n"); try f.git(["commit", "-am", "Clash"])
        do { try await f.repo.popStash(entry.id, expectedFingerprint: try await f.fingerprint()); XCTFail("expected conflict") }
        catch FolmiError.unsupported(let message) { XCTAssertTrue(message.contains("冲突")) }
        let list = try await f.repo.stashes()
        XCTAssertEqual(list.map(\.id), [entry.id])
    }

    func testStashUndoRedoAndDropUndo() async throws {
        let f = try StashFixture()
        try f.write("sample.txt", "edited\n"); try f.write("new.txt", "n\n")
        let entry = try await f.repo.stashAll(message: "wip", expectedFingerprint: try await f.fingerprint())
        // ⌘Z after stashing brings the changes back; redo puts them aside again.
        let redo = try await f.repo.undo(.stash(.pop(object: entry.id)))
        XCTAssertEqual(try f.read("sample.txt"), "edited\n"); XCTAssertTrue(f.exists("new.txt"))
        let stashesAfterUndo = try await f.repo.stashes()
        XCTAssertTrue(stashesAfterUndo.isEmpty)
        guard case .stash(.push) = redo else { return XCTFail("expected push") }
        let again = try await f.repo.undo(redo)
        XCTAssertEqual(try f.read("sample.txt"), "one\ntwo\nthree\n"); XCTAssertFalse(f.exists("new.txt"))
        guard case .stash(.pop(let object)) = again else { return XCTFail("expected pop") }

        // Dropping is undoable too: the same commit goes back on the list.
        let restore = try await f.repo.dropStash(object)
        let afterDrop = try await f.repo.stashes()
        XCTAssertTrue(afterDrop.isEmpty)
        _ = try await f.repo.undo(restore)
        let back = try await f.repo.stashes()
        XCTAssertEqual(back.map(\.id), [object]); XCTAssertEqual(back.first?.message, "wip"); XCTAssertEqual(back.first?.branch, "main")
    }

    func testDropTargetsTheEntryByObjectNotPosition() async throws {
        let f = try StashFixture()
        try f.write("sample.txt", "first\n")
        let first = try await f.repo.stashAll(message: "first", expectedFingerprint: try await f.fingerprint())
        try f.write("sample.txt", "second\n")
        let second = try await f.repo.stashAll(message: "second", expectedFingerprint: try await f.fingerprint())
        _ = try await f.repo.dropStash(first.id)
        let left = try await f.repo.stashes()
        XCTAssertEqual(left.map(\.id), [second.id])
    }
}
