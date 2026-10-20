import XCTest
@testable import FolmiCore

final class GitEnvironmentTests: XCTestCase {
    private func output(_ text: String = "", error: String = "", status: Int32 = 0) -> ProcessExecutionResult {
        .init(stdout: Data(text.utf8), stderr: Data(error.utf8), status: status)
    }

    func testMissingToolsNeverInvokeTheGitInstallationShim() {
        var commands: [String] = []
        let result = GitEnvironment.check { path, arguments in
            commands.append(path)
            XCTAssertEqual(arguments, ["--print-path"])
            return self.output(error: "unable to get active developer directory", status: 2)
        }
        XCTAssertEqual(commands, ["/usr/bin/xcode-select"])
        XCTAssertEqual(result, .needsCommandLineTools(details: "unable to get active developer directory"))
    }

    func testSelectedToolsStillRequireAWorkingGit() {
        let result = GitEnvironment.check { path, arguments in
            if path == "/usr/bin/xcode-select" { return self.output("/Applications/Xcode.app/Contents/Developer\n") }
            XCTAssertEqual(path, "/usr/bin/git")
            XCTAssertEqual(arguments, ["--version"])
            return self.output(error: "You have not agreed to the Xcode license agreements", status: 69)
        }
        XCTAssertEqual(result, .unavailable(details: "You have not agreed to the Xcode license agreements"))
    }

    func testReadyReportsTheActualGitVersion() {
        let result = GitEnvironment.check { path, _ in
            self.output(path == "/usr/bin/git" ? "git version 2.50.1 (Apple Git-155)\n" : "/Library/Developer/CommandLineTools\n")
        }
        XCTAssertEqual(result, .ready(version: "git version 2.50.1 (Apple Git-155)"))
        XCTAssertTrue(result.isReady)
    }

    func testEmptyDeveloperDirectoryDoesNotInvokeGit() {
        var calls = 0
        let result = GitEnvironment.check { _, _ in calls += 1; return self.output() }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(result.isReady)
    }

    func testUnexpectedGitOutputAndLaunchFailuresRemainUnavailable() {
        let result = GitEnvironment.check { path, _ in
            self.output(path == "/usr/bin/git" ? "not a Git version" : "/tools")
        }
        XCTAssertEqual(result, .unavailable(details: "not a Git version"))
        let failure = GitEnvironment.check { _, _ in throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "launch failed"]) }
        XCTAssertEqual(failure, .unavailable(details: "launch failed"))
    }
}
