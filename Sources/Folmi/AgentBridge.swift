import AppKit
import Foundation
import FolmiCore
import SwiftUI

/// The app's half of `folmi-hook mcp`: it writes the review state the MCP server reads, takes in the agent's
/// "dealt with it" replies, and opens `folmi://` links.
extension FolmiModel {
    /// Writes comments, review status and app.json a moment after they change (several changes, one write).
    func schedulePublishShared() {
        guard autoRefresh else { return }
        sharedPublishTask?.cancel()
        sharedPublishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.publishShared()
        }
    }

    func publishShared() {
        let state = SharedAppState(bundleID: Bundle.main.bundleIdentifier, appPath: Bundle.main.bundlePath, repository: repositoryURL?.path)
        AppLog.attempt("写 app.json") { try FolmiShared.write(state, to: FolmiShared.appState(settingsDirectory: AppFiles.directory)) }
        guard let snapshot, let gitDir = aiGitDir else { return }
        let comments = currentReviewComments.map {
            SharedComment(id: $0.id.uuidString, path: $0.path, firstLine: $0.firstLine, lastLine: $0.lastLine, excerpt: $0.excerpt,
                          body: $0.body, outdated: $0.outdated)
        }
        let files = snapshot.files.map {
            SharedReviewStatus.File(path: $0.path, staged: $0.hasStaged, working: $0.hasWorking && !$0.isUntracked, untracked: $0.isUntracked)
        }
        let latest = aiBatches.last(where: { !$0.paths.isEmpty }).map { SharedReviewStatus.Batch(id: $0.id, prompt: $0.prompt, paths: $0.paths, finished: $0.stopped != nil) }
        let status = SharedReviewStatus(branch: snapshot.branch, files: files, remaining: allChanges.isEmpty ? nil : reviewTally.remaining,
                                        latestBatch: latest)
        let commentsURL = FolmiShared.comments(gitDir: gitDir), statusURL = FolmiShared.status(gitDir: gitDir)
        // An empty list needs no file in a repository that never had notes.
        if !comments.isEmpty || FileManager.default.fileExists(atPath: commentsURL.path) {
            AppLog.attempt("写 comments.json") { try FolmiShared.write(comments, to: commentsURL) }
        }
        AppLog.attempt("写 review-status.json") { try FolmiShared.write(status, to: statusURL) }
    }

    /// The agent's replies (`mark_comment_addressed`) shown on their notes. Read when the file changed.
    func readCommentReplies() {
        guard let root = repositoryURL, let gitDir = aiGitDir else { return }
        let url = FolmiShared.replies(gitDir: gitDir)
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])).map { "\($0.contentModificationDate?.timeIntervalSince1970 ?? 0)-\($0.fileSize ?? 0)" }
        guard stamp != commentReplyStamps[root.path] else { return }
        commentReplyStamps[root.path] = stamp
        let replies = Dictionary(FolmiShared.lines(CommentReply.self, from: url).map { ($0.id, $0.note) }, uniquingKeysWith: { _, last in last })
        guard !replies.isEmpty else { return }
        let next = reviewComments.map { comment -> ReviewComment in
            guard comment.projectPath == root.path, let note = replies[comment.id.uuidString], comment.addressed != note else { return comment }
            var updated = comment
            updated.addressed = note
            return updated
        }
        if next != reviewComments { reviewComments = next }
    }

    /// `folmi://open?repo=…&path=…&line=…`: switches to that project when needed, then shows the place.
    func handleFolmiLink(_ url: URL) {
        guard let link = MCPServer.parse(url) else { return }
        guard !gitStartupState.blocksGit else { pendingFolmiLink = url; return }
        NSApp?.activate(ignoringOtherApps: true)
        let target = URL(fileURLWithPath: link.repository).resolvingSymlinksInPath().path
        if repositoryURL?.resolvingSymlinksInPath().path == target {
            if let path = link.path { revealLinked(path: path, line: link.line) }
            return
        }
        guard AIEventStore.locate(from: URL(fileURLWithPath: link.repository)) != nil else {
            report(FolmiFailure(message: "不是 Git 仓库：\(link.repository)"), title: "打开链接失败"); return
        }
        if let project = projects.first(where: { URL(fileURLWithPath: $0.rootPath).resolvingSymlinksInPath().path == target }) {
            switchProject(project.rootPath)
        } else {
            open(URL(fileURLWithPath: link.repository))
        }
        guard let path = link.path else { return }
        Task { [weak self] in
            // The project loads in the background; the place is shown once it is in front.
            for _ in 0..<150 {
                guard let self else { return }
                if !self.busy, self.repositoryURL?.resolvingSymlinksInPath().path == target, self.snapshot != nil {
                    self.revealLinked(path: path, line: link.line); return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// A changed file opens its diff (that is what to check); any other file opens in the editor at the line.
    func revealLinked(path: String, line: Int?) {
        guard !busy else { NSSound.beep(); return }
        if let change = snapshot?.files.first(where: { $0.path == path }) {
            area = change.hasWorking ? .working : .staged
            selectFile(change)
            focusPane(.editor)
            return
        }
        guard let editor = editorWorkspace else { return }
        do {
            try editor.reveal(path: path, line: line)
            content = .editor
            focusPane(.editor)
        } catch { report(error, title: "打开文件失败") }
    }
}

/// Registers `folmi-hook mcp` with the agents. Each one keeps its MCP list in its own place.
enum MCPInstaller {
    enum Client: String, CaseIterable, Identifiable {
        case claudeCode, claudeApp, codex
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claudeCode: return "Claude Code（终端）"
            case .claudeApp: return "Claude 桌面 App"
            case .codex: return "Codex（命令行和桌面 App）"
            }
        }
        /// The file that holds the registration, shown before anything is written.
        var configFile: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode: return home.appendingPathComponent(".claude.json")
            case .claudeApp: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            case .codex: return home.appendingPathComponent(".codex/config.toml")
            }
        }
    }

    static var helper: URL { HooksInstaller.installedHelper }

    static func snippet(_ client: Client, helper: URL = helper) -> String {
        switch client {
        case .claudeCode:
            return "claude mcp add --scope user \(MCPServer.name) -- '\(helper.path)' mcp"
        case .claudeApp:
            return """
            "mcpServers": {
              "\(MCPServer.name)": { "command": "\(helper.path)", "args": ["mcp"] }
            }
            """
        case .codex:
            return codexBlock(helper)
        }
    }
    static func codexBlock(_ helper: URL) -> String {
        "[mcp_servers.\(MCPServer.name)]\ncommand = \"\(tomlEscaped(helper.path))\"\nargs = [\"mcp\"]\n"
    }
    private static func tomlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func owns(_ server: Any?) -> Bool {
        guard let server = server as? [String: Any], let command = server["command"] as? String,
              server["args"] as? [String] == ["mcp"] else { return false }
        return URL(fileURLWithPath: command).lastPathComponent == "folmi-hook"
    }

    /// Only the known helper registration is ours; an unrelated server with the same name stays untouched.
    private static func jsonRegistration(_ object: [String: Any], helper: URL) throws -> [String: Any] {
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers[MCPServer.name], !owns(existing) {
            throw FolmiFailure(message: "已有自定义的 \(MCPServer.name) MCP 服务，没有覆盖它。")
        }
        var server = (servers[MCPServer.name] as? [String: Any]) ?? [:]
        server["command"] = helper.path; server["args"] = ["mcp"]
        servers[MCPServer.name] = server
        var next = object; next["mcpServers"] = servers
        return next
    }

    /// Recognize only simple helper tables that we generate, keeping all unrelated TOML bytes.
    static func codexRegistration(_ text: String, helper: URL) throws -> String {
        let lines = text.components(separatedBy: "\n")
        func header(_ line: String) -> String? {
            let value = line.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
            return String(value.dropFirst().dropLast())
        }
        func tableName(_ value: String, name: String) -> Bool {
            ["mcp_servers.\(name)", "mcp_servers.\"\(name)\"", "mcp_servers.'\(name)'"].contains(value)
        }
        let starts = lines.indices.filter { header(lines[$0]) != nil }
        let sections = starts.enumerated().map { (index, start) in start..<(index + 1 < starts.count ? starts[index + 1] : lines.count) }
        func section(_ name: String) -> Range<Int>? { sections.first { tableName(header(lines[$0.lowerBound]) ?? "", name: name) } }
        func commandLine(_ range: Range<Int>) -> (Int, String)? {
            for index in range.dropFirst() {
                let line = lines[index]
                guard let match = line.range(of: #"^\s*command\s*=\s*("(?:\\.|[^"\\])*"|'[^']*')\s*(?:#.*)?$"#, options: .regularExpression), match == line.startIndex..<line.endIndex,
                      let equals = line.firstIndex(of: "=") else { continue }
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("'"), let end = value.dropFirst().firstIndex(of: "'") { return (index, String(value[value.index(after: value.startIndex)..<end])) }
                if let end = value.range(of: #"^"(?:\\.|[^"\\])*""#, options: .regularExpression),
                   let decoded = try? JSONSerialization.jsonObject(with: Data(value[end].utf8), options: .fragmentsAllowed) as? String { return (index, decoded) }
            }
            return nil
        }
        func isOurs(_ range: Range<Int>?) -> Bool {
            guard let range, let (_, command) = commandLine(range),
                  URL(fileURLWithPath: command).lastPathComponent == "folmi-hook" else { return false }
            return range.contains { lines[$0].range(of: #"^\s*args\s*=\s*\[\s*(?:"mcp"|'mcp')\s*,?\s*\]\s*(?:#.*)?$"#, options: .regularExpression) != nil }
        }
        let current = section(MCPServer.name)
        if current != nil, !isOurs(current) {
            throw FolmiFailure(message: "已有自定义的 \(MCPServer.name) MCP 服务，没有覆盖它。")
        }
        if let current {
            var next = lines
            if let (index, _) = commandLine(current) { next[index] = "command = \"\(tomlEscaped(helper.path))\"" }
            return next.joined(separator: "\n")
        }
        return text + (text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n") + codexBlock(helper)
    }

    static func isInstalled(_ client: Client, file: URL? = nil) -> Bool {
        let url = file ?? client.configFile
        switch client {
        case .claudeCode, .claudeApp:
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (object["mcpServers"] as? [String: Any])?[MCPServer.name] != nil
        case .codex:
            return codexHasBlock((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
    }
    static func codexHasBlock(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.\(MCPServer.name)]" }
    }

    /// Copies the helper to its fixed place, then registers it. Returns what was done, for the sheet.
    @discardableResult
    static func install(_ client: Client, file: URL? = nil, helper: URL = helper, source: URL? = nil) throws -> String {
        try HooksInstaller.installHelper(source: source, destination: helper)
        let url = file ?? client.configFile
        switch client {
        case .claudeCode:
            guard let claude = LocalCLI.path(.claudeCLI) else {
                throw FolmiFailure(message: "没有找到 claude 命令行。在终端里运行：\n\(snippet(.claudeCode, helper: helper))")
            }
            if let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] {
                _ = try jsonRegistration(object, helper: helper)
            }
            try runClaude(claude, ["mcp", "remove", "--scope", "user", MCPServer.name], allowFailure: true)
            try runClaude(claude, ["mcp", "add", "--scope", "user", MCPServer.name, "--", helper.path, "mcp"], allowFailure: false)
            return "已通过 claude mcp add 接入（所有项目可用）"
        case .claudeApp:
            var object: [String: Any] = [:]
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw FolmiFailure(message: "\(url.path) 不是 JSON 对象，没有改动它。")
                }
                object = parsed
            }
            let next = try jsonRegistration(object, helper: helper)
            let data = try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return "已写入 \(url.path)，重启 Claude 桌面 App 后生效"
        case .codex:
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let joined = try codexRegistration(text, helper: helper)
            if joined == text { return "\(url.path) 里已经有 \(MCPServer.name)，没有改动" }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try joined.write(to: url, atomically: true, encoding: .utf8)
            return "已写入 \(url.path)，新开的 Codex 会话生效"
        }
    }

    private static func runClaude(_ path: String, _ arguments: [String], allowFailure: Bool) throws {
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = LocalCLI.environment(for: path)
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0, !allowFailure {
            throw FolmiFailure(message: "claude \(arguments.prefix(2).joined(separator: " ")) 失败：\(String(decoding: failure.prefix(300), as: UTF8.self))")
        }
    }
}

/// The MCP part of 接入 agent: one row per client, with the change shown before it is written.
struct MCPClientsSection: View {
    @State private var installed: [MCPInstaller.Client: Bool] = [:]
    @State private var pending: MCPInstaller.Client?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("让 agent 读到你的审阅（MCP）").themedFont(.headline, points: 13)
            Text("接入后，Claude / Codex 能读到你写的审阅评论和验收结果，改完逐条标「已处理」，不用再粘贴；改 JS、TS、Python 函数前后，还能查谁在调用它、这次改动有没有落下的调用。它不能替你收下、提交或推送。")
                .themedFont(.callout, points: 12).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(MCPInstaller.Client.allCases) { client in
                HStack {
                    Text(client.title).themedFont(.callout, points: 12)
                    Spacer()
                    Text(installed[client] == true ? "已接入" : "未接入").themedFont(.caption, points: 10).foregroundStyle(.secondary)
                    Button("复制配置") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MCPInstaller.snippet(client), forType: .string)
                        message = "已复制 \(client.title) 的配置"
                    }.controlSize(.small)
                    Button(installed[client] == true ? "重新接入…" : "接入…") { pending = client }.controlSize(.small)
                }
            }
            if let message { Text(message).themedFont(.caption, points: 10).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear(perform: refresh)
        .alert(pending.map { "接入 \($0.title)" } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { client in
            Button("写入") { install(client) }
            Button("取消", role: .cancel) {}
        } message: { client in
            Text(client == .claudeCode ? "将运行：\n\(MCPInstaller.snippet(client))" : "将在 \(client.configFile.path) 里加入：\n\n\(MCPInstaller.snippet(client))")
        }
    }

    private func refresh() {
        for client in MCPInstaller.Client.allCases { installed[client] = MCPInstaller.isInstalled(client) }
    }
    private func install(_ client: MCPInstaller.Client) {
        do { message = try MCPInstaller.install(client) } catch { message = error.localizedDescription }
        refresh()
    }
}
