import Foundation
import XCTest
@testable import FolmiCore

final class PTYProtocolTests: XCTestCase {
    func testPartialAndCoalescedFramesPreserveBinaryData() throws {
        let id = UUID()
        let input = PTYProtocol.Frame.bytes(.input, id: id, data: Data([0, 255, 27]))
        let hello = try PTYProtocol.Frame.json(.hello, PTYProtocol.Hello())
        let stream = try input.encoded() + hello.encoded()
        XCTAssertEqual(Array(stream.prefix(5)), [0, 0, 0, 20, PTYProtocol.Kind.input.rawValue])

        var decoder = PTYProtocol.Decoder()
        XCTAssertEqual(try decoder.receive(Data(stream.prefix(3))), [])
        XCTAssertEqual(try decoder.receive(Data(stream[3..<16])), [])
        let frames = try decoder.receive(Data(stream.dropFirst(16)))
        XCTAssertEqual(frames, [input, hello])
        XCTAssertEqual(try frames[0].bytes().id, id)
        XCTAssertEqual(try frames[0].bytes().data, Data([0, 255, 27]))
    }

    func testInvalidLengthsAreRejectedBeforeReadingPayload() throws {
        var decoder = PTYProtocol.Decoder()
        XCTAssertThrowsError(try decoder.receive(Data([0x7f, 0xff, 0xff, 0xff]))) {
            XCTAssertEqual($0 as? PTYProtocol.Failure, .frameTooLarge)
        }
        decoder = PTYProtocol.Decoder()
        XCTAssertThrowsError(try decoder.receive(Data([0, 0, 0, 0]))) {
            XCTAssertEqual($0 as? PTYProtocol.Failure, .malformedFrame)
        }
        XCTAssertThrowsError(try PTYProtocol.Frame(.input, payload: Data(count: PTYProtocol.Frame.maxLength)).encoded())
        XCTAssertThrowsError(try PTYProtocol.Frame(.output, payload: Data([0])).bytes())
    }

    func testHandshakeRejectsDifferentMajorAndRetainsRunningCount() throws {
        let other = PTYProtocol.Hello(protocolVersion: 7, runningCount: 3)
        let decoded = try PTYProtocol.Frame.json(.hello, other).decode(PTYProtocol.Hello.self)
        XCTAssertThrowsError(try decoded.requireCompatibility()) {
            XCTAssertEqual($0 as? PTYProtocol.Failure, .incompatible(other))
        }
        XCTAssertNoThrow(try PTYProtocol.Hello().requireCompatibility())
    }

    func testRingRetainsExactlyTheLatestBytesAcrossWrapAndLargeWrites() {
        var ring = PTYRingBuffer(capacity: 5)
        ring.append(Data([0, 1, 2]))
        XCTAssertEqual(ring.data, Data([0, 1, 2]))
        ring.append(Data([3, 4, 5]))
        XCTAssertEqual(ring.data, Data([1, 2, 3, 4, 5]))
        ring.append(Data([6, 7]))
        XCTAssertEqual(ring.data, Data([3, 4, 5, 6, 7]))
        ring.append(Data(8...19))
        XCTAssertEqual(ring.data, Data(15...19))
    }
}
