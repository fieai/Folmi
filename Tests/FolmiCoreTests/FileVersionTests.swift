import XCTest
@testable import FolmiCore

/// The before / after sides of a binary change, as the change previews read them.
final class FileVersionTests: XCTestCase {
    private var directory: URL!
    private var environment: [String: String] = [:]
    private var repo: GitRepository!

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-versions-" + UUID().uuidString, isDirectory: true)
        directory = temp.appendingPathComponent("repo", isDirectory: true)
        let home = temp.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        repo = GitRepository(url: directory, environment: environment)
        try git(["init", "--template=", "--initial-branch=main"])
        try git(["config", "user.name", "T"]); try git(["config", "user.email", "t@example.invalid"])
        try git(["config", "core.hooksPath", "/dev/null"]); try git(["config", "commit.gpgsign", "false"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    @discardableResult private func git(_ args: [String]) throws -> String { try GitProcess(directory: directory, environment: environment).run(args).text }
    private func write(_ path: String, _ bytes: [UInt8]) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }
    private func diff(_ path: String, _ area: ChangeArea) async throws -> FileDiff {
        let state = try await repo.load()
        let file = try XCTUnwrap(state.files.first { $0.path == path })
        return try await repo.diff(for: file, area: area)
    }

    func testWorkingAndStagedBinaryChangesNameBothSides() async throws {
        try write("img/a.png", [0x89, 0x50, 0x4E, 0x47, 0, 1])
        try git(["add", "."]); try git(["commit", "-m", "one"])
        try write("img/a.png", [0x89, 0x50, 0x4E, 0x47, 0, 2])
        var working = try await diff("img/a.png", .working)
        XCTAssertTrue(working.isBinary)
        XCTAssertEqual(working.versions, FileVersions(old: .object(":img/a.png"), new: .worktree("img/a.png")))
        let old = try await repo.bytes(of: try XCTUnwrap(working.versions?.old))
        let new = try await repo.bytes(of: try XCTUnwrap(working.versions?.new))
        XCTAssertEqual(old.map { [UInt8]($0) }, [0x89, 0x50, 0x4E, 0x47, 0, 1])
        XCTAssertEqual(new.map { [UInt8]($0) }, [0x89, 0x50, 0x4E, 0x47, 0, 2])

        try git(["add", "."])
        let staged = try await diff("img/a.png", .staged)
        XCTAssertEqual(staged.versions, FileVersions(old: .object("HEAD:img/a.png"), new: .object(":img/a.png")))
        let head = try await repo.bytes(of: .object("HEAD:img/a.png"))
        XCTAssertEqual(head.map { [UInt8]($0) }, [0x89, 0x50, 0x4E, 0x47, 0, 1])
        working = try await diff("img/a.png", .staged)
        XCTAssertNotNil(working.versions?.new)
    }

    func testNewAndDeletedFilesHaveOneSide() async throws {
        try write("keep.txt", Array("x\n".utf8)); try write("gone.docx", [0x50, 0x4B, 3, 4, 0])
        try git(["add", "."]); try git(["commit", "-m", "one"])
        try write("新建 (1).docx", [0x50, 0x4B, 3, 4, 0, 9])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("gone.docx"))
        let added = try await diff("新建 (1).docx", .working)
        XCTAssertTrue(added.isBinary)
        XCTAssertEqual(added.versions, FileVersions(old: nil, new: .worktree("新建 (1).docx")))
        let deleted = try await diff("gone.docx", .working)
        XCTAssertEqual(deleted.versions, FileVersions(old: .object(":gone.docx"), new: nil))
        let removedBytes = try await repo.bytes(of: .object(":gone.docx"))
        XCTAssertEqual(removedBytes.map { [UInt8]($0) }, [0x50, 0x4B, 3, 4, 0])
    }

    func testCommitAndCompareDiffsPointAtTheirCommits() async throws {
        try write("a.bin", [0, 1]); try git(["add", "."]); try git(["commit", "-m", "one"])
        let first = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("a.bin", [0, 2]); try git(["add", "."]); try git(["commit", "-m", "two"])
        let second = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try await repo.commitDiff(second, file: CommitFileChange(path: "a.bin", status: "M"))
        XCTAssertEqual(commit.versions, FileVersions(old: .object(first + ":a.bin"), new: .object(second + ":a.bin")))
        // The first commit has no parent: its old side is missing, not an error.
        let initial = try await repo.commitDiff(first, file: CommitFileChange(path: "a.bin", status: "A"))
        XCTAssertNil(initial.versions?.old)
        let compare = try await repo.compareDiff(base: first, target: second, file: CommitFileChange(path: "a.bin", status: "M"))
        let before = try await repo.bytes(of: try XCTUnwrap(compare.versions?.old))
        XCTAssertEqual(before.map { [UInt8]($0) }, [0, 1])
    }

    func testReplayKeepsItsBytesAndMissingVersionsReadAsNil() async throws {
        try write("a.txt", Array("x\n".utf8)); try git(["add", "."]); try git(["commit", "-m", "one"])
        let replay = try await repo.contentDiff(path: "p.png", before: nil, after: Data([1, 0, 2]))
        XCTAssertEqual(replay.versions, FileVersions(old: nil, new: .bytes(Data([1, 0, 2]))))
        let missingObject = try await repo.bytes(of: .object("HEAD:nope.png"))
        XCTAssertNil(missingObject)
        let missingFile = try await repo.bytes(of: .worktree("nope.png"))
        XCTAssertNil(missingFile)
        // Not object names of ours, and paths that leave the repository, read as nothing.
        let option = try await repo.bytes(of: .object("--output=/tmp/x"))
        XCTAssertNil(option)
        let outside = try await repo.bytes(of: .worktree("../outside.png"))
        XCTAssertNil(outside)
    }

    func testOversizedVersionsThrowInsteadOfReadingEverything() async throws {
        try write("big.bin", [UInt8](repeating: 0, count: 4_096)); try git(["add", "."]); try git(["commit", "-m", "one"])
        do { _ = try await repo.bytes(of: .object("HEAD:big.bin"), limit: 1_000); XCTFail("expected outputLimit") }
        catch FolmiError.outputLimit {}
        do { _ = try await repo.bytes(of: .worktree("big.bin"), limit: 1_000); XCTFail("expected outputLimit") }
        catch FolmiError.outputLimit {}
    }
}
