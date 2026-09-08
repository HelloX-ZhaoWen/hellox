import Foundation
import HelloXCore

struct TranslationProfileState: Codable {
    var profiles: [TranslationProfile]
    var defaultProfileID: UUID?
    var apiKeys: [String: String]
    var isOfflineTranslationEnabled: Bool

    init(
        profiles: [TranslationProfile],
        defaultProfileID: UUID?,
        apiKeys: [String: String] = [:],
        isOfflineTranslationEnabled: Bool = true
    ) {
        self.profiles = profiles
        self.defaultProfileID = defaultProfileID
        self.apiKeys = apiKeys
        self.isOfflineTranslationEnabled = isOfflineTranslationEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
        case defaultProfileID
        case apiKeys
        case isOfflineTranslationEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([TranslationProfile].self, forKey: .profiles)
        defaultProfileID = try container.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
        apiKeys = try container.decodeIfPresent([String: String].self, forKey: .apiKeys) ?? [:]
        isOfflineTranslationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isOfflineTranslationEnabled) ?? true
    }
}

enum TranslationProfilePreferences {
    private static let storageKey = "translation-profiles-v2"

    static func loadOrMigrate(
        legacyKeychain: any SecretStoring,
        defaults: UserDefaults = .standard
    ) -> TranslationProfileState {
        let storedData = defaults.data(forKey: storageKey)

        if let data = storedData,
           let state = try? JSONDecoder().decode(TranslationProfileState.self, from: data) {
            let storedProfiles = state.profiles
            var migrated = upgradingLegacyZhipuPreset(in: removingLocalProfiles(from: state))
            for profile in migrated.profiles {
                let account = legacyAccount(for: profile.id)
                if migrated.apiKeys[profile.id.uuidString] == nil,
                   let key = try? legacyKeychain.value(for: account),
                   !key.isEmpty {
                    migrated.apiKeys[profile.id.uuidString] = key
                }
            }
            for profile in storedProfiles {
                try? legacyKeychain.removeValue(for: legacyAccount(for: profile.id))
            }
            save(migrated, defaults: defaults)
            return migrated
        }

        try? legacyKeychain.removeValue(for: "deepl-api-key")
        try? legacyKeychain.removeValue(for: "openai-compatible-api-key")

        let state = TranslationProfileState(profiles: [], defaultProfileID: nil)
        save(state, defaults: defaults)
        return state
    }

    static func save(_ state: TranslationProfileState, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(state), forKey: storageKey)
    }

    static func removingLocalProfiles(from state: TranslationProfileState) -> TranslationProfileState {
        let profiles = state.profiles.filter { $0.vendor != .local }
        let defaultID = profiles.contains { $0.id == state.defaultProfileID }
            ? state.defaultProfileID
            : profiles.first?.id
        let validIDs = Set(profiles.map { $0.id.uuidString })
        let apiKeys = state.apiKeys.filter { validIDs.contains($0.key) }
        return TranslationProfileState(
            profiles: profiles,
            defaultProfileID: defaultID,
            apiKeys: apiKeys,
            isOfflineTranslationEnabled: state.isOfflineTranslationEnabled
        )
    }

    static func upgradingLegacyZhipuPreset(in state: TranslationProfileState) -> TranslationProfileState {
        var state = state
        for index in state.profiles.indices where
            state.profiles[index].vendor == .zhipu &&
            state.profiles[index].baseURL == TranslationVendor.zhipu.defaultBaseURL &&
            state.profiles[index].model == "glm-4-flash-250414" {
            state.profiles[index].model = TranslationVendor.zhipu.defaultModel
        }
        return state
    }

    static func legacyAccount(for profileID: UUID) -> String { "translation-profile-\(profileID.uuidString)" }
}
