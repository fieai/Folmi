import Foundation

public enum PTYProtocol {
    public static let version = 1
    public static let replayLimit = 1_024 * 1_024
    public static let sessionLimit = 32

    public enum Kind: UInt8, Sendable {
        case hello = 1, list, create, attach, detach, input, resize, kill, shutdown
        case sessions, replay, output, exited, created, failure, displaced
    }

    public enum Failure: LocalizedError, Equatable {
        case malformedFrame
        case frameTooLarge
        case incompatible(Hello)
        case service(String)
        case disconnected
        case timeout

        public var errorDescription: String? {
            switch self {
            case .malformedFrame: "后台终端消息格式不正确"
            case .frameTooLarge: "后台终端消息太长"
            case .incompatible: "后台终端服务版本不兼容"
            case .service(let reason): reason
            case .disconnected: "后台终端连接已断开"
            case .timeout: "后台终端服务响应超时"
            }
        }
    }

    public struct Hello: Codable, Equatable, Sendable {
        public var protocolVersion: Int
        public var runningCount: Int

        public init(protocolVersion: Int = PTYProtocol.version, runningCount: Int = 0) {
            self.protocolVersion = protocolVersion
            self.runningCount = runningCount
        }

        public func requireCompatibility() throws {
            guard protocolVersion == PTYProtocol.version else { throw Failure.incompatible(self) }
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        public let id: UUID
        public let projectRoot: String
        public let shellPid: Int32
        public let foregroundPid: Int32?
        public let foregroundName: String?
        public let backgroundJobName: String?
        public let exitCode: Int32?
        public let createdAt: Date
        public var hasExited: Bool { exitCode != nil }
        public var runningProgram: String? {
            if hasExited { return nil }
            if foregroundPid != nil { return foregroundName ?? "程序" }
            return backgroundJobName
        }

        public init(id: UUID, projectRoot: String, shellPid: Int32, foregroundPid: Int32?,
                    foregroundName: String?, backgroundJobName: String? = nil, exitCode: Int32?, createdAt: Date) {
            self.id = id
            self.projectRoot = projectRoot
            self.shellPid = shellPid
            self.foregroundPid = foregroundPid
            self.foregroundName = foregroundName
            self.backgroundJobName = backgroundJobName
            self.exitCode = exitCode
            self.createdAt = createdAt
        }
    }

    public struct Create: Codable, Sendable {
        public let id: UUID
        public let projectRoot: String
        public let cwd: String
        public let env: [String: String]
        public let argv: [String]
        public let cols: UInt16
        public let rows: UInt16

        public init(id: UUID, projectRoot: String, cwd: String, env: [String: String], argv: [String], cols: UInt16, rows: UInt16) {
            self.id = id
            self.projectRoot = projectRoot
            self.cwd = cwd
            self.env = env
            self.argv = argv
            self.cols = cols
            self.rows = rows
        }
    }

    public struct Resize: Codable, Sendable {
        public let id: UUID
        public let cols: UInt16
        public let rows: UInt16

        public init(id: UUID, cols: UInt16, rows: UInt16) {
            self.id = id
            self.cols = cols
            self.rows = rows
        }
    }

    public struct Exit: Codable, Sendable {
        public let id: UUID
        public let exitCode: Int32

        public init(id: UUID, exitCode: Int32) {
            self.id = id
            self.exitCode = exitCode
        }
    }

    public struct Frame: Equatable, Sendable {
        public let kind: Kind
        public let payload: Data
        public static let maxLength = replayLimit + 1_024

        public init(_ kind: Kind, payload: Data = Data()) {
            self.kind = kind
            self.payload = payload
        }

        public static func json(_ kind: Kind, _ value: some Encodable) throws -> Frame {
            try Frame(kind, payload: JSONEncoder().encode(value))
        }

        public func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: payload)
        }

        public static func bytes(_ kind: Kind, id: UUID, data: Data) -> Frame {
            var raw = id.uuid
            var payload = withUnsafeBytes(of: &raw) { Data($0) }
            payload.append(data)
            return Frame(kind, payload: payload)
        }

        public func bytes() throws -> (id: UUID, data: Data) {
            guard payload.count >= 16 else { throw Failure.malformedFrame }
            let id = payload.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            return (id, Data(payload.dropFirst(16)))
        }

        public func encoded() throws -> Data {
            let length = payload.count + 1
            guard length <= Self.maxLength else { throw Failure.frameTooLarge }
            var header = UInt32(length).bigEndian
            var data = withUnsafeBytes(of: &header) { Data($0) }
            data.append(kind.rawValue)
            data.append(payload)
            return data
        }
    }

    public struct Decoder {
        private var buffer = Data()
        public init() {}

        public mutating func receive(_ bytes: Data) throws -> [Frame] {
            buffer.append(bytes)
            var frames: [Frame] = []
            var start = buffer.startIndex
            while buffer.endIndex - start >= 4 {
                let length = buffer.withUnsafeBytes {
                    Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: start - buffer.startIndex, as: UInt32.self)))
                }
                guard length > 0 else { throw Failure.malformedFrame }
                guard length <= Frame.maxLength else { throw Failure.frameTooLarge }
                let end = start + 4 + length
                guard end <= buffer.endIndex else { break }
                guard let kind = Kind(rawValue: buffer[start + 4]) else { throw Failure.malformedFrame }
                frames.append(Frame(kind, payload: buffer.subdata(in: (start + 5)..<end)))
                start = end
            }
            if start != buffer.startIndex { buffer.removeSubrange(..<start) }
            return frames
        }
    }
}
