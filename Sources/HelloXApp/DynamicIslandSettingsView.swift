import AppKit
import SwiftUI

struct DynamicIslandSettingsCard: View {
    var initialSection: DynamicIslandSection = .menuBar
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DynamicIslandSettingsCardContent(
                store: model.dynamicIslandPreferences,
                service: model.menuBarOverflowService
            )
            DynamicIslandManagementView(
                initialSection: initialSection,
                store: model.dynamicIslandPreferences,
                service: model.menuBarOverflowService
            )
            .id(initialSection == .helloX ? "island-tools" : "island-apps")
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct DynamicIslandSettingsCardContent: View {
    @ObservedObject var store: DynamicIslandPreferencesStore
    @ObservedObject var service: MenuBarOverflowService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HXSettingsGroup(title: "显示") {
            HXSettingsToggle(title: "启用 Mac 灵动岛", isOn: preferenceBinding(\.isEnabled))
                .id("island-enabled")
            HXSettingsDivider()
            HXSettingsToggle(title: "在全屏空间显示", isOn: preferenceBinding(\.showsInFullScreen))
                .disabled(!store.value.isEnabled)
                .id("island-fullscreen")
            HXSettingsDivider()
            HStack {
                Text("刷新正在运行的应用").foregroundStyle(HXTextStyle.secondary)
                Spacer()
                if service.isScanning { ProgressView().controlSize(.small) }
                Button("刷新", action: service.refreshManually)
                    .disabled(!store.value.isEnabled || service.isScanning)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .id("island-refresh")
        }
        .font(HXTypography.body)
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<DynamicIslandPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.value[keyPath: keyPath] },
            set: { newValue in
                var preferences = store.value
                preferences[keyPath: keyPath] = newValue
                store.value = preferences
            }
        )
    }
}

struct DynamicIslandManagementView: View {
    var initialSection: DynamicIslandSection = .menuBar
    @ObservedObject var store: DynamicIslandPreferencesStore
    @ObservedObject var service: MenuBarOverflowService
    @Environment(\.colorScheme) private var colorScheme
    @State private var section: DynamicIslandSection = .menuBar

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HXSegmentedControl(
                    "管理内容", selection: $section,
                    options: [HXSegment(.menuBar, "运行中应用"), HXSegment(.helloX, "HelloX 功能")]
                )
                Spacer(minLength: 12)
                if service.isScanning { ProgressView().controlSize(.small) }
            }
            .padding(16)

            Group {
                switch section {
                case .menuBar: menuBarList
                case .helloX: helloXList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HelloXTheme.raisedSurface(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous)
                .stroke(HelloXTheme.border(for: colorScheme), lineWidth: 1)
        }
        .tint(HelloXTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 260)
        .onAppear {
            section = initialSection
            service.refreshManually()
        }
        .onChange(of: initialSection) { _, value in section = value }
    }

    private var menuBarList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(service.statusMessage)
                    .lineLimit(1)
                    .help(service.statusMessage)
                Spacer(minLength: 8)
                Text("置顶").frame(width: 28)
                Text("排序").frame(width: 58)
            }
            .font(HXTypography.caption)
            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(orderedMenuBarItems) { item in
                        menuBarRow(item)
                        if item.id != orderedMenuBarItems.last?.id {
                            rowDivider
                        }
                    }
                }
            }
            .codexScrollChrome()
            .padding(.bottom, 8)
            .overlay {
                if orderedMenuBarItems.isEmpty, !service.isScanning {
                    VStack(spacing: 8) {
                        HelloXIcon(icon: .menuBar, size: 28)
                        Text("没有正在运行的应用").font(HXTypography.body)
                        Text("应用启动后自动显示，可置顶或调整顺序。")
                            .font(HXTypography.caption)
                    }
                    .foregroundStyle(HXTextStyle.secondary).padding(20)
                }
            }
        }
    }

    private func menuBarRow(_ item: MenuBarItemDescriptor) -> some View {
        let pinned = store.value.pinnedItemIDs.contains(item.preferenceID)
        return HStack(spacing: 12) {
            settingsIcon(for: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(HXTypography.label)
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                    .lineLimit(1)
                    .help(item.title)
                Text(pinned ? "正在运行 · 已置顶" : "正在运行")
                    .font(HXTypography.caption)
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.setPinned(item.preferenceID, pinned: !pinned)
            } label: {
                HelloXIcon(icon: .pin, size: 15)
            }
            .buttonStyle(DynamicIslandManagementButtonStyle(isSelected: pinned))
            .accessibilityLabel("\(pinned ? "取消置顶" : "置顶")\(item.title)")
            .accessibilityValue(pinned ? "已置顶" : "未置顶")
            .help(pinned ? "取消置顶" : "优先显示在灵动岛中")
            moveButtons(item.preferenceID, in: sortablePreferenceIDs(pinned: pinned))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }

    private var helloXList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("调整功能在灵动岛中的显示顺序")
                Spacer()
                Text("排序").frame(width: 58)
            }
            .font(HXTypography.caption)
            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.value.helloXActionOrder) { action in
                        HStack(spacing: 12) {
                            HelloXIcon(icon: action.icon, size: HelloXTheme.iconMedium)
                                .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(action.settingsTitle).font(HXTypography.label).lineLimit(1)
                                Text(action.settingsDescription)
                                    .font(HXTypography.caption)
                                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            moveActionButtons(action)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        if action != store.value.helloXActionOrder.last { rowDivider }
                    }
                }
            }
            .codexScrollChrome()
            .padding(.bottom, 8)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(HelloXTheme.border(for: colorScheme))
            .frame(height: 0.5)
            .padding(.leading, 58)
            .padding(.trailing, 16)
    }

    private var orderedMenuBarItems: [MenuBarItemDescriptor] {
        RunningApplicationCatalog.ordered(service.items, preferences: store.value)
    }

    private func sortablePreferenceIDs(pinned: Bool) -> [MenuBarItemIdentity] {
        var seen: Set<MenuBarItemIdentity> = []
        return orderedMenuBarItems.compactMap { item in
            guard store.value.pinnedItemIDs.contains(item.preferenceID) == pinned,
                  seen.insert(item.preferenceID).inserted else { return nil }
            return item.preferenceID
        }
    }

    private func settingsIcon(for item: MenuBarItemDescriptor) -> some View {
        Group {
            if let image = NSRunningApplication(processIdentifier: item.processIdentifier)?.icon {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(4)
            } else if let url = item.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(4)
            } else {
                HelloXIcon(icon: .menuBar, size: HelloXTheme.iconMedium)
            }
        }
        .frame(width: 30, height: 30)
        .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
    }

    @ViewBuilder
    private func moveButtons(_ identity: MenuBarItemIdentity, in identities: [MenuBarItemIdentity]) -> some View {
        let index = identities.firstIndex(of: identity) ?? 0
        HStack(spacing: 2) {
            Button { moveMenuBarItem(identity, offset: -1, identities: identities) } label: {
                HelloXIcon(icon: .chevronUp, size: 12)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(DynamicIslandManagementButtonStyle())
            .accessibilityLabel("上移")
            .help("上移")
            .disabled(index == 0)
            Button { moveMenuBarItem(identity, offset: 1, identities: identities) } label: {
                HelloXIcon(icon: .chevronDown, size: 12)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(DynamicIslandManagementButtonStyle())
            .accessibilityLabel("下移")
            .help("下移")
            .disabled(index >= identities.count - 1)
        }
    }

    private func moveMenuBarItem(
        _ identity: MenuBarItemIdentity,
        offset: Int,
        identities: [MenuBarItemIdentity]
    ) {
        guard let source = identities.firstIndex(of: identity) else { return }
        let destination = source + offset
        guard identities.indices.contains(destination) else { return }
        var reordered = identities
        reordered.swapAt(source, destination)
        var preferences = store.value
        let movingIDs = Set(identities)
        preferences.menuBarItemOrder = reordered + preferences.menuBarItemOrder.filter { !movingIDs.contains($0) }
        store.value = preferences
    }

    @ViewBuilder
    private func moveActionButtons(_ action: ShortcutAction) -> some View {
        let actions = store.value.helloXActionOrder
        let index = actions.firstIndex(of: action) ?? 0
        HStack(spacing: 2) {
            Button { moveHelloXAction(from: index, to: index - 1) } label: {
                HelloXIcon(icon: .chevronUp, size: 12)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(DynamicIslandManagementButtonStyle())
            .accessibilityLabel("上移")
            .help("上移")
            .disabled(index == 0)
            Button { moveHelloXAction(from: index, to: index + 1) } label: {
                HelloXIcon(icon: .chevronDown, size: 12)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(DynamicIslandManagementButtonStyle())
            .accessibilityLabel("下移")
            .help("下移")
            .disabled(index >= actions.count - 1)
        }
    }

    private func moveHelloXAction(from source: Int, to destination: Int) {
        var preferences = store.value
        guard preferences.helloXActionOrder.indices.contains(source),
              preferences.helloXActionOrder.indices.contains(destination) else { return }
        preferences.helloXActionOrder.swapAt(source, destination)
        store.value = preferences
    }
}

private struct DynamicIslandManagementButtonStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .foregroundStyle(!isEnabled ? HelloXTheme.disabledForeground(for: colorScheme)
                : isSelected ? HelloXTheme.accent : HelloXTheme.secondaryText(for: colorScheme))
            .background(!isEnabled ? Color.clear
                : configuration.isPressed ? HelloXTheme.pressedBackground(for: colorScheme)
                : isSelected ? HelloXTheme.accent.opacity(0.1)
                : isHovered && isEnabled ? HelloXTheme.hoverBackground(for: colorScheme) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .overlay {
                if isFocused && isEnabled {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(HelloXTheme.focusRing, lineWidth: 2)
                }
            }
            .onHover { isHovered = isEnabled && $0 }
    }
}
