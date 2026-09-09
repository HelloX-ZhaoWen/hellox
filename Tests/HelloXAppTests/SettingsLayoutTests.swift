import AppKit
import SwiftUI
import HelloXCore
import Testing
@testable import HelloXApp

private struct TranslationSheetPreview<Content: View>: View {
    let scheme: ColorScheme
    @ViewBuilder let content: Content
    @State private var isPresented = false

    var body: some View {
        Color.gray.opacity(0.2)
            .frame(width: 800, height: 650)
            .onAppear { isPresented = true }
            .sheet(isPresented: $isPresented) {
                content
                    .presentationBackground(HXDialogStyle.background(scheme))
                    .presentationCornerRadius(HXDialogStyle.radius)
            }
    }
}

@MainActor
@Suite(.serialized)
struct SettingsLayoutTests {
    init() { HXTypography.configureRendering() }

    @Test func nativeWindowKeepsItsFrameAndTracksNavigationTitle() throws {
        let model = AppModel()
        #expect(model.mainDestination == .shortcuts)
        let controller = SettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        #expect(window.title == "快捷键")
        #expect(window.titleVisibility == .hidden)
        #expect(window.backgroundColor == .clear)
        model.mainDestination = .software
        #expect(window.title == "软件与更新")
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        let size = NSSize(width: 900, height: 650)
        window.setContentSize(size)
        #expect(window.contentRect(forFrameRect: window.frame).size == size)
        let resizedFrame = window.frame
        model.mainDestination = .shortcuts
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        #expect(window.frame == resizedFrame)
        let frameView = try #require(window.contentView?.superview)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(type))
            let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            #expect(frameView.hitTest(button.convert(center, to: frameView)) === button)
        }
    }

    @Test func defaultTranslationSelectionPersistsAndRejectsDisabledServices() throws {
        let key = "translation-profiles-v2"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let model = AppModel()
        var first = TranslationProfile.preset(.zhipu)
        first.isEnabled = true
        var second = TranslationProfile.preset(.zhipu)
        second.isEnabled = true
        let disabled = TranslationProfile.preset(.niutrans)
        model.translationProfiles = [first, second, disabled]
        model.defaultTranslationProfileID = first.id
        model.setDefaultTranslationProfile(second.id)
        let data = try #require(UserDefaults.standard.data(forKey: key))
        let state = try JSONDecoder().decode(TranslationProfileState.self, from: data)
        #expect(state.defaultProfileID == second.id)
        #expect(state.profiles.count == 3)
        model.setDefaultTranslationProfile(disabled.id)
        #expect(model.defaultTranslationProfileID == second.id)
        model.setDefaultTranslationProfile(UUID())
        #expect(model.defaultTranslationProfileID == second.id)
    }

    @Test func renderIndependentToolSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        for scheme in ["light", "dark"] {
            app.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
            for tool in UtilityTool.allCases {
                let controller = UtilityToolWindowController(tool: tool)
                let window = try #require(controller.window)
                defer { window.close() }
                let view = try #require(window.contentView)
                let normalSize = window.contentRect(forFrameRect: window.frame).size
                let minimumSize: NSSize
                switch tool {
                case .csvToExcel, .qrCode: minimumSize = NSSize(width: 560, height: 320)
                case .base64: minimumSize = NSSize(width: 700, height: 440)
                case .password: minimumSize = NSSize(width: 600, height: 300)
                case .colorPicker: minimumSize = NSSize(width: 380, height: 320)
                case .markdown: minimumSize = NSSize(width: 900, height: 580)
                }
                let sizes: [(String, NSSize)] = [
                    ("", normalSize), ("-minimum", minimumSize),
                    ("-large", NSSize(width: normalSize.width + 160, height: normalSize.height + 180))
                ]
                for (suffix, size) in sizes {
                    window.setContentSize(size)
                    let frame = window.frame
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    view.layoutSubtreeIfNeeded()
                    #expect(window.frame == frame)
                    #expect(view.bounds.size == size)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("tool-\(tool.rawValue)-\(scheme)\(suffix).png"))
                    #expect(window.titleVisibility == .hidden)
                    #expect(window.standardWindowButton(.closeButton)?.isHidden == (tool != .markdown))
                    #expect(view.bounds.width >= minimumSize.width)
                    #expect(view.bounds.height >= minimumSize.height)
                }
            }
        }
    }

    @Test func renderSharedIconCatalog() throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let catalog = VStack(alignment: .leading, spacing: 24) {
                Text("HelloX · 图标规范").font(HXTypography.title)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 22) {
                    ForEach(HelloXIconKey.allCases, id: \.rawValue) { icon in
                        VStack(spacing: 10) {
                            HelloXIcon(icon: icon, size: 16)
                            Text(icon.rawValue).font(.system(size: 10))
                                .foregroundStyle(HXTextStyle.secondary)
                        }
                        .frame(height: 44)
                    }
                }
                HStack(spacing: 18) {
                    Text("按钮状态").font(HXTypography.caption)
                    HelloXIconButton(icon: .undo, help: "撤销", action: {})
                    HelloXIconButton(icon: .copy, help: "复制", action: {})
                    HelloXIconButton(icon: .pen, help: "画笔", isSelected: true, action: {})
                    HelloXIconButton(icon: .save, help: "保存", role: .accent, action: {})
                    HelloXIconButton(icon: .close, help: "关闭", role: .destructive, action: {})
                    HelloXIconButton(icon: .redo, help: "重做", action: {}).disabled(true)
                }
            }
            .padding(28)
            .frame(width: 960)
            .foregroundStyle(HelloXTheme.iconForeground(for: scheme))
            .background(HelloXTheme.pageBackground(for: scheme))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: catalog)
            renderer.scale = 2
            let cgImage = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("icon-catalog-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test func renderSharedControlSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let appearanceOptions = [HXDropdownOption("system", "跟随系统"), HXDropdownOption("light", "浅色"), HXDropdownOption("dark", "暗黑")]
            let dropdownState = HXDropdownListState<String>()
            dropdownState.highlighted = "light"
            let content = VStack(alignment: .leading, spacing: 28) {
                Text("HelloX · 交互控件").font(HXTypography.title)
                HStack(spacing: 20) {
                    HXSegmentedControl("时间范围", selection: .constant(7), options: [HXSegment(7, "7 天"), HXSegment(30, "30 天")])
                    HXSegmentedControl("时间范围", selection: .constant(30), options: [HXSegment(7, "7 天"), HXSegment(30, "30 天")])
                    HXSegmentedControl("编码模式", selection: .constant(0), options: [HXSegment(0, "编码"), HXSegment(1, "解码")])
                }
                HXSearchField("搜索设置…", text: .constant(""))
                HXSearchField("搜索功能或快捷键", text: .constant("截图"))
                HStack(spacing: 20) {
                    HXDropdown("应用外观", selection: .constant("system"), options: [
                        HXDropdownOption("system", "跟随系统"), HXDropdownOption("light", "浅色"), HXDropdownOption("dark", "暗黑")
                    ])
                    HXDropdown("应用外观", selection: .constant("dark"), options: [
                        HXDropdownOption("system", "跟随系统"), HXDropdownOption("light", "浅色"), HXDropdownOption("dark", "暗黑")
                    ]).disabled(true)
                }
                HXDropdownList(title: "应用外观", selection: "system", options: appearanceOptions,
                               state: dropdownState, searchPlaceholder: nil, onSelect: { _ in })
                    .frame(width: 220, height: HXDropdownMetrics.rowHeight * 3 + HXDropdownMetrics.menuPadding * 2)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 12) {
                    Text("禁用状态 · 最右侧主按钮为可用对照")
                        .font(HXTypography.caption)
                        .foregroundStyle(HXTextStyle.secondary)
                    HStack(spacing: 12) {
                        Button("全部翻译", action: {})
                            .buttonStyle(HelloXButtonStyle(role: .accent)).disabled(true)
                        Button("复制", action: {})
                            .buttonStyle(HelloXButtonStyle()).disabled(true)
                        Button("删除", role: .destructive, action: {})
                            .buttonStyle(HelloXButtonStyle(role: .destructive)).disabled(true)
                        Button("全部翻译", action: {})
                            .buttonStyle(HelloXButtonStyle(role: .accent))
                    }
                    HStack(spacing: 12) {
                        HelloXUtilityTextButton(title: "复制结果", help: "复制结果", action: {})
                            .disabled(true)
                        Button("保存", action: {})
                            .buttonStyle(HXDialogButtonStyle(primary: true)).disabled(true)
                        Button("取消", action: {})
                            .buttonStyle(HXDialogButtonStyle()).disabled(true)
                    }
                    HStack(spacing: 16) {
                        HelloXIconButton(icon: .copy, help: "无边框禁用按钮", isBorderless: true, action: {})
                            .disabled(true)
                        HelloXIconButton(icon: .save, help: "有边框禁用按钮", isBorderless: false, action: {})
                            .disabled(true)
                        HXSegmentedControl("禁用的模式切换", selection: .constant(0), options: [
                            HXSegment(0, "编码"), HXSegment(1, "解码")
                        ]).disabled(true)
                    }
                }
            }
            .padding(32)
            .frame(width: 680, height: 680, alignment: .topLeading)
            .foregroundStyle(HXTextStyle.primary)
            .background(HelloXTheme.pageBackground(for: scheme))
            .environment(\.colorScheme, scheme)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: controller)
            defer { window.close() }
            window.setContentSize(NSSize(width: 680, height: 680))
            let view = try #require(window.contentView)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("controls-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test func renderTranslationEditorSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for (vendor, isGuide) in [TranslationVendor.zhipu, .volcengine, .niutrans, .baidu, .aliyun].flatMap({ [($0, false), ($0, true)] }) {
                let content = Group {
                    if isGuide { TranslationSetupGuideView(vendor: vendor) }
                    else { TranslationProfileEditor(profile: .preset(vendor), apiKey: "") }
                }
                    .environmentObject(AppModel(translationProfileState: .init(
                        profiles: [], defaultProfileID: nil, apiKeys: [:], isOfflineTranslationEnabled: false
                    )))
                    .environment(\.colorScheme, scheme)
                let controller = NSHostingController(rootView: TranslationSheetPreview(scheme: scheme) { content })
                let window = NSWindow(contentViewController: controller)
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                defer {
                    if let sheet = window.attachedSheet { window.endSheet(sheet) }
                    window.close()
                }
                try await Task.sleep(for: .milliseconds(500))
                let view = try #require(window.attachedSheet?.contentView?.superview ?? window.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("translation-\(isGuide ? "guide" : "editor")-\(vendor.rawValue)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// Opt-in rendered design samples use the production view and controller.
    /// They are generated without launching capture or changing user settings.
    @Test func renderMenuBarManagementSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suiteName = "MenuBarLayout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DynamicIslandPreferencesStore(defaults: defaults)
        let names = ["访达", "Safari", "系统设置", "预览", "微信", "Codex", "HelloX"]
        let bundlePaths = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app",
                           "/System/Applications/System Settings.app", "/System/Applications/Preview.app",
                           "/Applications/WeChat.app", "/Applications/Codex.app", "/Applications/HelloX.app"]
        let applications = names.enumerated().map { index, name in
            RunningApplicationSnapshot(processIdentifier: pid_t(900_000 + index),
                bundleIdentifier: "preview.app.\(index)", localizedName: name,
                bundleURL: URL(fileURLWithPath: bundlePaths[index]),
                activationPolicy: index == 6 ? .accessory : .regular)
        }
        let items = RunningApplicationCatalog.items(from: applications)
        store.setPinned(applications[4].preferenceID, pinned: true)
        var preferences = store.value
        preferences.menuBarItemOrder = applications.map(\.preferenceID)
        store.value = preferences
        let service = MenuBarOverflowService(applicationsProvider: { applications },
                                              activateApplication: { _ in false }, workspaceNotificationCenter: nil)
        service.start()
        defer { service.stop() }
        #expect(service.items.count == items.count)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for width in [520.0, 760.0] {
                let content = DynamicIslandManagementView(store: store, service: service)
                    .frame(width: width, height: 500)
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("menu-bar-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func renderNativeSettingsSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        for scheme in ["light", "dark"] {
            app.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
            for destination in SettingsDestination.allCases {
                let model = AppModel(translationProfileState: .init(
                    profiles: [], defaultProfileID: nil, apiKeys: [:], isOfflineTranslationEnabled: false
                ))
                model.mainDestination = destination
                let controller = SettingsWindowController(model: model)
                let window = try #require(controller.window)
                defer { window.close() }
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(120))
                for size in [SettingsWindowLayout.defaultSize, SettingsWindowLayout.minimumSize, NSSize(width: 1400, height: 900)] {
                    window.setContentSize(size)
                    let view = try #require(window.contentView)
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(120))
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "\(destination.rawValue)-\(scheme)-\(Int(size.width)).png"
                    try png.write(to: output.appendingPathComponent(name))
                    #expect(view.bounds.width == size.width)
                    #expect(window.contentRect(forFrameRect: window.frame).height == size.height)
                }
            }
        }
    }
}
