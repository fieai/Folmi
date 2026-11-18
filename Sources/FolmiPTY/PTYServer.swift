import Darwin
import FolmiCore
import FolmiPTYSpawn
import Foundation

private typealias Wire = PTYProtocol
private typealias Frame = PTYProtocol.Frame

/// One poll loop owns PTYs and sockets, so replay and the following live output cannot overtake each other.
final class PTYServer {
    private final class Client {
        let stream: PTYStream
        var decoder = Wire.Decoder()
        var outgoing = Data()
        var compatible: Bool?
        var closed = false
        var fd: Int32 { stream.descriptor }

        init(_ fd: Int32) { stream = PTYStream(owning: fd) }

        func enqueue(_ frame: Frame) {
            guard !closed, let encoded = try? frame.encoded() else { return }
            // A client that stops reading must not block the shell or the other attached clients.
            guard outgoing.count + encoded.count <= 4 * Wire.Frame.maxLength else { closed = true; return }
            outgoing.append(encoded)
        }
    }

    private final class Session {
        let id: UUID
        let projectRoot: String
        let pid: pid_t
        let createdAt = Date()
        var master: PTYStream?
        var output = PTYRingBuffer()
        var input = Data()
        weak var attached: Client?
        weak var killRequester: Client?
        var exitCode: Int32?
        var removeAfterExit = false
        var killAt: ContinuousClock.Instant?
        var groupsAtClose: Set<pid_t> = []
        var restoreSize: (when: ContinuousClock.Instant, size: winsize)?
        var size: winsize

        init(_ request: Wire.Create) throws {
            guard let executable = request.argv.first, executable.hasPrefix("/"),
                  request.projectRoot.hasPrefix("/"), request.cwd.hasPrefix("/"),
                  ([request.projectRoot, request.cwd] + request.argv).allSatisfy({ !$0.contains("\0") }),
                  request.env.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }),
                  request.cols > 0, request.rows > 0 else { throw Wire.Failure.service("终端启动参数不正确") }
            id = request.id
            projectRoot = request.projectRoot
            var dimensions = winsize(ws_row: request.rows, ws_col: request.cols, ws_xpixel: 0, ws_ypixel: 0)
            size = dimensions
            var argv = request.argv.map { strdup($0) } + [nil]
            var envp = request.env.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
                throw PTYStream.systemError(ENOMEM)
            }
            var fd: Int32 = -1
            let child = folmi_fork_pty(&fd, request.cwd, &argv, &envp, &dimensions)
            guard child > 0 else { throw PTYStream.systemError() }
            let stream = PTYStream(owning: fd)
            do { try PTYStream.configure(fd) }
            catch {
                Darwin.kill(child, SIGKILL)
                while waitpid(child, nil, 0) == -1 && errno == EINTR {}
                throw error
            }
            pid = child
            master = stream
        }

        var foreground: pid_t? {
            guard let fd = master?.descriptor else { return nil }
            let group = tcgetpgrp(fd)
            return group > 0 && group != pid ? group : nil
        }

        var info: Wire.Session {
            let group = foreground
            return Wire.Session(id: id, projectRoot: projectRoot, shellPid: pid, foregroundPid: group,
                                foregroundName: group.flatMap(PTYProcess.name),
                                backgroundJobName: group == nil && exitCode == nil ? PTYProcess.backgroundJob(in: pid) : nil,
                                exitCode: exitCode, createdAt: createdAt)
        }

        func resize(_ dimensions: winsize) {
            guard let fd = master?.descriptor else { return }
            var dimensions = dimensions
            // TIOCSWINSZ signals the foreground group when the size changes.
            _ = ioctl(fd, TIOCSWINSZ, &dimensions)
        }

        func redraw() {
            guard size.ws_row > 1 else { return }
            var smaller = size
            smaller.ws_row -= 1
            resize(smaller)
            // Give the foreground process a chance to observe each size before restoring it.
            restoreSize = (ContinuousClock.now + .milliseconds(40), size)
        }

        func beginClose() {
            removeAfterExit = true
            guard exitCode == nil, killAt == nil else { return }
            groupsAtClose = processGroups()
            if let foreground { groupsAtClose.insert(foreground) }
            for group in groupsAtClose { Darwin.kill(-group, SIGHUP) }
            if !groupsAtClose.contains(pid) { Darwin.kill(pid, SIGHUP) }
            input.removeAll()
            killAt = ContinuousClock.now + .seconds(2)
        }

        func tick(now: ContinuousClock.Instant) {
            if let restoreSize, now >= restoreSize.when {
                self.restoreSize = nil
                resize(restoreSize.size)
            }
            if let killAt {
                if now >= killAt {
                    let groups = processGroups()
                    for group in groups { Darwin.kill(-group, SIGKILL) }
                    if exitCode == nil && !groups.contains(pid) { Darwin.kill(pid, SIGKILL) }
                    master = nil
                    self.killAt = nil
                } else if exitCode != nil && !groupsAtClose.contains(where: { Darwin.kill(-$0, 0) == 0 }) && processGroups().isEmpty {
                    master = nil
                    self.killAt = nil
                }
            }
        }

        private func processGroups() -> Set<pid_t> {
            // Foreground and background jobs have distinct process groups but belong to the PTY's session.
            // Enumerate afresh before SIGKILL so a process group that has already gone away is never signaled.
            let estimate = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
            guard estimate > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.stride + 64)
            let bytes = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
            let groups = pids.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.stride))
                .compactMap { child -> pid_t? in
                    guard child > 0, getsid(child) == pid else { return nil }
                    let group = getpgid(child)
                    return group > 0 ? group : nil
                }
            return Set(groups)
        }
    }

    private let listener: PTYStream
    private let socketPath: String
    private let locator: URL?
    private let idleTime: Duration
    private var clients: [Int32: Client] = [:]
    private var sessions: [UUID: Session] = [:]
    private var emptySince = ContinuousClock.now
    private var shutdownDeadline: ContinuousClock.Instant?
    private var shuttingDown: Bool { shutdownDeadline != nil }

    init(socketPath: String, runDirectory: URL, idleMilliseconds: Int) throws {
        self.socketPath = socketPath
        idleTime = .milliseconds(idleMilliseconds)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PTYStream.systemError() }
        listener = PTYStream(owning: fd)
        try PTYStream.configure(fd, socket: true)
        // The settings lock is held for the entire process lifetime, including removing a stale socket.
        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid() else {
                throw Wire.Failure.service("后台终端接入路径已被占用")
            }
            guard unlink(socketPath) == 0 else { throw PTYStream.systemError() }
        }
        guard try PTYStream.withAddress(socketPath, { bind(fd, $0, $1) }) == 0 else { throw PTYStream.systemError() }
        do {
            guard chmod(socketPath, 0o600) == 0 else { throw PTYStream.systemError() }
            if socketPath != runDirectory.appendingPathComponent("pty.sock").path {
                let path = runDirectory.appendingPathComponent("pty.path")
                try socketPath.write(to: path, atomically: true, encoding: .utf8)
                locator = path
            } else {
                locator = nil
            }
            guard listen(fd, 32) == 0 else { throw PTYStream.systemError() }
        } catch {
            unlink(socketPath)
            throw error
        }
    }

    deinit {
        unlink(socketPath)
        if let locator { try? FileManager.default.removeItem(at: locator) }
    }

    func run() throws {
        while true {
            let now = ContinuousClock.now
            if folmi_pty_shutdown_requested() != 0 { beginShutdown() }
            if sessions.isEmpty && clients.isEmpty {
                if now >= emptySince + idleTime { return }
            } else {
                emptySince = now
            }
            if let shutdownDeadline, sessions.isEmpty,
               now >= shutdownDeadline || clients.values.allSatisfy({ $0.outgoing.isEmpty }) { return }

            let peers = Array(clients.values)
            let terminals = sessions.values.filter { $0.master != nil }
            let masters = terminals.compactMap(\.master)
            var descriptors = [pollfd(fd: listener.descriptor, events: shuttingDown ? 0 : Int16(POLLIN), revents: 0)]
            descriptors += peers.map { pollfd(fd: $0.fd, events: Int16(POLLIN | ($0.outgoing.isEmpty ? 0 : POLLOUT)), revents: 0) }
            descriptors += zip(terminals, masters).map {
                pollfd(fd: $1.descriptor, events: Int16(POLLIN | ($0.input.isEmpty ? 0 : POLLOUT)), revents: 0)
            }
            if poll(&descriptors, nfds_t(descriptors.count), pollTimeout(now: now)) < 0 {
                if errno == EINTR { continue }
                throw PTYStream.systemError()
            }
            if !shuttingDown && descriptors[0].revents & Int16(POLLIN) != 0 { acceptClient() }
            for (peer, descriptor) in zip(peers, descriptors.dropFirst()) {
                if descriptor.revents != 0 { process(peer, events: descriptor.revents) }
            }
            for ((terminal, master), descriptor) in zip(zip(terminals, masters), descriptors.dropFirst(1 + peers.count)) {
                if descriptor.revents != 0 { process(terminal, master: master, events: descriptor.revents) }
            }
            reapChildren()
            for session in sessions.values { session.tick(now: .now) }
            sessions = sessions.filter { !$0.value.removeAfterExit || $0.value.exitCode == nil || $0.value.killAt != nil }
            clients = clients.filter { !$0.value.closed }
        }
    }

    private func pollTimeout(now: ContinuousClock.Instant) -> Int32 {
        var deadline = now + .milliseconds(250)
        if sessions.isEmpty && clients.isEmpty { deadline = min(deadline, emptySince + idleTime) }
        for session in sessions.values {
            if let size = session.restoreSize { deadline = min(deadline, size.when) }
            if let killAt = session.killAt { deadline = min(deadline, killAt) }
        }
        let remaining = (deadline - now).components
        let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
        return Int32(max(1, milliseconds))
    }

    private func beginShutdown() {
        guard shutdownDeadline == nil else { return }
        shutdownDeadline = .now + .seconds(3)
        for session in sessions.values { session.beginClose() }
    }

    private func acceptClient() {
        let fd = accept(listener.descriptor, nil, nil)
        guard fd >= 0 else { return }
        guard clients.count < 80, PTYStream.isSameUser(fd), (try? PTYStream.configure(fd, socket: true)) != nil else {
            close(fd)
            return
        }
        clients[fd] = Client(fd)
    }

    private func process(_ client: Client, events: Int16) {
        guard !client.closed else { return }
        do {
            if events & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0,
               let bytes = try client.stream.readAvailable() {
                guard !bytes.isEmpty else { client.closed = true; return }
                for frame in try client.decoder.receive(bytes) { try handle(frame, from: client) }
            }
            if !client.outgoing.isEmpty {
                client.outgoing.removeFirst(try client.stream.writeAvailable(client.outgoing))
            }
        } catch {
            client.closed = true
        }
    }

    private func handle(_ frame: Frame, from client: Client) throws {
        if client.compatible == nil {
            guard frame.kind == .hello else { throw Wire.Failure.malformedFrame }
            let hello = try frame.decode(Wire.Hello.self)
            client.compatible = hello.protocolVersion == Wire.version
            client.enqueue(try .json(.hello, Wire.Hello(runningCount: sessions.values.count { $0.exitCode == nil })))
            return
        }
        // Hello and shutdown stay stable across major versions so the App can offer a deliberate restart.
        if frame.kind == .shutdown {
            beginShutdown()
            return
        }
        guard client.compatible == true, !shuttingDown else { return }

        switch frame.kind {
        case .list:
            let list = sessions.values.filter { !$0.removeAfterExit }.map(\.info).sorted { $0.createdAt < $1.createdAt }
            client.enqueue(try .json(.sessions, list))
        case .create:
            let request = try frame.decode(Wire.Create.self)
            do {
                if let existing = sessions[request.id] {
                    guard existing.projectRoot == request.projectRoot, !existing.removeAfterExit else {
                        throw Wire.Failure.service("终端编号已被使用")
                    }
                } else {
                    guard sessions.count < Wire.sessionLimit else { throw Wire.Failure.service("后台终端已满，请先关掉一些终端") }
                    sessions[request.id] = try Session(request)
                }
                client.enqueue(try .json(.created, sessions[request.id]!.info))
            } catch {
                client.enqueue(try .json(.failure, error.localizedDescription))
            }
        case .attach:
            let id = try frame.decode(UUID.self)
            guard let session = sessions[id], !session.removeAfterExit else {
                client.enqueue(try .json(.failure, "这个后台终端已关闭"))
                return
            }
            if let old = session.attached, old !== client { old.enqueue(try .json(.displaced, id)) }
            session.attached = client
            client.enqueue(.bytes(.replay, id: id, data: session.output.data))
            if let code = session.exitCode {
                client.enqueue(try .json(.exited, Wire.Exit(id: id, exitCode: code)))
            } else {
                session.redraw()
            }
        case .detach:
            let id = try frame.decode(UUID.self)
            if sessions[id]?.attached === client { sessions[id]?.attached = nil }
        case .input:
            let (id, data) = try frame.bytes()
            if let session = sessions[id], session.attached === client, !session.removeAfterExit, session.master != nil {
                guard session.input.count + data.count <= 4 * Wire.Frame.maxLength else {
                    client.enqueue(try .json(.failure, "终端输入太多，请稍后再试"))
                    return
                }
                session.input.append(data)
            }
        case .resize:
            let resize = try frame.decode(Wire.Resize.self)
            if let session = sessions[resize.id], session.attached === client, resize.cols > 0, resize.rows > 0 {
                session.size.ws_col = resize.cols
                session.size.ws_row = resize.rows
                if let pending = session.restoreSize {
                    session.restoreSize = (pending.when, session.size)
                } else {
                    session.resize(session.size)
                }
            }
        case .kill:
            let id = try frame.decode(UUID.self)
            if let session = sessions[id] {
                if let code = session.exitCode {
                    client.enqueue(try .json(.exited, Wire.Exit(id: id, exitCode: code)))
                } else {
                    session.killRequester = client
                }
                session.beginClose()
            }
        default:
            throw Wire.Failure.malformedFrame
        }
    }

    private func process(_ session: Session, master: PTYStream, events: Int16) {
        if events & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 { drain(session, master: master) }
        if events & Int16(POLLOUT) != 0, !session.input.isEmpty {
            do { session.input.removeFirst(try master.writeAvailable(session.input)) }
            catch { session.input.removeAll() }
        }
    }

    private func drain(_ session: Session, master: PTYStream) {
        // Bound each pass so a fast producer cannot starve the sockets or other PTYs.
        do {
            for _ in 0..<16 {
                guard let bytes = try master.readAvailable() else { return }
                guard !bytes.isEmpty else { session.master = nil; return }
                session.output.append(bytes)
                session.attached?.enqueue(.bytes(.output, id: session.id, data: bytes))
            }
        } catch {
            session.master = nil
        }
    }

    private func reapChildren() {
        var status: Int32 = 0
        while true {
            let pid = waitpid(-1, &status, WNOHANG)
            guard pid > 0 else { return }
            guard let session = sessions.values.first(where: { $0.pid == pid && $0.exitCode == nil }) else { continue }
            if let master = session.master {
                drain(session, master: master)
                if session.killAt == nil { session.master = nil }
            }
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            session.exitCode = code
            if let frame = try? Frame.json(.exited, Wire.Exit(id: session.id, exitCode: code)) {
                session.attached?.enqueue(frame)
                if session.killRequester !== session.attached { session.killRequester?.enqueue(frame) }
            }
        }
    }
}
