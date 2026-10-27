import Foundation
import FolmiCore

// Called by Claude Code or Codex hooks (installed by Folmi): `folmi-hook prompt|pre|post|stop|guard`, hook JSON on
// stdin. `folmi-hook mcp` is the MCP server instead (see MCPServer). It records what the agent does so the app can show it and take a whole turn back. It never blocks the agent
// except `guard`, which refuses dangerous git commands (exit 2 tells Claude Code to stop the tool call), and `stop --check`,
// which keeps the turn going once when it left calls broken (see TurnCallCheck).

let mode = CommandLine.arguments.dropFirst().first ?? ""
if mode == "mcp" {
    // The installed helper sits in `<settings dir>/bin/`; app.json is in the settings dir.
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let installed = executable.deletingLastPathComponent().lastPathComponent == "bin"
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    MCPServer.runStdio(settingsDirectory: installed ? executable.deletingLastPathComponent().deletingLastPathComponent() : support?.appendingPathComponent("Folmi"))
    exit(0)
}
let input = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
let agent = CommandLine.arguments.contains("codex") ? "codex" : "claude"
let session = AIEventStore.safe((agent == "codex" ? "codex-" : "") + (json["session_id"] as? String ?? "session"))
let turn = (json["turn_id"] as? String).map { AIEventStore.safe($0) }
let cwd = URL(fileURLWithPath: json["cwd"] as? String ?? FileManager.default.currentDirectoryPath)
let toolInput = json["tool_input"] as? [String: Any] ?? [:]

if mode == "guard" {
    let command = toolInput["command"] as? String ?? ""
    let rules: [(String, String)] = [
        (#"\bgit\s+(?:-C\s+\S+\s+)?push\b"#, "git push"),
        (#"\bgit\s+(?:-C\s+\S+\s+)?reset\s+[^;&|]*--hard"#, "git reset --hard"),
        (#"\bgit\s+(?:-C\s+\S+\s+)?clean\s+[^;&|]*-[a-zA-Z]*f"#, "git clean -f"),
        (#"\bgit\s+(?:-C\s+\S+\s+)?branch\s+[^;&|]*-D\b"#, "git branch -D"),
        (#"\bgit\s+(?:-C\s+\S+\s+)?checkout\s+(?:--\s+)?\.(?:\s|$|;|&)"#, "git checkout ."),
        (#"\bgit\s+(?:-C\s+\S+\s+)?restore\s+(?:--\S+\s+)*\.(?:\s|$|;|&)"#, "git restore ."),
    ]
    for (pattern, name) in rules where command.range(of: pattern, options: .regularExpression) != nil {
        FileHandle.standardError.write(Data("已拦截：\(name) 需要用户在 Folmi或终端里亲自执行（Folmi guardrails）。\n".utf8))
        exit(2)
    }
    exit(0)
}

// A hook must never discover another repository via an agent-provided file path.
guard let repository = AIEventStore.locate(from: cwd) else { exit(0) }
let tool = json["tool_name"] as? String
let rawPaths: [String]
if tool == "apply_patch" {
    rawPaths = AIEventStore.patchPaths(toolInput["command"] as? String ?? "")
} else {
    rawPaths = (toolInput["file_path"] as? String ?? toolInput["notebook_path"] as? String).map { [$0] } ?? []
}
let paths = Array(Set(rawPaths.compactMap { AIEventStore.safeRelativePath($0, cwd: cwd, root: repository.root) })).sorted()
let manager = FileManager.default
let store = AIEventStore.directory(gitDir: repository.gitDir)
do { try manager.createDirectory(at: store, withIntermediateDirectories: true) } catch { exit(0) }
// Tool hooks can run concurrently. Serialize preimage checks/copies and current-turn bookkeeping.
let lock = open(store.appendingPathComponent("hook.lock").path, O_WRONLY | O_CREAT, 0o600)
guard lock >= 0 else { exit(0) }
guard flock(lock, LOCK_EX) == 0 else { close(lock); exit(0) }
defer { flock(lock, LOCK_UN); close(lock) }
func note(_ what: String, _ error: Error) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(what)：\(error.localizedDescription)\n"
    let descriptor = open(AIEventStore.errorLog(gitDir: repository.gitDir).path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    _ = Data(line.utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
}
let currentFile = store.appendingPathComponent("current-" + session)
let now = Date().timeIntervalSince1970
// Retain the full turn id separately from the session prefix; safe() caps each individual component.
let turnBatch = turn.map { "\(session)-\($0)" }
func append(_ event: AIEvent) {
    guard var line = try? JSONEncoder().encode(event) else { return }
    line.append(10)
    let descriptor = open(AIEventStore.events(gitDir: repository.gitDir).path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
}
func event(_ kind: AIEvent.Kind, batch: String, path: String? = nil, prompt: String? = nil) -> AIEvent {
    AIEvent(t: now, kind: kind, session: session, batch: batch, path: path, tool: tool, prompt: prompt, agent: agent)
}
func currentBatch() -> String {
    let current = try? String(contentsOf: currentFile, encoding: .utf8)
    if let current, !current.isEmpty, turnBatch == nil || current == turnBatch { return current }
    let batch = turnBatch ?? "\(session)-\(Int(now * 1000))"
    do { try batch.write(to: currentFile, atomically: true, encoding: .utf8) } catch { note("记录当前这一轮失败", error) }
    append(event(.start, batch: batch))
    return batch
}
switch mode {
case "prompt":
    let batch = turnBatch ?? "\(session)-\(Int(now * 1000))"
    do { try batch.write(to: currentFile, atomically: true, encoding: .utf8) } catch { note("记录新的一轮失败", error) }
    let prompt = (json["prompt"] as? String).map { String($0.split(separator: "\n").first ?? "").prefix(60) }.map(String.init)
    append(event(.start, batch: batch, prompt: prompt))
case "pre":
    let batch = currentBatch()
    let preFolder = AIEventStore.batch(batch, gitDir: repository.gitDir).appendingPathComponent("pre", isDirectory: true)
    do { try AIEventStore.prepareSnapshot(in: preFolder) }
    catch { note("旧快照格式不明确，这一轮不能继续保存整批撤回副本", error); break }
    for path in paths {
        let pre = AIEventStore.preImage(path, batch: batch, gitDir: repository.gitDir)
        let absent = AIEventStore.absentMarker(path, batch: batch, gitDir: repository.gitDir)
        // Keep the FIRST contents even when apply_patch touches a file several times in one turn.
        guard !manager.fileExists(atPath: pre.path), !manager.fileExists(atPath: absent.path) else { continue }
        let source = repository.root.appendingPathComponent(path)
        do {
            try manager.createDirectory(at: pre.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: source.path))?[.size] as? NSNumber {
                if size.intValue <= 32 * 1024 * 1024 { try manager.copyItem(at: source, to: pre) }
                else { note("没能保存 \(path) 改之前的内容，这个文件不能整批撤回", CocoaError(.fileReadTooLarge)) }
            } else {
                try manager.createDirectory(at: absent.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard manager.createFile(atPath: absent.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
        } catch { note("没能保存 \(path) 改之前的内容，这个文件不能整批撤回", error) }
    }
case "post":
    let batch = currentBatch()
    if paths.isEmpty { append(event(.edit, batch: batch)) }
    for path in paths { append(event(.edit, batch: batch, path: path)) }
case "stop":
    let batch = turnBatch ?? (try? String(contentsOf: currentFile, encoding: .utf8)) ?? "\(session)-\(Int(now * 1000))"
    // Once per turn: a turn already continued by a Stop hook ends normally. Codex's Interrupt runs `stop` too, never checked.
    if CommandLine.arguments.contains("--check"), json["hook_event_name"] as? String == "Stop", json["stop_hook_active"] as? Bool != true,
       let reason = TurnCallCheck.run(root: repository.root, gitDir: repository.gitDir, batch: batch),
       let data = try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": reason]) {
        // The turn goes on: no end snapshot or stop event yet, and the pointer stays, so the fixes join this turn.
        FileHandle.standardOutput.write(data)
        exit(0)
    }
    let post = AIEventStore.post(batch: batch, gitDir: repository.gitDir)
    let staging = post.deletingLastPathComponent().appendingPathComponent("post-\(ProcessInfo.processInfo.processIdentifier)")
    if manager.fileExists(atPath: post.deletingLastPathComponent().appendingPathComponent("pre").path), !manager.fileExists(atPath: post.path) {
        do {
            AIEventStore.removeSnapshot(staging)
            try AIEventStore.snapshotTouched(batch: batch, root: repository.root, gitDir: repository.gitDir, into: staging)
            try AIEventStore.publishSnapshot(from: staging, to: post)
        } catch { AIEventStore.removeSnapshot(staging); note("没能记下这一轮结束时的文件，这一轮不能整批撤回", error) }
    }
    append(event(.stop, batch: batch))
    // A delayed Stop must not erase a newer turn's pointer.
    if (try? String(contentsOf: currentFile, encoding: .utf8)) == batch { try? manager.removeItem(at: currentFile) }
default:
    break
}
exit(0)
