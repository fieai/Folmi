import Foundation

struct GitOutput {
    let stdout: Data
    let stderr: Data
    let status: Int32
    var text: String { String(decoding: stdout, as: UTF8.self) }
}

struct GitProcess {
    let directory: URL
    let environment: [String: String]
    /// 大仓库模式: `git status` uses Git's file system monitor and untracked cache, and may refresh the index to keep
    /// them current. Every other command stays as before (no monitor, no optional locks).
    var largeRepository = false
    /// `literalPathspecs: false` only for commands that take no paths of ours: `git stash push -u` passes its own
    /// pathspecs to the clean step, which literal mode breaks (untracked files would be stashed but left in place).
    func run(_ arguments: [String], input: Data? = nil, allowFailure: Bool = false, timeout: TimeInterval = 60,
             literalPathspecs: Bool = true, stdoutLimit: Int = 16 * 1_024 * 1_024) throws -> GitOutput {
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] { env.removeValue(forKey: key) }
        environment.forEach { env[$0.key] = $0.value }
        let fastStatus = largeRepository && arguments.first == "status"
        env["GIT_TERMINAL_PROMPT"] = "0"; if !fastStatus { env["GIT_OPTIONAL_LOCKS"] = "0" }
        env.removeValue(forKey: "GIT_GLOB_PATHSPECS"); env.removeValue(forKey: "GIT_NOGLOB_PATHSPECS"); if literalPathspecs { env["GIT_LITERAL_PATHSPECS"] = "1" }
        let execution: ProcessExecutionResult
        do {
            execution = try ProcessExecutor.run(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: (fastStatus ? ["-c", "core.fsmonitor=true", "-c", "core.untrackedCache=true", "-c", "color.ui=false"]
                            : ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "color.ui=false"]) + arguments,
                directory: directory, environment: env, input: input, timeout: timeout, stdoutLimit: stdoutLimit
            )
        } catch let error as ProcessExecutionError {
            switch error {
            case let .workingDirectoryUnavailable(path, message): throw FolmiError.projectDirectoryUnavailable(path: path, message: message)
            case let .launch(executable, message): throw FolmiError.processLaunch(executable: executable, message: message)
            case .timeout: throw FolmiError.timedOut
            case .outputLimit: throw FolmiError.outputLimit
            case let .io(message): throw FolmiError.processIO(message)
            }
        }
        let result = GitOutput(stdout: execution.stdout, stderr: execution.stderr, status: execution.status)
        if result.status != 0 && !allowFailure {
            let message = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FolmiError.git(exitCode: result.status, message: message)
        }
        return result
    }
}
