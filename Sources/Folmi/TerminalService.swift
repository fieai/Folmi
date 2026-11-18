import AppKit
import FolmiCore
import Foundation

/// Serializes creation and destructive requests, including a close while the helper is still starting.
final class TerminalService: Sendable {
    enum OpenFailure: Error {
        case unavailable(any Error)
        case rejected(any Error)
        case uncertain(any Error)
    }

    struct Opened: Sendable {
        let stream: PTYStream
        let info: PTYProtocol.Session
    }

    let endpoint: PTYEndpoint
    private let helper: URL?
    private let queue = DispatchQueue(label: "Folmi.terminal-service", qos: .userInitiated)

    init(settingsDirectory: URL, helper: URL?) {
        endpoint = PTYEndpoint(settingsDirectory: settingsDirectory)
        self.helper = helper
    }

    static var bundledHelper: URL? {
        guard let app = Bundle.main.executableURL else { return nil }
        let candidate = app.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Library/Helpers/FolmiTerminal.app", isDirectory: true)
        let executable = candidate.appendingPathComponent("Contents/MacOS/folmi-pty")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? candidate : nil
    }

    static let launchApplication: PTYEndpoint.ApplicationLauncher = { helper, arguments, onFailure in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        configuration.arguments = arguments
        configuration.environment = ProcessInfo.processInfo.environment
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
            if error != nil { onFailure() }
        }
    }

    func open(_ request: PTYProtocol.Create, restoring: Bool,
              completion: @escaping @MainActor @Sendable (Result<Opened, OpenFailure>) -> Void) {
        queue.async {
            let result = self.open(request, restoring: restoring)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func open(_ request: PTYProtocol.Create, restoring: Bool) -> Result<Opened, OpenFailure> {
        var peer: PTYPeer
        do {
            peer = PTYPeer(try endpoint.connectOrLaunch(helper: helper, launchApplication: Self.launchApplication))
        } catch {
            return .failure(.unavailable(error))
        }
        do {
            try peer.hello().requireCompatibility()
        } catch let error as PTYProtocol.Failure {
            if case .incompatible = error { return .failure(.rejected(error)) }
            return .failure(restoring ? .uncertain(error) : .unavailable(error))
        } catch {
            return .failure(restoring ? .uncertain(error) : .unavailable(error))
        }
        do {
            if restoring, let existing = try list(&peer).first(where: { $0.id == request.id && $0.projectRoot == request.projectRoot }) {
                return .success(Opened(stream: peer.stream, info: existing))
            }
            try peer.send(.json(.create, request))
            return .success(Opened(stream: peer.stream, info: try peer.receive(.created).decode(PTYProtocol.Session.self)))
        } catch PTYProtocol.Failure.service(let reason) {
            return .failure(.rejected(PTYProtocol.Failure.service(reason)))
        } catch {
            // A create may have succeeded even if its reply was lost. Keep the ID and avoid opening a second shell.
            return .failure(.uncertain(error))
        }
    }

    func sessions() throws -> [PTYProtocol.Session] {
        try sessionStatus().sessions
    }

    func sessionStatus() throws -> (sessions: [PTYProtocol.Session], sharesCoalition: Bool) {
        try queue.sync {
            guard let stream = try endpoint.connect() else { return ([], false) }
            var peer = PTYPeer(stream)
            try peer.hello().requireCompatibility()
            return (try list(&peer), stream.peerSharesResourceCoalition)
        }
    }

    func end(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            guard let stream = try endpoint.connect() else { return }
            var peer = PTYPeer(stream)
            try peer.hello().requireCompatibility()
            for id in ids { try peer.send(.json(.kill, id)) }
            // The reply is a barrier: every kill was accepted before the tabs are removed from the workspace.
            try peer.send(.init(.list))
            var reply = try peer.next()
            while reply.kind == .exited { reply = try peer.next() }
            guard reply.kind == .sessions else { throw PTYProtocol.Failure.malformedFrame }
        }
    }

    func shutdown(confirmingVersion expectedVersion: Int? = nil) throws {
        try queue.sync {
            guard let stream = try endpoint.connect() else { return }
            var peer = PTYPeer(stream)
            let hello = try peer.hello()
            if let expectedVersion {
                guard hello.protocolVersion == expectedVersion else { throw PTYProtocol.Failure.incompatible(hello) }
            } else {
                try hello.requireCompatibility()
            }
            try peer.send(.init(.shutdown))
            // EOF confirms that the helper stopped all its PTYs and released the socket.
            do { _ = try peer.next(timeout: .seconds(4)); throw PTYProtocol.Failure.malformedFrame }
            catch PTYProtocol.Failure.disconnected {}
        }
    }

    private func list(_ peer: inout PTYPeer) throws -> [PTYProtocol.Session] {
        try peer.send(.init(.list))
        return try peer.receive(.sessions).decode([PTYProtocol.Session].self)
    }
}

/// SwiftTerm events and socket callbacks share the main thread. Socket writes never wait for the daemon.
@MainActor
final class TerminalConnection {
    private let stream: PTYStream
    private var decoder = PTYProtocol.Decoder()
    private var outgoing = Data()
    private let reader: DispatchSourceRead
    private var writer: DispatchSourceWrite?
    private var closed = false
    var onFrame: ((PTYProtocol.Frame) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    init(_ stream: PTYStream) {
        self.stream = stream
        reader = DispatchSource.makeReadSource(fileDescriptor: stream.descriptor, queue: .main)
        reader.setEventHandler { [weak self] in self?.receive() }
        reader.setCancelHandler { withExtendedLifetime(stream) {} }
        reader.activate()
    }

    deinit {
        reader.cancel()
        writer?.cancel()
    }

    func send(_ frame: PTYProtocol.Frame) {
        guard !closed else { return }
        do {
            let encoded = try frame.encoded()
            guard outgoing.count + encoded.count <= 4 * PTYProtocol.Frame.maxLength else {
                throw PTYProtocol.Failure.service("终端输入太多，请稍后再试")
            }
            outgoing.append(encoded)
            try flush()
        } catch {
            fail(error)
        }
    }

    func disconnect() {
        closed = true
        reader.cancel()
        writer?.cancel()
        writer = nil
    }

    private func receive() {
        do {
            for _ in 0..<32 where !closed {
                guard let bytes = try stream.readAvailable() else { return }
                guard !bytes.isEmpty else { throw PTYProtocol.Failure.disconnected }
                for frame in try decoder.receive(bytes) where !closed { onFrame?(frame) }
            }
        } catch {
            fail(error)
        }
    }

    private func flush() throws {
        if !outgoing.isEmpty { outgoing.removeFirst(try stream.writeAvailable(outgoing)) }
        if outgoing.isEmpty {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: stream.descriptor, queue: .main)
            writer.setCancelHandler { [stream] in withExtendedLifetime(stream) {} }
            writer.setEventHandler { [weak self] in
                guard let self, !self.closed else { return }
                do { try self.flush() } catch { self.fail(error) }
            }
            self.writer = writer
            writer.activate()
        }
    }

    private func fail(_ error: Error) {
        disconnect()
        onDisconnect?(error)
    }
}
