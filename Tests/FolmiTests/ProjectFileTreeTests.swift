import XCTest
@testable import Folmi
import FolmiCore

final class ProjectFileTreeTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("folmi-tree-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testDirectoriesFirstNaturalOrderingHierarchyAndEmptyDirectories() throws {
        try directory("dir10")
        try directory("dir2")
        try directory("src/empty")
        try write("src/index.js")
        try write("file10.txt")
        try write("file2.txt")
        let snapshot = try ProjectFileTree.scan(root: temporaryRoot)
        XCTAssertEqual(snapshot.roots.map(\.name), ["dir2", "dir10", "src", "file2.txt", "file10.txt"])
        let source = try XCTUnwrap(snapshot.roots.first { $0.path == "src" })
        XCTAssertEqual(source.children?.map(\.path), ["src/empty", "src/index.js"])
        let empty = try XCTUnwrap(source.children?.first)
        XCTAssertTrue(empty.isDirectory)
        XCTAssertEqual(empty.children, [])
        XCTAssertNil(empty.notice)
        XCTAssertEqual(snapshot.fileCount, 3)
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertNil(snapshot.notice)
    }

    func testSystemLeftoversAreHiddenButOtherDotfilesStay() throws {
        for path in [".DS_Store", "docs/.DS_Store", "docs/._合同.docx", "Thumbs.db", "docs/合同.docx", ".env", ".dsx"] { try write(path) }
        let snapshot = try ProjectFileTree.scan(root: temporaryRoot)
        func paths(_ nodes: [ProjectFileNode]) -> [String] { nodes.flatMap { $0.isDirectory ? paths($0.children ?? []) : [$0.path] } }
        XCTAssertEqual(Set(paths(snapshot.roots)), [".env", ".dsx", "docs/合同.docx"])
    }

    func testExcludesMetadataDependenciesAndAllSymbolicLinksButKeepsDotfiles() throws {
        for path in [".git/config", "nested/.GIT", "node_modules/pkg/index.js", ".build/cache", "build/output",
                     "vendor/dependency", "dist/index.js", ".venv/bin/python", "scripts/__pycache__/cached",
                     "src/main.py", ".gitignore", ".env.example", ".github/workflows/build.yml"] {
            try write(path)
        }
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("linked-src"),
                                                  withDestinationURL: temporaryRoot.appendingPathComponent("src"))
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("linked-file.py"),
                                                  withDestinationURL: temporaryRoot.appendingPathComponent("src/main.py"))
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("linked-outside"),
                                                  withDestinationURL: temporaryRoot.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("linked-git"),
                                                  withDestinationURL: temporaryRoot.appendingPathComponent(".git"))
        let snapshot = try ProjectFileTree.scan(root: temporaryRoot)
        XCTAssertEqual(Set(flatten(snapshot.roots).filter { !$0.isDirectory }.map(\.path)),
                       ["src/main.py", ".gitignore", ".env.example", ".github/workflows/build.yml"])
        XCTAssertFalse(flatten(snapshot.roots).contains { $0.path.contains("linked-") })
        XCTAssertEqual(snapshot.fileCount, 4)
        // Dependency folders are listed closed and dimmed; their contents wait until the folder is opened.
        let modules = try XCTUnwrap(snapshot.roots.first { $0.path == "node_modules" })
        XCTAssertTrue(modules.isIgnored && modules.isDeferred)
        XCTAssertEqual(modules.children, [])
    }

    func testGitIgnoredPathsAreShownDimmedAndDoNotCountTowardTheLimit() async throws {
        _ = try await CommandRunner.git(["init", "-q", "--template=", "--initial-branch=main"], at: temporaryRoot)
        try Data("outputs/\n*.log\n".utf8).write(to: temporaryRoot.appendingPathComponent(".gitignore"))
        for path in ["src/main.py", "outputs/a/report.json", "outputs/b.json", "src/run.log"] { try write(path) }
        let ignored = try await GitRepository(url: temporaryRoot).ignoredPaths(in: temporaryRoot)
        XCTAssertEqual(ignored, IgnoredPaths(directories: ["outputs"], files: ["src/run.log"]))

        let snapshot = try ProjectFileTree.scan(root: temporaryRoot, ignored: ignored,
                                               limits: .init(maximumFiles: 2, maximumEntries: 100, maximumDepth: 8))
        XCTAssertEqual(snapshot.fileCount, 2)
        XCTAssertFalse(snapshot.isTruncated)
        let outputs = try XCTUnwrap(snapshot.roots.first { $0.path == "outputs" })
        XCTAssertTrue(outputs.isIgnored && outputs.isDeferred)
        let log = try XCTUnwrap(flatten(snapshot.roots).first { $0.path == "src/run.log" })
        XCTAssertTrue(log.isIgnored)
        XCTAssertFalse(try XCTUnwrap(flatten(snapshot.roots).first { $0.path == "src/main.py" }).isIgnored)

        // Opening reads one level; the subfolder stays closed until it is opened in turn.
        let loaded = try ProjectFileTree.loadFolder(root: temporaryRoot, path: "outputs")
        XCTAssertEqual(loaded.roots.map(\.path), ["outputs/a", "outputs/b.json"])
        XCTAssertTrue(loaded.roots.allSatisfy(\.isIgnored))
        XCTAssertTrue(loaded.roots[0].isDeferred)
        let filled = ProjectFileTree.replacingChildren(in: snapshot.roots, path: "outputs", with: loaded)
        let opened = try XCTUnwrap(filled.first { $0.path == "outputs" })
        XCTAssertFalse(opened.isDeferred)
        XCTAssertTrue(opened.isIgnored)
        XCTAssertEqual(opened.children?.count, 2)
        let nested = try ProjectFileTree.loadFolder(root: temporaryRoot, path: "outputs/a")
        XCTAssertEqual(nested.roots.map(\.path), ["outputs/a/report.json"])
    }

    func testLoadFolderRefusesEscapesGitMetadataAndLinks() throws {
        try write(".git/config")
        try write("real/file.txt")
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("alias"),
                                                  withDestinationURL: temporaryRoot.appendingPathComponent("real"))
        for path in ["", "..", "real/..", ".git", "alias", "missing"] {
            XCTAssertThrowsError(try ProjectFileTree.loadFolder(root: temporaryRoot, path: path), path)
        }
    }

    func testFilteringRetainsAncestorsAndDirectoryMatchesIncludeTheirFiles() throws {
        try write("src/deep/Hello.py")
        try write("src/deep/other.js")
        try write("docs/readme.md")
        let roots = try ProjectFileTree.scan(root: temporaryRoot).roots
        let python = ProjectFileTree.filtered(roots, query: "HELLO.PY")
        XCTAssertEqual(python.map(\.path), ["src"])
        XCTAssertEqual(python.first?.children?.map(\.path), ["src/deep"])
        XCTAssertEqual(python.first?.children?.first?.children?.map(\.path), ["src/deep/Hello.py"])
        XCTAssertEqual(flatten(ProjectFileTree.filtered(roots, query: "src/deep")).filter { !$0.isDirectory }.count, 2)
        XCTAssertTrue(ProjectFileTree.filtered(roots, query: "not-in-this-project").isEmpty)
        XCTAssertEqual(ProjectFileTree.filtered(roots, query: " \n "), roots)
    }

    func testUnicodeWhitespaceAndSpecialFilenamesRemainExactRelativePaths() throws {
        let paths = ["中文目录/脚本 🐍.py", "folder with spaces/line\nbreak.js", "-leading-name.txt", ".配置.json"]
        for path in paths { try write(path) }
        let snapshot = try ProjectFileTree.scan(root: temporaryRoot)
        XCTAssertEqual(Set(flatten(snapshot.roots).filter { !$0.isDirectory }.map(\.path)), Set(paths))
        for node in flatten(snapshot.roots) { XCTAssertEqual(node.id, node.path) }
    }

    func testFileAndEntryLimitsAreBoundedAndVisible() throws {
        for index in 0..<12 { try write("file\(index).txt") }
        let fileLimited = try ProjectFileTree.scan(root: temporaryRoot,
                                                  limits: .init(maximumFiles: 3, maximumEntries: 30, maximumDepth: 8))
        XCTAssertEqual(fileLimited.fileCount, 3)
        XCTAssertTrue(fileLimited.isTruncated)
        XCTAssertTrue(try XCTUnwrap(fileLimited.notice).contains("3"))
        let entryLimited = try ProjectFileTree.scan(root: temporaryRoot,
                                                   limits: .init(maximumFiles: 30, maximumEntries: 4, maximumDepth: 8))
        XCTAssertEqual(entryLimited.fileCount, 4)
        XCTAssertTrue(entryLimited.isTruncated)
        XCTAssertNotNil(entryLimited.notice)
        XCTAssertEqual(ProjectFileTree.ScanLimits.default.maximumFiles, 10_000)
        XCTAssertEqual(ProjectFileTree.ScanLimits.default.maximumEntries, 20_000)
    }

    func testDepthLimitKeepsDirectoryWithNoticeRatherThanPretendingItIsEmpty() throws {
        try write("one/two/three/four/file.py")
        let snapshot = try ProjectFileTree.scan(root: temporaryRoot,
                                               limits: .init(maximumFiles: 50, maximumEntries: 100, maximumDepth: 2))
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(snapshot.fileCount, 0)
        let cutoff = try XCTUnwrap(flatten(snapshot.roots).first { $0.path == "one/two/three" })
        XCTAssertTrue(cutoff.isDirectory)
        XCTAssertEqual(cutoff.children, [])
        XCTAssertNotNil(cutoff.notice)
        XCTAssertNotNil(snapshot.notice)
    }

    func testRejectsGitRootFilesMissingPathsAndRootSymlinks() throws {
        try write(".git/config")
        try write("nested/.GIT/config")
        try write("plain.txt")
        for path in [".git", ".git/config", "nested/.GIT", "nested/.GIT/config", "missing", "plain.txt"] {
            XCTAssertThrowsError(try ProjectFileTree.scan(root: temporaryRoot.appendingPathComponent(path)), path)
        }
        try directory("src")
        try FileManager.default.createSymbolicLink(at: temporaryRoot.appendingPathComponent("alias"),
                                                  withDestinationURL: temporaryRoot.appendingPathComponent("src"))
        XCTAssertThrowsError(try ProjectFileTree.scan(root: temporaryRoot.appendingPathComponent("alias")))
    }

    func testCanonicalMacTemporaryRootHasIdenticalResults() throws {
        try write("src/main.js")
        let normal = try ProjectFileTree.scan(root: temporaryRoot)
        let canonical = try ProjectFileTree.scan(root: temporaryRoot.resolvingSymlinksInPath())
        XCTAssertEqual(normal.roots, canonical.roots)
        XCTAssertEqual(normal.fileCount, canonical.fileCount)
    }

    func testUnreadableSubdirectoryHasAnExplicitNotice() throws {
        try write("blocked/hidden.js")
        let blocked = temporaryRoot.appendingPathComponent("blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        guard !FileManager.default.isReadableFile(atPath: blocked.path) else {
            throw XCTSkip("Current user can bypass directory permissions")
        }
        let snapshot = try ProjectFileTree.scan(root: temporaryRoot)
        let node = try XCTUnwrap(snapshot.roots.first { $0.path == "blocked" })
        XCTAssertTrue(node.isDirectory)
        XCTAssertEqual(node.children, [])
        XCTAssertNotNil(node.notice)
        XCTAssertNotNil(snapshot.notice)
    }

    private func directory(_ path: String) throws {
        try FileManager.default.createDirectory(at: temporaryRoot.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    private func write(_ path: String) throws {
        let url = temporaryRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }

    private func flatten(_ nodes: [ProjectFileNode]) -> [ProjectFileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }
}
