import XCTest
@testable import FolmiCore

final class LineCountTests: XCTestCase {
    func testNumstatParsesPlainRenamedAndBinaryFiles() {
        let output = "3\t1\tREADME.md\u{0}12\t0\t\u{0}old name.txt\u{0}new name.txt\u{0}-\t-\tlogo.png\u{0}0\t4\tdir/a b.swift\u{0}"
        let parsed = LineCount.parseNumstat(output)
        XCTAssertEqual(parsed.map(\.0), ["README.md", "new name.txt", "dir/a b.swift"], "binary files are skipped, renames keep the new path")
        XCTAssertEqual(parsed.map(\.1), [LineCount(added: 3, removed: 1), LineCount(added: 12, removed: 0), LineCount(added: 0, removed: 4)])
        XCTAssertTrue(LineCount.parseNumstat("").isEmpty)
    }

    func testRepositoryCountsStagedWorkingAndUntrackedLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linecount-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            try process.run(); process.waitUntilExit()
        }
        try git("init", "-q")
        try "a\nb\nc\n".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git("add", "f.txt"); try git("commit", "-qm", "one")
        try "a\nB\nc\nd\n".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git("add", "f.txt")
        try "a\nB\n".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "x\ny".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let counts = try await GitRepository(url: root).lineCounts(untracked: ["new.txt"])
        XCTAssertEqual(counts["staged:f.txt"], LineCount(added: 2, removed: 1))
        XCTAssertEqual(counts["working:f.txt"], LineCount(added: 0, removed: 2))
        XCTAssertEqual(counts["working:new.txt"], LineCount(added: 2, removed: 0), "a last line without a newline still counts")
    }
}
