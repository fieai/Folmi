import AppKit
import FolmiCore
import SwiftUI
import XCTest
@testable import Folmi

@MainActor
final class AllTerminalsTests: XCTestCase {
    func testGroupingSortingAndSearch() async throws {
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let model = try makeModel(fixture, projects: ["second", "first"])
        let roots = model.projects.map(\.rootPath)
        let original = Date(timeIntervalSince1970: 100)
        func session(_ path: String, offset: TimeInterval, program: String? = nil, exit: Int32? = nil) -> TerminalService.ListedSession {
            .init(info: .init(id: UUID(), projectRoot: path, shellPid: 0, foregroundPid: program == nil ? nil : 42,
                             foregroundName: program, exitCode: exit, createdAt: original + offset),
                  directory: path + "/docs", commandLine: program.map { $0 + " dev" })
        }
        let anIdle = session(roots[0], offset: 0)
        let aJob = session(roots[0], offset: 2, program: "pnpm")
        let earlierJob = session(roots[0], offset: 1, program: "node")
        let exited = session(roots[0], offset: -1, exit: 7)
        let other = session(roots[1], offset: 0)
        let orphan = session(fixture.settings.path + "/unlisted", offset: -1)
        let groups = model.allTerminalGroups([other, orphan, aJob, exited, anIdle, earlierJob])
        XCTAssertEqual(groups.map(\.title), ["second", "first", "不属于任何项目"])
        XCTAssertEqual(groups[0].rows.map(\.id), [earlierJob, aJob, anIdle, exited].map(\.info.id))
        XCTAssertEqual(groups[0].rows.first?.displayDirectory, "docs")
        let list = AllTerminalList(groups: groups)
        XCTAssertEqual(list.matching("PNPM dev").flatMap(\.rows).map(\.id), [aJob.info.id])
        XCTAssertEqual(list.matching("first").flatMap(\.rows).map(\.id), [other.info.id])
        XCTAssertEqual(list.matching("/unlisted/docs").flatMap(\.rows).map(\.id), [orphan.info.id])
    }

    func testEndIdleKeepsRunningAndExitedSessions() async throws {
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let model = try makeModel(fixture, projects: ["project", "other"])
        let root = URL(fileURLWithPath: model.projects[1].rootPath)
        let idle = try create(at: root, fixture: fixture)
        let working = try create(at: root, fixture: fixture, command: "sleep 45; :")
        let backgroundJob = try create(at: root, fixture: fixture, command: "sleep 45 &\nread -r line")
        let exited = try create(at: root, fixture: fixture, command: "exit 7")
        let service = try XCTUnwrap(model.terminalService)
        let current = try XCTUnwrap(model.repositoryURL)
        let local = model.makeTerminal(root: current, name: "本地标签")
        let localExited = model.makeTerminal(root: current, name: "退出的本地标签")
        defer { local.stop(); localExited.stop() }
        model.terminals[current.path] = [local, localExited]
        localExited.terminalView.send(txt: "exit 6\r")
        try await eventually("各会话进入预期状态") {
            let status = try? service.sessions()
            return status?.first { $0.id == working.id }?.runningProgram == "sleep"
                && status?.first { $0.id == backgroundJob.id }?.runningProgram == "sleep"
                && status?.first { $0.id == exited.id }?.exitCode == 7 && localExited.hasExited
        }
        let listed = await model.loadAllTerminals()
        XCTAssertEqual(Set(listed.rows.filter(\.isIdle).map(\.id)), [idle.id, local.id])
        XCTAssertEqual(listed.rows.first { $0.id == working.id }?.commandLine, "sleep 45")
        XCTAssertEqual(listed.rows.first { $0.id == localExited.id }?.exitCode, 6)
        // The saved tabs of an unopened project must also be removed, or they would open as fresh shells.
        model.preferences.projects[1].terminalTabs = ["空闲", "运行"]
        model.preferences.projects[1].terminalSessionIDs = [idle.id.uuidString, working.id.uuidString]
        var prompts = 0
        await model.endIdleTerminals(Set(listed.rows.map(\.id))) { _ in prompts += 1; return true }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(Set(try service.sessions().map(\.id)), [working.id, backgroundJob.id, exited.id])
        XCTAssertFalse(local.isRunning)
        XCTAssertEqual(model.terminals[current.path]?.map(\.id), [localExited.id])
        try model.savePreferencesNow()
        XCTAssertEqual(try model.store.load().projects[1].terminalSessionIDs, [working.id.uuidString])
    }

    func testJumpFromSearchSelectsUnrestoredProjectAndFocusesTheVisibleTerminal() async throws {
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let source = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: source.root.deletingLastPathComponent()) }
        let target = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: target.root.deletingLastPathComponent()) }
        let targetRoot = try await GitRepository(url: target.root, environment: target.environment).load().root
        let model = try makeModel(fixture, projects: [])
        model.open(source.root, environment: source.environment, demo: true)
        try await eventually("打开起始仓库") { model.snapshot != nil && !model.busy }
        let project = ProjectPreferences(rootPath: targetRoot.path, name: "Target Project", isDemo: false)
        model.projects.append(project)
        let first = try create(at: targetRoot, fixture: fixture)
        let desired = try create(at: targetRoot, fixture: fixture)
        model.preferences.projects = model.projects
        let targetIndex = model.preferences.projects.count - 1
        model.preferences.projects[targetIndex].terminalTabs = ["FirstTab101", "TargetTab202"]
        model.preferences.projects[targetIndex].terminalSessionIDs = [first.id.uuidString, desired.id.uuidString]
        XCTAssertNil(model.terminals[targetRoot.path])

        let window = show(FolmiView(model: model))
        defer { close(window, model: model) }
        model.showAllTerminals = true
        try await eventually("列表显示，搜索已聚焦") {
            window.attachedSheet?.firstResponder is NSTextView && model.allTerminalCountOutsideProject == 2
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let editor = try XCTUnwrap(sheet.firstResponder as? NSTextView)
        editor.insertText("Target Project", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(250))
        key(in: sheet, code: 125, characters: "\u{F701}")
        try await Task.sleep(for: .milliseconds(150))
        key(in: sheet, code: 36, characters: "\r")
        try await eventually("目标项目和标签选中") {
            !model.busy && model.repositoryURL?.path == targetRoot.path && model.terminalSession?.id == desired.id
        }
        let tab = try XCTUnwrap(model.terminalSession)
        try await eventually("终端成为窗口焦点") { tab.terminalView.window === window && window.firstResponder === tab.terminalView }
        XCTAssertTrue(model.showTerminal)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(try ScreenText.read(XCTUnwrap(window.contentView)).contains("TargetTab202"))
        XCTAssertEqual(try model.terminalService?.sessions().count, 2)

        model.showAllTerminals = true
        try await eventually("重新打开列表") { window.attachedSheet?.firstResponder is NSTextView }
        let reopened = try XCTUnwrap(window.attachedSheet)
        let search = try XCTUnwrap(reopened.firstResponder as? NSTextView)
        search.insertText("Target Project", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(250))
        key(in: reopened, code: 51, characters: "\u{7F}", modifiers: .command)
        try await eventually("⌘⌫ 结束选中终端") { (try? model.terminalService?.sessions().map(\.id)) == [desired.id] }
        XCTAssertEqual(search.string, "Target Project")
        key(in: reopened, code: 53, characters: "\u{1B}")
        try await eventually("Esc 关闭列表") { window.attachedSheet == nil }
    }

    func testClaimAddsTabPersistsIDAndReattachesSameShellAfterRestart() async throws {
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let model = try makeModel(fixture, projects: ["project"])
        model.keepTerminalsRunning = true
        let original = fixture.settings.appendingPathComponent("unlisted", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let orphan = try create(at: original, fixture: fixture)
        let initial = await model.loadAllTerminals()
        let row = try XCTUnwrap(initial.rows.first)
        XCTAssertNil(row.projectPath)
        XCTAssertEqual(model.allTerminalCountOutsideProject, 1)
        await model.claimListedTerminal(row)
        let tab = try XCTUnwrap(model.terminalTabs.first)
        try await eventually("认领的标签连上原来的 shell") { tab.isRunning }
        XCTAssertEqual(tab.shellPID, orphan.shellPid)
        XCTAssertNil(model.allTerminalCountOutsideProject)
        XCTAssertEqual(model.orphanTerminalCount, 0)
        try model.savePreferencesNow()
        XCTAssertEqual(try model.store.load().projects.first?.terminalSessionIDs, [orphan.id.uuidString])
        tab.detachForQuit()

        let restored = FolmiModel(store: model.store, terminalService: model.terminalService)
        restored.restoreBackgroundTerminals()
        let root = try XCTUnwrap(model.repositoryURL)
        let resumed = try XCTUnwrap(restored.terminals[root.path]?.first)
        try await eventually("重开后接回原会话") { resumed.isRunning }
        XCTAssertEqual(resumed.id, orphan.id)
        XCTAssertEqual(resumed.shellPID, orphan.shellPid)
        XCTAssertEqual(try restored.backgroundTerminals(in: root.path).map(\.id), [orphan.id])
        XCTAssertEqual(restored.orphanTerminalCount, 0)
    }

    func testPanelStopsPollingWhenClosed() async throws {
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let model = try makeModel(fixture, projects: [])
        var reads = 0
        let window = show(AllTerminalsSheet(model: model) {
            reads += 1
            return await model.loadAllTerminals()
        })
        defer { close(window) }
        try await eventually("打开后立即查询") { reads == 1 }
        try await eventually("两秒后再次查询") { reads == 2 }
        close(window)
        let before = reads
        try await Task.sleep(for: .milliseconds(2_250))
        XCTAssertEqual(reads, before)
    }

    func testMarkdownTableKeepsOptionCommandT() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = EditorTextView(frame: window.frame)
        window.contentView = editor
        defer { window.contentView = nil }
        window.makeFirstResponder(editor)
        editor.markdownEditing = true
        editor.string = "文字"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        func shortcut(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "†",
                                          charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        }
        XCTAssertTrue(editor.performKeyEquivalent(with: try shortcut([.command, .option])))
        XCTAssertTrue(editor.string.contains("| 列 1 | 列 2 |"))
    }

    private func makeModel(_ fixture: PTYTestFixture, projects: [String]) throws -> FolmiModel {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: fixture.settings, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = WorkspaceStore(url: fixture.settings.appendingPathComponent("workspace.json"))
        let service = TerminalService(settingsDirectory: fixture.settings, helper: fixture.helper)
        let model = FolmiModel(store: store, autoRefresh: false, terminalService: service)
        model.projects = try projects.map { name in
            let root = fixture.settings.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return ProjectPreferences(rootPath: root.path, name: name, isDemo: false)
        }
        model.preferences.projects = model.projects
        model.repositoryURL = model.projects.first.map { URL(fileURLWithPath: $0.rootPath) }
        model.commandEnvironment = ["ZDOTDIR": fixture.settings.path, "HOME": fixture.settings.path, "HISTFILE": "/dev/null"]
        model.keepTerminalsRunning = false
        return model
    }

    private func create(at root: URL, fixture: PTYTestFixture, command: String? = nil) throws -> PTYProtocol.Session {
        var peer = PTYPeer(try fixture.endpoint.connectOrLaunch(helper: fixture.helper))
        try peer.hello().requireCompatibility()
        var argv = ["/bin/zsh", "-d", "-f", "-i"]
        if let command { argv += ["-c", command] }
        let request = PTYProtocol.Create(id: UUID(), projectRoot: root.path, cwd: root.path,
                                         env: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": fixture.settings.path],
                                         argv: argv, cols: 80, rows: 24)
        try peer.send(.json(.create, request))
        return try peer.receive(.created).decode(PTYProtocol.Session.self)
    }

    private func show<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func close(_ window: NSWindow, model: FolmiModel) {
        if window.attachedSheet != nil {
            model.showAllTerminals = false
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        }
        close(window)
    }

    private func key(in window: NSWindow, code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            if modifiers.contains(.command) { NSApp.sendEvent(event) }
            else { window.sendEvent(event) }
        }
    }

    private func eventually(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
        guard predicate() else {
            XCTFail(description)
            throw NSError(domain: description, code: 1)
        }
    }
}
