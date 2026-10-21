import Foundation
import Security

/// One place a model is reached: an HTTP endpoint with the user's key, or a command line already logged in on this Mac.
struct AIProvider: Codable, Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openai, anthropic, claudeCLI, codexCLI
        var isCLI: Bool { self == .claudeCLI || self == .codexCLI }
        var label: String {
            switch self {
            case .openai: return "OpenAI 兼容（/chat/completions）"
            case .anthropic: return "Anthropic（/v1/messages）"
            case .claudeCLI: return "本机 claude 命令行"
            case .codexCLI: return "本机 codex 命令行"
            }
        }
    }
    var id: String
    var name: String
    var kind: Kind
    var baseURL = ""
    var model = ""
    /// The endpoint runs on this Mac (Ollama, LM Studio): no key, and allowed in projects set to local models only.
    var localOnly = false

    var needsKey: Bool { !kind.isCLI && !localOnly }
    var hasEndpoint: Bool { kind.isCLI || (!baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty) }
    /// "DeepSeek · deepseek-chat"; a command line shows its own name.
    var displayName: String {
        let model = model.trimmingCharacters(in: .whitespaces)
        return kind.isCLI || model.isEmpty ? name : "\(name) · \(model)"
    }

    /// The command lines are not stored: they are listed whenever they are installed.
    static let claudeCLI = AIProvider(id: "cli.claude", name: "本机 claude", kind: .claudeCLI)
    static let codexCLI = AIProvider(id: "cli.codex", name: "本机 codex", kind: .codexCLI)

    struct Preset: Identifiable, Sendable {
        let name: String, kind: Kind, baseURL: String, model: String, localOnly: Bool
        var id: String { name }
    }
    static let presets: [Preset] = [
        Preset(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-haiku-5-5", localOnly: false),
        Preset(name: "OpenAI", kind: .openai, baseURL: "https://api.openai.com/v1", model: "", localOnly: false),
        Preset(name: "DeepSeek", kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-chat", localOnly: false),
        Preset(name: "OpenRouter", kind: .openai, baseURL: "https://openrouter.ai/api/v1", model: "", localOnly: false),
        Preset(name: "Ollama", kind: .openai, baseURL: "http://localhost:11434/v1", model: "", localOnly: true),
        Preset(name: "LM Studio", kind: .openai, baseURL: "http://localhost:1234/v1", model: "", localOnly: true),
        Preset(name: "自定义", kind: .openai, baseURL: "", model: "", localOnly: false),
    ]
    static func make(_ preset: Preset) -> AIProvider {
        AIProvider(id: UUID().uuidString, name: preset.name, kind: preset.kind, baseURL: preset.baseURL, model: preset.model,
                   localOnly: preset.localOnly)
    }
}

/// What a model is asked to do. Each one can go to its own provider: cheap and fast for the frequent ones.
enum AIUse: String, Codable, CaseIterable, Identifiable, Sendable {
    case commitMessage, rewrite, translate, explain, rules
    var id: String { rawValue }
    var label: String {
        switch self {
        case .commitMessage: return "提交说明"
        case .rewrite: return "说人话 / 去 AI 腔"
        case .translate: return "翻译"
        case .explain: return "解释改动 / 问 AI"
        case .rules: return "总结规则"
        }
    }
}

/// Providers, which provider each use goes to, and the projects that may only use models on this Mac.
/// Older files held one endpoint (`baseURL` / `model` / `format` / `useClaudeCLI`); they decode into one provider.
struct AISettings: Codable, Equatable, Sendable {
    var providers: [AIProvider] = []
    /// Use → provider id. A use without an entry goes to the first provider that can run.
    var routes: [String: String] = [:]
    /// Pre-generates the commit message in the background while reviewing.
    var autoCommitMessage = true
    /// Lets the command lines stand in when no provider with a key is set.
    var useCLIFallback = true
    var localOnlyProjects: [String] = []
    /// The ACP adapter command per agent (`claude` / `codex`), when the user changed it from the default.
    var agentCommands: [String: String] = [:]
    /// The agent the AI tab starts with.
    var defaultAgent = "claude"
    /// Set while decoding an older file: its key still sits under the old keychain account.
    var migratedLegacyProvider: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case providers, routes, autoCommitMessage, useCLIFallback, localOnlyProjects, agentCommands, defaultAgent
        case baseURL, model, format, useClaudeCLI
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoCommitMessage = try container.decodeIfPresent(Bool.self, forKey: .autoCommitMessage) ?? true
        agentCommands = try container.decodeIfPresent([String: String].self, forKey: .agentCommands) ?? [:]
        defaultAgent = try container.decodeIfPresent(String.self, forKey: .defaultAgent) ?? "claude"
        if let providers = try container.decodeIfPresent([AIProvider].self, forKey: .providers) {
            self.providers = providers
            routes = try container.decodeIfPresent([String: String].self, forKey: .routes) ?? [:]
            useCLIFallback = try container.decodeIfPresent(Bool.self, forKey: .useCLIFallback) ?? true
            localOnlyProjects = try container.decodeIfPresent([String].self, forKey: .localOnlyProjects) ?? []
            return
        }
        useCLIFallback = try container.decodeIfPresent(Bool.self, forKey: .useClaudeCLI) ?? true
        let baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        let model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        let format = try container.decodeIfPresent(String.self, forKey: .format) ?? "openai"
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let provider = AIProvider(id: "imported", name: Self.guessName(baseURL), kind: format == "anthropic" ? .anthropic : .openai,
                                  baseURL: baseURL, model: model)
        providers = [provider]
        migratedLegacyProvider = provider.id
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
        try container.encode(routes, forKey: .routes)
        try container.encode(autoCommitMessage, forKey: .autoCommitMessage)
        try container.encode(useCLIFallback, forKey: .useCLIFallback)
        try container.encode(localOnlyProjects, forKey: .localOnlyProjects)
        try container.encode(agentCommands, forKey: .agentCommands)
        try container.encode(defaultAgent, forKey: .defaultAgent)
    }
    static func == (a: AISettings, b: AISettings) -> Bool {
        a.providers == b.providers && a.routes == b.routes && a.autoCommitMessage == b.autoCommitMessage
            && a.useCLIFallback == b.useCLIFallback && a.localOnlyProjects == b.localOnlyProjects
            && a.agentCommands == b.agentCommands && a.defaultAgent == b.defaultAgent
    }

    /// A readable name for an endpoint: the preset whose host matches, else the host.
    static func guessName(_ baseURL: String) -> String {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
        if let preset = AIProvider.presets.first(where: { !$0.baseURL.isEmpty && URL(string: $0.baseURL)?.host == host }) { return preset.name }
        return host.isEmpty ? "自定义" : host
    }

    func isLocalOnly(_ project: String?) -> Bool { project.map { localOnlyProjects.contains($0) } ?? false }

    /// Every provider a use may pick: the stored ones, then the installed command lines.
    func candidates(cliInstalled: (AIProvider.Kind) -> Bool) -> [AIProvider] {
        providers + [AIProvider.claudeCLI, AIProvider.codexCLI].filter { cliInstalled($0.kind) }
    }

    enum Resolution: Equatable { case ready(AIProvider), missing(String) }
    /// Which provider runs `use` in `project`. A provider can run when its endpoint is filled and its key (when it needs
    /// one) is in the keychain. An explicit route that cannot run is reported instead of silently replaced.
    func resolve(_ use: AIUse, project: String?, hasKey: (String) -> Bool, cliInstalled: (AIProvider.Kind) -> Bool) -> Resolution {
        let localOnly = isLocalOnly(project)
        func runnable(_ provider: AIProvider) -> Bool {
            guard provider.hasEndpoint else { return false }
            if provider.kind.isCLI { return cliInstalled(provider.kind) }
            return !provider.needsKey || hasKey(provider.id)
        }
        let all = candidates(cliInstalled: cliInstalled)
        if let id = routes[use.rawValue] {
            guard let chosen = all.first(where: { $0.id == id }) else { return .missing("「\(use.label)」选的模型已经不在了，请在 AI 设置里重新选。") }
            if localOnly && !chosen.localOnly { return .missing("这个项目只用本机模型，「\(use.label)」选的 \(chosen.name) 不在本机。") }
            guard runnable(chosen) else {
                return .missing(chosen.kind.isCLI ? "没有找到 \(chosen.name) 命令行。" : "\(chosen.name) 还没填完接口地址、模型或 Key。")
            }
            return .ready(chosen)
        }
        let order = providers + (useCLIFallback ? [AIProvider.claudeCLI, AIProvider.codexCLI].filter { cliInstalled($0.kind) } : [])
        if let found = order.first(where: { runnable($0) && (!localOnly || $0.localOnly) }) { return .ready(found) }
        if localOnly { return .missing("这个项目只用本机模型：在 AI 设置里添加 Ollama 或 LM Studio。") }
        return .missing("还没有配置模型：在「AI 设置」里添加服务商，或安装 Claude Code / Codex 命令行。")
    }

    /// Reads `COMMIT_LLM_*` lines of an llm-commit.env file into a provider. The key is returned separately: it goes to the keychain.
    static func importEnv(_ text: String) -> (provider: AIProvider?, key: String?) {
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "="), line.hasPrefix("COMMIT_LLM_") else { continue }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            value = value.replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[String(line[..<equals])] = value
        }
        let key = values["COMMIT_LLM_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        guard let base = values["COMMIT_LLM_BASE_URL"], !base.isEmpty else { return (nil, key) }
        let provider = AIProvider(id: UUID().uuidString, name: guessName(base),
                                  kind: values["COMMIT_LLM_API_FORMAT"] == "anthropic" ? .anthropic : .openai,
                                  baseURL: base, model: values["COMMIT_LLM_MODEL"] ?? "")
        return (provider, key)
    }
}

/// API keys live in the login keychain, one per provider, never in the settings file.
enum AIKeychain {
    /// Tests use their own service name so they never touch the user's keys.
    nonisolated(unsafe) static var service = "local.folmi.ai"
    /// The single key of older versions.
    static let legacyAccount = "api-key"
    static func account(_ provider: String) -> String { "api-key.\(provider)" }

    static func read(_ provider: String) -> String? { read(account: account(provider)) }
    static func write(_ key: String?, for provider: String) { write(key, account: account(provider)) }
    static func has(_ provider: String) -> Bool { read(provider) != nil }

    /// Moves the old single key to the provider made from the old settings.
    @discardableResult
    static func migrateLegacy(to provider: String) -> Bool {
        do {
            if try readChecked(provider) != nil { return true }
            guard let old = try readChecked(account: legacyAccount) else { return true }
            try writeChecked(old, for: provider)
            try writeChecked(nil, account: legacyAccount)
            return true
        } catch { AppLog.failure("AI keychain migration failed", error); return false }
    }

    static func writeLegacyForTests(_ key: String) { write(key, account: legacyAccount) }

    static func readChecked(_ provider: String) throws -> String? { try readChecked(account: account(provider)) }
    static func writeChecked(_ key: String?, for provider: String) throws { try writeChecked(key, account: account(provider)) }

    private static func read(account: String) -> String? {
        do { return try readChecked(account: account) }
        catch { AppLog.failure("AI keychain read failed", error); return nil }
    }
    private static func readChecked(account: String) throws -> String? { try readChecked(account: account, service: service) }
    private static func readChecked(account: String, service: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = item as? Data else { throw AIFailure(message: "钥匙串中的 Key 无法读取。") }
        guard let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw AIFailure(message: "钥匙串中的 Key 格式无效。")
        }
        return key
    }
    private static func write(_ key: String?, account: String) {
        do { try writeChecked(key, account: account) } catch { AppLog.failure("AI keychain write failed", error) }
    }
    private static func writeChecked(_ key: String?, account: String) throws { try writeChecked(key, account: account, service: service) }
    private static func writeChecked(_ key: String?, account: String, service: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw keychainError(updated) }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
    }
    private static func keychainError(_ status: OSStatus) -> AIFailure {
        let description = SecCopyErrorMessageString(status, nil) as String? ?? "错误 \(status)"
        return AIFailure(message: "钥匙串读写失败：\(description)")
    }
}

/// Text that looks like a credential. Nothing that matches is sent to a model.
enum SecretScan {
    private static let patterns: [NSRegularExpression] = [
        #"AKIA[0-9A-Z]{16}"#, #"-----BEGIN [A-Z ]*PRIVATE KEY"#, #"gh[pousr]_[A-Za-z0-9]{36}"#, #"sk-[A-Za-z0-9_\-]{20,}"#,
        #"xox[abpr]-[A-Za-z0-9-]{10,}"#, #"AIza[0-9A-Za-z_\-]{35}"#,
        #"(?i)(api[_-]?key|secret|token|password)["']?\s*[:=]\s*["']?[A-Za-z0-9_\-/+]{20,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    /// File names that should not be sent or committed without a second look.
    static func isSensitivePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name == ".env" || (name.hasPrefix(".env.") && !name.hasSuffix(".example") && !name.hasSuffix(".sample"))
            || ["id_rsa", "id_ed25519", "id_ecdsa"].contains(name) || name.hasSuffix(".pem") || name.hasSuffix(".p12") || name.hasSuffix(".key")
    }
    /// The first few matches as `line: text` for a warning.
    static func findings(in text: String, limit: Int = 3) -> [String] {
        var found: [String] = []
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.count < 4_000 {
            let range = NSRange(line.startIndex..., in: line)
            if patterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                found.append("第 \(index + 1) 行：" + String(line.trimmingCharacters(in: .whitespaces).prefix(60)) + "…")
                if found.count >= limit { break }
            }
        }
        return found
    }
}

struct AIFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One-shot generation. `stream` yields the text as it grows (whole text so far, not deltas).
struct AIClient: Sendable {
    /// nil: nothing can run; `problem` says why.
    let provider: AIProvider?
    let key: String?
    let problem: String?

    /// The provider for `use` in `project`, with its key read from the keychain.
    static func client(for use: AIUse, project: String?, settings: AISettings) -> AIClient {
        switch settings.resolve(use, project: project, hasKey: AIKeychain.has, cliInstalled: { LocalCLI.path($0) != nil }) {
        case .ready(let provider):
            // A local endpoint may still have an optional key.
            return AIClient(provider: provider, key: provider.kind.isCLI ? nil : AIKeychain.read(provider.id), problem: nil)
        case .missing(let reason):
            return AIClient(provider: nil, key: nil, problem: reason)
        }
    }
    /// A given provider, for the settings sheet's test button.
    static func testing(_ provider: AIProvider, key: String?) -> AIClient {
        if provider.kind.isCLI, LocalCLI.path(provider.kind) == nil { return AIClient(provider: nil, key: nil, problem: "没有找到 \(provider.name) 命令行。") }
        if !provider.hasEndpoint { return AIClient(provider: nil, key: nil, problem: "先填接口地址和模型。") }
        if provider.needsKey, key == nil { return AIClient(provider: nil, key: nil, problem: "先填 API Key。") }
        return AIClient(provider: provider, key: key, problem: nil)
    }

    var isAvailable: Bool { provider != nil }
    /// The slower command lines only run when the result is wanted now.
    var isCLI: Bool { provider?.kind.isCLI ?? false }
    var sourceName: String { provider?.displayName ?? "未配置" }

    func complete(system: String, user: String, maxTokens: Int = 1024) async throws -> String {
        var last = ""
        for try await text in stream(system: system, user: user, maxTokens: maxTokens) { last = text }
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stream(system: String, user: String, maxTokens: Int = 1024) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let provider else { throw AIFailure(message: problem ?? "还没有配置模型。") }
                    switch provider.kind {
                    case .openai, .anthropic:
                        try await streamHTTP(provider, system: system, user: user, maxTokens: maxTokens) { continuation.yield($0) }
                    case .claudeCLI, .codexCLI:
                        guard let path = LocalCLI.path(provider.kind) else { throw AIFailure(message: "没有找到 \(provider.name) 命令行。") }
                        continuation.yield(try await LocalCLI.run(provider.kind, path: path, prompt: system + "\n\n" + user))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamHTTP(_ provider: AIProvider, system: String, user: String, maxTokens: Int, yield: (String) -> Void) async throws {
        let base = provider.baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let anthropic = provider.kind == .anthropic
        let endpoint = anthropic ? (base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages") : base + "/chat/completions"
        guard let url = URL(string: endpoint), ["https", "http"].contains(url.scheme ?? "") else {
            throw AIFailure(message: "接口地址无效：\(provider.baseURL)")
        }
        let model = provider.model.trimmingCharacters(in: .whitespaces)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any]
        if anthropic {
            if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "temperature": 0.2, "stream": true, "system": system,
                    "messages": [["role": "user", "content": user]]]
        } else {
            body = ["model": model, "max_tokens": maxTokens, "temperature": 0.2, "stream": true,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIFailure(message: "模型接口没有返回 HTTP 响应。") }
        guard http.statusCode == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 400 { break } }
            throw AIFailure(message: "模型接口返回 \(http.statusCode)：\(text.prefix(300))")
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var delta: String?
            if anthropic {
                if object["type"] as? String == "content_block_delta" { delta = (object["delta"] as? [String: Any])?["text"] as? String }
            } else if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
                delta = (first["delta"] as? [String: Any])?["content"] as? String
            }
            if let delta, !delta.isEmpty { text += delta; yield(text) }
        }
        if text.isEmpty { throw AIFailure(message: "模型没有返回文字。") }
    }
}

/// The Claude Code and Codex command lines, found once. GUI apps do not get the login shell's PATH, so common install
/// places are checked first and the login shell is asked last. Both are often Node scripts (`#!/usr/bin/env node`),
/// so they run with their own folder on PATH.
enum LocalCLI {
    /// Filled by `warm()` off the main thread at launch; empty until then (or when not installed).
    nonisolated(unsafe) private static var found: [AIProvider.Kind: String] = [:]
    static func path(_ kind: AIProvider.Kind) -> String? { found[kind] }

    static func warm() {
        DispatchQueue.global(qos: .utility).async {
            var paths: [AIProvider.Kind: String] = [:]
            for (kind, name) in [(AIProvider.Kind.claudeCLI, "claude"), (.codexCLI, "codex")] { paths[kind] = locate(name) }
            DispatchQueue.main.async { found = paths.compactMapValues { $0 } }
        }
    }
    /// Any tool installed the same ways (e.g. `npx` for the ACP adapters). Blocking: call off the main thread.
    static func locateTool(_ name: String) -> String? { locate(name) }
    private static func locate(_ name: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                          "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)", "\(home)/.volta/bin/\(name)"]
        if name == "claude" { candidates.insert("\(home)/.claude/local/claude", at: 1) }
        // nvm installs each Node version in its own folder; the newest one wins.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/\(name)" }
        }
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.hasPrefix("/") && fm.isExecutableFile(atPath: output) ? output : nil
    }

    /// The tool's own folder first, then the folder its link points into, then the usual places, so `env node` finds the
    /// Node it was installed with. A Homebrew `npx` can be left linked after `node` itself was unlinked; the real folder
    /// in the Cellar still has its node. nvm and Volta folders come last, for a shell that loads nvm lazily.
    static func environment(for path: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let folder = (path as NSString).deletingLastPathComponent
        let resolved = (URL(fileURLWithPath: path).resolvingSymlinksInPath().path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvm = "\(home)/.nvm/versions/node"
        let nvmFolders = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        env["PATH"] = ([folder, resolved, "/opt/homebrew/bin", "/usr/local/bin"] + (env["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
                       + nvmFolders + ["\(home)/.volta/bin"])
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        return env
    }

    /// The prompt goes in on stdin. Codex runs read-only, without a session file, and hands back only its last message.
    static func run(_ kind: AIProvider.Kind, path: String, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe(), input = Pipe(), errors = Pipe()
                let lastMessage = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-codex-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: lastMessage) }
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = kind == .codexCLI
                    ? ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                       "--output-last-message", lastMessage.path, "-"]
                    : ["-p", "--output-format", "text"]
                process.environment = environment(for: path)
                process.standardInput = input; process.standardOutput = output; process.standardError = errors
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                input.fileHandleForWriting.write(Data(prompt.utf8)); try? input.fileHandleForWriting.close()
                // Both pipes are drained together: a chatty stderr must not block the process while stdout is read.
                let failure = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { failure.data = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                let raw = kind == .codexCLI ? ((try? Data(contentsOf: lastMessage)) ?? data) : data
                let text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0, !text.isEmpty { continuation.resume(returning: text) }
                else {
                    let name = kind == .codexCLI ? "codex" : "claude"
                    let reason = String(data: failure.data.suffix(600), encoding: .utf8)?.suffix(300) ?? ""
                    continuation.resume(throwing: AIFailure(message: "\(name) 命令行失败（\(process.terminationStatus)）：\(reason)"))
                }
            }
        }
    }
    /// Written by one reader thread, read after `group.wait()`.
    private final class DataBox: @unchecked Sendable { var data = Data() }
}

/// Settings live in their own small file next to the workspace file, so the AI setup never blocks loading the workspace.
enum AISettingsStore {
    private static var url: URL {
        AppFiles.directory.appendingPathComponent("ai-settings.json")
    }
    static func load() -> AISettings {
        guard let data = try? Data(contentsOf: url), var value = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
        if let legacy = value.migratedLegacyProvider, AIKeychain.migrateLegacy(to: legacy) {
            value.migratedLegacyProvider = nil
            do { try save(value) } catch { AppLog.failure("AI settings migration not saved", error) }
        }
        return value
    }
    /// Throws so the settings sheet can say the change was not kept (the key itself lives in the keychain).
    static func save(_ settings: AISettings) throws {
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
    }
}

/// The app's own prompts: short, single-call versions of the wf-skills ones.
enum AIPrompts {
    /// Whether the repository's own subjects use `type(scope): …`; with no history yet, they are the default.
    static func usesConventionalCommits(_ subjects: [String]) -> Bool {
        guard !subjects.isEmpty else { return true }
        let matching = subjects.filter { $0.range(of: #"^[a-z]+(\([^)]*\))?!?: "#, options: .regularExpression) != nil }.count
        return matching * 2 >= subjects.count
    }
    static func commitMessage(chinese: Bool, conventional: Bool = true) -> String {
        """
        You generate git commit messages\(conventional ? " in Conventional Commits format" : " in the style of this repository's recent commits").
        Output ONLY the raw commit message: a subject line, then a blank line, then an optional short body. No markdown, no code fences, no explanations.
        Rules:
        - \(conventional ? "Format: <type>(<scope>)?: <subject> ; allowed types: feat fix docs style refactor perf test chore ci revert" : "No type prefix such as feat: or fix: (the recent subjects do not use one); start with what changed")
        - Subject <= 72 chars, imperative mood; name what the change does, by its purpose
        - Body: motivation and key changes in a few lines; omit it for trivial changes
        - Never use metaphors or sequence labels such as 第一刀, 第一批, commit 1
        - Follow the recent commit subjects: same language, same prefix and scope habits, similar length
        - \(chinese ? (conventional ? "Write the commit message in Chinese (keep the type and scope in English)." : "Write the commit message in Chinese.") : "Match the language of the recent commit subjects; if unclear, use English.")
        """
    }
    static let plain = """
    把下面这段内容用简单直白的中文重新讲一遍：先用一两句交代背景，再用短句说清结论和下一步。
    不用代号、缩写和比喻；保留文件名、命令和数字原样。只输出改写后的内容。
    """
    static let deAI = """
    改写下面这段文字，去掉 AI 腔：删掉空话、套话、排比和“总之”“值得注意的是”这类填充；不加粗、不用表情。
    意思和事实不变，长度不超过原文。只输出改写后的文字。
    """
    static let translate = """
    把下面的内容翻译成简体中文；如果原文主要是中文，就翻译成英文。
    代码、命令、文件路径、变量名、函数名、链接和数字保持原样；保留 Markdown 结构（标题、列表、表格、代码块），代码块里只翻译注释。
    译文要通顺自然，不加解释，只输出译文。
    例外：如果内容只是一个词、短语或代码里的名字（比如 GitRepository、fetchUpdates、merge-tree），不要原样输出，
    给出它的意思：名字按单词拆开翻译（GitRepository → Git 仓库），再用一句话说明它通常指什么。
    """
    static let explainDiff = """
    你在帮人验收一段代码改动。用中文、三到六条短句说明：改了什么、为什么可能这样改、有没有明显的风险（只说有依据的）。
    不复述代码，不写客套话。没有风险就写“没看到明显问题”。
    """
    static let splitCommits = """
    下面是暂存区的改动统计和 diff。判断它们是否应该拆成几次独立提交。
    只输出 JSON：{"groups":[{"title":"中文提交目的","paths":["文件路径"]}]}；不需要拆分时只输出一个组。
    """
    static let ruleFromNotes = """
    下面是用户在代码审阅里反复写的一类评论或丢弃原因，每行前面是文件路径。把它改写成一条给 AI 编程助手的长期要求：一句话、祈使句、中文、
    不超过 40 个字，说清楚以后该怎么做或不该做什么，不提具体文件和行号。只输出这一句。
    如果这些话只针对某几处具体代码（比如某个变量名、某个函数的写法），推广成长期要求并不合适，就只输出：\(AIPrompts.notGeneral)
    """
    static let notGeneral = "不适合当规则"
    static let ask = """
    你是 Folmi 里的助手，只负责阅读和建议，不负责动手改代码。回答简短、直接、用中文。
    需要改多个文件、运行命令或长时间工作的请求，建议用户点「交给 agent」，交给 AI 标签里的 Claude / Codex。
    """
}
