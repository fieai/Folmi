import XCTest
@testable import FolmiCore

final class CodexRolloutTests: XCTestCase {
    private let id = "01a18192-e94a-79e0-8779-868b00abde87"

    func testTranscriptKeepsWhatWasSaidRunAndChanged() {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/repo"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"AGENTS.md instructions"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(id)","item":{"type":"UserMessage","content":[{"type":"text","text":"修一下登录"}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(id)","item":{"type":"Reasoning","summary_text":[]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(id)","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","swift build"]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(id)","item":{"type":"FileChange","changes":{"/repo/Sources/Login.swift":{"type":"update"}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"other-sub-agent","item":{"type":"AgentMessage","content":[{"type":"Text","text":"子代理的话"}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(id)","item":{"type":"AgentMessage","content":[{"type":"Text","text":"改好了"}]}}}"#,
            "not json",
        ]
        let transcript = CodexRollout.transcript(Data(lines.joined(separator: "\n").utf8), id: id, root: "/repo")
        XCTAssertEqual(transcript.entries.map(\.kind), [.user, .tool, .tool, .agent])
        XCTAssertEqual(transcript.entries.map(\.text), ["修一下登录", "运行 swift build", "改了 Sources/Login.swift", "改好了"])
        XCTAssertEqual(transcript.entries[2].paths, ["Sources/Login.swift"])
    }

    func testOlderRecordsWithoutCompletedItems() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"你好"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"在呢"}}"#,
        ]
        let transcript = CodexRollout.transcript(Data(lines.joined(separator: "\n").utf8), id: id)
        XCTAssertEqual(transcript.entries.map(\.text), ["你好", "在呢"])
    }

    func testLocatesTheRecordByTheDayInItsID() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let started = try XCTUnwrap(CodexRollout.startDate(of: id))
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: started)
        let day = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-10-28T16-14-11-\(id).jsonl")
        try Data().write(to: file)
        XCTAssertEqual(CodexRollout.locate(id: id, home: home)?.lastPathComponent, file.lastPathComponent)

        // Moved elsewhere (archived, or a day folder the id does not point to): still found.
        let archived = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archived.appendingPathComponent("rollout-x-\(id).jsonl.zst"))
        XCTAssertEqual(CodexRollout.locate(id: id, home: home)?.lastPathComponent, "rollout-x-\(id).jsonl.zst")
        XCTAssertNil(CodexRollout.locate(id: "01a18192-0000-7000-8000-000000000000", home: home))
        XCTAssertNil(CodexRollout.startDate(of: "not-a-uuid"))
    }
}
