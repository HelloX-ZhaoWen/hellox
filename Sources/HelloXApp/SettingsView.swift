import AppKit
import HelloXCore
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case shortcuts, dynamicIsland, intelligence, software
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortcuts: "快捷键"
        case .dynamicIsland: "灵动岛"
        case .intelligence: "翻译设置"
        case .software: "软件与更新"
        }
    }
    var icon: HelloXIconKey {
        switch self {
        case .shortcuts: .shortcuts
        case .dynamicIsland: .dynamicIsland
        case .intelligence: .translation
        case .software: .settings
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var shortcutSearch = ""
    @State private var appearanceMode = HelloXAppearance.mode
    @State private var settingsSearch = ""
    @State private var selectedSearchID: String?
    @State private var searchNavigationID = UUID()
    @FocusState private var focusedSearchID: String?
    @FocusState private var focusedDestination: SettingsDestination?

    init(searchQuery: String = "") {
        _settingsSearch = State(initialValue: searchQuery)
    }

    var body: some View {
        // Width is fixed, as in Codex. NSSplitView inserts a titlebar-safe inset
        // into each pane even in a full-size-content window, leaving a white band.
        HStack(spacing: 0) {
            sidebar.frame(width: SettingsWindowLayout.sidebarWidth)
            detail.frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .font(HXTypography.body)
        .foregroundStyle(HXTextStyle.primary)
        .buttonStyle(HelloXButtonStyle())
        .tint(HelloXTheme.accent)
        .background(HelloXTheme.pageBackground(for: colorScheme))
    }

    private var isSearching: Bool {
        !settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchIndex.results(for: settingsSearch, profiles: model.translationProfiles,
                                    bindings: model.shortcutBindings)
    }

    private func selectSearchResult(_ result: SettingsSearchResult) {
        shortcutSearch = ""
        model.mainDestination = result.destination
        selectedSearchID = result.id
        searchNavigationID = UUID()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HelloX").font(HXTypography.control)
                .padding(.horizontal, 16)
                .frame(height: 28)
            HXSearchField("搜索设置…", text: $settingsSearch)
            .onSubmit {
                if let first = searchResults.first { selectSearchResult(first) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Text(isSearching ? "搜索结果" : "设置").font(HXTypography.sidebar)
                        .foregroundStyle(HelloXTheme.sidebarSectionForeground(for: colorScheme))
                        .padding(.horizontal, 8).frame(height: 24)
                    if isSearching {
                        ForEach(searchResults) { result in
                            Button { selectSearchResult(result) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.title).font(HXTypography.sidebar)
                                        .foregroundStyle(HXTextStyle.primary)
                                    Text(result.destination.title).font(HXTypography.caption)
                                        .foregroundStyle(HXTextStyle.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(selectedSearchID == result.id
                                    ? HelloXTheme.sidebarSelectedBackground(for: colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedSearchID, equals: result.id)
                            .accessibilityLabel(result.location)
                        }
                        if searchResults.isEmpty {
                            Text("未找到匹配设置或功能").font(HXTypography.caption)
                                .foregroundStyle(HXTextStyle.secondary).padding(8)
                        }
                    } else {
                        ForEach(SettingsDestination.allCases) { destination in
                            HXSidebarRow(title: destination.title, icon: destination.icon,
                                         isSelected: model.mainDestination == destination) {
                                model.mainDestination = destination
                                selectedSearchID = nil
                            }
                            .focused($focusedDestination, equals: destination)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .codexScrollChrome()
            .padding(.top, 16)
            .onMoveCommand { direction in
                if isSearching {
                    let results = searchResults
                    guard !results.isEmpty, direction == .down || direction == .up else { return }
                    let index = results.firstIndex { $0.id == focusedSearchID } ?? (direction == .down ? -1 : results.count)
                    let next = results[min(max(index + (direction == .down ? 1 : -1), 0), results.count - 1)]
                    focusedSearchID = next.id
                    selectSearchResult(next)
                    return
                }
                let destinations = SettingsDestination.allCases
                guard !destinations.isEmpty else { return }
                let index = destinations.firstIndex(of: focusedDestination ?? model.mainDestination) ?? 0
                let step = direction == .down ? 1 : direction == .up ? -1 : 0
                guard step != 0 else { return }
                let next = destinations[min(max(index + step, 0), destinations.count - 1)]
                model.mainDestination = next
                focusedDestination = next
            }
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HXSidebarMaterial())
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text(model.mainDestination.title).font(HXTypography.title)
                        .id("page-" + model.mainDestination.rawValue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        switch model.mainDestination {
                        case .shortcuts: shortcutsPage
                        case .intelligence: IntelligenceSettingsView()
                        case .software: softwarePage
                        case .dynamicIsland:
                            DynamicIslandSettingsCard(initialSection: selectedSearchID == "island-tools" ? .helloX : .menuBar)
                                .frame(minHeight: 540)
                        }
                    }
                }
                .frame(maxWidth: 768, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 64).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .codexScrollChrome()
            .background(HelloXTheme.pageBackground(for: colorScheme))
            .onChange(of: searchNavigationID) { _, _ in
                guard let id = selectedSearchID else { return }
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 40) {
            HStack(spacing: 12) {
                HXSearchField("搜索功能或快捷键", text: $shortcutSearch)
                Button("恢复默认", action: model.resetAllShortcuts)
                    .id("shortcut-reset")
                    .help("将全部快捷键恢复为默认值")
            }
            if filteredShortcutActions.isEmpty {
                VStack(spacing: 10) {
                    HelloXIcon(icon: .search, size: 28)
                    Text("未找到匹配功能或快捷键").font(HXTypography.body)
                }
                .foregroundStyle(HXTextStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                HXSettingsGroup(title: "全局快捷键", footer: "点击快捷键后按下新的组合键，按 Delete 清空，按 Esc 取消。") {
                    ForEach(filteredShortcutActions) { action in
                        shortcutRow(action).id("shortcut-" + action.rawValue)
                        if action != filteredShortcutActions.last { HXSettingsDivider() }
                    }
                }
            }
        }
    }

    private var filteredShortcutActions: [ShortcutAction] {
        let query = shortcutSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutAction.configurableCases.filter { action in
            query.isEmpty || "\(action.settingsTitle) \(action.settingsDescription) \(model.shortcutBindings[action]?.displayName ?? "")"
                .localizedCaseInsensitiveContains(query)
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.settingsTitle).font(HXTypography.label)
                    Text(action.settingsDescription).font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                ShortcutRecorder(binding: Binding(
                    get: { model.shortcutBindings[action] },
                    set: { value in
                        if let value { model.setShortcut(action, binding: value) }
                        else { model.clearShortcut(action) }
                    }
                ), hasConflict: model.shortcutConflictMessages[action] != nil)
                .frame(width: 112, height: 28)
                .accessibilityLabel("\(action.settingsTitle)快捷键")
            }
            if let message = model.shortcutConflictMessages[action] {
                Label { Text(message) } icon: { HelloXIcon(icon: .warning, size: 14) }
                    .font(HXTypography.caption).foregroundStyle(HelloXTheme.error)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var softwarePage: some View {
        VStack(alignment: .leading, spacing: 40) {
            HXSettingsGroup(title: "关于") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HelloX").font(.system(size: 15, weight: .semibold))
                        Text(HelloXBrand.slogan).font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
                    }
                    Spacer()
                    Text("版本 \(model.currentVersion)").foregroundStyle(HXTextStyle.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .id("software-about")
            HXSettingsGroup(title: "外观", footer: "选择“跟随系统”时，HelloX 会随 macOS 自动切换外观。") {
                HXSettingsRow(title: "应用外观") {
                    HXDropdown(
                        "应用外观",
                        selection: appearanceModeBinding,
                        options: HelloXAppearanceMode.allCases.map { HXDropdownOption($0, $0.title) }
                    )
                }
            }
            .id("software-appearance")
            HXSettingsGroup(title: "权限") {
                permissionRow(icon: .screen, title: "屏幕录制", subtitle: "用于截图和录屏",
                              granted: model.permissions.canRecordScreen,
                              action: model.requestScreenPermission)
                    .id("permission-screen")
                HXSettingsDivider()
                permissionRow(icon: .capture, title: "辅助功能", subtitle: "用于滚动截图和划词翻译",
                              granted: model.permissions.canUseAccessibility,
                              action: model.requestAccessibilityPermission)
                    .id("permission-accessibility")
            }
            HXSettingsGroup(title: "软件更新") {
                HStack(spacing: 12) {
                    HelloXRowIcon(icon: .update, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.updateState.message ?? "检查是否有可用更新")
                            .foregroundStyle(updateMessageColor)
                        Text("当前版本 \(model.currentVersion)")
                            .font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
                    }
                    Spacer(minLength: 8)
                    if isUpdating { ProgressView().controlSize(.small) }
                    Button(updateActionTitle) {
                        if case .available = model.updateState { model.installAvailableUpdate() }
                        else { model.checkForUpdates() }
                    }
                    .disabled(isUpdating)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .id("software-update")
            HStack(spacing: 16) {
                Link("项目主页", destination: URL(string: "https://github.com/HelloX-ZhaoWen/hellox")!)
                Link("隐私说明", destination: URL(string: "https://github.com/HelloX-ZhaoWen/hellox#隐私与数据")!)
            }
            .font(HXTypography.caption).padding(.horizontal, 12)
            .id("software-links")
        }
    }

    private func permissionRow(icon: HelloXIconKey, title: String, subtitle: String,
                               granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            HelloXRowIcon(icon: icon, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
            }
            Spacer(minLength: 8)
            if granted {
                HStack(spacing: 5) {
                    HelloXIcon(icon: .confirm, size: 12)
                    Text("已授权")
                }
                    .foregroundStyle(HXTextStyle.secondary)
                    .font(HXTypography.control)
                    .lineLimit(1)
                    .frame(minHeight: 28)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title)，已授权")
            } else {
                Button("前往授权", action: action)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var isUpdating: Bool {
        switch model.updateState {
        case .checking, .downloading, .installing: true
        default: false
        }
    }
    private var updateMessageColor: Color {
        if case .failed = model.updateState { return HelloXTheme.error }
        return HelloXTheme.primaryText(for: colorScheme)
    }
    private var updateActionTitle: String {
        if case .available = model.updateState { return "立即更新" }
        return "检查更新"
    }
    private var appearanceModeBinding: Binding<HelloXAppearanceMode> {
        Binding(get: { appearanceMode }, set: {
            appearanceMode = $0
            HelloXAppearance.setMode($0)
        })
    }
}
