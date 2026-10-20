import Foundation

/// Configuration and credentials stay in memory until Save. Testing reads this same draft without writing it.
struct AISettingsDraft {
    var settings: AISettings
    var keys: [String: String]
    private let originalProviderIDs: Set<String>
    private var editedKeys: Set<String> = []

    init(settings: AISettings, readKey: (String) -> String?) {
        self.settings = settings
        originalProviderIDs = Set(settings.providers.map(\.id))
        keys = Dictionary(uniqueKeysWithValues: settings.providers.map { ($0.id, readKey($0.id) ?? "") })
    }

    mutating func setKey(_ key: String, for id: String) {
        keys[id] = key
        editedKeys.insert(id)
    }

    func keyForTesting(_ id: String) -> String? {
        guard let key = keys[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// If credentials or the settings file cannot be saved, restore credentials before reporting the error.
    /// Injectable persistence keeps the failure paths testable without touching the user's keychain or settings.
    func commit(readKey: (String) throws -> String? = AIKeychain.readChecked,
                writeKey: (String?, String) throws -> Void = { try AIKeychain.writeChecked($0, for: $1) },
                saveSettings: (AISettings) throws -> Void = AISettingsStore.save) throws -> AISettings {
        let remainingIDs = Set(settings.providers.map(\.id))
        let changedIDs = editedKeys.intersection(remainingIDs).union(originalProviderIDs.subtracting(remainingIDs)).sorted()
        // Read all rollback values before writing anything. A locked keychain must not look like an empty one.
        var previous: [String: String] = [:]
        for id in changedIDs { previous[id] = try readKey(id) }
        var attempted: [String] = []
        do {
            for id in changedIDs {
                attempted.append(id)
                try writeKey(remainingIDs.contains(id) ? keyForTesting(id) : nil, id)
            }
            try saveSettings(settings)
            return settings
        } catch {
            var rollbackFailed = false
            for id in attempted.reversed() {
                do { try writeKey(previous[id], id) } catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw AIFailure(message: "AI 设置没有保存，部分 Key 无法恢复。请解锁钥匙串，核对 Key 后重新保存。")
            }
            throw AIFailure(message: "AI 设置没有保存，原配置已保留。\(error.localizedDescription)")
        }
    }
}

extension FolmiModel {
    /// The draft already persisted both stores; publish the new state without a second file write.
    func applySavedAISettings(_ settings: AISettings) {
        applyingSavedAISettings = true
        defer { applyingSavedAISettings = false }
        aiSettings = settings
    }
}
