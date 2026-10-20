import XCTest
@testable import FolmiCore
@testable import Folmi

final class CommitCheckTests: XCTestCase {
    func testFindsSecretsConflictsDebugAndFiles() {
        let patch = """
        diff --git a/app.js b/app.js
        --- a/app.js
        +++ b/app.js
        @@ -1,2 +1,5 @@
         const a = 1
        +console.log("here")
        +const key = "sk-abcdefghijklmnopqrstuvwxyz0123"
        +<<<<<<< HEAD
        +fine line
        """
        let check = CommitCheck.run(patch: patch, stagedPaths: ["app.js", ".env"], sizes: ["big.bin": 6 * 1024 * 1024], fingerprint: "f")
        let kinds = Set(check.findings.map(\.kind))
        XCTAssertEqual(kinds, [.debug, .secret, .conflict, .sensitiveFile, .largeFile])
        XCTAssertTrue(check.blocking)
        XCTAssertEqual(check.findings.first { $0.kind == .debug }?.detail.hasPrefix("第 2 行"), true)
    }
    func testCleanPatchHasNoFindings() {
        let patch = "+++ b/a.swift\n@@ -1,1 +1,2 @@\n let a = 1\n+let b = 2\n"
        XCTAssertTrue(CommitCheck.run(patch: patch, stagedPaths: ["a.swift"], sizes: [:], fingerprint: "f").findings.isEmpty)
    }
}

final class SplitSuggestionTests: XCTestCase {
    func testDescribesGroupsOrSaysNoSplit() {
        let two = #"好的 {"groups":[{"title":"修复登录","paths":["a.swift"]},{"title":"补测试","paths":["aTests.swift"]}]}"#
        let text = FolmiModel.describeSplit(two)
        XCTAssertTrue(text.contains("2 次提交")); XCTAssertTrue(text.contains("修复登录")); XCTAssertTrue(text.contains("· aTests.swift"))
        XCTAssertTrue(FolmiModel.describeSplit(#"{"groups":[{"title":"x","paths":[]}]}"#).contains("不需要拆分"))
        XCTAssertEqual(FolmiModel.describeSplit("not json"), "not json")
    }
}

final class FileHistoryTests: XCTestCase {
    func testFollowsRenamesAndReadsOldText() async throws {
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let env = demo.environment
        try "# One\n".write(to: demo.root.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
        _ = try await CommandRunner.git(["add", "doc.md"], at: demo.root, environment: env)
        _ = try await CommandRunner.git(["commit", "-m", "add doc"], at: demo.root, environment: env)
        _ = try await CommandRunner.git(["mv", "doc.md", "guide.md"], at: demo.root, environment: env)
        _ = try await CommandRunner.git(["commit", "-m", "rename doc"], at: demo.root, environment: env)
        try "# One\n\nTwo\n".write(to: demo.root.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        _ = try await CommandRunner.git(["commit", "-am", "extend guide"], at: demo.root, environment: env)
        let repository = GitRepository(url: demo.root, environment: env)
        let history = try await repository.fileHistory(path: "guide.md")
        XCTAssertEqual(history.map(\.subject), ["extend guide", "rename doc", "add doc"])
        XCTAssertEqual(history.last?.path, "doc.md")
        let first = try await repository.fileText(commit: history[2].id, path: history[2].path)
        XCTAssertEqual(first, "# One\n")
        let parent = try await repository.parent(of: history[0].id)
        XCTAssertEqual(parent, history[1].id)
    }
}
