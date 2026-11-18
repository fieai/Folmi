import AppKit
import FolmiCore
import SwiftUI
import XCTest
@testable import Folmi

@MainActor
final class AgentAttentionTests: XCTestCase {
    func testPriorityAgeAndWorktreeFallback() async throws {
        let now = Date()
        var project = ProjectBoard.Row(path: "/main", name: "Main")
        project.changes = 6
        project.unaccepted = 5
        project.hookEvent = event(.stop, at: now, agent: "codex")
        XCTAssertEqual(project.attention?.text, "Codex 改完了 · 5 个文件没验收")
        project.acpAttention = .init(kind: .failed, text: "Claude 出错了")
        XCTAssertEqual(project.attention?.kind, .failed)
        project.acpAttention = .waiting(agent: "Claude", message: "想运行 npm test")
        XCTAssertEqual(project.attention?.text, "Claude 在等你处理：想运行 npm test")
        project.acpAttention = nil
        project.unaccepted = 0
        XCTAssertNil(project.attention, "staged-only changes do not count")
        let oldStop = event(.stop, at: now.addingTimeInterval(-24 * 3600))
        XCTAssertNil(AgentAttention.hook(oldStop, unaccepted: 1, now: now))
        let oldRun = event(.edit, at: now.addingTimeInterval(-30 * 60))
        XCTAssertNil(AgentAttention.hook(oldRun, unaccepted: 1, now: now))

        var tree = ProjectBoard.Row(path: "/tree", name: "Tree", parent: project.path)
        tree.hookEvent = event(.waiting, at: now, message: "需要允许")
        var other = ProjectBoard.Row(path: "/another", name: "Another", unaccepted: 2, parent: project.path)
        other.hookEvent = event(.stop, at: now)
        let board = ProjectBoard()
        board.setRowsForTesting([project, other, tree])
        XCTAssertEqual(board.attention(for: project.path, includeWorktrees: true), tree.attention)
        XCTAssertEqual(board.attention(for: tree.path, includeWorktrees: false), tree.attention)
        project.hookEvent = event(.start, at: now)
        board.setRowsForTesting([project, other, tree])
        XCTAssertEqual(board.attention(for: project.path, includeWorktrees: true)?.kind, .running)
    }

    func testWaitingHookExpiresAfterThirtyMinutes() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let waiting = event(.waiting, at: now)
        XCTAssertEqual(AgentAttention.hook(waiting, unaccepted: 0, now: now.addingTimeInterval(1_799))?.kind, .waiting)
        XCTAssertNil(AgentAttention.hook(waiting, unaccepted: 0, now: now.addingTimeInterval(1_800)))
        XCTAssertNil(AgentAttention.hook(waiting, unaccepted: 0, now: now.addingTimeInterval(1_801)))
    }

    func testPorcelainCountsWorkingChangesAndSkipsRenameSourceRecord() async {
        let entries = ["1 M. staged-only", "1 .M edited", "1 MM staged-and-edited",
                       "2 R. renamed", "? original-with-status-like-name", "u UU conflicting", "? untracked"]
        var row = ProjectBoard.Row(path: "/p", name: "P")
        ProjectBoard.parseStatus(entries.joined(separator: "\0") + "\0", into: &row)
        XCTAssertEqual(row.changes, 6)
        XCTAssertEqual(row.unaccepted, 4)
        ProjectBoard.parseStatus("1 A. staged\0", into: &row)
        XCTAssertEqual(row.unaccepted, 0)
    }

    func testBoardWatchesFirstWriteAndReplacementInLinkedWorktreeAndRefreshesOnStop() async throws {
        let demo = try await DemoRepository.create()
        let folder = demo.root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let requestedTree = folder.appendingPathComponent("worktree")
        _ = try await CommandRunner.git(["worktree", "add", "--detach", requestedTree.path], at: demo.root, environment: demo.environment)
        let board = ProjectBoard()
        let project = ProjectPreferences(rootPath: demo.root.path, name: "主项目", isDemo: true, environment: demo.environment)
        let tree = ProjectPreferences(rootPath: requestedTree.resolvingSymlinksInPath().path, name: "子工作树", isDemo: true, environment: demo.environment)
        board.refresh(projects: [project, tree])
        try await eventually("board loaded both paths once") { !board.refreshing && board.rows.count == 2 }
        XCTAssertEqual(board.rows.first { $0.path == tree.rootPath }?.parent, project.rootPath)
        let gitDir = try XCTUnwrap(AIEventStore.locate(from: requestedTree)).gitDir
        let url = AIEventStore.events(gitDir: gitDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try line(event(.waiting, message: "等待许可")).write(to: url)
        try await eventually("linked worktree event reached project") {
            board.attention(for: project.rootPath, includeWorktrees: true)?.kind == .waiting
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: line(event(.start)))
        try handle.close()
        try await eventually("start cleared waiting") {
            board.attention(for: tree.rootPath, includeWorktrees: false)?.kind == .running
        }

        let change = requestedTree.appendingPathComponent("new-from-agent.txt")
        try Data("new".utf8).write(to: change)
        let ended = event(.stop, agent: "codex")
        let previousUpdated = board.updated
        try line(ended).write(to: url, options: .atomic)
        try await eventually("stop reread the new file") {
            board.attention(for: tree.rootPath, includeWorktrees: false)?.text == "Codex 改完了 · 1 个文件没验收"
        }
        XCTAssertEqual(board.updated, previousUpdated, "only the stopped worktree was read")
        _ = try await CommandRunner.git(["add", "--", "new-from-agent.txt"], at: requestedTree, environment: demo.environment)
        let repo = GitRepository(url: requestedTree, environment: demo.environment)
        board.patch(path: tree.rootPath, snapshot: try await repo.load(), inReview: 0)
        XCTAssertNil(board.attention(for: project.rootPath, includeWorktrees: true))
    }

    func testLiveACPReportsByRootAndClearsOnceSeen() async throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: settings) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        let root = URL(fileURLWithPath: "/background")
        model.repositoryURL = URL(fileURLWithPath: "/current")
        model.board.setRowsForTesting([.init(path: root.path, name: "Background")])
        let session = AgentSession(agent: .codex, root: root, gitDir: nil)
        model.wire(session)
        model.agentSessions = [session]
        session.state = .failed("连接已关闭")
        try await eventually("background session failed") {
            model.board.rows.first?.attention?.kind == .failed
        }
        session.transcript.append(.init(id: "p", kind: .permission, text: "运行 npm test"))
        try await eventually("permission beats a failure") {
            model.board.rows.first?.attention?.text == "Codex 在等你处理：运行 npm test"
        }
        model.selectAgentSession(session)
        XCTAssertFalse(session.unseen)
        session.transcript.entries[0].status = "允许"
        try await eventually("seen and answered") { model.board.rows.first?.attention == nil }
    }

    func testHookNotificationThrottleIsPerSession() async {
        var throttle = HookNoticeThrottle()
        let now = Date()
        XCTAssertTrue(throttle.shouldPost(session: "claude-1", now: now))
        XCTAssertTrue(throttle.shouldPost(session: "codex-1", now: now))
        XCTAssertFalse(throttle.shouldPost(session: "claude-1", now: now.addingTimeInterval(299)))
        XCTAssertTrue(throttle.shouldPost(session: "claude-1", now: now.addingTimeInterval(300)))
    }

    func testProjectRailReadsBackWaitingTooltip() async throws {
        _ = NSApplication.shared
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("rail-accessibility-\(UUID())")
        defer { try? FileManager.default.removeItem(at: settings) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        let path = settings.appendingPathComponent("project").path
        model.projects = [ProjectPreferences(rootPath: path, name: "项目")]
        model.repositoryURL = URL(fileURLWithPath: path)
        var row = ProjectBoard.Row(path: path, name: "项目")
        row.hookEvent = event(.waiting, message: "想运行 npm test")
        model.board.setRowsForTesting([row])
        let host = NSHostingView(rootView: ProjectRail(model: model, expanded: .constant(true))
            .frame(width: 168, height: 460))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 170, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        func dropTarget(in view: NSView) -> ProjectIconDropView? {
            (view as? ProjectIconDropView) ?? view.subviews.lazy.compactMap { dropTarget(in: $0) }.first
        }
        let text = "Claude 在等你处理：想运行 npm test"
        try await eventually("the rendered project square has its waiting tooltip") {
            dropTarget(in: host)?.toolTip?.contains(text) == true
        }
        XCTAssertEqual(dropTarget(in: host)?.toolTip, "项目\n\(path)\n\(text)")
    }

    private func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), message)
    }

    private func event(_ kind: AIEvent.Kind, at: Date = Date(), agent: String = "claude", message: String? = nil) -> AIEvent {
        AIEvent(t: at.timeIntervalSince1970, kind: kind, session: "s", batch: "b", agent: agent, message: message)
    }

    private func line(_ event: AIEvent) throws -> Data { try JSONEncoder().encode(event) + Data([10]) }
}
