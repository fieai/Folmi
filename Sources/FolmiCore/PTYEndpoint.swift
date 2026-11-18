import CryptoKit
import Darwin
import Foundation

public struct PTYEndpoint: Sendable {
    public typealias ApplicationLauncher = @Sendable (URL, [String], @escaping @Sendable () -> Void) -> Void

    public let runDirectory: URL
    public var locator: URL { runDirectory.appendingPathComponent("pty.path") }
    private let fallbackName: String

    public init(settingsDirectory: URL) {
        let directory = Self.canonicalDirectory(settingsDirectory.standardizedFileURL)
        runDirectory = directory.appendingPathComponent("run", isDirectory: true)
        fallbackName = "folmi-\(Self.digest(Data(directory.path.utf8))).sock"
    }

    public var socketPath: String {
        if localSocketPath.utf8.count < 104 { return localSocketPath }
        if let saved = try? String(contentsOf: locator, encoding: .utf8),
           saved.hasPrefix("/"), saved.utf8.count < 104, (saved as NSString).lastPathComponent == fallbackName {
            return saved
        }
        return launchSocketPath
    }

    private var localSocketPath: String { runDirectory.appendingPathComponent("pty.sock").path }

    private var launchSocketPath: String {
        if localSocketPath.utf8.count < 104 { return localSocketPath }
        // A locator from a previous boot can point into a temporary directory that no longer exists.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(fallbackName).path
        return temporary.utf8.count < 104 ? temporary : "/tmp/" + fallbackName
    }

    public func prepareRunDirectory() throws {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(runDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PTYStream.systemError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else {
            throw PTYProtocol.Failure.service("后台终端目录不属于当前用户")
        }
        guard fchmod(descriptor, 0o700) == 0 else { throw PTYStream.systemError() }
    }

    public func connect() throws -> PTYStream? { try PTYStream.connect(socketPath) }

    public func connectOrLaunch(helper: URL?, idleMilliseconds: Int? = nil,
                                launchApplication: ApplicationLauncher? = nil) throws -> PTYStream {
        if let existing = try connect() { return existing }
        guard let helper else { throw PTYProtocol.Failure.service("找不到 folmi-pty") }
        let installed = try install(helper)
        try prepareRunDirectory()
        var arguments = ["serve", "--socket", launchSocketPath, "--run-directory", runDirectory.path]
        if let idleMilliseconds { arguments += ["--idle-ms", String(idleMilliseconds)] }
        if let launchApplication, installed.pathExtension == "app" {
            let failed = DispatchSemaphore(value: 0)
            let deadline = DispatchTime.now() + .seconds(3)
            launchApplication(installed, arguments) { failed.signal() }
            // LaunchServices reports failures asynchronously. The socket, not the callback, signals readiness.
            while DispatchTime.now() < deadline {
                if let stream = try connect() { return stream }
                if failed.wait(timeout: min(deadline, .now() + .milliseconds(20))) == .success { break }
            }
            if let stream = try connect() { return stream }
        }
        let pid = try spawn(Self.executable(in: installed), arguments: arguments)
        // The helper outlives the App; reap it if it happens to finish while the App is still open.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if let stream = try connect() { return stream }
            usleep(20_000)
        } while ContinuousClock.now < deadline
        throw PTYProtocol.Failure.timeout
    }

    private static func canonicalDirectory(_ url: URL) -> URL {
        if let physical = realpath(url.path, nil) {
            defer { free(physical) }
            return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        }
        // The settings folder need not exist on the first launch, but its socket hash must stay the same after it is made.
        guard url.path != "/" else { return url }
        return canonicalDirectory(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func executable(in helper: URL) -> URL {
        helper.pathExtension == "app" ? helper.appendingPathComponent("Contents/MacOS/folmi-pty") : helper
    }

    func install(_ source: URL) throws -> URL {
        let isApp = source.pathExtension == "app"
        var data = try Data(contentsOf: Self.executable(in: source), options: .mappedIfSafe)
        if isApp { data.append(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))) }
        let digest = Self.digest(data)
        let bin = runDirectory.deletingLastPathComponent().appendingPathComponent("bin", isDirectory: true)
        let destination = bin.appendingPathComponent(isApp ? "FolmiTerminal-\(digest).app" : "folmi-pty-\(digest)")
        let manager = FileManager.default
        let executable = Self.executable(in: destination)
        if manager.isExecutableFile(atPath: executable.path) { return destination }
        try manager.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = bin.appendingPathComponent(".folmi-pty-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        if isApp {
            // ditto --noqtn can still copy the raw quarantine attribute on some macOS versions.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-drs", "com.apple.quarantine", staging.path]
            try xattr.run()
            xattr.waitUntilExit()
            guard xattr.terminationStatus == 0 else { throw PTYProtocol.Failure.service("无法安装后台终端") }
        }
        if rename(staging.path, destination.path) != 0 {
            let error = PTYStream.systemError()
            // Another instance may have installed the same bundle during the copy.
            guard manager.isExecutableFile(atPath: executable.path) else { throw error }
        }
        return destination
    }

    private func spawn(_ executable: URL, arguments: [String]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attrs: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attrs))
        defer { posix_spawnattr_destroy(&attrs) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
        try Self.check(posix_spawnattr_setflags(&attrs, Int16(bitPattern: UInt16(flags))))
        for (fd, mode) in [(STDIN_FILENO, O_RDONLY), (STDOUT_FILENO, O_WRONLY), (STDERR_FILENO, O_WRONLY)] {
            try Self.check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", mode, 0))
        }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw PTYStream.systemError(ENOMEM)
        }
        var pid: pid_t = 0
        try Self.check(posix_spawn(&pid, executable.path, &actions, &attrs, &argv, &envp))
        return pid
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw PTYStream.systemError(code) }
    }
}

/// A descriptor is never closed while a read or write source still retains its stream.
public final class PTYStream: Sendable {
    public let descriptor: Int32
    public init(owning descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    public var peerPID: pid_t? {
        var pid: pid_t = 0
        let size = socklen_t(MemoryLayout<pid_t>.size)
        var length = size
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, length == size, pid > 0 else { return nil }
        return pid
    }

    public var peerSharesResourceCoalition: Bool {
        guard let peerPID, let ownCoalition = PTYProcess.resourceCoalition(of: getpid()) else { return false }
        return PTYProcess.resourceCoalition(of: peerPID) == ownCoalition
    }

    public static func systemError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    public static func configure(_ fd: Int32, socket: Bool = false) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1, fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw systemError() }
        if socket {
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw systemError() }
        }
    }

    public static func isSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    public static func withAddress<T>(_ path: String, _ call: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw systemError(ENAMETOOLONG) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count)
        bytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: source) }
        }
        let length = socklen_t(address.sun_len)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try call($0, length) }
        }
    }

    fileprivate static func connect(_ path: String) throws -> PTYStream? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError() }
        let stream = PTYStream(owning: fd)
        try configure(fd, socket: true)
        let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        if result != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { return nil }
            throw systemError()
        }
        guard isSameUser(fd) else { throw systemError(EACCES) }
        return stream
    }

    /// nil means the nonblocking descriptor has no bytes ready; empty data means EOF.
    public func readAvailable() throws -> Data? {
        var bytes = Data(count: 32 * 1_024)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return nil }
            throw Self.systemError()
        }
        bytes.count = count
        return bytes
    }

    public func writeAvailable(_ data: Data) throws -> Int {
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return 0 }
            throw Self.systemError()
        }
        return count
    }

    fileprivate func wait(for events: Int16, until deadline: ContinuousClock.Instant) throws {
        var request = pollfd(fd: descriptor, events: events, revents: 0)
        while ContinuousClock.now < deadline {
            let remaining = (deadline - ContinuousClock.now).components
            let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
            let result = poll(&request, 1, Int32(max(1, milliseconds)))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw Self.systemError() }
        }
        throw PTYProtocol.Failure.timeout
    }
}

/// Request/reply operations run with a deadline. Streaming clients can take over the same descriptor after hello.
public struct PTYPeer {
    public let stream: PTYStream
    private var decoder = PTYProtocol.Decoder()
    private var pending: [PTYProtocol.Frame] = []

    public init(_ stream: PTYStream) { self.stream = stream }

    public mutating func hello(version: Int = PTYProtocol.version) throws -> PTYProtocol.Hello {
        try send(.json(.hello, PTYProtocol.Hello(protocolVersion: version)))
        return try receive(.hello).decode(PTYProtocol.Hello.self)
    }

    public func send(_ frame: PTYProtocol.Frame, timeout: Duration = .milliseconds(500)) throws {
        var data = try frame.encoded()
        let deadline = ContinuousClock.now + timeout
        while !data.isEmpty {
            try stream.wait(for: Int16(POLLOUT), until: deadline)
            data.removeFirst(try stream.writeAvailable(data))
        }
    }

    public mutating func next(timeout: Duration = .milliseconds(500)) throws -> PTYProtocol.Frame {
        let deadline = ContinuousClock.now + timeout
        while pending.isEmpty {
            try stream.wait(for: Int16(POLLIN), until: deadline)
            guard let bytes = try stream.readAvailable() else { continue }
            guard !bytes.isEmpty else { throw PTYProtocol.Failure.disconnected }
            pending = try decoder.receive(bytes)
        }
        let frame = pending.removeFirst()
        if frame.kind == .failure { throw PTYProtocol.Failure.service(try frame.decode(String.self)) }
        return frame
    }

    public mutating func receive(_ kind: PTYProtocol.Kind, timeout: Duration = .milliseconds(500)) throws -> PTYProtocol.Frame {
        let frame = try next(timeout: timeout)
        guard frame.kind == kind else { throw PTYProtocol.Failure.malformedFrame }
        return frame
    }
}
