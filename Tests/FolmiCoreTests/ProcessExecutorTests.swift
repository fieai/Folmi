import XCTest
import Foundation
@testable import FolmiCore

final class ProcessExecutorTests: XCTestCase {
    private func withTemporaryRoot<T>(_ body: (URL, [String: String]) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path,
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null"]
        return try body(root, environment)
    }

    func testExactArgumentsEnvironmentAndWorkingDirectory() throws {
        try withTemporaryRoot { root, _ in
            let literal = "space ' quote; $(touch NOT_CREATED)`touch ALSO_NOT_CREATED`"
            let result = try ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["%s\\0", literal], directory: root, environment: [:])
            XCTAssertEqual(result.stdout, Data(literal.utf8) + Data([0]))
            XCTAssertEqual(result.status, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NOT_CREATED").path))
            let env = try ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [], directory: root, environment: ["ONLY_THIS": "exact value"])
            XCTAssertEqual(String(decoding: env.stdout, as: UTF8.self), "ONLY_THIS=exact value\n")
            let cwd = try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [], directory: root, environment: [:])
            let actual = String(decoding: cwd.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            XCTAssertEqual(URL(fileURLWithPath: actual).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        }
    }

    func testDrainsBothOutputStreamsWhileFeedingLargeInput() throws {
        try withTemporaryRoot { root, environment in
            let input = Data(repeating: 0x61, count: 2 * 1_024 * 1_024)
            let result = try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(/bin/dd if=/dev/zero bs=65536 count=8 2>/dev/null) >&2; /bin/cat"],
                directory: root, environment: environment, input: input, timeout: 5)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout, input)
            XCTAssertEqual(result.stderr, Data(repeating: 0, count: 8 * 65_536))
        }
    }

    func testNonzeroExitPreservesOutputAndError() throws {
        try withTemporaryRoot { root, environment in
            let result = try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf result; printf problem >&2; exit 23"], directory: root, environment: environment)
            XCTAssertEqual(result.status, 23)
            XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "result")
            XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "problem")
        }
    }

    func testTimeoutIsBoundedAndEscalatesWhenTERMIsIgnored() throws {
        try withTemporaryRoot { root, environment in
            let started = Date()
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"], directory: root,
                environment: environment, timeout: 0.15)) { error in
                guard case ProcessExecutionError.timeout = error else { return XCTFail("Expected timeout, got \(error)") }
            }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 2)
            XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        }
    }

    func testTimeoutForResponsiveProcessReturnsPromptly() throws {
        try withTemporaryRoot { root, environment in
            let started = Date()
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"], directory: root, environment: environment, timeout: 0.1)) { error in
                guard case ProcessExecutionError.timeout = error else { return XCTFail("Expected timeout, got \(error)") }
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }

    func testOutputLimitsStopUnboundedWriters() throws {
        try withTemporaryRoot { root, environment in
            let started = Date()
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [],
                directory: root, environment: environment, timeout: 5, stdoutLimit: 131_072, stderrLimit: 1_024)) { error in
                guard case let ProcessExecutionError.outputLimit(stream, limit) = error else { return XCTFail("Expected output limit, got \(error)") }
                XCTAssertEqual(stream, "标准输出")
                XCTAssertEqual(limit, 131_072)
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do printf '0123456789abcdef' >&2; done"], directory: root,
                environment: environment, timeout: 5, stdoutLimit: 1_024, stderrLimit: 512)) { error in
                guard case let ProcessExecutionError.outputLimit(stream, _) = error else { return XCTFail("Expected output limit, got \(error)") }
                XCTAssertEqual(stream, "标准错误")
            }
        }
    }

    func testInvalidExecutableDirectoryAndNULArgumentsFailWithoutHanging() throws {
        try withTemporaryRoot { root, environment in
            XCTAssertThrowsError(try ProcessExecutor.run(executable: root.appendingPathComponent("missing-command"), arguments: [], directory: root, environment: environment))
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], directory: root.appendingPathComponent("missing"), environment: environment))
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["abc\0def"], directory: root, environment: environment))
        }
    }

    func testEarlyStdinClosureDoesNotSignalOrHangParent() throws {
        try withTemporaryRoot { root, environment in
            let started = Date()
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                directory: root, environment: environment, input: Data(repeating: 1, count: 4 * 1_024 * 1_024), timeout: 3))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }

    func testInheritedOutputPipeHasBoundedDrainAfterOwnedChildExits() throws {
        try withTemporaryRoot { root, environment in
            let started = Date()
            XCTAssertThrowsError(try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/bin/sleep 2 & exit 0"], directory: root, environment: environment, timeout: 5)) { error in
                guard case ProcessExecutionError.io = error else { return XCTFail("Expected pipe error, got \(error)") }
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.7)
        }
    }

    func testConcurrentFastExitsKeepEachOwnedStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-ConcurrentProcess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withThrowingTaskGroup(of: (Int32, Int32).self) { group in
            for expected in Int32(0)..<32 {
                group.addTask {
                    let result = try ProcessExecutor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "exit \(expected)"], directory: root, environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
                    return (expected, result.status)
                }
            }
            for try await (expected, actual) in group { XCTAssertEqual(actual, expected) }
        }
    }

    func testGitProcessUsesExecutorForBinaryStdinAndPreservesGitFailure() throws {
        try withTemporaryRoot { root, environment in
            let git = GitProcess(directory: root, environment: environment)
            let result = try git.run(["hash-object", "--stdin"], input: Data("hello\n".utf8))
            XCTAssertEqual(result.text, "ce013625030ba8dba906f756967f9e9ca394464a\n")
            XCTAssertThrowsError(try git.run(["not-a-command"])) { error in
                guard case FolmiError.git(let exitCode, let message) = error else { return XCTFail("Expected Git error, got \(error)") }
                XCTAssertNotEqual(exitCode, 0)
                XCTAssertTrue(message.contains("not a git command"))
            }
            XCTAssertNotEqual(try git.run(["not-a-command"], allowFailure: true).status, 0)
        }
    }
}
