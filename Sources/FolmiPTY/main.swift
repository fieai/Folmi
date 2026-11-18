import Darwin
import FolmiCore
import FolmiPTYSpawn
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4, arguments[1] == "serve", arguments[2] == "--socket" else { exit(64) }
let socketPath = arguments[3]
var settings: [String: String] = [:]
let options = Array(arguments.dropFirst(4))
guard options.count % 2 == 0 else { exit(64) }
for index in stride(from: 0, to: options.count, by: 2) {
    let key = options[index]
    guard key == "--run-directory" || key == "--idle-ms", settings[key] == nil else { exit(64) }
    settings[key] = options[index + 1]
}
guard let idleMilliseconds = Int(settings["--idle-ms"] ?? "10000"), (1...10_000).contains(idleMilliseconds) else { exit(64) }
let previousMask = umask(0o077)
let runDirectory = settings["--run-directory"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: socketPath).deletingLastPathComponent()
let lock = open(runDirectory.appendingPathComponent("pty.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }

do {
    let server = try PTYServer(socketPath: socketPath, runDirectory: runDirectory, idleMilliseconds: idleMilliseconds)
    log("后台终端服务已启动", in: runDirectory)
    umask(previousMask)
    folmi_install_pty_shutdown_handler()
    try server.run()
} catch {
    log(error.localizedDescription, in: runDirectory)
    exit(1)
}

func log(_ message: String, in runDirectory: URL) {
    // Never copy shell output into this file. It is only for helper diagnostics.
    let path = runDirectory.appendingPathComponent("pty.log").path
    let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    let bytes = Data("\(Date()): \(message)\n".utf8.prefix(1_024))
    let end = lseek(descriptor, 0, SEEK_END)
    if end < 0 || end + off_t(bytes.count) > 1_024 * 1_024 {
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else { return }
    }
    _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
}
