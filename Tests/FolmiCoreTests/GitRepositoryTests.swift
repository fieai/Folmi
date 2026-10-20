import XCTest
@testable import FolmiCore

private final class Fixture {
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

final class GitRepositoryTests: XCTestCase {
    func testUnbornStageAndUnstagePreserveEditedWorktree() async throws {
        let f = try Fixture()
        try f.write("new.txt", "first\n")
        var snapshot = try await f.repo.load()
        XCTAssertNil(snapshot.head); XCTAssertEqual(snapshot.branch, "main")
        try await f.repo.stage(XCTUnwrap(snapshot.files.first), expectedFingerprint: snapshot.fingerprint)
        try f.write("new.txt", "first\nsecond\n")
        snapshot = try await f.repo.load()
        let file = try XCTUnwrap(snapshot.files.first)
        XCTAssertTrue(file.hasStaged); XCTAssertTrue(file.hasWorking)
        try await f.repo.unstage(file, expectedFingerprint: snapshot.fingerprint)
        let result = try await f.repo.load()
        XCTAssertTrue(try XCTUnwrap(result.files.first).isUntracked)
        XCTAssertEqual(try f.read("new.txt"), "first\nsecond\n")
    }

    /// Several files go in one step and out again; a name with `*` stays literal and does not pull in its neighbours.
    func testStageAndUnstageSeveralFilesTogether() async throws {
        let f = try Fixture(); try f.initial()
        try f.write("sample.txt", "changed\n")
        try f.write("a*.txt", "star\n")
        try f.write("ab.txt", "left alone\n")
        try f.write("dir/new file.txt", "spaced\n")
        var snapshot = try await f.repo.load()
        let chosen = snapshot.files.filter { ["sample.txt", "a*.txt", "dir/new file.txt"].contains($0.path) }
        XCTAssertEqual(chosen.count, 3)
        try await f.repo.stage(chosen, expectedFingerprint: snapshot.fingerprint)
        snapshot = try await f.repo.load()
        XCTAssertEqual(Set(snapshot.files.filter(\.hasStaged).map(\.path)), ["sample.txt", "a*.txt", "dir/new file.txt"])
        XCTAssertTrue(try XCTUnwrap(snapshot.files.first { $0.path == "ab.txt" }).isUntracked)
        try await f.repo.unstage(snapshot.files.filter(\.hasStaged), expectedFingerprint: snapshot.fingerprint)
        snapshot = try await f.repo.load()
        XCTAssertTrue(snapshot.files.allSatisfy { !$0.hasStaged })
        XCTAssertEqual(try f.read("sample.txt"), "changed\n")
    }

    func testUnbornUnstageSeveralFiles() async throws {
        let f = try Fixture()
        try f.write("one.txt", "1\n"); try f.write("two.txt", "2\n")
        var snapshot = try await f.repo.load()
        try await f.repo.stage(snapshot.files, expectedFingerprint: snapshot.fingerprint)
        snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.files.filter(\.hasStaged).count, 2)
        try await f.repo.unstage(snapshot.files, expectedFingerprint: snapshot.fingerprint)
        snapshot = try await f.repo.load()
        XCTAssertTrue(snapshot.files.allSatisfy(\.isUntracked))
    }

    func testSelectedReplacementStagesOnlySelectedChangeAndReverses() async throws {
        let f = try Fixture(); try f.initial()
        let work = "one\nTWO\nthree\nFOUR\nfive\nsix\n"
        try f.write("sample.txt", work)
        let initial = try await f.repo.load(), file = try XCTUnwrap(initial.files.first)
        let diff = try await f.repo.diff(for: file, area: .working), hunk = try XCTUnwrap(diff.hunks.first)
        XCTAssertTrue(diff.isPartialSupported)
        let ids = Set(hunk.lines.filter { ["two", "TWO"].contains($0.text) }.map(\.id))
        try await f.repo.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: ids)
        XCTAssertEqual(try f.index(), "one\nTWO\nthree\nfour\nfive\nsix\n")
        XCTAssertEqual(try f.read("sample.txt"), work)
        let staged = try await f.repo.diff(for: file, area: .staged)
        let stagedHunk = try XCTUnwrap(staged.hunks.first)
        let reverseIDs = Set(stagedHunk.lines.filter { ["two", "TWO"].contains($0.text) }.map(\.id))
        try await f.repo.apply(diff: staged, hunkID: stagedHunk.id, selectedLineIDs: reverseIDs)
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\n")
        XCTAssertEqual(try f.read("sample.txt"), work)
    }

    func testSelectOnlyAdditionRetainsUnselectedDeletion() async throws {
        let f = try Fixture(); try f.initial()
        try f.write("sample.txt", "one\nTWO\nthree\nfour\nfive\nsix\n")
        let snapshot = try await f.repo.load()
        let diff = try await f.repo.diff(for: XCTUnwrap(snapshot.files.first), area: .working)
        let hunk = try XCTUnwrap(diff.hunks.first), addition = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        try await f.repo.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: [addition.id])
        XCTAssertEqual(try f.index(), "one\ntwo\nTWO\nthree\nfour\nfive\nsix\n")
        let staged = try await f.repo.diff(for: XCTUnwrap(snapshot.files.first), area: .staged)
        let stagedHunk = try XCTUnwrap(staged.hunks.first)
        let selected = try XCTUnwrap(stagedHunk.lines.first { $0.text == "TWO" })
        try await f.repo.apply(diff: staged, hunkID: stagedHunk.id, selectedLineIDs: [selected.id])
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\n")
    }

    func testSelectOnlyDeletionAndRestoreIt() async throws {
        let f = try Fixture(); try f.initial()
        try f.write("sample.txt", "one\nTWO\nthree\nfour\nfive\nsix\n")
        let snapshot = try await f.repo.load()
        let diff = try await f.repo.diff(for: XCTUnwrap(snapshot.files.first), area: .working)
        let hunk = try XCTUnwrap(diff.hunks.first), deletion = try XCTUnwrap(hunk.lines.first { $0.kind == .deletion })
        try await f.repo.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: [deletion.id])
        XCTAssertEqual(try f.index(), "one\nthree\nfour\nfive\nsix\n")
        let staged = try await f.repo.diff(for: XCTUnwrap(snapshot.files.first), area: .staged)
        let stagedHunk = try XCTUnwrap(staged.hunks.first)
        try await f.repo.apply(diff: staged, hunkID: stagedHunk.id)
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\n")
    }

    func testSecondHunkStageAndReversePreserveOtherIndexEntries() async throws {
        let f = try Fixture()
        let original = (1...60).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try f.initial("sample.txt", original)
        try f.write("other.txt", "staged other\n"); try f.git(["add", "--", "other.txt"])
        let working = original.replacingOccurrences(of: "line 3\n", with: "changed 3\n").replacingOccurrences(of: "line 55\n", with: "changed 55\n")
        try f.write("sample.txt", working)
        let snapshot = try await f.repo.load(), file = try XCTUnwrap(snapshot.files.first { $0.path == "sample.txt" })
        let diff = try await f.repo.diff(for: file, area: .working)
        XCTAssertEqual(diff.hunks.count, 2)
        try await f.repo.apply(diff: diff, hunkID: diff.hunks[1].id)
        XCTAssertEqual(try f.index(), original.replacingOccurrences(of: "line 55\n", with: "changed 55\n"))
        XCTAssertEqual(try f.index("other.txt"), "staged other\n")
        let staged = try await f.repo.diff(for: file, area: .staged)
        try await f.repo.apply(diff: staged, hunkID: XCTUnwrap(staged.hunks.first).id)
        XCTAssertEqual(try f.index(), original); XCTAssertEqual(try f.read("sample.txt"), working)
        XCTAssertEqual(try f.index("other.txt"), "staged other\n")
    }

    func testStaleWorktreeAndIndexAreRejected() async throws {
        let f = try Fixture(); try f.initial()
        try f.write("sample.txt", "one\nchanged\nthree\nfour\nfive\nsix\n")
        let snapshot = try await f.repo.load(), file = try XCTUnwrap(snapshot.files.first)
        let diff = try await f.repo.diff(for: file, area: .working)
        try f.write("sample.txt", "one\nchanged again\nthree\nfour\nfive\nsix\n")
        do { try await f.repo.stage(file, expectedFingerprint: snapshot.fingerprint); XCTFail("Expected stale snapshot") }
        catch FolmiError.staleSnapshot { }
        do { try await f.repo.apply(diff: diff, hunkID: XCTUnwrap(diff.hunks.first).id); XCTFail("Expected stale diff") }
        catch FolmiError.staleSnapshot { }
        let fresh = try await f.repo.load(), newDiff = try await f.repo.diff(for: file, area: .working)
        try f.write("other.txt", "new index\n"); try f.git(["add", "--", "other.txt"])
        do { try await f.repo.apply(diff: newDiff, hunkID: XCTUnwrap(newDiff.hunks.first).id); XCTFail("Expected stale index") }
        catch FolmiError.staleSnapshot { }
        do { _ = try await f.repo.commit(message: "Should not commit", amend: false, expectedFingerprint: fresh.fingerprint); XCTFail("Expected stale commit") }
        catch FolmiError.staleSnapshot { }
        XCTAssertEqual(try f.git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .newlines), "1")
    }

    func testLiteralSpecialPathsAndRenameUnstage() async throws {
        let f = try Fixture()
        let paths = ["-leading.txt", "space 中文.txt", "line\nbreak.txt", ":(glob)*", "folder/[x].txt"]
        for path in paths { try f.write(path, "first\n") }
        var snapshot = try await f.repo.load()
        XCTAssertEqual(Set(snapshot.files.map(\.path)), Set(paths))
        for path in paths {
            snapshot = try await f.repo.load()
            try await f.repo.stage(XCTUnwrap(snapshot.files.first { $0.path == path }), expectedFingerprint: snapshot.fingerprint)
        }
        snapshot = try await f.repo.load()
        _ = try await f.repo.commit(message: "Special paths", amend: false, expectedFingerprint: snapshot.fingerprint)
        try FileManager.default.moveItem(at: f.directory.appendingPathComponent(paths[1]), to: f.directory.appendingPathComponent("renamed 中文.txt"))
        try f.git(["add", "--all", "--", paths[1], "renamed 中文.txt"])
        snapshot = try await f.repo.load()
        let rename = try XCTUnwrap(snapshot.files.first { $0.originalPath != nil })
        XCTAssertEqual(rename.path, "renamed 中文.txt"); XCTAssertEqual(rename.originalPath, paths[1])
        try f.write(rename.path, "first\n+\n")
        snapshot = try await f.repo.load()
        try await f.repo.stage(rename, expectedFingerprint: snapshot.fingerprint)
        XCTAssertEqual(try f.index(rename.path), "first\n+\n")
        snapshot = try await f.repo.load()
        let refreshedRename = try XCTUnwrap(snapshot.files.first { $0.originalPath != nil })
        try await f.repo.unstage(refreshedRename, expectedFingerprint: snapshot.fingerprint)
        XCTAssertEqual(try f.read(rename.path), "first\n+\n")
        XCTAssertEqual(try f.index(paths[1]), "first\n")
    }

    func testCommitAmendRetainsFullMessageAndOnlyIndex() async throws {
        let f = try Fixture(); try f.initial()
        try f.write("sample.txt", "staged\n"); try f.git(["add", "--", "sample.txt"])
        try f.write("sample.txt", "staged\nwork only\n")
        let message = "Subject\n\nBody paragraph.\n\nChange-Id: I0123456789abcdef\n"
        var snapshot = try await f.repo.load()
        let first = try await f.repo.commit(message: message, amend: false, expectedFingerprint: snapshot.fingerprint)
        XCTAssertEqual(try f.git(["show", "HEAD:sample.txt"]), "staged\n")
        XCTAssertEqual(try f.read("sample.txt"), "staged\nwork only\n")
        let fullMessage = try await f.repo.latestCommitMessage()
        XCTAssertTrue(fullMessage.contains("Body paragraph.\n\nChange-Id: I0123456789abcdef"))
        snapshot = try await f.repo.load()
        _ = try await f.repo.commit(message: fullMessage.replacingOccurrences(of: "Subject", with: "Amended subject"), amend: true, expectedFingerprint: snapshot.fingerprint)
        let amended = try await f.repo.latestCommitMessage()
        XCTAssertTrue(amended.hasPrefix("Amended subject\n")); XCTAssertTrue(amended.contains("Change-Id: I0123456789abcdef"))
        XCTAssertEqual(try f.git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .newlines), "2")
        XCTAssertEqual(first.count, 40)
    }

    func testConflictedIndexCannotCommit() async throws {
        let f = try Fixture(); try f.initial()
        try f.git(["switch", "-c", "topic"])
        try f.write("sample.txt", "topic\n"); try f.git(["add", "--", "sample.txt"]); try f.git(["commit", "-m", "Topic"])
        try f.git(["switch", "main"])
        try f.write("sample.txt", "main\n"); try f.git(["add", "--", "sample.txt"]); try f.git(["commit", "-m", "Main"])
        let merge = try GitProcess(directory: f.directory, environment: f.environment).run(["merge", "topic"], allowFailure: true)
        XCTAssertNotEqual(merge.status, 0)
        let snapshot = try await f.repo.load(), file = try XCTUnwrap(snapshot.files.first)
        XCTAssertTrue(file.isConflict)
        let index = try Data(contentsOf: f.directory.appendingPathComponent(".git/index"))
        do { _ = try await f.repo.commit(message: "Must not commit", amend: false, expectedFingerprint: snapshot.fingerprint); XCTFail("Conflict must reject commit") }
        catch FolmiError.unsupported { }
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent(".git/index")), index)
    }

    func testCheckoutRefusalPreservesDirtyWorktree() async throws {
        let f = try Fixture(); try f.initial()
        try f.git(["switch", "-c", "topic"])
        try f.write("sample.txt", "topic\n"); try f.git(["add", "--", "sample.txt"]); try f.git(["commit", "-m", "Topic"])
        try f.git(["switch", "main"]); try f.write("sample.txt", "uncommitted local\n")
        let snapshot = try await f.repo.load()
        do { try await f.repo.checkout(branch: "topic", expectedFingerprint: snapshot.fingerprint); XCTFail("Expected Git to protect working changes") }
        catch FolmiError.git(let code, _) { XCTAssertNotEqual(code, 0) }
        XCTAssertEqual(try f.read("sample.txt"), "uncommitted local\n")
        let after = try await f.repo.load(); XCTAssertEqual(after.branch, "main")
    }

    func testWholeFileDeletionStageUnstagePreservesDeletionOnDisk() async throws {
        let f = try Fixture(); try f.initial()
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("sample.txt"))
        var snapshot = try await f.repo.load()
        try await f.repo.stage(XCTUnwrap(snapshot.files.first), expectedFingerprint: snapshot.fingerprint)
        snapshot = try await f.repo.load()
        XCTAssertTrue(try XCTUnwrap(snapshot.files.first).hasStaged)
        try await f.repo.unstage(XCTUnwrap(snapshot.files.first), expectedFingerprint: snapshot.fingerprint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("sample.txt").path))
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\n")
    }

    func testUnsupportedPartialCasesHaveNotices() async throws {
        let f = try Fixture(); try f.initial()
        try Data([0, 1, 2, 3]).write(to: f.directory.appendingPathComponent("sample.txt"))
        let snapshot = try await f.repo.load()
        let diff = try await f.repo.diff(for: XCTUnwrap(snapshot.files.first), area: .working)
        XCTAssertFalse(diff.isPartialSupported); XCTAssertNotNil(diff.notice)
    }

    func testUTF8TextKeepsByteOrderMarks() {
        XCTAssertEqual(UTF8Text.decode(Data("\u{FEFF}a".utf8)).map { ($0 as NSString).length }, 2)
        XCTAssertEqual(UTF8Text.decode(Data("\u{FEFF}\u{FEFF}a".utf8)), "\u{FEFF}\u{FEFF}a")
        XCTAssertEqual(UTF8Text.decode(Data("中文".utf8)), "中文")
        XCTAssertEqual(UTF8Text.decode(Data()), "")
        XCTAssertNil(UTF8Text.decode(Data([0xEF, 0xBB, 0xBF, 0xFF])))
    }

    func testPartialStagingKeepsByteOrderMark() async throws {
        let f = try Fixture(); try f.initial("sample.txt", "\u{FEFF}one\ntwo\nthree\n")
        try f.write("sample.txt", "\u{FEFF}one\nTWO\nthree\n")
        let diff = try await onlyFile(f, .working)
        let hunk = try XCTUnwrap(diff.hunks.first), addition = try XCTUnwrap(hunk.lines.first { $0.kind == .addition })
        try await f.repo.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: [addition.id])
        let staged = try GitProcess(directory: f.directory, environment: f.environment).run(["show", ":sample.txt"]).stdout
        XCTAssertEqual(staged, Data("\u{FEFF}one\ntwo\nTWO\nthree\n".utf8))
    }

    private func onlyFile(_ f: Fixture, _ area: ChangeArea) async throws -> FileDiff {
        let snapshot = try await f.repo.load()
        let file = try XCTUnwrap(snapshot.files.first)
        return try await f.repo.diff(for: file, area: area)
    }

    func testMissingFinalNewlineCanBeStagedAndUnstagedByLine() async throws {
        let f = try Fixture(); try f.initial()
        try f.write("sample.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight")
        let diff = try await onlyFile(f, .working)
        XCTAssertTrue(diff.isPartialSupported, diff.notice ?? "")
        let hunk = try XCTUnwrap(diff.hunks.first)
        XCTAssertTrue(hunk.lines.contains { $0.kind == .meta }, "the diff marks the missing newline")
        let seven = try XCTUnwrap(hunk.lines.first { $0.kind == .addition && $0.text == "seven" })

        try await f.repo.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: [seven.id])
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\nseven\n", "a line in the middle keeps its newline")

        let rest = try await onlyFile(f, .working)
        try await f.repo.apply(diff: rest, hunkID: XCTUnwrap(rest.hunks.first).id)
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight", "the last line is staged without a newline")
        XCTAssertEqual(try f.git(["diff", "--name-only"]), "")

        let staged = try await onlyFile(f, .staged)
        let eight = try XCTUnwrap(staged.hunks.flatMap(\.lines).first { $0.kind == .addition && $0.text == "eight" })
        try await f.repo.apply(diff: staged, hunkID: XCTUnwrap(staged.hunks.first).id, selectedLineIDs: [eight.id])
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\nseven\n", "unstaging the last line restores the newline")
        let remaining = try await onlyFile(f, .staged)
        try await f.repo.apply(diff: remaining, hunkID: XCTUnwrap(remaining.hunks.first).id)
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\n")
    }

    func testIndexWithoutFinalNewlineKeepsItWhenStagingEarlierLines() async throws {
        let f = try Fixture(); try f.initial("sample.txt", "a\nb")
        try f.write("sample.txt", "x\na\nb")
        let diff = try await onlyFile(f, .working)
        XCTAssertTrue(diff.isPartialSupported, diff.notice ?? "")
        try await f.repo.apply(diff: diff, hunkID: XCTUnwrap(diff.hunks.first).id)
        XCTAssertEqual(try f.index(), "x\na\nb")
    }

    func testPartialStagingKeepsCRLFAndExecutableMode() async throws {
        let f = try Fixture(); try f.initial("tool.sh", "one\r\ntwo\r\nthree\r\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.appendingPathComponent("tool.sh").path)
        try f.git(["add", "--", "tool.sh"]); try f.git(["commit", "-m", "Executable"])
        try f.write("tool.sh", "one\r\nmid\r\ntwo\r\nthree\r\nend\r\n")
        let diff = try await onlyFile(f, .working)
        let mid = try XCTUnwrap(diff.hunks.flatMap(\.lines).first { $0.kind == .addition && $0.text == "mid\r" })
        let hunk = try XCTUnwrap(diff.hunks.first { $0.lines.contains(mid) })
        try await f.repo.apply(diff: diff, hunkID: hunk.id, selectedLineIDs: [mid.id])
        XCTAssertEqual(try f.index("tool.sh"), "one\r\nmid\r\ntwo\r\nthree\r\n")
        XCTAssertTrue(try f.git(["ls-files", "-s", "--", "tool.sh"]).hasPrefix("100755 "))
    }

    func testIndexFileReadAndReplaceKeepModeAndRefuseStaleObject() async throws {
        let f = try Fixture(); try f.initial("tool.sh", "one\ntwo\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.appendingPathComponent("tool.sh").path)
        try f.git(["add", "--", "tool.sh"]); try f.git(["commit", "-m", "Executable"])
        try f.write("draft.txt", "untracked\n")
        let untracked = try await f.repo.indexFile(path: "draft.txt")
        XCTAssertNil(untracked)
        let file = try await XCTUnwrapAsync(await f.repo.indexFile(path: "tool.sh"))
        XCTAssertEqual(file.mode, "100755")
        XCTAssertEqual(String(decoding: file.data, as: UTF8.self), "one\ntwo\n")

        try await f.repo.replaceIndexFile(path: "tool.sh", data: Data("one\nnew\ntwo\n".utf8), expectedObject: file.object)
        XCTAssertEqual(try f.index("tool.sh"), "one\nnew\ntwo\n")
        XCTAssertTrue(try f.git(["ls-files", "-s", "--", "tool.sh"]).hasPrefix("100755 "))
        XCTAssertEqual(try f.read("tool.sh"), "one\ntwo\n", "the work tree is untouched")
        do { try await f.repo.replaceIndexFile(path: "tool.sh", data: Data("x\n".utf8), expectedObject: file.object); XCTFail("Expected stale") }
        catch FolmiError.staleSnapshot {}
        XCTAssertEqual(try f.index("tool.sh"), "one\nnew\ntwo\n")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    func testPartialStagingRefusesWhenIndexChangedUnderneath() async throws {
        let f = try Fixture(); try f.initial()
        try f.write("sample.txt", "zero\none\ntwo\nthree\nfour\nfive\nsix\n")
        let diff = try await onlyFile(f, .working)
        try f.write("sample.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\n")
        do { try await f.repo.apply(diff: diff, hunkID: XCTUnwrap(diff.hunks.first).id); XCTFail("Expected stale diff") }
        catch FolmiError.staleSnapshot {}
        XCTAssertEqual(try f.index(), "one\ntwo\nthree\nfour\nfive\nsix\n")
    }

    func testCheckoutAndReadOnlyLoadDoNotRefreshIndex() async throws {
        let f = try Fixture(); try f.initial()
        try f.git(["branch", "topic"])
        let indexURL = f.directory.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: indexURL)
        let snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.commits.count, 1); XCTAssertEqual(Set(snapshot.branches), ["main", "topic"])
        XCTAssertEqual(try Data(contentsOf: indexURL), before)
        try await f.repo.checkout(branch: "topic", expectedFingerprint: snapshot.fingerprint)
        let after = try await f.repo.load()
        XCTAssertEqual(after.branch, "topic")
    }

    func testRepositoryRootEndingWithNewlineIsPreserved() async throws {
        let f = try Fixture(directoryName: "repo\n")
        try f.initial()
        let snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.root.standardizedFileURL.path, f.directory.standardizedFileURL.path)
        XCTAssertEqual(snapshot.branch, "main")
    }

    func testProcessTimeoutAndOutputLimitAreBounded() throws {
        let f = try Fixture()
        let process = GitProcess(directory: f.directory, environment: f.environment)
        let started = Date()
        do {
            _ = try process.run(["hash-object", "--stdin"], input: Data(repeating: 65, count: 16 * 1024 * 1024), timeout: 0.001)
            XCTFail("Expected timeout")
        } catch FolmiError.timedOut { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let large = Data(repeating: 65, count: 17 * 1024 * 1024)
        try large.write(to: f.directory.appendingPathComponent("large.txt"))
        try f.git(["add", "--", "large.txt"]); try f.git(["commit", "-m", "Large fixture"])
        let outputStarted = Date()
        do { _ = try process.run(["show", "HEAD:large.txt"]); XCTFail("Expected output limit") }
        catch FolmiError.outputLimit { }
        XCTAssertLessThan(Date().timeIntervalSince(outputStarted), 5)
    }

    func testWorktreeOnlyRefreshKeepsRefsAndHeadChangeReadsThemAgain() async throws {
        let f = try Fixture()
        try f.initial()
        try f.git(["branch", "side"])
        try f.git(["stash", "list"])
        let first = try await f.repo.load()
        XCTAssertEqual(first.branches.sorted(), ["main", "side"])
        XCTAssertEqual(first.commits.count, 1)

        // A work tree edit: status is new, refs come from the previous snapshot without being read.
        try f.write("sample.txt", "changed\n")
        try f.git(["branch", "made-behind-the-back"])
        let quick = try await f.repo.load(reusing: first)
        XCTAssertEqual(quick.files.map(\.path), ["sample.txt"])
        XCTAssertNotEqual(quick.fingerprint, first.fingerprint)
        XCTAssertEqual(quick.branches.sorted(), ["main", "side"])

        // HEAD moved: the previous snapshot is not trusted, everything is read again.
        try f.git(["commit", "-am", "Second"])
        let full = try await f.repo.load(reusing: quick)
        XCTAssertEqual(full.commits.count, 2)
        XCTAssertEqual(full.branches.sorted(), ["made-behind-the-back", "main", "side"])
    }

    func testSideBySideReadsMatchOneByOne() async throws {
        let f = try Fixture()
        try f.initial()
        try f.write("sample.txt", "stash me\n")
        try f.git(["stash", "push", "-m", "kept"])
        let snapshot = try await f.repo.load()
        XCTAssertEqual(snapshot.stashCount, 1)
        XCTAssertEqual(snapshot.branches, ["main"])
        XCTAssertEqual(snapshot.commits.first?.subject, "Initial")
        XCTAssertEqual(snapshot.unpushed, nil) // no remotes: nothing counted
        XCTAssertNil(snapshot.operation)
        let git = GitProcess(directory: f.directory, environment: f.environment)
        XCTAssertThrowsError(try GitRepository.runSideBySide(git, [(["remote"], false), (["no-such-command"], false)]))
    }

    func testLargeRepositoryModeReadsTheSameStatus() async throws {
        let f = try Fixture()
        try f.initial()
        try f.write("sample.txt", "changed\n")
        try f.write("new.txt", "new\n")
        let normal = try await f.repo.load()
        await f.repo.setLargeRepository(true)
        defer { _ = try? f.git(["fsmonitor--daemon", "stop"]) }
        let fast = try await f.repo.load()
        XCTAssertEqual(fast.files.map(\.path).sorted(), normal.files.map(\.path).sorted())
        // Status rewrites the index in this mode; the fingerprint must still stay put between reads…
        let again = try await f.repo.load()
        XCTAssertEqual(again.fingerprint, fast.fingerprint)
        // …and still notice staging.
        try f.git(["add", "--", "sample.txt"])
        let staged = try await f.repo.load()
        XCTAssertNotEqual(staged.fingerprint, fast.fingerprint)
        let duration = await f.repo.lastStatusDuration
        XCTAssertGreaterThan(duration, 0)
    }

    func testContentDiffBetweenTwoVersions() async throws {
        let f = try Fixture()
        try f.initial()
        let changed = try await f.repo.contentDiff(path: "a.txt", before: Data("one\ntwo\n".utf8), after: Data("one\nTWO\n".utf8))
        XCTAssertEqual(changed.file.worktreeCode, "M")
        XCTAssertEqual(changed.hunks.count, 1)
        XCTAssertEqual(changed.hunks[0].lines.filter { $0.kind == .addition }.map(\.text).first?.hasSuffix("TWO"), true)
        let created = try await f.repo.contentDiff(path: "b.txt", before: nil, after: Data("new\n".utf8))
        XCTAssertEqual(created.file.worktreeCode, "A")
        XCTAssertEqual(created.hunks.first?.lines.filter { $0.kind == .addition }.count, 1)
        let same = try await f.repo.contentDiff(path: "c.txt", before: Data("x\n".utf8), after: Data("x\n".utf8))
        XCTAssertTrue(same.hunks.isEmpty)
        XCTAssertNotNil(same.notice)
    }

    func testCaptureRecordsOnlyMissingFilesAsAbsent() throws {
        let f = try Fixture()
        try f.initial()
        XCTAssertNil(try GitRepository.readWorktreeFile("gone.txt", root: f.directory).data, "a missing file is absent")
        // An unreadable folder is an error, never "absent" (undo would then delete the file).
        try f.write("locked/inner.txt", "keep me\n")
        let locked = f.directory.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try GitRepository.readWorktreeFile("locked/inner.txt", root: f.directory))
    }
}
