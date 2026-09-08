import AppKit
import HelloXCore
import SwiftUI
import Testing
@testable import HelloXApp

struct SettingsSearchTests {
    @Test func searchesNestedFunctionsAndSettingsAcrossPages() {
        for (query, target) in [("base64", "shortcut-base64"), ("OCR", "shortcut-captureAndOCR"),
                                ("离线", "translation-offline"), ("深色", "software-appearance"),
                                ("辅助功能", "permission-accessibility"), ("置顶", "island-apps"),
                                ("全屏 显示", "island-fullscreen"),
                                ("语言包 下载", "translation-languages")] {
            let results = SettingsSearchIndex.results(for: query, profiles: [], bindings: [:])
            #expect(results.contains { $0.id == target }, "Missing result for \(query)")
            #expect(Set(results.map(\.id)).count == results.count)
        }
        #expect(SettingsSearchIndex.results(for: "   ", profiles: [], bindings: [:]).isEmpty)
        #expect(SettingsSearchIndex.results(for: "不存在的设置xyz", profiles: [], bindings: [:]).isEmpty)
    }

    @Test func searchesConfiguredProfilesAndOnlyVisibleSettings() {
        var profile = TranslationProfile.preset(.volcengine)
        profile.name = "团队翻译"
        profile.isEnabled = true
        let result = SettingsSearchIndex.results(for: "团队", profiles: [profile], bindings: [:])
        #expect(result.first?.id == "translation-profile-" + profile.id.uuidString)
        #expect(result.first?.destination == .intelligence)
        #expect(SettingsSearchIndex.results(for: "默认云端", profiles: [], bindings: [:]).isEmpty)
        #expect(!SettingsSearchIndex.results(for: "默认云端", profiles: [profile], bindings: [:]).isEmpty)
        let binding = ShortcutAction.regionCapture.defaultBinding!
        #expect(SettingsSearchIndex.results(for: binding.displayName, profiles: [], bindings: [.regionCapture: binding])
            .contains { $0.id == "shortcut-regionCapture" })
    }

    @MainActor @Test func renderNestedSearchResults() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        HXTypography.configureRendering()
        let model = AppModel(translationProfileState: .init(
            profiles: [], defaultProfileID: nil, apiKeys: [:], isOfflineTranslationEnabled: false
        ))
        let host = NSHostingController(rootView: SettingsView(searchQuery: "截图").environmentObject(model))
        host.safeAreaRegions = []
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        HelloXWindowStyle.applySettingsReference(to: window)
        window.setContentSize(NSSize(width: 1100, height: 760))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("settings-search.png"))
    }
}
