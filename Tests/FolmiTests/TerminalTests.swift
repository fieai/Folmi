import AppKit
import Darwin
import FolmiCore
import Darwin
import XCTest
@testable import Folmi

final class TerminalTests: XCTestCase {
    @MainActor
    func testDemoPTYStartsInLiteralDirectoryWithIsolatedConfigurationAndANSI() async throws {
        let root = try makeRoot("work ; \u{4E2D} $ literal")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let session = TerminalSession(root: root, environment: ["GIT_CONFIG_GLOBAL": "/private/forbidden", "HOME": "/private/forbidden"], isDemo: true)
        defer { session.stop() }
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.shellArguments, ["-d", "-f"])
        XCTAssertEqual(session.launchEnvironment["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(session.launchEnvironment["GIT_CONFIG_SYSTEM"], "/dev/null")
        XCTAssertEqual(session.launchEnvironment["HISTFILE"], "/dev/null")
        XCTAssertNotEqual(session.launchEnvironment["HOME"], "/private/forbidden")
        let output = try await response(session, command: "printf '\\033[31mANSI_%s\\033[0m\\n' READY; pwd; test -t 0 && printf 'REAL_%s\\n' PTY; printf 'FINISH_%s\\n' A", marker: "FINISH_A")
        XCTAssertTrue(output.contains(root.path))
        XCTAssertTrue(output.contains("REAL_PTY"), "标准输入必须是 PTY")
        XCTAssertTrue(output.contains("\u{1B}[31mANSI_READY\u{1B}[0m"))
        let visible = String(decoding: session.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(visible.contains("ANSI_READY"))
        XCTAssertFalse(visible.contains("\u{1B}[31m"), "终端应解析 ANSI，不能原样画转义序列")
        XCTAssertNil(session.terminalView.terminalDelegate?.clipboardRead(source: session.terminalView))
    }

    @MainActor
    func testTerminalColorsFollowTheViewAppearanceInsteadOfStayingWhite() throws {
        let root = try makeRoot("colors")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let session = TerminalSession(root: root, environment: [:], isDemo: true)
        defer { session.stop() }
        let view = session.terminalView
        func brightness(_ color: NSColor) -> CGFloat { color.usingColorSpace(.sRGB)?.brightnessComponent ?? -1 }
        func layerBrightness() -> CGFloat { view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }.map(brightness) ?? -1 }

        view.appearance = NSAppearance(named: .darkAqua)
        view.applyAppearanceColors()
        XCTAssertLessThan(brightness(view.nativeBackgroundColor), 0.3)
        XCTAssertGreaterThan(brightness(view.nativeForegroundColor), 0.7)
        if view.layer != nil { XCTAssertLessThan(layerBrightness(), 0.3, "边距层不能还是白色") }

        view.appearance = NSAppearance(named: .aqua)
        view.applyAppearanceColors()
        XCTAssertGreaterThan(brightness(view.nativeBackgroundColor), 0.7)
        XCTAssertLessThan(brightness(view.nativeForegroundColor), 0.3)
    }

    @MainActor
    func testControlCAndResizePreserveTheSameSession() async throws {
        let root = try makeRoot("terminal")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let session = TerminalSession(root: root, environment: [:], isDemo: true)
        defer { session.stop() }
        let originalPID = session.terminalView.process.shellPid
        _ = try await response(session, command: "printf 'BEGIN_%s\\n' WAIT; sleep 15", marker: "BEGIN_WAIT")
        // printf can reach the PTY before zsh has forked sleep and assigned it the foreground.
        // Synchronize on the actual foreground process group, not on output timing.
        let descriptor = session.terminalView.process.childfd
        for _ in 0..<200 {
            let foreground = tcgetpgrp(descriptor)
            if foreground > 0, foreground != originalPID { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let foreground = tcgetpgrp(descriptor)
        XCTAssertGreaterThan(foreground, 0)
        XCTAssertNotEqual(foreground, originalPID, "sleep 必须实际取得终端前台进程组后才发送 Ctrl-C")
        let prompt = expectation(description: "Ctrl-C 后返回 shell prompt")
        var interruption = ""
        var promptReceived = false
        session.terminalView.outputObserver = { bytes in
            interruption += String(decoding: bytes, as: UTF8.self)
            if interruption.contains("demo "), !promptReceived {
                promptReceived = true
                prompt.fulfill()
            }
        }
        session.terminalView.process.send(data: [3][...])
        // The TTY flushes pending keyboard input on SIGINT; wait for its new prompt before typing.
        await fulfillment(of: [prompt], timeout: 4)
        session.terminalView.outputObserver = nil
        // A new command runs promptly after Ctrl-C, rather than waiting for the sleep to finish.
        _ = try await response(session, command: "printf 'INTERRUPT_%s\\n' OK", marker: "INTERRUPT_OK")
        session.terminalView.getTerminal().resize(cols: 101, rows: 31)
        session.terminalView.sizeChanged(source: session.terminalView, newCols: 101, newRows: 31)
        let result = try await response(session, command: "stty size; printf 'RESIZE_%s\\n' OK", marker: "RESIZE_OK")
        XCTAssertTrue(result.contains("31 101"))
        XCTAssertEqual(session.terminalView.process.shellPid, originalPID)
        XCTAssertTrue(session.isRunning)
    }

    @MainActor
    func testStoppingOneSessionLeavesUnrelatedProcessAndOtherTerminalAlive() async throws {
        let root = try makeRoot("two sessions")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var unrelated: pid_t = 0
        let arguments = [strdup("sleep"), strdup("20"), nil]
        let childEnvironment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { arguments.forEach { free($0) }; childEnvironment.forEach { free($0) } }
        let launched = arguments.withUnsafeBufferPointer { argv in
            childEnvironment.withUnsafeBufferPointer { envp in
                posix_spawn(&unrelated, "/bin/sleep", nil, nil, argv.baseAddress!, envp.baseAddress!)
            }
        }
        XCTAssertEqual(launched, 0)
        guard launched == 0 else { return }
        defer {
            Darwin.kill(unrelated, SIGKILL)
            var status: Int32 = 0
            for _ in 0..<100 {
                if waitpid(unrelated, &status, WNOHANG) != 0 { break }
                usleep(10_000)
            }
        }
        let first = TerminalSession(root: root, environment: [:], isDemo: true)
        let second = TerminalSession(root: root, environment: [:], isDemo: true)
        defer { first.stop(); second.stop() }
        let closedPID = first.terminalView.process.shellPid
        first.stop()
        first.stop()
        for _ in 0..<60 {
            if Darwin.kill(closedPID, 0) == -1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(Darwin.kill(closedPID, 0), -1, "关闭会话必须实际结束并回收自己的 shell")
        XCTAssertEqual(Darwin.kill(unrelated, 0), 0)
        XCTAssertTrue(second.isRunning)
        _ = try await response(second, command: "printf 'SECOND_%s\\n' ALIVE", marker: "SECOND_ALIVE")
    }

    @MainActor
    func testNaturalExitUpdatesRunningState() async throws {
        let root = try makeRoot("exit")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let session = TerminalSession(root: root, environment: [:], isDemo: true)
        defer { session.stop() }
        session.terminalView.process.send(data: Array("exit\r".utf8)[...])
        for _ in 0..<60 {
            if !session.isRunning { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.title, "终端已退出")
    }

    @MainActor
    func testMissingProjectDirectoryDoesNotStartInAnotherDirectory() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-Missing-\(UUID().uuidString)")
        let session = TerminalSession(root: missing, environment: [:], isDemo: true)
        defer { session.stop() }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.terminalView.process.shellPid, 0)
        XCTAssertEqual(session.title, "终端启动失败")
    }

    /// Tabs are named by the folder the shell is in, follow a `cd`, and repeats are numbered.
    @MainActor
    func testTabTitleFollowsTheShellFolder() async throws {
        let root = try makeRoot("repository")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let session = TerminalSession(root: root, environment: [:], isDemo: true)
        defer { session.stop() }
        XCTAssertEqual(session.displayTitle, "repository · zsh")
        let inDocs = TerminalSession(root: root, environment: [:], isDemo: true, directory: "docs")
        defer { inDocs.stop() }
        XCTAssertEqual(inDocs.displayTitle, "docs · zsh")
        _ = try await response(session, command: "cd docs; printf 'CD_%s\\n' OK", marker: "CD_OK")
        session.refreshFolder(force: true)
        XCTAssertEqual(session.displayTitle, "docs · zsh")
        session.name = "构建"
        XCTAssertEqual(session.displayTitle, "构建")
        XCTAssertEqual(TerminalSession.distinctTitles(["docs · zsh", "repository · zsh", "docs · zsh"]),
                       ["docs · zsh", "repository · zsh", "docs · zsh 2"])
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-PTY-Test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func response(_ session: TerminalSession, command: String, marker: String) async throws -> String {
        let received = expectation(description: marker)
        var output = ""
        var fulfilled = false
        session.terminalView.outputObserver = { bytes in
            output += String(decoding: bytes, as: UTF8.self)
            if output.contains(marker), !fulfilled {
                fulfilled = true
                received.fulfill()
            }
        }
        session.terminalView.process.send(data: Array((command + "\r").utf8)[...])
        await fulfillment(of: [received], timeout: 4)
        session.terminalView.outputObserver = nil
        XCTAssertTrue(fulfilled, "PTY 输出为：\(output)")
        return output
    }
}
