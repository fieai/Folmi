import FolmiCore
import Foundation

let usage = "用法：folmi [目录 | 文件[:行[:列]]]"
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

if arguments == ["-h"] || arguments == ["--help"] {
    print(usage)
    exit(0)
}
guard arguments.count <= 1 else { fail(usage, status: 2) }

do {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let link = try TerminalCommand.link(for: arguments.first ?? ".", from: directory)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var options: [String] = []
    if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
       executable.deletingLastPathComponent().lastPathComponent == "Helpers" {
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app" { options = ["-a", app.path] }
    }
    process.arguments = options + [link.absoluteString]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("没能打开 Folmi。请先把 Folmi.app 放到「应用程序」并打开一次。") }
} catch {
    fail(error.localizedDescription)
}
