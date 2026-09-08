import AppKit
import HelloXCore
import SwiftUI
import Testing
@testable import HelloXApp

struct SystemTranslationSettingsTests {
    @MainActor @Test func opensLanguageManagementAndFallsBackWhenUnavailable() {
        var opened: [URL] = []
        #expect(SystemTranslationSettings.open { opened.append($0); return true })
        #expect(opened == [SystemTranslationSettings.languageSettingsURL])
        opened = []
        #expect(SystemTranslationSettings.open {
            opened.append($0)
            return $0 == SystemTranslationSettings.languageAndRegionURL
        })
        #expect(opened == [SystemTranslationSettings.languageSettingsURL, SystemTranslationSettings.languageAndRegionURL])
        #expect(!SystemTranslationSettings.open { _ in false })
    }

    @Test func catalogUsesSystemLanguagesAndPreservesChineseScripts() {
        let languages = SystemTranslationLanguage.catalog(from: [
            Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant"),
            Locale.Language(identifier: "en"), Locale.Language(identifier: "en")
        ])
        #expect(languages.count == 3)
        #expect(Set(languages.map(\.id)).count == 3)
        #expect(languages.allSatisfy { !$0.name.isEmpty })
        #expect(!languages.contains { $0.id == "auto" })
    }

    @MainActor @Test func refreshReplacesLanguageListAfterReturningFromSettings() async {
        var available = [Locale.Language(identifier: "en")]
        let model = SystemTranslationLanguagesModel { available }
        await model.refresh()
        #expect(model.hasLoaded)
        #expect(model.languages.count == 1)
        available = [Locale.Language(identifier: "ja"), Locale.Language(identifier: "fr")]
        await model.refresh()
        #expect(Set(model.languages.map(\.id)) == ["ja", "fr"])
        available = []
        await model.refresh()
        #expect(model.languages.isEmpty)
        #expect(!model.isLoading)
    }

    @MainActor @Test func renderSystemLanguageConfiguration() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        HXTypography.configureRendering()
        var cloud = TranslationProfile.preset(.niutrans)
        cloud.isEnabled = true
        let model = AppModel(translationProfileState: .init(
            profiles: [cloud], defaultProfileID: cloud.id, apiKeys: [:], isOfflineTranslationEnabled: true
        ))
        let host = NSHostingController(rootView: IntelligenceSettingsView()
            .environmentObject(model).padding(24).frame(width: 680)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 560))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("system-translation-settings.png"))
    }

    @MainActor @Test func renderSystemLanguageGrid() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        HXTypography.configureRendering()
        let model = SystemTranslationLanguagesModel()
        await model.refresh()
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingController(rootView: SystemTranslationLanguagesSheet(model: model)
                .environment(\.colorScheme, scheme))
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 620, height: 560))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            let view = try #require(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("system-language-grid-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
