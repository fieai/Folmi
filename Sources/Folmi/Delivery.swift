import Foundation
import Darwin
import FolmiCore
import CryptoKit

enum DeliveryKind: String, CaseIterable, Identifiable, Codable {
    case push, gerrit, script
    var id: String { rawValue }
    var title: String {
        switch self {
        case .push: return "推送分支"
        case .gerrit: return "提交 Gerrit 评审"
        case .script: return "运行自定义脚本"
        }
    }
}

struct DeliveryCommand {
    let executable: URL
    let arguments: [String]
    var display: String {
        ([executable.path] + arguments).map { value in
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

struct DeliveryPlan {
    let id = UUID()
    let root: URL
    let head: String
    let fingerprint: String
    let formSignature: String
    let kind: DeliveryKind
    let endpoint: String?
    let command: DeliveryCommand
    let executableFingerprint: String?
}

enum ExecutableFingerprint {
    static func read(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 128 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum RuntimeOptions {
    /// `--present pull|stash`: opens that sheet once the project is up, for screenshots of each theme.
    static var present: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--present"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    static var workspaceURL: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--workspace-file"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        if arguments.contains("--demo") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Settings-\(UUID().uuidString)/workspace.json")
        }
        return WorkspaceStore.defaultURL
    }
}

struct CommandResult {
    let output: String
    let error: String
    let exitCode: Int32
    var combined: String { [output, error].filter { !$0.isEmpty }.joined(separator: "\n") }
}

struct FolmiFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CommandRunner {
    static func run(_ command: DeliveryCommand, at directory: URL,
                    environment: [String: String] = [:], timeout: TimeInterval = 180) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            var env = ProcessInfo.processInfo.environment
            for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] {
                env.removeValue(forKey: key)
            }
            environment.forEach { env[$0.key] = $0.value }
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_PAGER"] = "cat"
            env["LC_ALL"] = "C"
            let result = try ProcessExecutor.run(executable: command.executable, arguments: command.arguments,
                                                 directory: directory, environment: env, timeout: timeout,
                                                 stdoutLimit: 4 * 1024 * 1024, stderrLimit: 4 * 1024 * 1024)
            return CommandResult(output: String(decoding: result.stdout, as: UTF8.self),
                                 error: String(decoding: result.stderr, as: UTF8.self), exitCode: result.status)
        }.value
    }
    static func git(_ arguments: [String], at directory: URL,
                    environment: [String: String] = [:]) async throws -> String {
        let command = DeliveryCommand(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments)
        let result = try await run(command, at: directory, environment: environment)
        guard result.exitCode == 0 else {
            throw FolmiFailure(message: "Git 退出码 \(result.exitCode)\n\(result.combined)")
        }
        return result.output
    }
}
