import Darwin
import Foundation
import XCTest
@testable import Folmi
@testable import FolmiCore

final class PTYIntegrationTests: XCTestCase {
    func testDetachedSessionReplaysAndCanBeKilled() throws {
        try withService { endpoint, helper in
            try Self.verifyDetachedSession(endpoint: endpoint) {
                let stream = try endpoint.connectOrLaunch(helper: helper)
                XCTAssertTrue(stream.peerSharesResourceCoalition)
                return stream
            }
        }
    }

    func testBackgroundApplicationUsesSeparateCoalitionAndReplays() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue(label: "Folmi.tests.terminal-application").async {
                continuation.resume(with: Result {
                    let fixture = try PTYTestFixture()
                    let endpoint = fixture.endpoint
                    var installed: URL?
                    defer { fixture.cleanUp(unregistering: installed) }
                    let helper = try fixture.makeApplication()
                    installed = try endpoint.install(helper)
                    try Self.verifyDetachedSession(endpoint: endpoint) {
                        let stream = try endpoint.connectOrLaunch(helper: helper, idleMilliseconds: 5_000,
                                                                  launchApplication: TerminalService.launchApplication)
                        let pid = try XCTUnwrap(stream.peerPID)
                        let ownCoalition = try XCTUnwrap(PTYProcess.resourceCoalition(of: getpid()))
                        let serviceCoalition = try XCTUnwrap(PTYProcess.resourceCoalition(of: pid))
                        XCTAssertNotEqual(serviceCoalition, ownCoalition)
                        return stream
                    }
                })
            }
        }
    }

    func testFailedApplicationLaunchFallsBackToSpawningBundledExecutable() throws {
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        let helper = try fixture.makeApplication()
        let stream = try fixture.endpoint.connectOrLaunch(helper: helper) { app, _, onFailure in
            XCTAssertEqual(app.pathExtension, "app")
            onFailure()
        }
        XCTAssertTrue(stream.peerSharesResourceCoalition)
        var peer = PTYPeer(stream)
        try peer.hello().requireCompatibility()
    }

    private static func verifyDetachedSession(endpoint: PTYEndpoint, connect: () throws -> PTYStream) throws {
        let id = UUID()
        let info: PTYProtocol.Session
        do {
            let stream = try connect()
            var peer = PTYPeer(stream)
            try peer.hello().requireCompatibility()
            info = try create(id, command: "printf hello; sleep 30", at: endpoint, peer: &peer)
            let servicePID = try XCTUnwrap(stream.peerPID)
            XCTAssertEqual(try XCTUnwrap(PTYProcess.resourceCoalition(of: info.shellPid)),
                           try XCTUnwrap(PTYProcess.resourceCoalition(of: servicePID)))
            try peer.send(.json(.attach, id))
            var output = try peer.receive(.replay).bytes().data
            while !String(decoding: output, as: UTF8.self).contains("hello") {
                output.append(try peer.receive(.output).bytes().data)
            }
            try peer.send(.json(.detach, id))
            // A reply on the same connection confirms detach was processed before the next attach.
            try peer.send(.init(.list))
            _ = try peer.receive(.sessions)
        }
        var resumed = PTYPeer(try XCTUnwrap(endpoint.connect()))
        try resumed.hello().requireCompatibility()
        try resumed.send(.init(.list))
        let listed = try resumed.receive(.sessions).decode([PTYProtocol.Session].self)
        XCTAssertEqual(listed.map(\.shellPid), [info.shellPid])
        try resumed.send(.json(.attach, id))
        let restored = try resumed.receive(.replay).bytes()
        XCTAssertEqual(restored.id, id)
        XCTAssertTrue(String(decoding: restored.data, as: UTF8.self).contains("hello"))
        try resumed.send(.json(.kill, id))
        XCTAssertEqual(try resumed.receive(.exited, timeout: .seconds(3)).decode(PTYProtocol.Exit.self).id, id)
    }

    func testNaturalExitPreservesOutputAndStatusAndNewAttachmentTakesOver() throws {
        try withService { endpoint, helper in
            var first = try Self.connect(endpoint, helper)
            var second = try Self.connect(endpoint, helper)
            let id = UUID()
            _ = try Self.create(id, command: "read line; printf 'result=%s' \"$line\"; exit 7", at: endpoint, peer: &first)
            try first.send(.json(.attach, id))
            _ = try first.receive(.replay)
            try second.send(.json(.attach, id))
            _ = try second.receive(.replay)
            XCTAssertEqual(try first.receive(.displaced).decode(UUID.self), id)
            try first.send(.bytes(.input, id: id, data: Data("stale\n".utf8)))
            try second.send(.json(.resize, PTYProtocol.Resize(id: id, cols: 100, rows: 32)))
            try second.send(.bytes(.input, id: id, data: Data("fresh\n".utf8)))
            var exit: PTYProtocol.Exit?
            for _ in 0..<8 where exit == nil {
                let next = try second.next()
                if next.kind == .exited { exit = try next.decode(PTYProtocol.Exit.self) }
            }
            XCTAssertEqual(exit?.exitCode, 7)

            var resumed = try Self.connect(endpoint, helper)
            try resumed.send(.json(.attach, id))
            let text = String(decoding: try resumed.receive(.replay).bytes().data, as: UTF8.self)
            XCTAssertTrue(text.contains("result=fresh"), text)
            XCTAssertFalse(text.contains("stale"), text)
            XCTAssertEqual(try resumed.receive(.exited).decode(PTYProtocol.Exit.self).exitCode, 7)
        }
    }

    func testVersionMismatchCannotListButCanShutDown() throws {
        try withService { endpoint, helper in
            var original = try Self.connect(endpoint, helper)
            _ = try Self.create(UUID(), command: "sleep 30", at: endpoint, peer: &original)
            var incompatible = PTYPeer(try XCTUnwrap(endpoint.connect()))
            let hello = try incompatible.hello(version: PTYProtocol.version + 1)
            XCTAssertEqual(hello.runningCount, 1)
            try incompatible.send(.init(.list))
            XCTAssertThrowsError(try incompatible.next(timeout: .milliseconds(100))) {
                XCTAssertEqual($0 as? PTYProtocol.Failure, .timeout)
            }
            try incompatible.send(.init(.shutdown))
            XCTAssertThrowsError(try incompatible.next(timeout: .seconds(3))) {
                XCTAssertEqual($0 as? PTYProtocol.Failure, .disconnected)
            }
        }
    }

    func testIdleHelperExitsAndReleasesSocketAndLock() throws {
        try withService { endpoint, helper in
            var peer: PTYPeer? = PTYPeer(try endpoint.connectOrLaunch(helper: helper, idleMilliseconds: 150))
            _ = try peer!.hello()
            XCTAssertNotNil(try endpoint.connect())
            peer = nil
            XCTAssertTrue(Self.waitForExit(endpoint))
        }
    }

    func testLongPathReplacesStaleLocatorAndUsesPrivatePermissions() throws {
        try withService { endpoint, helper in
            try endpoint.prepareRunDirectory()
            let name = URL(fileURLWithPath: endpoint.socketPath).lastPathComponent
            let stale = "/tmp/folmi-vanished-\(UUID().uuidString.prefix(8))/\(name)"
            try stale.write(to: endpoint.locator, atomically: true, encoding: .utf8)
            XCTAssertEqual(endpoint.socketPath, stale)

            var peer = try Self.connect(endpoint, helper)
            XCTAssertNotEqual(endpoint.socketPath, stale)
            XCTAssertEqual(try String(contentsOf: endpoint.locator, encoding: .utf8), endpoint.socketPath)
            for (path, mode) in [(endpoint.runDirectory.path, 0o700), (endpoint.socketPath, 0o600)] {
                var info = stat()
                XCTAssertEqual(lstat(path, &info), 0)
                XCTAssertEqual(Int(info.st_mode) & 0o777, mode)
            }
            try peer.send(.init(.list))
            XCTAssertTrue(try peer.receive(.sessions).decode([PTYProtocol.Session].self).isEmpty)
        }
    }

    func testKillEscalatesForJobsThatIgnoreHangup() throws {
        try withService { endpoint, helper in
            var peer = try Self.connect(endpoint, helper)
            let id = UUID()
            let command = #"""
                use POSIX;
                $SIG{HUP} = 'IGNORE';
                my $job = fork();
                die $! unless defined $job;
                if ($job == 0) {
                    POSIX::setpgid(0, 0) == 0 or die $!;
                    open my $ready, ">", "job.pid" or die $!;
                    print $ready $$;
                    close $ready;
                }
                while (1) { sleep 1; }
                """#
            let info = try Self.create(id, argv: ["/usr/bin/perl", "-e", command], at: endpoint, peer: &peer)
            let file = endpoint.runDirectory.deletingLastPathComponent().appendingPathComponent("job.pid")
            var jobContents: String?
            for _ in 0..<40 where jobContents?.isEmpty != false {
                jobContents = try? String(contentsOf: file, encoding: .utf8)
                if jobContents?.isEmpty != false { usleep(25_000) }
            }
            let job = try XCTUnwrap(pid_t(try XCTUnwrap(jobContents).trimmingCharacters(in: .whitespacesAndNewlines)))
            var program: String?
            for _ in 0..<30 where program != "perl" {
                try peer.send(.init(.list))
                let sessions = try peer.receive(.sessions).decode([PTYProtocol.Session].self)
                program = sessions.first?.runningProgram
                if program != "perl" { usleep(10_000) }
            }
            XCTAssertEqual(program, "perl")

            var closer = try Self.connect(endpoint, helper)
            let start = ContinuousClock.now
            try closer.send(.json(.kill, id))
            let exit = try closer.receive(.exited, timeout: .seconds(4)).decode(PTYProtocol.Exit.self)
            XCTAssertEqual(exit.exitCode, 128 + SIGKILL)
            XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(2))
            XCTAssertEqual(kill(info.shellPid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            for _ in 0..<40 where kill(job, 0) == 0 { usleep(25_000) }
            XCTAssertEqual(kill(job, 0), -1)
        }
    }

    func testReplayAndSessionCountAreBounded() throws {
        try withService { endpoint, helper in
            var peer = try Self.connect(endpoint, helper)
            let id = UUID()
            let command = "printf EARLY; head -c 1100000 /dev/zero | tr '\\000' A; printf LATE"
            _ = try Self.create(id, command: command, at: endpoint, peer: &peer)
            let deadline = ContinuousClock.now + .seconds(3)
            var finished = false
            repeat {
                try peer.send(.init(.list))
                let sessions = try peer.receive(.sessions).decode([PTYProtocol.Session].self)
                finished = sessions.first?.hasExited == true
                if !finished { usleep(20_000) }
            } while !finished && ContinuousClock.now < deadline
            XCTAssertTrue(finished)

            try peer.send(.json(.attach, id))
            let replay = try peer.receive(.replay, timeout: .seconds(2)).bytes().data
            XCTAssertEqual(replay.count, PTYProtocol.replayLimit)
            XCTAssertEqual(replay.first, UInt8(ascii: "A"))
            XCTAssertTrue(replay.suffix(4).elementsEqual(Data("LATE".utf8)))
            _ = try peer.receive(.exited)
            for _ in 1..<PTYProtocol.sessionLimit {
                _ = try Self.create(UUID(), command: "exit 0", at: endpoint, peer: &peer)
            }
            let next = UUID()
            XCTAssertThrowsError(try Self.create(next, command: "exit 0", at: endpoint, peer: &peer)) {
                guard case PTYProtocol.Failure.service(let message) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(message.contains("先关掉一些终端"))
            }
            try peer.send(.json(.kill, id))
            _ = try peer.receive(.exited)
            _ = try Self.create(next, command: "exit 0", at: endpoint, peer: &peer)
        }
    }

    func testAttachNotifiesBothSizesAndLaterResizeReachesTheProgram() throws {
        try withService { endpoint, helper in
            var peer = try Self.connect(endpoint, helper)
            let id = UUID()
            let command = #"""
                $|=1;
                $SIG{WINCH}=sub { system("stty size"); };
                open my $ready, ">", "winch.ready" or die $!;
                close $ready;
                while (1) { sleep 1; }
                """#
            _ = try Self.create(id, argv: ["/usr/bin/perl", "-e", command], at: endpoint, peer: &peer)
            let ready = endpoint.runDirectory.deletingLastPathComponent().appendingPathComponent("winch.ready").path
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: ready) { usleep(20_000) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready))
            try peer.send(.json(.attach, id))
            _ = try peer.receive(.replay)

            var recordedSizes = ""
            for _ in 0..<6 where !recordedSizes.contains("24 80") {
                recordedSizes += String(decoding: try peer.receive(.output).bytes().data, as: UTF8.self)
            }
            XCTAssertTrue(recordedSizes.contains("23 80"), recordedSizes)
            XCTAssertTrue(recordedSizes.contains("24 80"), recordedSizes)
            try peer.send(.json(.resize, PTYProtocol.Resize(id: id, cols: 107, rows: 34)))
            for _ in 0..<6 where !recordedSizes.contains("34 107") {
                recordedSizes += String(decoding: try peer.receive(.output).bytes().data, as: UTF8.self)
            }
            XCTAssertTrue(recordedSizes.contains("34 107"), recordedSizes)
        }
    }

    private static func connect(_ endpoint: PTYEndpoint, _ helper: URL) throws -> PTYPeer {
        var peer = PTYPeer(try endpoint.connectOrLaunch(helper: helper))
        try peer.hello().requireCompatibility()
        return peer
    }

    private static func create(_ id: UUID, command: String, at endpoint: PTYEndpoint, peer: inout PTYPeer) throws -> PTYProtocol.Session {
        try create(id, argv: ["/bin/sh", "-c", command], at: endpoint, peer: &peer)
    }

    private static func create(_ id: UUID, argv: [String], at endpoint: PTYEndpoint, peer: inout PTYPeer) throws -> PTYProtocol.Session {
        let cwd = endpoint.runDirectory.deletingLastPathComponent().path
        try peer.send(.json(.create, PTYProtocol.Create(id: id, projectRoot: cwd, cwd: cwd,
                                                       env: ["PATH": "/usr/bin:/bin", "ZDOTDIR": cwd], argv: argv,
                                                       cols: 80, rows: 24)))
        return try peer.receive(.created).decode(PTYProtocol.Session.self)
    }

    private func withService(_ body: (PTYEndpoint, URL) throws -> Void) throws {
        let fixture = try PTYTestFixture()
        defer { fixture.cleanUp() }
        try body(fixture.endpoint, fixture.helper)
    }

    fileprivate static func waitForExit(_ endpoint: PTYEndpoint) -> Bool {
        let lock = endpoint.runDirectory.appendingPathComponent("pty.lock").path
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            let fd = Darwin.open(lock, O_RDONLY | O_CLOEXEC)
            if fd < 0 { return errno == ENOENT }
            let stopped = flock(fd, LOCK_EX | LOCK_NB) == 0
            close(fd)
            if stopped { return true }
            usleep(20_000)
        } while ContinuousClock.now < deadline
        return false
    }
}

struct PTYTestFixture {
    let settings: URL
    let helper: URL
    var endpoint: PTYEndpoint { PTYEndpoint(settingsDirectory: settings) }

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let parent = environment["FOLMI_PTY_TEST_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        // A long settings path exercises the locator on systems with short custom TMPDIR values too.
        settings = parent.appendingPathComponent("folmi-pty-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(String(repeating: "settings", count: 14), isDirectory: true)
        let bundle = Bundle(for: PTYIntegrationTests.self).bundleURL
        helper = bundle.deletingLastPathComponent().appendingPathComponent("folmi-pty")
        _ = try XCTUnwrap(FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil,
                          "找不到测试构建的 folmi-pty：\(helper.path)")
    }

    func makeApplication() throws -> URL {
        let app = settings.appendingPathComponent("FolmiTerminal.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/folmi-pty")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: helper, to: executable)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "folmi-pty",
            "CFBundleIdentifier": "local.folmi.pty-tests.\(UUID().uuidString).terminal",
            "CFBundleName": "Folmi 测试 终端",
            "CFBundleDisplayName": "Folmi 测试 终端",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "100",
            "LSMinimumSystemVersion": "14.0",
            "LSBackgroundOnly": true
        ], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "--force", app.path]
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw PTYProtocol.Failure.service("测试后台 App 签名失败") }
        return app
    }

    func cleanUp(unregistering application: URL? = nil) {
        do {
            if let stream = try endpoint.connect() {
                var peer = PTYPeer(stream)
                _ = try peer.hello()
                try peer.send(.init(.shutdown))
            }
            XCTAssertTrue(PTYIntegrationTests.waitForExit(endpoint), "测试结束后 folmi-pty 仍在运行")
        } catch {
            XCTFail("无法清理测试后台终端：\(error)")
        }
        if let application {
            do {
                let unregister = Process()
                unregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
                unregister.arguments = ["-u", application.path]
                try unregister.run()
                unregister.waitUntilExit()
                XCTAssertEqual(unregister.terminationStatus, 0)
            } catch {
                XCTFail("无法注销测试后台 App：\(error)")
            }
        }
        try? FileManager.default.removeItem(at: settings.deletingLastPathComponent())
    }
}
