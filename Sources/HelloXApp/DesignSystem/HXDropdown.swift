import AppKit
import SwiftUI

enum HXDropdownMetrics {
    // Codex text-sm line height with five points of padding above and below.
    static let rowHeight: CGFloat = 13 * (1.25 / 0.875) + 10
    static let menuPadding: CGFloat = 4
}

struct HXDropdownOption<Value: Hashable> {
    let value: Value
    let title: String
    var image: NSImage?
    var searchTerms = ""
    var isEnabled = true

    init(_ value: Value, _ title: String, image: NSImage? = nil, searchTerms: String = "", isEnabled: Bool = true) {
        self.value = value
        self.title = title
        self.image = image
        self.searchTerms = searchTerms
        self.isEnabled = isEnabled
    }
}

/// A compact selector with the same trigger and floating list on every surface.
/// Options remain text-only unless their original control already has an icon.
struct HXDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [HXDropdownOption<Value>]
    var displayTitle: String?
    var searchPlaceholder: String?
    var menuWidth: CGFloat = 220
    var triggerWidth: CGFloat?
    var showsChevron = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false
    @State private var isHovered = false
    @StateObject private var state = HXDropdownListState<Value>()
    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [HXDropdownOption<Value>],
        displayTitle: String? = nil,
        searchPlaceholder: String? = nil,
        menuWidth: CGFloat = 220,
        triggerWidth: CGFloat? = nil,
        showsChevron: Bool = true
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.displayTitle = displayTitle
        self.searchPlaceholder = searchPlaceholder
        self.menuWidth = menuWidth
        self.triggerWidth = triggerWidth
        self.showsChevron = showsChevron
    }

    private var selectedTitle: String {
        options.first(where: { $0.value == selection })?.title ?? "请选择"
    }

    private var selectedImage: NSImage? {
        guard displayTitle == nil else { return nil }
        return options.first(where: { $0.value == selection })?.image
    }

    private var visibleOptions: [HXDropdownOption<Value>] { state.filtered(options) }
    private var canInteract: Bool { isEnabled && options.contains(where: \.isEnabled) }

    private var menuHeight: CGFloat {
        CGFloat(max(1, min(9, visibleOptions.count))) * HXDropdownMetrics.rowHeight
            + 2 * HXDropdownMetrics.menuPadding + (searchPlaceholder == nil ? 0 : 42)
    }

    var body: some View {
        Button {
            if isPresented { isPresented = false }
            else { present() }
        } label: {
            HStack(spacing: 6) {
                HStack(spacing: 8) {
                    if let selectedImage {
                        Image(nsImage: selectedImage)
                            .resizable()
                            .renderingMode(canInteract ? .original : .template)
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                    }
                    Text(displayTitle ?? selectedTitle)
                        .font(.system(size: 14, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if triggerWidth != nil {
                    Spacer(minLength: 0)
                }
                if showsChevron {
                    HelloXIcon(icon: .chevronDown, size: 12)
                        .foregroundStyle(canInteract ? HelloXTheme.secondaryText(for: colorScheme) : HelloXTheme.disabledForeground(for: colorScheme))
                }
            }
            .foregroundStyle(canInteract ? HelloXTheme.primaryText(for: colorScheme) : HelloXTheme.disabledForeground(for: colorScheme))
            .padding(.horizontal, 12)
            .frame(width: triggerWidth, height: 28)
            .background(triggerBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(canInteract && isFocused ? HelloXTheme.focusRing : triggerBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HXDropdownButtonStyle())
        .onHover { isHovered = canInteract && $0 }
        .focused($isFocused)
        .focusEffectDisabled()
        .disabled(!canInteract)
        .accessibilityLabel(title)
        .accessibilityValue(displayTitle == nil ? selectedTitle : "")
        .accessibilityHint("打开选项列表")
        .onKeyPress(.downArrow) {
            guard canInteract else { return .ignored }
            present()
            return .handled
        }
        .background {
            HXDropdownAnchor(
                isPresented: $isPresented,
                width: menuWidth,
                height: menuHeight,
                colorScheme: colorScheme,
                prepareDismiss: { state.dismissPopup = $0 },
                onKeyDown: handleKey
            ) {
                HXDropdownList(
                    title: title,
                    selection: selection,
                    options: options,
                    state: state,
                    searchPlaceholder: searchPlaceholder,
                    onSelect: choose
                )
                .frame(width: menuWidth, height: menuHeight)
            }
        }
        .onChange(of: canInteract) { _, enabled in
            if !enabled {
                state.dismissPopup?()
                isPresented = false
                isHovered = false
            }
        }
    }

    private var triggerBackground: Color {
        if !canInteract { return HelloXTheme.disabledBackground(for: colorScheme) }
        guard isPresented || isHovered else { return HelloXTheme.surface(for: colorScheme) }
        return colorScheme == .dark ? HelloXTheme.controlBackground(for: colorScheme)
            : Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
    }

    private var triggerBorder: Color {
        if !canInteract { return HelloXTheme.disabledBorder(for: colorScheme) }
        return colorScheme == .dark ? HelloXTheme.border(for: colorScheme)
            : Color(red: 229 / 255, green: 229 / 255, blue: 230 / 255)
    }

    private func present() {
        guard canInteract else { return }
        state.query = ""
        state.highlighted = options.first(where: { $0.value == selection && $0.isEnabled })?.value
            ?? options.first(where: \.isEnabled)?.value
        isPresented = true
    }

    private func choose(_ option: HXDropdownOption<Value>) {
        guard isEnabled, option.isEnabled else { return }
        // Close and release the key window before a selection action can open
        // a save sheet, a modal panel, or change the application's appearance.
        state.dismissPopup?()
        isPresented = false
        selection = option.value
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
        switch event.keyCode {
        case 125: state.move(1, in: visibleOptions); return true
        case 126: state.move(-1, in: visibleOptions); return true
        case 36, 76:
            if let option = visibleOptions.first(where: { $0.value == state.highlighted && $0.isEnabled }) {
                choose(option)
            }
            return true
        default:
            guard searchPlaceholder == nil,
                  let characters = event.characters,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            state.highlightMatchingPrefix(characters, in: options)
            return true
        }
    }
}

struct HXDropdownAction {
    let title: String
    var image: NSImage?
    var isEnabled = true
    let action: () -> Void

    init(_ title: String, image: NSImage? = nil, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.image = image
        self.isEnabled = isEnabled
        self.action = action
    }
}

struct HXDropdownMenu: View {
    let title: String
    let actions: [HXDropdownAction]
    var showsChevron = true

    init(_ title: String, showsChevron: Bool = true, actions: [HXDropdownAction]) {
        self.title = title
        self.actions = actions
        self.showsChevron = showsChevron
    }

    var body: some View {
        HXDropdown(
            title,
            selection: Binding<Int?>(get: { nil }, set: { index in
                guard let index, actions.indices.contains(index), actions[index].isEnabled else { return }
                actions[index].action()
            }),
            options: actions.enumerated().map {
                HXDropdownOption(Optional($0.offset), $0.element.title, image: $0.element.image, isEnabled: $0.element.isEnabled)
            },
            displayTitle: title,
            showsChevron: showsChevron
        )
    }
}

@MainActor
final class HXDropdownListState<Value: Hashable>: ObservableObject {
    @Published var query = ""
    @Published var highlighted: Value?
    var dismissPopup: (() -> Void)?
    private var typedPrefix = ""
    private var lastTypedAt = Date.distantPast

    func filtered(_ options: [HXDropdownOption<Value>]) -> [HXDropdownOption<Value>] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(term) || $0.searchTerms.localizedCaseInsensitiveContains(term)
        }
    }

    func move(_ step: Int, in options: [HXDropdownOption<Value>]) {
        let enabled = options.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        let current = enabled.firstIndex(where: { $0.value == highlighted }) ?? (step > 0 ? -1 : enabled.count)
        highlighted = enabled[min(max(current + step, 0), enabled.count - 1)].value
    }

    func highlightMatchingPrefix(_ characters: String, in options: [HXDropdownOption<Value>]) {
        if Date().timeIntervalSince(lastTypedAt) > 0.8 { typedPrefix = "" }
        typedPrefix += characters
        lastTypedAt = Date()
        if let match = options.first(where: {
            $0.isEnabled && $0.title.range(of: typedPrefix, options: [.anchored, .caseInsensitive]) != nil
        }) { highlighted = match.value }
    }
}

struct HXDropdownList<Value: Hashable>: View {
    let title: String
    let selection: Value
    let options: [HXDropdownOption<Value>]
    @ObservedObject var state: HXDropdownListState<Value>
    let searchPlaceholder: String?
    let onSelect: (HXDropdownOption<Value>) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool

    private var visibleOptions: [HXDropdownOption<Value>] { state.filtered(options) }

    var body: some View {
        VStack(spacing: 0) {
            if let searchPlaceholder {
                HXSearchField(searchPlaceholder, text: $state.query, focus: $isSearchFocused)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if visibleOptions.isEmpty {
                            Text("没有匹配选项")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                                .frame(maxWidth: .infinity, minHeight: HXDropdownMetrics.rowHeight)
                        }
                        ForEach(visibleOptions, id: \.value) { option in
                            Button { onSelect(option) } label: {
                                HStack(spacing: 8) {
                                    if let image = option.image {
                                        Image(nsImage: image)
                                            .resizable()
                                            .renderingMode(option.isEnabled ? .original : .template)
                                            .scaledToFit()
                                            .frame(width: 16, height: 16)
                                            .accessibilityHidden(true)
                                    }
                                    Text(option.title)
                                        .lineLimit(1)
                                }
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(option.isEnabled ? HelloXTheme.primaryText(for: colorScheme) : HelloXTheme.disabledForeground(for: colorScheme))
                                    .frame(maxWidth: .infinity, minHeight: HXDropdownMetrics.rowHeight, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .background {
                                        if option.isEnabled && state.highlighted == option.value {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(HelloXTheme.hoverBackground(for: colorScheme))
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(HXDropdownButtonStyle())
                            .disabled(!option.isEnabled)
                            .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                            .onHover { hovering in
                                if hovering, option.isEnabled { state.highlighted = option.value }
                            }
                            .id(option.value)
                        }
                    }
                    .padding(.horizontal, HXDropdownMetrics.menuPadding)
                }
                .scrollIndicators(.hidden)
                .onChange(of: state.highlighted) { _, value in
                    if let value { proxy.scrollTo(value) }
                }
                .onAppear {
                    if let value = state.highlighted { proxy.scrollTo(value, anchor: .center) }
                }
            }
            .padding(.vertical, HXDropdownMetrics.menuPadding)
        }
        .background(HelloXTheme.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(colorScheme == .dark ? HelloXTheme.border(for: colorScheme) : Color(white: 239 / 255), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onAppear { isSearchFocused = searchPlaceholder != nil }
        .onChange(of: state.query) { _, _ in
            state.highlighted = visibleOptions.first(where: \.isEnabled)?.value
        }
    }
}

/// A child panel avoids the native menu's blue selection and popover arrow while
/// keeping dismissal independent of whichever view hosts the dropdown.
private struct HXDropdownAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let width: CGFloat
    let height: CGFloat
    let colorScheme: ColorScheme
    let prepareDismiss: (@escaping () -> Void) -> Void
    let onKeyDown: (NSEvent) -> Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> HXDropdownPresenter { HXDropdownPresenter() }

    func makeNSView(context: Context) -> NSView { HXDropdownAnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let presenter = context.coordinator
        prepareDismiss { [weak presenter] in presenter?.dismiss(notify: false) }
        presenter.update(
            anchor: nsView,
            isPresented: isPresented,
            size: NSSize(width: width, height: height),
            colorScheme: colorScheme,
            content: AnyView(content().environment(\.colorScheme, colorScheme)),
            onKeyDown: onKeyDown,
            onDismiss: { isPresented = false }
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: HXDropdownPresenter) {
        coordinator.dismiss(notify: false)
    }
}

@MainActor
private final class HXDropdownPresenter {
    private var panel: HXDropdownPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private weak var anchorView: NSView?
    private var onKeyDown: ((NSEvent) -> Bool)?
    private var onDismiss: (() -> Void)?

    func update(
        anchor: NSView,
        isPresented: Bool,
        size: NSSize,
        colorScheme: ColorScheme,
        content: AnyView,
        onKeyDown: @escaping (NSEvent) -> Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.onKeyDown = onKeyDown
        self.onDismiss = onDismiss
        self.anchorView = anchor
        guard isPresented, let parent = anchor.window else {
            dismiss(notify: false)
            return
        }
        let panel: HXDropdownPanel
        if let existing = self.panel {
            panel = existing
            hostingView?.rootView = content
        } else {
            panel = HXDropdownPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = true
            let hosting = NSHostingView(rootView: content)
            panel.contentView = hosting
            hostingView = hosting
            self.panel = panel
            parent.addChildWindow(panel, ordered: .above)
            installMonitors()
            installLifecycleObservers(parent: parent)
        }
        panel.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let trigger = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visibleFrame = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? trigger
        let x = min(max(trigger.maxX - size.width, visibleFrame.minX + 6), visibleFrame.maxX - size.width - 6)
        let below = trigger.minY - 2 - size.height
        let y = below >= visibleFrame.minY + 6 ? below : min(trigger.maxY + 2, visibleFrame.maxY - size.height - 6)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    func dismiss(notify: Bool = true) {
        guard let closing = panel else { return }
        panel = nil
        hostingView = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        let parent = closing.parent
        let restoresKey = closing.isKeyWindow
        parent?.removeChildWindow(closing)
        closing.orderOut(nil)
        closing.close()
        if restoresKey, NSApplication.shared.isActive { parent?.makeKey() }
        if notify { onDismiss?() }
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                guard event.window === panel else { return event }
                // An input method owns Return, arrows and Escape until its
                // composition is committed or cancelled.
                if let inputClient = panel.firstResponder as? NSTextInputClient,
                   inputClient.hasMarkedText() { return event }
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                if event.keyCode == 48 {
                    let parent = panel.parent
                    self.dismiss()
                    if event.modifierFlags.contains(.shift) { parent?.selectPreviousKeyView(nil) }
                    else { parent?.selectNextKeyView(nil) }
                    return nil
                }
                return self.onKeyDown?(event) == true ? nil : event
            }
            if event.window !== panel {
                let clickedTrigger: Bool
                if let anchor = self.anchorView, event.window === anchor.window {
                    clickedTrigger = anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                } else { clickedTrigger = false }
                self.dismiss()
                // Do not let the same press reopen the trigger after dismissal.
                if clickedTrigger { return nil }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func installLifecycleObservers(parent: NSWindow) {
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApplication.shared, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        ]
    }
}

private final class HXDropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HXDropdownAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// The label supplies its disabled colors; PlainButtonStyle would dim them again.
private struct HXDropdownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
