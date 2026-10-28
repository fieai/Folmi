import Darwin
import Foundation

/// A process of the user's that listens on TCP ports and works inside the project (its current directory is the
/// project root or a folder in it): a dev server, an API, a database started from the project.
public struct RunningService: Hashable, Sendable, Identifiable {
    public var pid: Int32
    public var ports: [Int]
    /// The program's short name (node, python3, java).
    public var name: String
    /// The full command line, as the process was started.
    public var arguments: [String]
    /// The process's working directory, relative to the project ("" for the root).
    public var directory: String
    public var startedAt: Date?
    /// Parent, grandparent… up to launchd, so a service can be traced to the terminal tab that started it.
    public var ancestors: [Int32]
    public var id: Int32 { pid }

    public init(pid: Int32, ports: [Int], name: String, arguments: [String], directory: String, startedAt: Date?, ancestors: [Int32]) {
        self.pid = pid
        self.ports = ports
        self.name = name
        self.arguments = arguments
        self.directory = directory
        self.startedAt = startedAt
        self.ancestors = ancestors
    }

    /// The command line as it could be typed again; long paths in it are kept as they are.
    public var commandLine: String { arguments.isEmpty ? name : arguments.map(ShellQuote.quote).joined(separator: " ") }
}

public enum ShellQuote {
    /// Leaves plain words alone and single-quotes the rest, so the result pastes back into zsh.
    public static func quote(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Finds listening services with libproc rather than `lsof`: no subprocess, a few milliseconds, so the toolbar can
/// keep it current. Only the user's own processes are readable, which is also all that could be stopped from here.
public enum ServiceScanner {
    public static func scan(root: URL) -> [RunningService] {
        let rootPath = realPath(root.path)
        guard !rootPath.isEmpty, rootPath != "/" else { return [] }
        var services: [RunningService] = []
        for pid in allPIDs() where pid > 1 {
            // The working directory is checked first: it is one call, and rules out nearly every process.
            guard let cwd = workingDirectory(pid), cwd == rootPath || cwd.hasPrefix(rootPath + "/") else { continue }
            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { continue }
            let info = bsdInfo(pid)
            services.append(RunningService(
                pid: pid, ports: ports, name: processName(pid), arguments: arguments(pid),
                directory: cwd == rootPath ? "" : String(cwd.dropFirst(rootPath.count + 1)),
                startedAt: info.map { Date(timeIntervalSince1970: TimeInterval($0.pbi_start_tvsec)) },
                ancestors: ancestors(of: pid)))
        }
        return services.sorted { ($0.ports.first ?? 0, $0.pid) < ($1.ports.first ?? 0, $1.pid) }
    }

    public static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// A process's command line, working directory and start, for telling which start command began a service.
    public struct Details: Sendable, Equatable {
        public var pid: Int32
        public var arguments: [String]
        public var directory: String?
        public var startedAt: Date?
    }

    public static func details(_ pid: Int32) -> Details? {
        guard let info = bsdInfo(pid) else { return nil }
        return Details(pid: pid, arguments: arguments(pid), directory: workingDirectory(pid),
                       startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
    }

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static func listeningPorts(_ pid: Int32) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var ports: Set<Int> = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "进程 \(pid)"
    }

    static func ancestors(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while chain.count < 24, let info = bsdInfo(current) {
            let parent = Int32(bitPattern: info.pbi_ppid)
            guard parent > 1, !chain.contains(parent) else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// argv from KERN_PROCARGS2: argc, the executable path, padding, then the arguments.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        return parseArguments(Array(buffer.prefix(size)), argc: Int(argc))
    }

    static func parseArguments(_ buffer: [UInt8], argc: Int) -> [String] {
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }   // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }   // padding
        var result: [String] = []
        while result.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}

/// A way to start the project (or a part of it) found in its files: package.json scripts, Makefile targets,
/// Procfile, docker compose, .claude/launch.json… or one the user added.
public struct LaunchCommand: Hashable, Sendable, Identifiable, Codable {
    /// Where it runs, relative to the project ("" for the root).
    public var directory: String
    /// A short name (dev, start, web).
    public var name: String
    public var command: String
    /// Where it was found (package.json, Makefile); "自己加的" for one the user added.
    public var source: String
    /// The port it says it uses, when the files say so.
    public var port: Int?
    public var id: String { directory + "\u{1f}" + command }

    public init(directory: String, name: String, command: String, source: String, port: Int? = nil) {
        self.directory = directory
        self.name = name
        self.command = command
        self.source = source
        self.port = port
    }

    public static let customSource = "自己加的"
}

public enum LaunchCommandScanner {
    static let skipped: Set<String> = ["node_modules", "dist", "build", "out", "target", "vendor", "Pods", "coverage",
                                       "DerivedData", "bower_components", "venv", "env", "__pycache__", "tmp", "logs"]
    /// Script names that start something long-running; build, test and lint scripts are left out.
    static let scriptPattern = try! NSRegularExpression(pattern: "^(dev|start|serve|server|preview|watch|storybook|web|api|app)([:_-].*)?$")

    /// Looks at the root and folders up to `depth` levels below it, at most `limit` folders, so a large monorepo stays quick.
    public static func scan(root: URL, depth: Int = 3, limit: Int = 1_500) -> [LaunchCommand] {
        let fm = FileManager.default
        var found: [LaunchCommand] = []
        var queue: [(String, Int)] = [("", 0)]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let (relative, level) = queue.removeFirst()
            visited += 1
            let folder = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            let files = Set(names)
            found += commands(in: folder, relative: relative, files: files, root: root)
            guard level < depth else { continue }
            for name in names.sorted() where !name.hasPrefix(".") && !skipped.contains(name) {
                var isDirectory: ObjCBool = false
                let child = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue,
                      (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                queue.append((relative.isEmpty ? name : relative + "/" + name, level + 1))
            }
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.id).inserted }
    }

    static func commands(in folder: URL, relative: String, files: Set<String>, root: URL) -> [LaunchCommand] {
        var result: [LaunchCommand] = []
        func add(_ name: String, _ command: String, _ source: String, port: Int? = nil) {
            result.append(LaunchCommand(directory: relative, name: name, command: command, source: source, port: port))
        }
        if relative.isEmpty { result += launchConfigurations(root: root) }
        if files.contains("package.json"), let json = readJSON(folder.appendingPathComponent("package.json")),
           let scripts = json["scripts"] as? [String: String] {
            let runner = packageRunner(json: json, folder: folder, root: root)
            for name in scripts.keys.sorted(by: scriptOrder) where matches(name) {
                add(name, "\(runner) \(name)", "package.json", port: guessPort(scripts[name] ?? ""))
            }
        }
        for file in ["deno.json", "deno.jsonc"] where files.contains(file) {
            if let tasks = readJSON(folder.appendingPathComponent(file))?["tasks"] as? [String: String] {
                for name in tasks.keys.sorted(by: scriptOrder) where matches(name) {
                    add(name, "deno task \(name)", file, port: guessPort(tasks[name] ?? ""))
                }
            }
        }
        if files.contains("Makefile"), let text = try? String(contentsOf: folder.appendingPathComponent("Makefile"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(" ") else { continue }
                let target = String(line[..<colon])
                if ["dev", "run", "serve", "server", "start", "up", "watch"].contains(target) { add(target, "make \(target)", "Makefile") }
            }
        }
        for file in ["Procfile.dev", "Procfile"] where files.contains(file) {
            if file == "Procfile.dev", files.contains("bin") { add("dev", "bin/dev", file) }
            guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let command = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !command.isEmpty, !name.contains(" ") { add(name, command, file, port: guessPort(command)) }
            }
        }
        if !files.isDisjoint(with: ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]) {
            add("compose", "docker compose up", "docker compose")
        }
        if files.contains("manage.py") { add("runserver", "python3 manage.py runserver", "manage.py", port: 8000) }
        if files.contains("Cargo.toml"), FileManager.default.fileExists(atPath: folder.appendingPathComponent("src/main.rs").path) {
            add("run", "cargo run", "Cargo.toml")
        }
        if files.contains("go.mod"), files.contains("main.go") { add("run", "go run .", "go.mod") }
        if files.contains("Gemfile"), FileManager.default.fileExists(atPath: folder.appendingPathComponent("bin/rails").path) {
            add("server", "bin/rails server", "Rails", port: 3000)
        }
        return result
    }

    /// .claude/launch.json, which Claude Code's preview also reads.
    static func launchConfigurations(root: URL) -> [LaunchCommand] {
        guard let json = readJSON(root.appendingPathComponent(".claude/launch.json")),
              let configurations = json["configurations"] as? [[String: Any]] else { return [] }
        return configurations.compactMap { item in
            guard let executable = item["runtimeExecutable"] as? String, !executable.isEmpty else { return nil }
            let arguments = item["runtimeArgs"] as? [String] ?? []
            let command = ([executable] + arguments).map(ShellQuote.quote).joined(separator: " ")
            var directory = (item["cwd"] as? String ?? "").replacingOccurrences(of: "${workspaceFolder}", with: "")
            while directory.hasPrefix("/") || directory.hasPrefix("./") { directory.removeFirst(directory.hasPrefix("/") ? 1 : 2) }
            if directory.split(separator: "/").contains("..") { directory = "" }
            return LaunchCommand(directory: directory, name: item["name"] as? String ?? executable, command: command,
                                 source: ".claude/launch.json", port: item["port"] as? Int)
        }
    }

    /// npm, pnpm, yarn or bun: from `packageManager`, else the lock file here or in a folder above (a monorepo's root).
    static func packageRunner(json: [String: Any], folder: URL, root: URL) -> String {
        if let manager = (json["packageManager"] as? String)?.split(separator: "@").first {
            switch manager { case "pnpm": return "pnpm run"; case "yarn": return "yarn"; case "bun": return "bun run"; default: break }
        }
        var current = folder.standardizedFileURL
        let top = root.standardizedFileURL.path
        while true {
            let fm = FileManager.default
            if fm.fileExists(atPath: current.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm run" }
            if fm.fileExists(atPath: current.appendingPathComponent("yarn.lock").path) { return "yarn" }
            if fm.fileExists(atPath: current.appendingPathComponent("bun.lockb").path)
                || fm.fileExists(atPath: current.appendingPathComponent("bun.lock").path) { return "bun run" }
            if current.path == top || !current.path.hasPrefix(top) { return "npm run" }
            current.deleteLastPathComponent()
        }
    }

    static func matches(_ name: String) -> Bool {
        scriptPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func scriptOrder(_ a: String, _ b: String) -> Bool {
        let order = ["dev", "start", "serve", "server", "preview", "watch", "storybook"]
        let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
        return ia != ib ? ia < ib : a < b
    }

    static let portPattern = try! NSRegularExpression(pattern: "(?:--port[= ]|-p |PORT=|localhost:|0\\.0\\.0\\.0:)(\\d{2,5})")
    public static func guessPort(_ text: String) -> Int? {
        guard let match = portPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let port = Int(text[range]), port < 65_536 else { return nil }
        return port
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Tells whether a process's command line is a start command typed by hand: `pnpm dev` runs as
/// `node /…/pnpm dev`, `python3 manage.py runserver` as `/…/Python manage.py runserver`.
public enum LaunchCommandMatcher {
    static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl", "sh", "bash", "zsh"]
    /// Runners where `run` can be left out (`pnpm dev` is `pnpm run dev`).
    static let runners: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    public struct Origin: Sendable, Equatable {
        public var commandID: String
        /// The process the command runs as, `pid@start`, so one start is counted once however many ports it opens.
        public var process: String
    }

    /// Which start command began the service: the service itself or a process above it, working in the command's
    /// folder, whose command line is that command. Only starts after `since` count (the ones Folmi saw happen).
    public static func origin(of service: RunningService, root: URL, commands: [LaunchCommand], since: Date) -> Origin? {
        let rootPath = ServiceScanner.realPath(root.path)
        for pid in [service.pid] + service.ancestors {
            guard let details = ServiceScanner.details(pid), let directory = details.directory,
                  directory == rootPath || directory.hasPrefix(rootPath + "/") else { continue }
            let relative = directory == rootPath ? "" : String(directory.dropFirst(rootPath.count + 1))
            guard let command = commands.first(where: { $0.directory == relative && matches(arguments: details.arguments, command: $0.command) })
            else { continue }
            guard let started = details.startedAt, started >= since.addingTimeInterval(-1) else { return nil }
            return Origin(commandID: command.id, process: "\(pid)@\(Int(started.timeIntervalSince1970))")
        }
        return nil
    }

    /// The process's words start with the command's (extra flags typed after it still count).
    public static func matches(arguments: [String], command: String) -> Bool {
        let commandWords = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !commandWords.isEmpty, !arguments.isEmpty else { return false }
        for wanted in variants(commandWords) {
            for actual in variants(arguments) where actual.count >= wanted.count && Array(actual.prefix(wanted.count)) == wanted {
                return true
            }
        }
        return false
    }

    static func variants(_ words: [String]) -> [[String]] {
        var result = [normalized(words)]
        if words.count > 1, interpreters.contains(program(words[0])), !words[1].hasPrefix("-") {
            result.append(normalized(Array(words.dropFirst())))
        }
        return result
    }

    static func normalized(_ words: [String]) -> [String] {
        guard let first = words.first else { return [] }
        var result = [program(first)] + words.dropFirst()
        if runners.contains(result[0]), result.count > 2, result[1] == "run" { result.remove(at: 1) }
        return result
    }

    /// `/opt/homebrew/bin/pnpm.cjs` → `pnpm`, `Python` / `python3.12` → `python3`.
    static func program(_ word: String) -> String {
        var name = (word as NSString).lastPathComponent.lowercased()
        for ext in [".cjs", ".mjs", ".js"] where name.hasSuffix(ext) { name.removeLast(ext.count) }
        if name == "python" || name.hasPrefix("python3") { return "python3" }
        return name
    }
}
