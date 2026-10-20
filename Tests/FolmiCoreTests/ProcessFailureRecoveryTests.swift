import XCTest
@testable import FolmiCore

final class ProcessFailureRecoveryTests: XCTestCase {
    func testMissingProjectReportsItsPathWithoutClaimingAnOperationRan() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-project-\(UUID().uuidString)")
        XCTAssertThrowsError(try GitProcess(directory: missing, environment: [:]).run(["status"])) { error in
            XCTAssertTrue(error.localizedDescription.contains(missing.path))
            XCTAssertTrue(error.localizedDescription.contains("不存在"))
            XCTAssertFalse(error.localizedDescription.contains("可能已经完成"))
            XCTAssertFalse(error.localizedDescription.contains("通信异常"))
        }
    }

    func testMissingExecutableReportsLaunchFailureRatherThanCommunicationFailure() {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent("missing-program-\(UUID().uuidString)")
        XCTAssertThrowsError(try ProcessExecutor.run(executable: executable, arguments: [],
                            directory: FileManager.default.temporaryDirectory, environment: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("未能启动"))
            XCTAssertTrue(error.localizedDescription.contains(executable.path))
        }
    }
}
