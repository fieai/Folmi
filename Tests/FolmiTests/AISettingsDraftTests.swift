import XCTest
@testable import Folmi

final class AISettingsDraftTests: XCTestCase {
    private func settings() -> AISettings {
        var value = AISettings()
        value.providers = [AIProvider(id: "a", name: "Provider", kind: .openai, baseURL: "https://example.test", model: "model")]
        return value
    }

    func testEditingAndTestingDraftLeavesSavedConfigurationAndKeysUntouched() {
        let original = settings()
        let keychain = ["a": "original-key"]
        var draft = AISettingsDraft(settings: original, readKey: { keychain[$0] })
        draft.settings.providers[0].model = "new-model"
        draft.settings.routes[AIUse.explain.rawValue] = "a"
        draft.setKey("  draft-key\n", for: "a")
        XCTAssertEqual(draft.keyForTesting("a"), "draft-key")
        XCTAssertEqual(original.providers[0].model, "model")
        XCTAssertTrue(original.routes.isEmpty)
        XCTAssertEqual(keychain["a"], "original-key")
        // Discarding the value (Cancel or dismiss) has no persistence side effects.
    }

    func testSaveKeepsProviderRouteAndKeyTogetherAndNeverEncodesKey() throws {
        var persisted = settings()
        var keychain = ["a": "original-key"]
        var draft = AISettingsDraft(settings: persisted, readKey: { keychain[$0] })
        draft.settings.providers[0].model = "new-model"
        draft.settings.routes[AIUse.explain.rawValue] = "a"
        draft.setKey("secret-draft-credential", for: "a")
        let saved = try draft.commit(readKey: { keychain[$0] }, writeKey: { keychain[$1] = $0 }, saveSettings: { persisted = $0 })
        XCTAssertEqual(saved, persisted)
        XCTAssertEqual(persisted.providers[0].model, "new-model")
        XCTAssertEqual(persisted.routes[AIUse.explain.rawValue], "a")
        XCTAssertEqual(keychain["a"], "secret-draft-credential")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self).contains("secret-draft-credential"))
    }

    func testFileSaveFailureRestoresUpdatedAndDeletedKeys() {
        let original = settings()
        var keychain = ["a": "original-key", "b": "second-key"]
        var initial = original
        initial.providers.append(AIProvider(id: "b", name: "Second", kind: .openai))
        var draft = AISettingsDraft(settings: initial, readKey: { keychain[$0] })
        draft.settings.providers.removeAll { $0.id == "b" }
        draft.setKey("new-key", for: "a")
        XCTAssertThrowsError(try draft.commit(readKey: { keychain[$0] }, writeKey: { keychain[$1] = $0 }, saveSettings: { _ in
            throw AIFailure(message: "disk full")
        })) { XCTAssertTrue($0.localizedDescription.contains("disk full")) }
        XCTAssertEqual(keychain, ["a": "original-key", "b": "second-key"])
    }

    func testKeyWriteFailureDoesNotSaveConfigurationAndRestoresPriorWrites() {
        var keychain = ["a": "original-key"]
        var draft = AISettingsDraft(settings: settings(), readKey: { keychain[$0] })
        draft.settings.providers.append(AIProvider(id: "b", name: "Second", kind: .openai))
        draft.setKey("new-a", for: "a")
        draft.setKey("new-b", for: "b")
        var saved = false
        XCTAssertThrowsError(try draft.commit(readKey: { keychain[$0] }, writeKey: { key, id in
            if id == "b" && key == "new-b" { throw AIFailure(message: "keychain locked") }
            keychain[id] = key
        }, saveSettings: { _ in saved = true }))
        XCTAssertFalse(saved)
        XCTAssertEqual(keychain, ["a": "original-key"])
    }

    func testUnreadableKeychainStopsBeforeAnyWrite() {
        var draft = AISettingsDraft(settings: settings(), readKey: { _ in nil })
        draft.setKey("new-key", for: "a")
        var writes = 0
        XCTAssertThrowsError(try draft.commit(readKey: { _ in throw AIFailure(message: "keychain locked") },
                                             writeKey: { _, _ in writes += 1 }, saveSettings: { _ in writes += 1 }))
        XCTAssertEqual(writes, 0)
    }

    func testRollbackFailureExplicitlyAsksToCheckKeys() {
        var draft = AISettingsDraft(settings: settings(), readKey: { _ in "original-key" })
        draft.setKey("new-key", for: "a")
        XCTAssertThrowsError(try draft.commit(readKey: { _ in "original-key" }, writeKey: { key, _ in
            if key == "original-key" { throw AIFailure(message: "keychain locked") }
        }, saveSettings: { _ in throw AIFailure(message: "disk full") })) {
            XCTAssertTrue($0.localizedDescription.contains("部分 Key 无法恢复"))
        }
    }

    func testRemovingProviderOnlyDeletesItsKeyWhenSaving() throws {
        var keychain = ["a": "original-key"]
        var draft = AISettingsDraft(settings: settings(), readKey: { keychain[$0] })
        draft.settings.providers.removeAll()
        XCTAssertEqual(keychain["a"], "original-key")
        _ = try draft.commit(readKey: { keychain[$0] }, writeKey: { keychain[$1] = $0 }, saveSettings: { _ in })
        XCTAssertNil(keychain["a"])
    }
}
