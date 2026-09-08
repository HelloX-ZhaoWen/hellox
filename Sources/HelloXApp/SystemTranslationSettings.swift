import AppKit
import Translation

enum SystemTranslationSettings {
    static let languageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation")!
    static let languageAndRegionURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    @MainActor
    static func open(openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        if openURL(languageSettingsURL) { return true }
        return openURL(languageAndRegionURL)
    }
}

struct SystemTranslationLanguage: Identifiable, Equatable {
    let id: String
    let name: String

    static func catalog(from languages: [Locale.Language]) -> [Self] {
        let locale = Locale(identifier: "zh-Hans")
        return Set(languages.map(\.minimalIdentifier)).map { identifier in
            Self(id: identifier, name: locale.localizedString(forIdentifier: identifier) ?? identifier)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

@MainActor
final class SystemTranslationLanguagesModel: ObservableObject {
    @Published private(set) var languages: [SystemTranslationLanguage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    private let loadLanguages: () async -> [Locale.Language]

    init(loadLanguages: @escaping () async -> [Locale.Language] = {
        await LanguageAvailability().supportedLanguages
    }) {
        self.loadLanguages = loadLanguages
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let available = await loadLanguages()
        guard !Task.isCancelled else { return }
        languages = SystemTranslationLanguage.catalog(from: available)
        hasLoaded = true
    }
}
