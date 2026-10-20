import XCTest
@testable import Folmi

final class AISettingsTests: XCTestCase {
    private let deepseek = AIProvider(id: "ds", name: "DeepSeek", kind: .openai, baseURL: "https://api.deepseek.com", model: "deepseek-chat")
    private let claude = AIProvider(id: "an", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-haiku-5-5")
    private let ollama = AIProvider(id: "ol", name: "Ollama", kind: .openai, baseURL: "http://localhost:11434/v1", model: "qwen3", localOnly: true)

    private func resolve(_ settings: AISettings, _ use: AIUse, project: String? = nil, keys: Set<String> = [],
                         cli: Set<AIProvider.Kind> = []) -> AISettings.Resolution {
        settings.resolve(use, project: project, hasKey: { keys.contains($0) }, cliInstalled: { cli.contains($0) })
    }
    private func id(_ resolution: AISettings.Resolution) -> String? {
        if case .ready(let provider) = resolution { return provider.id }
        return nil
    }

    func testOlderSingleEndpointFileBecomesOneProvider() throws {
        let old = #"{"baseURL":"https://api.deepseek.com","model":"deepseek-chat","format":"openai","useClaudeCLI":false,"autoCommitMessage":false}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.providers.count, 1)
        XCTAssertEqual(settings.providers[0].name, "DeepSeek")
        XCTAssertEqual(settings.providers[0].model, "deepseek-chat")
        XCTAssertEqual(settings.migratedLegacyProvider, "imported")
        XCTAssertFalse(settings.useCLIFallback)
        XCTAssertFalse(settings.autoCommitMessage)
        // Saved again in the new shape, it reads back the same and no longer asks for a migration.
        let again = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again, settings)
        XCTAssertNil(again.migratedLegacyProvider)
    }

    func testOlderFileWithoutEndpointKeepsCLIChoice() throws {
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(#"{"baseURL":"","model":"","useClaudeCLI":true}"#.utf8))
        XCTAssertTrue(settings.providers.isEmpty)
        XCTAssertTrue(settings.useCLIFallback)
        XCTAssertNil(settings.migratedLegacyProvider)
    }

    func testAutomaticRouteTakesFirstRunnableProviderThenCLI() {
        var settings = AISettings()
        settings.providers = [deepseek, claude]
        XCTAssertEqual(id(resolve(settings, .commitMessage, keys: ["an"])), "an", "a provider without its key is skipped")
        XCTAssertEqual(id(resolve(settings, .commitMessage, keys: ["ds", "an"])), "ds")
        XCTAssertEqual(id(resolve(settings, .commitMessage, cli: [.codexCLI])), AIProvider.codexCLI.id)
        XCTAssertEqual(id(resolve(settings, .commitMessage, cli: [.claudeCLI, .codexCLI])), AIProvider.claudeCLI.id)
        settings.useCLIFallback = false
        XCTAssertNil(id(resolve(settings, .commitMessage, cli: [.codexCLI])))
    }

    func testEachUseFollowsItsOwnRoute() {
        var settings = AISettings()
        settings.providers = [deepseek, claude]
        settings.routes = [AIUse.explain.rawValue: "an"]
        XCTAssertEqual(id(resolve(settings, .commitMessage, keys: ["ds", "an"])), "ds")
        XCTAssertEqual(id(resolve(settings, .explain, keys: ["ds", "an"])), "an")
        // A chosen provider that cannot run is reported, not silently swapped for another one.
        guard case .missing(let reason) = resolve(settings, .explain, keys: ["ds"]) else { return XCTFail() }
        XCTAssertTrue(reason.contains("Anthropic"))
        settings.routes = [AIUse.explain.rawValue: AIProvider.codexCLI.id]
        XCTAssertEqual(id(resolve(settings, .explain, cli: [.codexCLI])), AIProvider.codexCLI.id)
        guard case .missing = resolve(settings, .explain, keys: ["ds"]) else { return XCTFail("codex is not installed") }
        settings.routes = [AIUse.explain.rawValue: "gone"]
        guard case .missing = resolve(settings, .explain, keys: ["ds"]) else { return XCTFail("a removed provider is reported") }
    }

    func testLocalOnlyProjectUsesOnlyLocalProviders() {
        var settings = AISettings()
        settings.providers = [deepseek, ollama]
        settings.localOnlyProjects = ["/work/secret"]
        XCTAssertEqual(id(resolve(settings, .rewrite, keys: ["ds"])), "ds", "other projects are unaffected")
        XCTAssertEqual(id(resolve(settings, .rewrite, project: "/work/secret", keys: ["ds"], cli: [.claudeCLI])), "ol",
                       "a local endpoint needs no key; remote providers and the CLIs are skipped")
        settings.routes = [AIUse.rewrite.rawValue: "ds"]
        guard case .missing(let reason) = resolve(settings, .rewrite, project: "/work/secret", keys: ["ds"]) else { return XCTFail() }
        XCTAssertTrue(reason.contains("本机"))
        settings.providers = [deepseek]; settings.routes = [:]
        guard case .missing = resolve(settings, .rewrite, project: "/work/secret", keys: ["ds"], cli: [.claudeCLI]) else { return XCTFail() }
    }

    func testKeysArePerProviderAndOldKeyMoves() {
        let original = AIKeychain.service
        AIKeychain.service = "local.folmi.ai.tests.\(UUID().uuidString)"
        defer {
            for id in ["a", "b", "imported"] { AIKeychain.write(nil, for: id) }
            AIKeychain.service = original
        }
        AIKeychain.write("key-a", for: "a")
        AIKeychain.write("key-b", for: "b")
        XCTAssertEqual(AIKeychain.read("a"), "key-a")
        XCTAssertEqual(AIKeychain.read("b"), "key-b")
        AIKeychain.write(nil, for: "a")
        XCTAssertNil(AIKeychain.read("a"))
        XCTAssertTrue(AIKeychain.has("b"))
        AIKeychain.writeLegacyForTests("old-key")
        AIKeychain.migrateLegacy(to: "imported")
        XCTAssertEqual(AIKeychain.read("imported"), "old-key")
        AIKeychain.migrateLegacy(to: "imported")
        XCTAssertEqual(AIKeychain.read("imported"), "old-key", "running the migration twice keeps the moved key")
    }

    func testPresetNamesAnImportedEndpoint() {
        XCTAssertEqual(AISettings.guessName("https://api.deepseek.com/"), "DeepSeek")
        XCTAssertEqual(AISettings.guessName("https://ark.cn-beijing.volces.com/api/coding"), "ark.cn-beijing.volces.com")
        let local = AIProvider.make(AIProvider.presets.first { $0.name == "Ollama" }!)
        XCTAssertTrue(local.localOnly)
        XCTAssertFalse(local.needsKey)
    }
}
