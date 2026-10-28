import Foundation

/// A Codex conversation read from the file Codex keeps it in (`~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`,
/// older ones compressed as `.jsonl.zst`). Read-only: opening the conversation through the adapter fails while the
/// Codex app, CLI or an editor has it open, and two clients writing to one conversation would tangle it.
public enum CodexRollout {
    /// `$CODEX_HOME`, else `~/.codex`.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment["CODEX_HOME"], !value.isEmpty { return URL(fileURLWithPath: value, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The record of one conversation. Its id is a UUIDv7, so the day folder it was started in is checked first
    /// (and the days either side, for time zones); only then the whole sessions folder and the archive.
    public static func locate(id: String, home: URL) -> URL? {
        let names = ["-\(id).jsonl", "-\(id).jsonl.zst"]
        func match(in folder: URL) -> URL? {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
            return files.first { file in names.contains { file.lastPathComponent.hasSuffix($0) } }
        }
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        if let started = startDate(of: id) {
            let calendar = Calendar(identifier: .gregorian)
            for offset in [0, -1, 1] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: started) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
                if let found = match(in: folder) { return found }
            }
        }
        if let found = match(in: home.appendingPathComponent("archived_sessions", isDirectory: true)) { return found }
        let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)
        while let file = walker?.nextObject() as? URL {
            if names.contains(where: { file.lastPathComponent.hasSuffix($0) }) { return file }
        }
        return nil
    }

    /// The creation time a UUIDv7 carries in its first 48 bits.
    public static func startDate(of id: String) -> Date? {
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
              let millis = UInt64(hex.prefix(12), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// The conversation as the AI tab shows it: what was said, commands run and files changed. Reasoning, token
    /// counts and injected instructions are left out. Only lines of this conversation count, not its sub-agents'.
    public static func transcript(_ data: Data, id: String, root: String? = nil) -> ACPTranscript {
        var completed = ACPTranscript(), legacy = ACPTranscript()
        for line in data.split(separator: 10) {
            guard let record = JSON.parse(Data(line)), let payload = record["payload"] else { continue }
            if let thread = payload["thread_id"]?.string, thread != id { continue }
            switch (record["type"]?.string, payload["type"]?.string) {
            case ("event_msg", "item_completed"):
                if let item = payload["item"], let entry = entry(item, index: completed.entries.count, root: root) { completed.append(entry) }
            // Records written before item_completed existed.
            case ("event_msg", "user_message"):
                if let text = payload["message"]?.string { legacy.append(.init(id: "user-\(legacy.entries.count)", kind: .user, text: text)) }
            case ("event_msg", "agent_message"):
                if let text = payload["message"]?.string { legacy.append(.init(id: "agent-\(legacy.entries.count)", kind: .agent, text: text)) }
            default:
                break
            }
        }
        return completed.entries.isEmpty ? legacy : completed
    }

    private static func entry(_ item: JSON, index: Int, root: String?) -> ACPTranscript.Entry? {
        let id = "\(item["type"]?.string ?? "item")-\(index)"
        func texts(_ content: JSON?) -> String {
            (content?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        }
        func relative(_ path: String) -> String {
            guard let root, path.hasPrefix(root + "/") else { return path }
            return String(path.dropFirst(root.count + 1))
        }
        switch item["type"]?.string {
        case "UserMessage":
            let text = texts(item["content"])
            return text.isEmpty ? nil : .init(id: id, kind: .user, text: text)
        case "AgentMessage":
            let text = texts(item["content"])
            return text.isEmpty ? nil : .init(id: id, kind: .agent, text: text)
        case "CommandExecution":
            // `zsh -lc "<command>"`: the command is what was asked for, not the shell around it.
            let words = item["command"]?.array?.compactMap(\.string) ?? []
            let command = words.count >= 3 && words[words.count - 2].hasPrefix("-") ? words.last ?? "" : words.joined(separator: " ")
            return .init(id: id, kind: .tool, text: "运行 " + String(command.prefix(200)), status: "completed", toolKind: "execute")
        case "FileChange":
            let paths = (item["changes"].flatMap { change -> [String]? in
                if case .object(let files) = change { return files.keys.sorted() }
                return nil
            } ?? []).map(relative)
            return .init(id: id, kind: .tool, text: paths.count == 1 ? "改了 \(paths[0])" : "改了 \(paths.count) 个文件",
                         status: "completed", toolKind: "edit", paths: paths)
        case "McpToolCall":
            let name = [item["server"]?.string, item["tool"]?.string].compactMap { $0 }.joined(separator: ".")
            return .init(id: id, kind: .tool, text: "调用 " + (name.isEmpty ? "MCP 工具" : name), status: "completed", toolKind: "other")
        default:
            return nil
        }
    }
}
