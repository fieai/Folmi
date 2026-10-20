import XCTest
import FolmiCore
@testable import Folmi

/// Application flows exercise only newly-created repositories, local bare remotes and private JSON.
final class FolmiFlowTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs.reversed() { try? FileManager.default.removeItem(at: url) }
        cleanupURLs = []
    }

    private func makeStore() throws -> WorkspaceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-FlowTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanupURLs.append(directory)
        return WorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
    }

    private func makeDemo() async throws -> DemoRepository {
        let demo = try await DemoRepository.create()
        cleanupURLs.append(demo.root.deletingLastPathComponent())
        return demo
    }

    @MainActor
    private func eventually(_ description: String, timeout: TimeInterval = 8,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("等待超时：\(description)", file: file, line: line)
                throw FolmiFailure(message: "等待超时：\(description)")
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    @MainActor
    private func open(_ demo: DemoRepository, in model: FolmiModel,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        model.errorMessage = nil
        model.open(demo.root, environment: demo.environment, demo: true)
        try await eventually("打开演示项目", file: file, line: line) { !model.busy }
        XCTAssertNil(model.errorMessage, file: file, line: line)
        XCTAssertNotNil(model.snapshot, file: file, line: line)
        return try XCTUnwrap(model.repositoryURL?.path, file: file, line: line)
    }

    @MainActor
    private func preflight(_ model: FolmiModel,
                           file: StaticString = #filePath, line: UInt = #line) async throws -> DeliveryPlan {
        model.errorMessage = nil
        model.prepareDelivery()
        model.preflightDelivery()
        try await eventually("交付预检", file: file, line: line) { !model.busy }
        XCTAssertNil(model.errorMessage, file: file, line: line)
        return try XCTUnwrap(model.deliveryPlan, file: file, line: line)
    }

    @MainActor
    func testProjectsKeepDraftsAndDeliveryProfilesAfterSwitchAndRestart() async throws {
        let store = try makeStore()
        let first = try await makeDemo(), second = try await makeDemo()
        let model = FolmiModel(store: store)
        let firstPath = try await open(first, in: model)
        model.draftMessage = "一号项目的完整草稿\n\nChange-Id: I111"
        model.amendLast = true
        model.activateProfile(nil)
        model.profileName = "一号评审"
        model.deliveryKind = .gerrit
        model.deliveryRemote = "demo"
        model.deliveryBranch = "review/main"
        model.saveDeliveryProfile()
        let firstID = try XCTUnwrap(model.selectedProfileID)
        XCTAssertNil(model.errorMessage)

        let secondPath = try await open(second, in: model)
        XCTAssertEqual(model.draftMessage, "")
        XCTAssertFalse(model.amendLast)
        XCTAssertFalse(model.profiles.contains { $0.id == firstID })
        model.draftMessage = "二号项目的草稿"
        model.activateProfile(nil)
        model.profileName = "二号本地推送"
        model.deliveryKind = .push
        model.deliveryRemote = "demo"
        model.deliveryBranch = "release"
        model.saveDeliveryProfile()
        let secondID = try XCTUnwrap(model.selectedProfileID)
        XCTAssertNotEqual(firstID, secondID)

        model.switchProject(firstPath)
        try await eventually("切回一号项目") { !model.busy }
        XCTAssertEqual(model.draftMessage, "一号项目的完整草稿\n\nChange-Id: I111")
        XCTAssertTrue(model.amendLast)
        XCTAssertEqual(model.selectedProfileID, firstID)
        XCTAssertEqual(model.deliveryKind, .gerrit)
        XCTAssertEqual(model.deliveryBranch, "review/main")
        XCTAssertFalse(model.profiles.contains { $0.id == secondID })
        model.switchProject(secondPath)
        try await eventually("切回二号项目") { !model.busy }
        try model.savePreferencesNow()

        let restarted = FolmiModel(store: WorkspaceStore(url: store.url))
        XCTAssertEqual(restarted.projects.count, 2)
        restarted.restoreStartup()
        try await eventually("重启恢复选中项目") { !restarted.busy && restarted.snapshot != nil }
        XCTAssertEqual(restarted.repositoryURL?.path, secondPath)
        XCTAssertEqual(restarted.draftMessage, "二号项目的草稿")
        XCTAssertEqual(restarted.selectedProfileID, secondID)
        XCTAssertEqual(restarted.deliveryBranch, "release")
        restarted.switchProject(firstPath)
        try await eventually("重启后切换一号项目") { !restarted.busy }
        XCTAssertEqual(restarted.draftMessage, "一号项目的完整草稿\n\nChange-Id: I111")
        XCTAssertEqual(restarted.selectedProfileID, firstID)
        XCTAssertEqual(restarted.deliveryKind, .gerrit)
        XCTAssertNil(restarted.errorMessage)
        try restarted.savePreferencesNow()
    }

    @MainActor
    func testDirtyEditorTabsRemainInTheirOwnProjectAcrossSwitches() async throws {
        let first = try await makeDemo(), second = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        let firstPath = try await open(first, in: model)
        let firstDisk = try Data(contentsOf: first.root.appendingPathComponent("README.md"))
        model.editPath("README.md")
        model.editPath("Notes.txt")
        let firstEditor = try XCTUnwrap(model.editorWorkspace)
        firstEditor.updateText(id: "README.md", text: "一号未保存草稿\n")
        firstEditor.updateText(id: "Notes.txt", text: "一号独立笔记草稿\n")
        XCTAssertEqual(model.content, .editor)
        XCTAssertEqual(firstEditor.documents.count, 2)

        let secondPath = try await open(second, in: model)
        model.editPath("README.md")
        let secondEditor = try XCTUnwrap(model.editorWorkspace)
        secondEditor.updateText(id: "README.md", text: "二号未保存草稿\n")
        XCTAssertFalse(firstEditor === secondEditor)
        model.switchProject(firstPath)
        try await eventually("返回含脏标签的一号项目") { !model.busy }
        XCTAssertTrue(model.editorWorkspace === firstEditor)
        XCTAssertTrue(firstEditor.hasUnsavedChanges)
        XCTAssertEqual(firstEditor.documents.first { $0.path == "README.md" }?.text, "一号未保存草稿\n")
        XCTAssertEqual(firstEditor.documents.first { $0.path == "Notes.txt" }?.text, "一号独立笔记草稿\n")
        XCTAssertEqual(try Data(contentsOf: first.root.appendingPathComponent("README.md")), firstDisk)
        model.switchProject(secondPath)
        try await eventually("返回二号项目") { !model.busy }
        XCTAssertTrue(model.editorWorkspace === secondEditor)
        XCTAssertEqual(secondEditor.selectedDocument?.text, "二号未保存草稿\n")
        XCTAssertTrue(secondEditor.hasUnsavedChanges)
        XCTAssertNil(model.errorMessage)
        try model.savePreferencesNow()
    }

    @MainActor
    func testDeliveryLocksCommitAndAddressThenPushesOnlyToDisposableBareRemote() async throws {
        let demo = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        _ = try await open(demo, in: model)
        let before = try XCTUnwrap(model.snapshot)
        let plan = try await preflight(model)
        let remote = demo.root.deletingLastPathComponent().appendingPathComponent("demo-remote.git")
        XCTAssertEqual(plan.head, before.head)
        XCTAssertEqual(plan.endpoint, remote.path)
        XCTAssertEqual(plan.command.arguments, ["push", "--", remote.path, "\(plan.head):refs/heads/main"])
        XCTAssertFalse(plan.command.arguments.contains("HEAD:refs/heads/main"))
        XCTAssertTrue(model.canDeliver)
        model.runDelivery()
        try await eventually("本地演示推送完成") { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.deliveryPlan)
        XCTAssertEqual(model.activity.first { $0.title == "交付命令完成" }?.isError, false)
        let pushed = try await CommandRunner.git(["--git-dir", remote.path, "rev-parse", "refs/heads/main"], at: demo.root, environment: demo.environment)
        XCTAssertEqual(pushed.trimmingCharacters(in: .whitespacesAndNewlines), plan.head)
        XCTAssertEqual(model.snapshot?.fingerprint, before.fingerprint, "推送不应顺便暂存、提交或改动工作区")
        XCTAssertEqual(model.snapshot?.head, before.head)
        try model.savePreferencesNow()
    }

    @MainActor
    func testDeliveryRefusesStalePlanAfterExternalFileChange() async throws {
        let demo = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        _ = try await open(demo, in: model)
        let plan = try await preflight(model)
        let readme = demo.root.appendingPathComponent("README.md")
        let changed = try String(contentsOf: readme, encoding: .utf8) + "\n预检后发生的外部编辑\n"
        try changed.write(to: readme, atomically: true, encoding: .utf8)
        model.runDelivery()
        try await eventually("旧计划被拒绝") { !model.busy }
        XCTAssertTrue(model.errorMessage?.contains("预检后发生变化") == true)
        XCTAssertNil(model.deliveryPlan)
        XCTAssertEqual(model.snapshot?.head, plan.head)
        XCTAssertFalse(model.activity.contains { $0.title == "交付命令完成" })
        let remote = demo.root.deletingLastPathComponent().appendingPathComponent("demo-remote.git")
        let ref = try await CommandRunner.run(DeliveryCommand(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["--git-dir", remote.path, "show-ref", "--verify", "--quiet", "refs/heads/main"]), at: demo.root, environment: demo.environment)
        XCTAssertEqual(ref.exitCode, 1, "拒绝旧计划时不应创建远程分支")
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), changed)
        try model.savePreferencesNow()
    }

    @MainActor
    func testChangingFormOrProfileInvalidatesPreflightPlan() async throws {
        let demo = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        _ = try await open(demo, in: model)
        let defaultID = try XCTUnwrap(model.selectedProfileID)
        model.activateProfile(nil)
        model.profileName = "另一份评审配置"
        model.deliveryKind = .gerrit
        model.deliveryBranch = "review/main"
        model.saveDeliveryProfile()
        let alternateID = try XCTUnwrap(model.selectedProfileID)
        model.activateProfile(defaultID)
        _ = try await preflight(model)
        model.deliveryBranch = "another-target"
        XCTAssertNil(model.deliveryPlan)
        XCTAssertFalse(model.canDeliver)
        model.activateProfile(defaultID)
        _ = try await preflight(model)
        model.activateProfile(alternateID)
        XCTAssertNil(model.deliveryPlan)
        XCTAssertFalse(model.canDeliver)
        XCTAssertEqual(model.deliveryKind, .gerrit)
        XCTAssertEqual(model.deliveryBranch, "review/main")
        XCTAssertNil(model.errorMessage)
        try model.savePreferencesNow()
    }

    @MainActor
    func testSingleAndMultipleDiffSelectionKeepPathsAndAreaConsistent() async throws {
        let demo = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        _ = try await open(demo, in: model)
        model.selectFiles(["Sources/Greeting.swift"])
        try await eventually("查看单文件差异") {
            model.fileDiffs.count == 1 && model.fileDiffs.first?.file.path == "Sources/Greeting.swift"
        }
        XCTAssertEqual(model.content, .diff)
        XCTAssertTrue(model.fileDiffs[0].rawPatch.contains("Sources/Greeting.swift"))
        let paths: Set<String> = ["README.md", "Sources/Greeting.swift"]
        model.selectFiles(paths)
        try await eventually("查看多文件差异") { Set(model.fileDiffs.map { $0.file.path }) == paths }
        XCTAssertEqual(model.fileDiffs.count, 2)
        XCTAssertTrue(model.fileDiffs.allSatisfy { $0.area == .working })
        XCTAssertEqual(model.selectedFileIDs, paths)
        for diff in model.fileDiffs { XCTAssertTrue(diff.rawPatch.contains(diff.file.path)) }
        model.setArea(.staged)
        try await eventually("切换暂存区差异") {
            model.fileDiffs.count == 1 && model.fileDiffs.first?.area == .staged && model.fileDiffs.first?.file.path == "README.md"
        }
        XCTAssertEqual(model.selectedFileIDs, ["README.md"])
        XCTAssertNil(model.errorMessage)
        try model.savePreferencesNow()
    }

    @MainActor
    func testLivePTYCoexistsWithConcurrentGitRefreshAndDeliveryWithoutLosingShell() async throws {
        let demo = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        _ = try await open(demo, in: model)
        model.toggleTerminal()
        let terminal = try XCTUnwrap(model.terminalSession)
        defer { terminal.stop() }
        XCTAssertTrue(model.showTerminal)
        XCTAssertTrue(terminal.isRunning)
        let shellPID = terminal.terminalView.process.shellPid
        XCTAssertGreaterThan(shellPID, 0)
        _ = try await terminalResponse(terminal, command: "printf 'COEXIST_%s\\n' BEFORE", marker: "COEXIST_BEFORE")

        // Run the model refresh and a separate core actor concurrently while its real PTY shell
        // remains alive. A test that merely runs Git before terminal creation misses child reaping bugs.
        let started = Date()
        let core = GitRepository(url: demo.root, environment: demo.environment)
        var coreResult: Result<RepositorySnapshot, Error>?
        let coreLoad = Task { @MainActor in
            do { coreResult = .success(try await core.load()) }
            catch { coreResult = .failure(error) }
        }
        defer { coreLoad.cancel() }
        model.refresh()
        try await eventually("活动 PTY 中的 model refresh 与 core Git load", timeout: 8) {
            !model.busy && coreResult != nil
        }
        XCTAssertNil(model.errorMessage)
        let loaded = try XCTUnwrap(coreResult).get()
        XCTAssertEqual(loaded.head, model.snapshot?.head)

        let plan = try await preflight(model)
        XCTAssertTrue(model.canDeliver)
        model.runDelivery()
        try await eventually("活动 PTY 中的本地推送交付", timeout: 8) { !model.busy }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.activity.contains { $0.title == "交付命令完成" && !$0.isError })
        let remote = demo.root.deletingLastPathComponent().appendingPathComponent("demo-remote.git")
        var pushedResult: Result<String, Error>?
        let readback = Task { @MainActor in
            do { pushedResult = .success(try await CommandRunner.git(["--git-dir", remote.path, "rev-parse", "refs/heads/main"], at: demo.root, environment: demo.environment)) }
            catch { pushedResult = .failure(error) }
        }
        defer { readback.cancel() }
        try await eventually("活动 PTY 中读取本地远程提交", timeout: 8) { pushedResult != nil }
        let pushed = try XCTUnwrap(pushedResult).get()
        XCTAssertEqual(pushed.trimmingCharacters(in: .whitespacesAndNewlines), plan.head)
        _ = try await terminalResponse(terminal, command: "printf 'COEXIST_%s\\n' AFTER", marker: "COEXIST_AFTER")
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(terminal.terminalView.process.shellPid, shellPID, "Git 与交付完成后必须仍是原来同一个 shell")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "本地刷新、预检、交付与 PTY 响应应在 8 秒内完整完成")
        try model.savePreferencesNow()
    }

    @MainActor
    private func terminalResponse(_ session: TerminalSession, command: String, marker: String) async throws -> String {
        var output = ""
        session.terminalView.outputObserver = { output += String(decoding: $0, as: UTF8.self) }
        defer { session.terminalView.outputObserver = nil }
        session.terminalView.process.send(data: Array((command + "\r").utf8)[...])
        try await eventually("PTY 输出 \(marker)", timeout: 8) { output.contains(marker) }
        return output
    }
    @MainActor
    func testScriptPlanDetectsExecutableChangeWithoutRunningIt() async throws {
        let demo = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        _ = try await open(demo, in: model)
        let script = demo.root.deletingLastPathComponent().appendingPathComponent("delivery.sh")
        try "#!/bin/sh\nprintf 'ORIGINAL\\n'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        model.deliveryKind = .script
        model.scriptPath = script.path
        let plan = try await preflight(model)
        XCTAssertNotNil(plan.executableFingerprint)
        try "#!/bin/sh\nprintf 'CHANGED\\n'\n".write(to: script, atomically: true, encoding: .utf8)
        model.runDelivery()
        try await eventually("拒绝变化后的交付脚本") { !model.busy }
        XCTAssertTrue(model.errorMessage?.contains("交付脚本在预检后发生变化") == true)
        XCTAssertFalse(model.activity.contains { $0.title == "交付命令完成" })
        XCTAssertEqual(model.snapshot?.head, plan.head)
        try model.savePreferencesNow()
    }

    @MainActor
    func testScriptPlanRunsLiteralArgumentsOnceAndRequiresNewPreflight() async throws {
        let demo = try await makeDemo()
        let model = FolmiModel(store: try makeStore())
        _ = try await open(demo, in: model)
        let script = demo.root.deletingLastPathComponent().appendingPathComponent("delivery.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        model.deliveryKind = .script
        model.scriptPath = script.path
        model.scriptArguments = "a b;$(ignored)\nsecond"
        let plan = try await preflight(model)
        XCTAssertEqual(plan.command.arguments, ["a b;$(ignored)", "second"])
        model.runDelivery()
        try await eventually("字面量脚本交付完成") { !model.busy }
        XCTAssertNil(model.errorMessage)
        let record = try XCTUnwrap(model.activity.first { $0.title == "交付命令完成" })
        XCTAssertTrue(record.details.contains("a b;$(ignored)\nsecond"))
        XCTAssertNil(model.deliveryPlan)
        XCTAssertFalse(model.canDeliver)
        XCTAssertEqual(model.snapshot?.head, plan.head)
        try model.savePreferencesNow()
    }

}
