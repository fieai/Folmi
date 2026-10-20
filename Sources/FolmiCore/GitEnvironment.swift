import Foundation

/// Check the selected developer tools before invoking Apple's Git shim, which can otherwise open
/// a system installation dialog as a side effect of restoring a repository.
public enum GitEnvironment: Equatable, Sendable {
    case ready(version: String)
    case needsCommandLineTools(details: String)
    case unavailable(details: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public static func check() -> Self {
        check { path, arguments in
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            return try ProcessExecutor.run(executable: URL(fileURLWithPath: path), arguments: arguments,
                                           directory: URL(fileURLWithPath: "/"), environment: environment,
                                           timeout: 10, stdoutLimit: 64 * 1_024, stderrLimit: 64 * 1_024)
        }
    }

    static func check(run: (String, [String]) throws -> ProcessExecutionResult) -> Self {
        do {
            let tools = try run("/usr/bin/xcode-select", ["--print-path"])
            guard tools.status == 0, text(tools.stdout).hasPrefix("/") else {
                return .needsCommandLineTools(details: diagnostic(tools))
            }
            let git = try run("/usr/bin/git", ["--version"])
            let version = text(git.stdout)
            guard git.status == 0, version.hasPrefix("git version ") else {
                return .unavailable(details: diagnostic(git))
            }
            return .ready(version: version)
        } catch {
            return .unavailable(details: error.localizedDescription)
        }
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func diagnostic(_ result: ProcessExecutionResult) -> String {
        let output = text(result.stderr.isEmpty ? result.stdout : result.stderr)
        return output.isEmpty ? "检测命令退出，状态码 \(result.status)。" : String(output.prefix(2_000))
    }
}
