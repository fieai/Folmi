import XCTest
@testable import FolmiCore

final class ProjectServicesTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-services-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func write(_ path: String, _ text: String) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testFindsAListeningProcessInASubfolderWithItsPortAndCommand() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let folder = base.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import socket,time\ns=socket.socket();s.bind(('127.0.0.1',0));s.listen()\nprint(s.getsockname()[1],flush=True)\ntime.sleep(30)"]
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try XCTUnwrap(Int(line))

        let services = ServiceScanner.scan(root: base)
        let service = try XCTUnwrap(services.first { $0.pid == process.processIdentifier })
        XCTAssertEqual(service.ports, [port])
        XCTAssertEqual(service.directory, "api")
        XCTAssertTrue(service.arguments.contains("-c"), "\(service.arguments)")
        XCTAssertTrue(service.ancestors.contains(getpid()))
        XCTAssertNotNil(service.startedAt)

        // A sibling folder that only shares a prefix is not inside the project.
        let other = URL(fileURLWithPath: base.path + "-other")
        XCTAssertFalse(ServiceScanner.scan(root: other).contains { $0.pid == process.processIdentifier })
    }

    func testFindsStartCommandsAcrossFolders() throws {
        try write("package.json", #"{"scripts":{"build":"vite build","dev":"vite --port 5173","test":"vitest"}}"#)
        try write("pnpm-lock.yaml", "")
        try write("apps/web/package.json", #"{"scripts":{"start":"next start","lint":"eslint"}}"#)
        try write("api/Makefile", "build:\n\tgo build\nrun:\n\tgo run .\n")
        try write("api/manage.py", "")
        try write("Procfile", "web: bundle exec puma -p 4000\n# comment\nworker: sidekiq\n")
        try write("docker-compose.yml", "services: {}\n")
        try write("node_modules/x/package.json", #"{"scripts":{"dev":"x"}}"#)
        try write(".claude/launch.json", #"{"configurations":[{"name":"site","runtimeExecutable":"python3","runtimeArgs":["-m","http.server","8765"],"port":8765}]}"#)

        let commands = LaunchCommandScanner.scan(root: base)
        let pairs = Set(commands.map { "\($0.directory)|\($0.command)" })
        XCTAssertTrue(pairs.contains("|pnpm run dev"), "\(pairs)")
        XCTAssertFalse(pairs.contains("|pnpm run build"))
        XCTAssertTrue(pairs.contains("apps/web|pnpm run start"), "the monorepo root's lock file decides the runner")
        XCTAssertTrue(pairs.contains("api|make run"))
        XCTAssertFalse(pairs.contains("api|make build"))
        XCTAssertTrue(pairs.contains("api|python3 manage.py runserver"))
        XCTAssertTrue(pairs.contains("|bundle exec puma -p 4000"))
        XCTAssertTrue(pairs.contains("|sidekiq"))
        XCTAssertTrue(pairs.contains("|docker compose up"))
        XCTAssertTrue(pairs.contains("|python3 -m http.server 8765"))
        XCTAssertFalse(commands.contains { $0.directory.hasPrefix("node_modules") })
        XCTAssertEqual(commands.first { $0.command == "pnpm run dev" }?.port, 5173)
        XCTAssertEqual(commands.first { $0.command.hasPrefix("bundle") }?.port, 4000)
    }

    func testReadsArgumentsAfterTheExecutablePathAndPadding() {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/usr/bin/node".utf8) + [0, 0, 0] + Array("node".utf8) + [0] + Array("server.js".utf8) + [0] + Array("PATH=/bin".utf8) + [0]
        XCTAssertEqual(ServiceScanner.parseArguments(buffer, argc: 2), ["node", "server.js"])
    }

    func testQuotesOnlyWordsThatNeedIt() {
        XCTAssertEqual(ShellQuote.quote("--port=3000"), "--port=3000")
        XCTAssertEqual(ShellQuote.quote("a b"), "'a b'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
    }

    func testMatchesStartCommandsTypedByHand() {
        let matches = LaunchCommandMatcher.matches
        XCTAssertTrue(matches(["node", "/opt/homebrew/bin/pnpm", "dev"], "pnpm run dev"), "run can be left out")
        XCTAssertTrue(matches(["/usr/local/bin/node", "/Users/me/Library/pnpm/pnpm.cjs", "run", "dev", "--host"], "pnpm run dev"))
        XCTAssertTrue(matches(["/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", "manage.py", "runserver"],
                              "python3 manage.py runserver"))
        XCTAssertTrue(matches(["make", "run"], "make run"))
        XCTAssertFalse(matches(["node", "/opt/homebrew/bin/pnpm", "run", "dev:debug"], "pnpm run dev"))
        XCTAssertFalse(matches(["node", "/x/vite.js", "--port", "5173"], "pnpm run dev"))
        XCTAssertFalse(matches(["sh", "-c", "pnpm run dev"], "pnpm run dev"), "the shell running a script line is not the command")
    }

    func testTracesAServiceToTheStartCommandThatBeganIt() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        try write("api/serve.py", "import socket,time\ns=socket.socket();s.bind(('127.0.0.1',0));s.listen()\nprint(s.getsockname()[1],flush=True)\ntime.sleep(30)\n")
        let before = Date().addingTimeInterval(-2)
        let process = Process()
        process.executableURL = python
        process.arguments = ["serve.py"]
        process.currentDirectoryURL = base.appendingPathComponent("api")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        _ = output.fileHandleForReading.availableData

        let service = try XCTUnwrap(ServiceScanner.scan(root: base).first { $0.pid == process.processIdentifier })
        let commands = [LaunchCommand(directory: "", name: "serve", command: "python3 serve.py", source: "x"),
                        LaunchCommand(directory: "api", name: "serve", command: "python3 serve.py", source: "x")]
        let origin = try XCTUnwrap(LaunchCommandMatcher.origin(of: service, root: base, commands: commands, since: before))
        XCTAssertEqual(origin.commandID, commands[1].id, "the folder has to match too")
        XCTAssertNil(LaunchCommandMatcher.origin(of: service, root: base, commands: commands, since: Date().addingTimeInterval(60)),
                     "a service started before Folmi was watching is not counted")
    }
}
