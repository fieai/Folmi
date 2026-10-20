import Foundation
import Darwin

public struct ProcessExecutionResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    /// Normal exit code, or 128 + the terminating signal number.
    public let status: Int32

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

public enum ProcessExecutionError: LocalizedError, Sendable {
    case workingDirectoryUnavailable(path: String, message: String)
    case launch(executable: String, message: String)
    case timeout
    case outputLimit(stream: String, limit: Int)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .workingDirectoryUnavailable(path, message): return "工作目录无法访问：\(path)\n\(message)"
        case let .launch(executable, message): return "未能启动 \(executable)：\(message)。命令尚未执行。"
        case .timeout: return "命令执行超时；已向本次启动的进程发送终止信号。操作可能已部分完成，请刷新后确认。"
        case let .outputLimit(stream, limit): return "\(stream)超过输出上限（\(limit) 字节）；已终止本次启动的进程。"
        case let .io(message): return "进程执行失败：\(message)"
        }
    }
}

/// A synchronous, PID-owned subprocess runner. Call from an actor or detached task, not AppKit's main thread.
/// It installs no process-wide signal handlers and never waits for or signals a different process's PID.
public enum ProcessExecutor {
    public static func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        input: Data? = nil,
        timeout: TimeInterval = 60,
        stdoutLimit: Int = 16 * 1_024 * 1_024,
        stderrLimit: Int = 2 * 1_024 * 1_024
    ) throws -> ProcessExecutionResult {
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              directory.isFileURL, directory.path.hasPrefix("/"),
              !executable.path.contains("\0"), !directory.path.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }),
              timeout.isFinite, timeout > 0, timeout < 86_400,
              stdoutLimit >= 0, stderrLimit >= 0 else {
            throw ProcessExecutionError.io("可执行文件、工作目录、参数、环境或超时限制无效")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw ProcessExecutionError.workingDirectoryUnavailable(path: directory.path, message: "目录不存在、已被移动或当前无权访问。")
        }
        guard isDirectory.boolValue else {
            throw ProcessExecutionError.workingDirectoryUnavailable(path: directory.path, message: "此路径不是文件夹。")
        }

        let (outRead, outWrite) = try makePipe()
        let (errRead, errWrite) = try makePipe()
        var inputRead: OwnedDescriptor
        var inputWrite: OwnedDescriptor?
        if input != nil {
            let descriptors = try makePipe()
            inputRead = descriptors.0
            inputWrite = descriptors.1
        } else {
            inputRead = try openNull()
        }
        let descriptors = [outRead, outWrite, errRead, errWrite, inputRead] + (inputWrite.map { [$0] } ?? [])
        defer { descriptors.forEach { $0.close() } }
        try makeNonblocking(outRead.fd)
        try makeNonblocking(errRead.fd)
        if let inputWrite {
            try makeNonblocking(inputWrite.fd)
            guard fcntl(inputWrite.fd, F_SETNOSIGPIPE, 1) != -1 else { throw currentError("设置标准输入管道") }
        }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), operation: "初始化启动文件操作")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path), operation: "设置工作目录")
        try check(posix_spawn_file_actions_adddup2(&actions, inputRead.fd, STDIN_FILENO), operation: "连接标准输入")
        try check(posix_spawn_file_actions_adddup2(&actions, outWrite.fd, STDOUT_FILENO), operation: "连接标准输出")
        try check(posix_spawn_file_actions_adddup2(&actions, errWrite.fd, STDERR_FILENO), operation: "连接标准错误")
        for descriptor in descriptors {
            try check(posix_spawn_file_actions_addclose(&actions, descriptor.fd), operation: "关闭子进程额外管道")
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), operation: "初始化启动属性")
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), operation: "设置子进程信号掩码")
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGQUIT, SIGHUP] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), operation: "设置子进程默认信号")
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        try check(posix_spawnattr_setflags(&attributes, flags), operation: "设置启动标记")
        var pid: pid_t = 0
        let argv = [executable.path] + arguments
        let envp = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        let spawnResult = try withCStringArray(argv) { argumentPointers in
            try withCStringArray(envp) { environmentPointers in
                posix_spawn(&pid, executable.path, &actions, &attributes, argumentPointers, environmentPointers)
            }
        }
        guard spawnResult == 0 else {
            throw ProcessExecutionError.launch(executable: executable.path,
                message: "\(String(cString: strerror(spawnResult)))（\(spawnResult)）")
        }
        guard pid > 0 else { throw ProcessExecutionError.io("启动未返回有效的进程标识") }
        var ownsChild = true
        defer {
            if ownsChild {
                // Only an exceptional path reaches this fallback. Reap this one PID off-thread.
                _ = Darwin.kill(pid, SIGKILL)
                let ownedPID = pid
                DispatchQueue.global(qos: .utility).async {
                    var raw: Int32 = 0
                    while waitpid(ownedPID, &raw, 0) < 0 && errno == EINTR {}
                }
            }
        }
        outWrite.close()
        errWrite.close()
        inputRead.close()
        if input?.isEmpty == true { inputWrite?.close() }

        var stdout = Data(), stderr = Data()
        var inputOffset = 0
        var inputIncomplete = false
        var exitStatus: Int32?
        var exitTime: UInt64?
        var failure: ProcessExecutionError?
        var terminationTime: TimeInterval?
        var sentKill = false
        let start = monotonicSeconds()
        let deadline = start + timeout
        let pollMilliseconds: Int32 = 25

        func beginTermination(_ reason: ProcessExecutionError) {
            if failure == nil { failure = reason }
            if terminationTime == nil, ownsChild {
                terminationTime = monotonicSeconds()
                _ = Darwin.kill(pid, SIGTERM)
            }
        }

        func drain(_ descriptor: OwnedDescriptor, into bytes: inout Data, limit: Int, label: String) {
            guard descriptor.fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            // Limit each turn so a child writing forever cannot starve timeout or waitpid checks.
            for _ in 0..<8 {
                let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
                if count == 0 { descriptor.close(); return }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    let error = currentError("读取\(label)")
                    descriptor.close()
                    beginTermination(error)
                    return
                }
                if bytes.count <= limit, count <= limit - bytes.count {
                    bytes.append(contentsOf: buffer.prefix(count))
                } else {
                    beginTermination(.outputLimit(stream: label, limit: limit))
                    return
                }
            }
        }

        while true {
            if exitStatus == nil {
                var rawStatus: Int32 = 0
                let waited = waitpid(pid, &rawStatus, WNOHANG)
                if waited == pid {
                    ownsChild = false
                    exitStatus = normalizedStatus(rawStatus)
                    exitTime = DispatchTime.now().uptimeNanoseconds
                    if let input, inputOffset < input.count { inputIncomplete = true }
                    inputWrite?.close()
                } else if waited < 0, errno != EINTR {
                    let code = errno
                    if code == ECHILD { ownsChild = false }
                    beginTermination(.io("等待本次子进程失败：\(String(cString: strerror(code)))（\(code)）"))
                    if code == ECHILD { break }
                }
            }
            let now = monotonicSeconds()
            if exitStatus == nil, now >= deadline { beginTermination(.timeout) }
            if let terminationTime, exitStatus == nil {
                if !sentKill, now >= terminationTime + 2 {
                    _ = Darwin.kill(pid, SIGKILL)
                    sentKill = true
                }
                if now >= terminationTime + 3 { break }
            }
            if let exitTime {
                if outRead.fd < 0, errRead.fd < 0 { break }
                // A descendant may retain inherited stdout even after our own child has exited.
                if DispatchTime.now().uptimeNanoseconds - exitTime >= 1_000_000_000 {
                    if failure == nil { failure = .io("子进程已退出，但输出管道被其他进程继续持有") }
                    break
                }
            }

            var pollDescriptors: [pollfd] = []
            if outRead.fd >= 0 { pollDescriptors.append(pollfd(fd: outRead.fd, events: Int16(POLLIN), revents: 0)) }
            if errRead.fd >= 0 { pollDescriptors.append(pollfd(fd: errRead.fd, events: Int16(POLLIN), revents: 0)) }
            if let inputWrite, inputWrite.fd >= 0 {
                pollDescriptors.append(pollfd(fd: inputWrite.fd, events: Int16(POLLOUT), revents: 0))
            }
            let polled = pollDescriptors.withUnsafeMutableBufferPointer { pointers in
                Darwin.poll(pointers.baseAddress, nfds_t(pointers.count), pollMilliseconds)
            }
            if polled < 0 {
                if errno == EINTR { continue }
                beginTermination(currentError("等待进程管道"))
                continue
            }
            for descriptor in pollDescriptors where descriptor.revents != 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 {
                    beginTermination(.io("进程管道已失效"))
                    continue
                }
                if descriptor.fd == outRead.fd { drain(outRead, into: &stdout, limit: stdoutLimit, label: "标准输出") }
                else if descriptor.fd == errRead.fd { drain(errRead, into: &stderr, limit: stderrLimit, label: "标准错误") }
                else if let inputWrite, descriptor.fd == inputWrite.fd, let input {
                    if descriptor.revents & Int16(POLLHUP | POLLERR) != 0 {
                        inputIncomplete = inputOffset < input.count
                        inputWrite.close()
                        continue
                    }
                    let remaining = min(65_536, input.count - inputOffset)
                    let count = input.withUnsafeBytes { bytes in
                        Darwin.write(inputWrite.fd, bytes.baseAddress!.advanced(by: inputOffset), remaining)
                    }
                    if count > 0 {
                        inputOffset += count
                        if inputOffset == input.count { inputWrite.close() }
                    } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                        if errno == EPIPE {
                            inputIncomplete = inputOffset < input.count
                            inputWrite.close()
                        } else {
                            let error = currentError("写入标准输入")
                            inputWrite.close()
                            beginTermination(error)
                        }
                    }
                }
            }
        }
        if let failure { throw failure }
        guard let exitStatus else { throw ProcessExecutionError.io("子进程未在终止宽限期内退出") }
        if inputIncomplete, exitStatus == 0 {
            throw ProcessExecutionError.io("子进程在接收完标准输入之前已退出")
        }
        return ProcessExecutionResult(stdout: stdout, stderr: stderr, status: exitStatus)
    }

    private static func makePipe() throws -> (OwnedDescriptor, OwnedDescriptor) {
        var values = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&values) == 0 else { throw currentError("创建进程管道") }
        let read = OwnedDescriptor(values[0]), write = OwnedDescriptor(values[1])
        for descriptor in [read, write] {
            if descriptor.fd < 3 {
                let replacement = fcntl(descriptor.fd, F_DUPFD_CLOEXEC, 3)
                guard replacement >= 0 else { throw currentError("复制管道描述符") }
                descriptor.close()
                descriptor.fd = replacement
            }
            guard fcntl(descriptor.fd, F_SETFD, FD_CLOEXEC) == 0 else { throw currentError("设置管道关闭标记") }
        }
        return (read, write)
    }

    private static func openNull() throws -> OwnedDescriptor {
        let descriptor = OwnedDescriptor(Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC))
        guard descriptor.fd >= 0 else { throw currentError("打开空标准输入") }
        if descriptor.fd < 3 {
            let replacement = fcntl(descriptor.fd, F_DUPFD_CLOEXEC, 3)
            guard replacement >= 0 else { throw currentError("复制空标准输入") }
            descriptor.close()
            descriptor.fd = replacement
        }
        return descriptor
    }

    private static func makeNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw currentError("设置非阻塞管道") }
    }

    private static func normalizedStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static func check(_ code: Int32, operation: String) throws {
        guard code == 0 else { throw ProcessExecutionError.io("\(operation)：\(String(cString: strerror(code)))（\(code)）") }
    }

    private static func currentError(_ operation: String) -> ProcessExecutionError {
        let code = errno
        return .io("\(operation)：\(String(cString: strerror(code)))（\(code)）")
    }

    private static func withCStringArray<T>(_ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else { throw currentError("分配启动参数") }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
}

private final class OwnedDescriptor {
    var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func close() {
        if fd >= 0 { _ = Darwin.close(fd); fd = -1 }
    }
    deinit { close() }
}
