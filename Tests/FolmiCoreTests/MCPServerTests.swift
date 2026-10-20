import XCTest
@testable import FolmiCore

final class MCPServerTests: XCTestCase {
    private var root: URL!
    private var gitDir: URL { root.appendingPathComponent(".git") }
    private var settings: URL!
    private var opened: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)").resolvingSymlinksInPath()
        settings = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        opened = []
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func server(cwd: URL? = nil) -> MCPServer {
        MCPServer(settingsDirectory: settings, workingDirectory: cwd ?? root, now: { Date(timeIntervalSince1970: 100) },
                  openLink: { [unowned self] url, _ in opened.append(url); return nil })
    }
    private func send(_ server: MCPServer, _ message: [String: Any]) throws -> [String: Any] {
        let reply = try XCTUnwrap(server.handle(try JSONSerialization.data(withJSONObject: message)))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }
    /// The text of a tools/call reply and whether it is an error.
    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, error: Bool) {
        let reply = try send(server, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func testHandshakeListsOnlyReadingTools() throws {
        let server = server()
        let hello = try send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                      "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t"]]])
        let result = try XCTUnwrap(hello["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "folmi")
        XCTAssertNil(server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)), "notifications get no reply")
        let list = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(Set(names), ["list_review_comments", "mark_comment_addressed", "review_status", "recent_decisions", "show_in_folmi"])
        XCTAssertFalse(names.contains { $0.contains("commit") || $0.contains("stage") || $0.contains("push") })
        let unknown = try send(server, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testCommentsAndReplies() throws {
        let server = server()
        XCTAssertEqual(try call(server, "list_review_comments").text, "No review comments.")
        let comments = [SharedComment(id: "c1", path: "a.swift", firstLine: 3, lastLine: 4, excerpt: ["+let x = []"], body: "空数组会崩", outdated: false),
                        SharedComment(id: "c2", path: "b.swift", firstLine: 9, lastLine: 9, excerpt: ["-old"], body: "旧的", outdated: true)]
        try FolmiShared.write(comments, to: FolmiShared.comments(gitDir: gitDir))
        let listed = try call(server, "list_review_comments").text
        XCTAssertTrue(listed.contains("空数组会崩")); XCTAssertTrue(listed.contains("\"lines\" : \"3-4\""))
        XCTAssertFalse(listed.contains("旧的"), "outdated notes are left out by default")
        XCTAssertTrue(try call(server, "list_review_comments", ["include_outdated": true]).text.contains("旧的"))

        XCTAssertTrue(try call(server, "mark_comment_addressed", ["id": "nope", "note": "x"]).error)
        XCTAssertTrue(try call(server, "mark_comment_addressed", ["id": "c1", "note": "  "]).error)
        XCTAssertFalse(try call(server, "mark_comment_addressed", ["id": "c1", "note": "加了空数组判断"]).error)
        XCTAssertEqual(FolmiShared.lines(CommentReply.self, from: FolmiShared.replies(gitDir: gitDir)),
                       [CommentReply(id: "c1", note: "加了空数组判断", t: 100)])
        XCTAssertTrue(try call(server, "list_review_comments").text.contains("\"addressed\" : \"加了空数组判断\""))
    }

    func testStatusDecisionsAndShow() throws {
        let server = server()
        XCTAssertTrue(try call(server, "review_status").text.contains("has not opened"))
        try FolmiShared.write(SharedReviewStatus(branch: "main", files: [.init(path: "a.swift", staged: true, working: false, untracked: false)],
                                                     remaining: 3, latestBatch: .init(id: "b", prompt: "改 a", paths: ["a.swift"], finished: true)),
                                  to: FolmiShared.status(gitDir: gitDir))
        let status = try call(server, "review_status").text
        XCTAssertTrue(status.contains("\"hunksNotReviewed\" : 3")); XCTAssertTrue(status.contains("改 a"))

        for index in 0..<5 {
            try FolmiShared.append(ReviewDecision(t: Double(index), path: "f\(index)", action: index == 4 ? .reject : .accept, scope: .hunk,
                                                      added: 1, removed: 0, commentOnly: false, preview: ["+x"], batch: nil),
                                       to: FolmiShared.decisions(gitDir: gitDir))
        }
        let decisions = try call(server, "recent_decisions", ["limit": 2]).text
        XCTAssertTrue(decisions.contains("f4")); XCTAssertTrue(decisions.contains("rejected")); XCTAssertFalse(decisions.contains("f2"))
        XCTAssertFalse(decisions.contains("reason"))
        try FolmiShared.append(DecisionReason(t: 4, path: "f4", reason: "不要动这个配置"), to: FolmiShared.reasons(gitDir: gitDir))
        XCTAssertTrue(try call(server, "recent_decisions", ["limit": 2]).text.contains("\"reason\" : \"不要动这个配置\""),
                      "a reason written after the rejection is joined to it")

        XCTAssertFalse(try call(server, "show_in_folmi", ["path": "a.swift", "line": 12]).error)
        let link = try XCTUnwrap(opened.first)
        XCTAssertEqual(link.scheme, "folmi")
        XCTAssertEqual(MCPServer.parse(link), MCPServer.Link(repository: root.path, path: "a.swift", line: 12))
    }

    func testRepositoryFallsBackToTheAppsProject() throws {
        let away = server(cwd: URL(fileURLWithPath: "/"))
        XCTAssertTrue(try call(away, "review_status").error, "no repo argument, no project in the app")
        try FolmiShared.write(SharedAppState(bundleID: "x", appPath: nil, repository: root.path), to: FolmiShared.appState(settingsDirectory: settings))
        XCTAssertFalse(try call(away, "review_status").error)
        XCTAssertFalse(try call(away, "review_status", ["repo": root.path]).error)
        XCTAssertTrue(try call(away, "review_status", ["repo": "/nonexistent-\(UUID().uuidString)"]).error)
    }

    func testLinksRejectPathsOutsideTheRepository() {
        XCTAssertNil(MCPServer.parse(URL(string: "folmi://open?repo=relative&path=a")!))
        XCTAssertNil(MCPServer.parse(URL(string: "folmi://open?repo=/r&path=../../etc/passwd")!)?.path)
        XCTAssertNil(MCPServer.parse(URL(string: "folmi://open?repo=/r&path=/etc/passwd")!)?.path)
        XCTAssertEqual(MCPServer.parse(URL(string: "folmi://open?repo=/r&path=a&line=2")!),
                       MCPServer.Link(repository: "/r", path: "a", line: 2))
        XCTAssertNil(MCPServer.parse(URL(string: "other://open?repo=/r&path=a")!))
        XCTAssertNil(MCPServer.parse(URL(string: "https://open?repo=/r")!))
        let round = MCPServer.link(repository: "/a b/仓库", path: "dir/文件 1.md", line: 3)!
        XCTAssertEqual(MCPServer.parse(round), MCPServer.Link(repository: "/a b/仓库", path: "dir/文件 1.md", line: 3))
    }

    /// The built helper answers over real pipes, one line per message.
    func testHelperSpeaksStdio() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let helper = products.appendingPathComponent("folmi-hook")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper not built next to the tests")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper; process.arguments = ["mcp"]
        process.currentDirectoryURL = root
        process.standardInput = input; process.standardOutput = output
        try process.run()
        let messages = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
                        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_review_comments","arguments":{}}}"#]
        input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("No review comments."))
    }
}
