import XCTest
@testable import FolmiCore

final class ACPClientTests: XCTestCase {
    func testTranscriptGrowsChunksAndTracksTools() {
        var transcript = ACPTranscript()
        transcript.apply(JSON(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "先看"]]))
        transcript.apply(JSON(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "一下"]]))
        transcript.apply(JSON(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Edit a.swift", "kind": "edit", "status": "pending",
                               "locations": [["path": "/r/a.swift"]]]))
        transcript.apply(JSON(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed",
                               "content": [["type": "diff", "path": "/r/b.swift", "oldText": "a", "newText": "b"]]]))
        transcript.apply(JSON(["sessionUpdate": "plan", "entries": [["content": "改 a", "status": "completed"], ["content": "跑测试", "status": "in_progress"]]]))
        transcript.apply(JSON(["sessionUpdate": "plan", "entries": [["content": "改 a", "status": "completed"], ["content": "跑测试", "status": "completed"]]]))
        transcript.apply(JSON(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "好了"]]))
        transcript.apply(JSON(["sessionUpdate": "available_commands_update", "availableCommands": []]))
        XCTAssertEqual(transcript.entries.map(\.kind), [.agent, .tool, .plan, .agent])
        XCTAssertEqual(transcript.entries[0].text, "先看一下")
        XCTAssertEqual(transcript.entries[1].status, "completed")
        XCTAssertEqual(transcript.entries[1].paths, ["/r/a.swift", "/r/b.swift"])
        XCTAssertEqual(transcript.entries[2].text, "✓ 改 a\n✓ 跑测试", "a newer plan replaces the one right before it")
    }

    func testJSONRoundTripKeepsBoolsAndNumbers() {
        let value = JSON.parse(Data(#"{"a":true,"b":1,"c":1.5,"d":[null,"x"]}"#.utf8))
        XCTAssertEqual(value?["a"], .bool(true))
        XCTAssertEqual(value?["b"]?.int, 1)
        XCTAssertEqual(value?["c"], .number(1.5))
        XCTAssertEqual(JSON.parse(value!.data()), value)
    }

    /// A fake agent on the other end of two pipes: answers requests, streams an update, asks for permission.
    func testRequestsNotificationsAndAgentRequests() async throws {
        let toAgent = Pipe(), fromAgent = Pipe()
        let updates = Locked<[String]>([])
        let connection = ACPConnection(reading: fromAgent.fileHandleForReading, writing: toAgent.fileHandleForWriting,
                                       requests: { method, params in
                                           XCTAssertEqual(method, "session/request_permission")
                                           return .success(JSON(["outcome": ["outcome": "selected", "optionId": params["options"]?.array?.first?["optionId"]?.string ?? ""]]))
                                       },
                                       notifications: { method, params in
                                           if method == "session/update" { updates.mutate { $0.append(params["update"]?["sessionUpdate"]?.string ?? "") } }
                                       })
        connection.start()
        let agent = Thread {
            let reader = toAgent.fileHandleForReading, writer = fromAgent.fileHandleForWriting
            var buffer = Data()
            var promptID: Any?
            func write(_ object: [String: Any]) {
                var data = try! JSONSerialization.data(withJSONObject: object); data.append(10); writer.write(data)
            }
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<newline]; buffer.removeSubrange(buffer.startIndex...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    let id = message["id"]
                    switch message["method"] as? String {
                    case "initialize": write(["jsonrpc": "2.0", "id": id!, "result": ["protocolVersion": 1]])
                    case "session/prompt":
                        write(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "s", "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hi"]]]])
                        write(["jsonrpc": "2.0", "id": 900, "method": "session/request_permission",
                               "params": ["sessionId": "s", "toolCall": ["toolCallId": "t"], "options": [["optionId": "yes", "name": "允许", "kind": "allow_once"]]]])
                        // Holds the prompt's answer until the permission reply arrives.
                        promptID = id
                    case nil:
                        if message["id"] as? Int == 900, ((message["result"] as? [String: Any])?["outcome"] as? [String: Any])?["optionId"] as? String == "yes",
                           let promptID {
                            write(["jsonrpc": "2.0", "id": promptID, "result": ["stopReason": "end_turn"]])
                        }
                    default: write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "nope"]])
                    }
                }
            }
            try? writer.close()
        }
        agent.start()

        let hello = try await connection.request("initialize", JSON(["protocolVersion": 1]))
        XCTAssertEqual(hello["protocolVersion"]?.int, 1)
        let done = try await connection.request("session/prompt", JSON(["sessionId": "s", "prompt": []]))
        XCTAssertEqual(done["stopReason"]?.string, "end_turn")
        XCTAssertEqual(updates.value, ["agent_message_chunk"])
        do { _ = try await connection.request("unknown", .null); XCTFail("errors are thrown") }
        catch let error as ACPError { XCTAssertEqual(error.code, -32601) }

        // The agent going away fails what is still waiting instead of hanging.
        try toAgent.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while connection.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(connection.isRunning)
        do { _ = try await connection.request("session/prompt", .null); XCTFail("closed") } catch {}
    }
}

final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
