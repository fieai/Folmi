import AppKit
import FolmiCore
import XCTest
@testable import Folmi

final class TerminalPersistenceTests: XCTestCase {
    @MainActor
    func testQuitAndRestoreKeepsShellDirectoryOutputAndTabID() throws {
        _ = NSApplication.shared
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let root = try project("repo", fixture)
        let subfolder = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let first = makeModel(fixture, roots: [root])
        first.preferences.terminalQuitNoticeSuppressed = true
        first.showTerminal = true
        first.startTerminal()
        let original = try XCTUnwrap(first.terminalSession)
        XCTAssertTrue(waitUntil { original.isRunning })
        let pid = original.shellPID
        send("cd docs; printf '\\033]2;持久化标题\\007'; printf '%s' KEEP${:-_}OUTPUT; read line", to: original)
        XCTAssertTrue(waitUntil { original.title == "持久化标题" && original.currentDirectory?.lastPathComponent == "docs" })
        first.renameTerminalTab(original.id, to: "开发")
        XCTAssertTrue(first.prepareToQuit(), first.errorMessage ?? "")

        let second = makeModel(fixture, roots: [])
        second.repositoryURL = root
        second.startTerminal()
        let restored = try XCTUnwrap(second.terminalSession)
        var transcript = ""
        restored.terminalView.outputObserver = { transcript += String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(waitUntil { restored.isRunning && transcript.contains("KEEP_OUTPUT") })
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.shellPID, pid)
        XCTAssertEqual(restored.name, "开发")
        XCTAssertEqual(restored.title, "持久化标题")
        XCTAssertEqual(restored.currentDirectory?.lastPathComponent, "docs")
        XCTAssertTrue(second.endTerminal(restored))
        XCTAssertTrue(try second.terminalService!.sessions().isEmpty)
    }

    @MainActor
    func testExitedBackgroundTabRestoresItsExitStatusAndFinalOutput() throws {
        _ = NSApplication.shared
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let root = try project("exited", fixture)
        let first = makeModel(fixture, roots: [root])
        first.startTerminal()
        let original = try XCTUnwrap(first.terminalSession)
        XCTAssertTrue(waitUntil { original.isRunning })
        first.renameTerminalTab(original.id, to: "测试")
        send("printf '%s' FINAL${:-_}OUTPUT; exit 7", to: original)
        XCTAssertTrue(waitUntil { original.status == "已退出（退出码 7）" })
        XCTAssertTrue(first.prepareToQuit(), first.errorMessage ?? "")

        let second = makeModel(fixture, roots: [])
        second.repositoryURL = root
        second.startTerminal()
        let restored = try XCTUnwrap(second.terminalSession)
        var output = ""
        restored.terminalView.outputObserver = { output += String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(waitUntil { restored.status == "已退出（退出码 7）" })
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.displayTitle, "测试 · 已退出（退出码 7）")
        XCTAssertTrue(output.contains("FINAL_OUTPUT"))
        XCTAssertFalse(restored.isRunning)
    }

    @MainActor
    func testLegacyPreferencesStartFreshShellInSavedDirectory() throws {
        _ = NSApplication.shared
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let root = try project("legacy", fixture)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let store = store(for: fixture)
        let legacy: [String: Any] = ["showTerminal": true, "projects": [[
            "rootPath": root.path, "name": "旧项目", "terminalTabs": ["旧标签"], "terminalDirectories": ["docs"]
        ]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
        let decoded = try store.load()
        XCTAssertTrue(decoded.keepTerminalsRunning)
        XCTAssertFalse(decoded.terminalQuitNoticeSuppressed)
        XCTAssertEqual(decoded.projects.first?.terminalSessionIDs, [])

        let model = makeModel(fixture, roots: [])
        model.repositoryURL = root
        model.commandEnvironment = ["ZDOTDIR": root.path]
        model.startTerminal()
        let tab = try XCTUnwrap(model.terminalSession)
        XCTAssertTrue(waitUntil { tab.isRunning && tab.currentDirectory?.lastPathComponent == "docs" })
        XCTAssertEqual(tab.name, "旧标签")
        XCTAssertEqual(tab.backgroundID, tab.id)
        try model.savePreferencesNow()
        XCTAssertEqual(try store.load().projects.first?.terminalSessionIDs, [tab.id.uuidString])
    }

    @MainActor
    func testAdoptsUnclaimedTabsAndDetectsOrphansWithoutCreatingNewShells() throws {
        _ = NSApplication.shared
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let active = try project("active", fixture)
        let inactive = try project("inactive", fixture)
        let orphaned = try project("orphaned", fixture)
        let source = makeModel(fixture, roots: [active, inactive, orphaned])
        source.repositoryURL = inactive
        source.startTerminal()
        let one = try XCTUnwrap(source.terminalSession)
        source.repositoryURL = orphaned
        source.startTerminal()
        let two = try XCTUnwrap(source.terminalSession)
        XCTAssertTrue(waitUntil { one.isRunning && two.isRunning })
        one.detachForQuit()
        two.detachForQuit()

        let restored = makeModel(fixture, roots: [active, inactive])
        restored.restoreBackgroundTerminals()
        let adopted = try XCTUnwrap(restored.terminals[inactive.path]?.first)
        XCTAssertTrue(waitUntil { adopted.isRunning })
        XCTAssertEqual(adopted.id, one.id)
        XCTAssertEqual(restored.orphanTerminalCount, 1)
        XCTAssertTrue(restored.terminals[orphaned.path, default: []].isEmpty)
        // Removing an inactive project still ends its background tab, verified on the service.
        XCTAssertTrue(restored.forgetProject(inactive.path), restored.errorMessage ?? "")
        XCTAssertEqual(try restored.terminalService?.sessions().map(\.id), [two.id])
    }

    @MainActor
    func testDemoUsesOnlyLocalShellAndDisabledSettingEndsServiceOnQuit() throws {
        _ = NSApplication.shared
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let root = try project("project", fixture)
        let demo = makeModel(fixture, roots: [root], demo: true)
        demo.startTerminal()
        let demoTab = try XCTUnwrap(demo.terminalSession)
        XCTAssertTrue(demoTab.isRunning)
        XCTAssertNil(demoTab.backgroundID)
        XCTAssertNil(try fixture.endpoint.connect())
        XCTAssertTrue(demo.prepareToQuit(), demo.errorMessage ?? "")

        let model = makeModel(fixture, roots: [root])
        model.startTerminal()
        let background = try XCTUnwrap(model.terminalSession)
        XCTAssertTrue(waitUntil { background.isRunning })
        model.keepTerminalsRunning = false
        model.showTerminal = true
        model.newTerminalTab()
        let local = try XCTUnwrap(model.terminalSession)
        XCTAssertNil(local.backgroundID)
        XCTAssertTrue(local.isRunning)
        XCTAssertTrue(model.prepareToQuit(), model.errorMessage ?? "")
        XCTAssertFalse(local.isRunning)
        XCTAssertNil(try fixture.endpoint.connect())
        XCTAssertFalse(try store(for: fixture).load().keepTerminalsRunning)
    }

    @MainActor
    func testMissingHelperFallsBackToLocalAndReportsReason() throws {
        _ = NSApplication.shared
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let root = try project("project", fixture)
        let model = FolmiModel(store: store(for: fixture),
                               terminalService: TerminalService(settingsDirectory: fixture.settings, helper: nil))
        model.repositoryURL = root
        model.commandEnvironment = ["ZDOTDIR": root.path]
        model.startTerminal()
        let tab = try XCTUnwrap(model.terminalSession)
        defer { tab.stop() }
        XCTAssertTrue(waitUntil { tab.isRunning && model.terminalServiceNotice != nil })
        XCTAssertNil(tab.backgroundID)
        XCTAssertGreaterThan(tab.terminalView.process.shellPid, 0)
    }

    @MainActor
    func testWarmTabOpenLatencyAndIdleTabClosure() throws {
        _ = NSApplication.shared
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let root = try project("timing", fixture)
        try Data("printf 'FOLMI_PROMPT_READY\\n'\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let model = makeModel(fixture, roots: [root])
        model.showTerminal = true

        func openAndClose(persist: Bool) throws -> Double {
            model.keepTerminalsRunning = persist
            let start = ContinuousClock.now
            model.newTerminalTab()
            let terminal = try XCTUnwrap(model.terminalSession)
            var ready = false
            terminal.terminalView.outputObserver = { ready = ready || String(decoding: $0, as: UTF8.self).contains("FOLMI_PROMPT_READY") }
            XCTAssertTrue(waitUntil { ready && terminal.isRunning })
            let elapsed = start.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            model.closeTerminalTab(terminal.id)
            XCTAssertNil(model.terminalSession)
            return milliseconds
        }

        let cold = try openAndClose(persist: true)
        let local = try (0..<5).map { _ in try openAndClose(persist: false) }.sorted()[2]
        let warm = try (0..<5).map { _ in try openAndClose(persist: true) }.sorted()[2]
        print(String(format: "终端首条输出（毫秒） 本地中位数 %.1f，后台热启动中位数 %.1f，后台冷启动 %.1f", local, warm, cold))
    }

    @MainActor
    private func makeModel(_ fixture: PTYTestFixture, roots: [URL], demo: Bool = false) -> FolmiModel {
        let model = FolmiModel(store: store(for: fixture),
                               terminalService: TerminalService(settingsDirectory: fixture.settings, helper: fixture.helper))
        if !roots.isEmpty {
            model.projects = roots.map { ProjectPreferences(rootPath: $0.path, name: $0.lastPathComponent,
                                                            isDemo: demo) }
            model.preferences.projects = model.projects
        }
        model.repositoryURL = roots.first
        model.isDemo = demo
        model.commandEnvironment = roots.first.map { ["ZDOTDIR": $0.path] } ?? [:]
        return model
    }

    private func store(for fixture: PTYTestFixture) -> WorkspaceStore {
        WorkspaceStore(url: fixture.settings.appendingPathComponent("workspace.json"))
    }

    private func project(_ name: String, _ fixture: PTYTestFixture) throws -> URL {
        try FileManager.default.createDirectory(at: fixture.settings, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = fixture.settings.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @MainActor
    private func send(_ command: String, to tab: TerminalSession) {
        tab.terminalView.send(txt: command + "\r")
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }
}
