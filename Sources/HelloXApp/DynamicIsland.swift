import AppKit
import Combine
import SwiftUI

@MainActor
final class DynamicIslandViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var isPresented = false

    let appModel: AppModel
    let dispatcher: HelloXActionDispatcher
    let overflowService: MenuBarOverflowService
    let preferencesStore: DynamicIslandPreferencesStore
    var prepareForExternalAction: (() -> Void)?
    var dismissRequested: (() -> Void)?
    var expansionDidChange: (() -> Void)?

    init(model: AppModel, dispatcher: HelloXActionDispatcher) {
        appModel = model
        self.dispatcher = dispatcher
        overflowService = model.menuBarOverflowService
        preferencesStore = model.dynamicIslandPreferences
    }

    var selectedSection: DynamicIslandSection {
        get { preferencesStore.value.selectedSection }
        set {
            var preferences = preferencesStore.value
            preferences.selectedSection = newValue
            preferencesStore.value = preferences
        }
    }

    var displayedMenuBarItems: [MenuBarItemDescriptor] {
        RunningApplicationCatalog.ordered(overflowService.items, preferences: preferencesStore.value)
    }

    func toggleExpanded() {
        isExpanded.toggle()
        expansionDidChange?()
    }

    func collapse() {
        dismissRequested?()
    }

    func select(_ section: DynamicIslandSection) {
        guard selectedSection != section else { return }
        selectedSection = section
    }

    func perform(_ action: ShortcutAction) {
        prepareForExternalAction?()
        dispatcher.perform(action, source: .dynamicIsland)
    }

    func activate(_ item: MenuBarItemDescriptor) {
        prepareForExternalAction?()
        Task { [weak self] in
            guard let self else { return }
            if !(await overflowService.openApplication(for: item)) {
                CopyFeedbackPresenter.shared.showFailure("无法打开 \(item.applicationName)")
            }
        }
    }

    func openSettings() {
        prepareForExternalAction?()
        appModel.showSettingsWindow(destination: .dynamicIsland)
    }
}

@MainActor
final class DynamicIslandWindowController: NSObject {
    static let defaultCollapsedSize = NSSize(width: 240, height: 36)
    static let defaultExpandedSize = NSSize(width: 620, height: 380)

    private let panel: DynamicIslandPanel
    private let viewModel: DynamicIslandViewModel
    private let appModel: AppModel
    private let preferencesStore: DynamicIslandPreferencesStore
    private let menuBarReservationItem = NSStatusBar.system.statusItem(withLength: 0)
    private var cancellables: Set<AnyCancellable> = []
    private var localEventMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var autoHideTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var visibilityGeneration = 0
    private var lastAppliedExpandedState = false
    private var isCollapsedTriggerVisible = false
    private var isCollapseInProgress = false
    private var waitsForPointerExitBeforeShowing = false
    private var started = false

    init(model: AppModel, dispatcher: HelloXActionDispatcher) {
        appModel = model
        preferencesStore = model.dynamicIslandPreferences
        viewModel = DynamicIslandViewModel(model: model, dispatcher: dispatcher)
        panel = DynamicIslandPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultCollapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.tabbingMode = .disallowed
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        menuBarReservationItem.isVisible = false
        if let reservationButton = menuBarReservationItem.button {
            reservationButton.image = nil
            reservationButton.title = ""
            reservationButton.isEnabled = false
            reservationButton.alphaValue = 0
        }
        let hostingView = NSHostingView(
            rootView: DynamicIslandView(viewModel: viewModel)
                .preferredColorScheme(.dark)
        )
        panel.contentView = hostingView
        panel.contentView?.autoresizingMask = [.width, .height]
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        viewModel.prepareForExternalAction = { [weak self] in self?.hideForExternalAction() }
        viewModel.dismissRequested = { [weak self] in
            self?.dismissIsland(waitsForPointerExit: false)
        }
        viewModel.expansionDidChange = { [weak self] in self?.updateWindow() }
        bindState()
    }

    func start() {
        guard !started else { return }
        started = true
        if preferencesStore.value.isEnabled {
            appModel.menuBarOverflowService.start()
        }
        installPointerMonitors()
        updateWindow()
    }

    func stop() {
        started = false
        cancelAutoHide()
        cancelVisibilityTransition()
        cancelCollapseTransition()
        panel.orderOut(nil)
        releaseMenuBarSpace()
        removeEventMonitors()
        removePointerMonitors()
        appModel.menuBarOverflowService.stop()
    }

    private func bindState() {
        appModel.$isDynamicIslandSuppressed
            .removeDuplicates()
            .sink { [weak self] isSuppressed in
                guard let self else { return }
                if isSuppressed {
                    hideImmediatelyForCapture()
                } else {
                    updateWindow()
                }
            }
            .store(in: &cancellables)

        preferencesStore.$value
            .removeDuplicates()
            .sink { [weak self] preferences in
                guard let self else { return }
                if started {
                    if preferences.isEnabled { appModel.menuBarOverflowService.start() }
                    else {
                        dismissIsland(waitsForPointerExit: false)
                        appModel.menuBarOverflowService.stop()
                    }
                }
                updateWindow()
            }
            .store(in: &cancellables)

        viewModel.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                guard let self else { return }
                configureEventMonitors(expanded: expanded)
                appModel.menuBarOverflowService.setPresentationActive(expanded)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.updateWindow() }
            .store(in: &cancellables)

        appModel.menuBarOverflowService.$items
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, viewModel.isExpanded,
                      preferencesStore.value.selectedSection == .menuBar else { return }
                updateWindow()
            }
            .store(in: &cancellables)
    }

    private func updateWindow() {
        guard started,
              preferencesStore.value.isEnabled,
              !appModel.isDynamicIslandSuppressed else {
            hidePanel(animated: false)
            return
        }

        configureCollectionBehavior()
        let screen = targetScreen()
        if waitsForPointerExitBeforeShowing {
            if collapsedTriggerHotZone(for: screen).contains(NSEvent.mouseLocation) {
                hidePanel(animated: false)
                return
            }
            waitsForPointerExitBeforeShowing = false
        }
        let size = viewModel.isExpanded ? expandedSize(for: screen) : collapsedSize(for: screen)
        let targetFrame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        let expansionChanged = lastAppliedExpandedState != viewModel.isExpanded
        if panel.frame != targetFrame {
            if panel.isVisible, expansionChanged,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.allowsImplicitAnimation = true
                    panel.animator().setFrame(targetFrame, display: true)
                }
            } else {
                panel.setFrame(targetFrame, display: true)
            }
        }
        lastAppliedExpandedState = viewModel.isExpanded

        if viewModel.isExpanded {
            isCollapsedTriggerVisible = false
            panel.ignoresMouseEvents = false
            presentPanel(makeKey: true)
        } else if isCollapseInProgress {
            // Pointer movement and hover detection must not revive the pill
            // while the expanded island is animating back into it.
            panel.ignoresMouseEvents = true
        } else {
            updateCollapsedTriggerVisibility(for: screen)
        }
    }

    private func refreshCollapsedPointerState() {
        guard started,
              preferencesStore.value.isEnabled,
              !appModel.isDynamicIslandSuppressed,
              !isCollapseInProgress else { return }

        let screen = targetScreen()
        let size = collapsedSize(for: screen)
        let expectedFrame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if panel.frame != expectedFrame {
            panel.setFrame(expectedFrame, display: true)
        }
        updateCollapsedTriggerVisibility(for: screen)
    }

    private func updateCollapsedTriggerVisibility(for screen: NSScreen) {
        let pointer = NSEvent.mouseLocation
        let shouldShow = collapsedTriggerHotZone(for: screen).contains(pointer)
            || (isCollapsedTriggerVisible && panel.frame.contains(pointer))
        if shouldShow {
            cancelAutoHide()
            setCollapsedTriggerVisible(true)
        } else if isCollapsedTriggerVisible {
            scheduleAutoHide()
        }
    }

    private func setCollapsedTriggerVisible(_ visible: Bool) {
        if visible, isCollapseInProgress { return }
        guard isCollapsedTriggerVisible != visible else { return }
        isCollapsedTriggerVisible = visible
        panel.ignoresMouseEvents = !visible
        if visible {
            presentPanel(makeKey: false)
        } else {
            hidePanel(animated: true)
        }
    }

    private func presentPanel(makeKey: Bool) {
        cancelCollapseTransition()
        cancelVisibilityTransition()
        reserveMenuBarSpace(for: panel.frame.width)
        panel.alphaValue = 1
        if panel.isVisible {
            viewModel.isPresented = true
            if makeKey, !panel.isKeyWindow { panel.makeKey() }
            return
        }
        viewModel.isPresented = false
        panel.orderFrontRegardless()
        if makeKey, !panel.isKeyWindow { panel.makeKey() }
        panel.contentView?.layoutSubtreeIfNeeded()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        visibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled,
                  let self,
                  visibilityGeneration == generation else { return }
            visibilityTask = nil
            viewModel.isPresented = true
        }
    }

    private func hidePanel(animated: Bool) {
        cancelVisibilityTransition()
        panel.ignoresMouseEvents = true
        guard panel.isVisible, animated else {
            viewModel.isPresented = false
            panel.alphaValue = 0
            panel.orderOut(nil)
            releaseMenuBarSpace()
            return
        }

        visibilityGeneration += 1
        let generation = visibilityGeneration
        viewModel.isPresented = false
        visibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled,
                  let self,
                  visibilityGeneration == generation else { return }
            visibilityTask = nil
            panel.alphaValue = 0
            panel.orderOut(nil)
            releaseMenuBarSpace()
        }
    }

    private func reserveMenuBarSpace(for islandWidth: CGFloat) {
        // A transparent status item participates in the system menu-bar layout.
        // Reserving the island's right half lets macOS move or overflow nearby
        // status items before our centered panel becomes visible.
        let reservedWidth = min(360, max(0, islandWidth / 2 + 12))
        menuBarReservationItem.length = reservedWidth
        menuBarReservationItem.isVisible = reservedWidth > 0
    }

    private func releaseMenuBarSpace() {
        menuBarReservationItem.isVisible = false
        menuBarReservationItem.length = 0
    }

    private func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func expandedSize(for screen: NSScreen) -> NSSize {
        // Keep expansion deterministic. Item scans and adaptive-grid rounding
        // must not change the island between presentations.
        let width = min(Self.defaultExpandedSize.width, max(320, screen.visibleFrame.width - 32))
        let height = min(Self.defaultExpandedSize.height, max(260, screen.visibleFrame.height - 16))
        return NSSize(width: width, height: height)
    }

    private func collapsedSize(for screen: NSScreen) -> NSSize {
        let notchWidth = notchRect(for: screen)?.width ?? 0
        let width = min(screen.frame.width - 32, max(Self.defaultCollapsedSize.width, notchWidth + 112))
        return NSSize(width: width, height: Self.defaultCollapsedSize.height)
    }

    private func collapsedTriggerHotZone(for screen: NSScreen) -> NSRect {
        if let notch = notchRect(for: screen) {
            return notch.insetBy(dx: -4, dy: -2)
        }
        return NSRect(x: screen.frame.midX - 90, y: screen.frame.maxY - 8, width: 180, height: 8)
    }

    private func notchRect(for screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.maxX < right.minX else { return nil }
        return NSRect(
            x: left.maxX,
            y: min(left.minY, right.minY),
            width: right.minX - left.maxX,
            height: max(left.height, right.height)
        )
    }

    private func configureCollectionBehavior() {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
        if preferencesStore.value.showsInFullScreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior
    }

    private func hideForExternalAction() {
        dismissIsland(waitsForPointerExit: true)
    }

    private func hideImmediatelyForCapture() {
        dismissIsland(waitsForPointerExit: true)
    }

    private func dismissIsland(waitsForPointerExit: Bool) {
        cancelAutoHide()
        if isCollapseInProgress {
            if waitsForPointerExit {
                cancelCollapseTransition()
                waitsForPointerExitBeforeShowing = true
                viewModel.isExpanded = false
                hidePanel(animated: false)
            }
            return
        }
        waitsForPointerExitBeforeShowing = waitsForPointerExit
        isCollapsedTriggerVisible = false
        removeEventMonitors()

        guard viewModel.isExpanded, !waitsForPointerExit else {
            viewModel.isExpanded = false
            hidePanel(animated: !waitsForPointerExit)
            return
        }

        // First return the expanded island to its menu-bar pill, then fade the
        // pill away. Keeping these as distinct phases prevents the expanded
        // card from vanishing before the window resize animation finishes.
        // Suppress the hover trigger until the pointer has left the notch;
        // otherwise the close-button pointer can immediately present the pill
        // again and create an endless show/hide flicker loop.
        isCollapseInProgress = true
        waitsForPointerExitBeforeShowing = true
        viewModel.isExpanded = false
        updateWindow()
        panel.ignoresMouseEvents = true
        collapseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 80 : 340
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            hidePanel(animated: true)
            try? await Task.sleep(for: .milliseconds(210))
            guard !Task.isCancelled else { return }
            isCollapseInProgress = false
            collapseTask = nil
        }
    }

    private func configureEventMonitors(expanded: Bool) {
        removeEventMonitors()
        guard expanded else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                dismissIsland(waitsForPointerExit: false)
                return nil
            }
            if event.window !== panel {
                dismissIsland(waitsForPointerExit: false)
            } else {
                cancelAutoHide()
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismissIsland(waitsForPointerExit: false)
            }
        }
    }

    private func installPointerMonitors() {
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePointerMovement()
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.handlePointerMovement() }
        }
    }

    private func removePointerMonitors() {
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        localPointerMonitor = nil
        globalPointerMonitor = nil
    }

    private func handlePointerMovement() {
        guard started,
              preferencesStore.value.isEnabled,
              !appModel.isDynamicIslandSuppressed,
              !isCollapseInProgress else {
            cancelAutoHide()
            return
        }

        let screen = targetScreen()
        let pointer = NSEvent.mouseLocation
        let isInHotZone = collapsedTriggerHotZone(for: screen).contains(pointer)
        let isInPanel = panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(pointer)

        if waitsForPointerExitBeforeShowing {
            guard !isInHotZone, !isInPanel else { return }
            waitsForPointerExitBeforeShowing = false
        }

        if viewModel.isExpanded {
            if isInPanel {
                cancelAutoHide()
            } else {
                scheduleAutoHide()
            }
        } else {
            refreshCollapsedPointerState()
        }
    }

    private func scheduleAutoHide() {
        guard autoHideTask == nil, !isCollapseInProgress else { return }
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            autoHideTask = nil
            let screen = targetScreen()
            let pointer = NSEvent.mouseLocation
            let isInHotZone = collapsedTriggerHotZone(for: screen).contains(pointer)
            let isInPanel = panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(pointer)
            guard !isInHotZone, !isInPanel else { return }
            dismissIsland(waitsForPointerExit: false)
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func cancelVisibilityTransition() {
        visibilityGeneration += 1
        visibilityTask?.cancel()
        visibilityTask = nil
    }

    private func cancelCollapseTransition() {
        collapseTask?.cancel()
        collapseTask = nil
        isCollapseInProgress = false
    }

    private func removeEventMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localEventMonitor = nil
        globalMouseMonitor = nil
    }
}

private final class DynamicIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum DynamicIslandTheme {
    static let background = Color.black
    static let surface = HelloXTheme.raisedSurface(for: .dark)
    static let primaryText = HelloXTheme.primaryText(for: .dark)
    static let secondaryText = HelloXTheme.secondaryText(for: .dark)
    static let accent = HelloXTheme.accent
    static let control = HelloXTheme.controlBackground(for: .dark)
    static let selected = HelloXTheme.selectedBackground(for: .dark)
    static let pressed = HelloXTheme.pressedBackground(for: .dark)
    static let border = Color.white.opacity(0.08)
}

private struct DynamicIslandNotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct DynamicIslandView: View {
    @ObservedObject var viewModel: DynamicIslandViewModel
    @ObservedObject private var appModel: AppModel
    @ObservedObject private var overflowService: MenuBarOverflowService
    @ObservedObject private var preferencesStore: DynamicIslandPreferencesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: DynamicIslandViewModel) {
        self.viewModel = viewModel
        appModel = viewModel.appModel
        overflowService = viewModel.overflowService
        preferencesStore = viewModel.preferencesStore
    }

    var body: some View {
        GeometryReader { proxy in
            let shape = DynamicIslandNotchShape(bottomRadius: shellBottomRadius)
            ZStack(alignment: .top) {
                islandShell(size: proxy.size)
                if viewModel.isExpanded {
                    expandedContent
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipShape(shape)
                } else {
                    collapsedContent
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipShape(shape)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(shape)
        }
        .foregroundStyle(DynamicIslandTheme.primaryText)
        .tint(DynamicIslandTheme.accent)
        .scaleEffect(
            x: reduceMotion || viewModel.isPresented ? 1 : 0.08,
            y: reduceMotion || viewModel.isPresented ? 1 : 0.94,
            anchor: .center
        )
        .opacity(viewModel.isPresented ? 1 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: viewModel.isPresented)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84), value: viewModel.isExpanded)
    }

    private var collapsedContent: some View {
        Button(action: viewModel.toggleExpanded) {
            HStack(spacing: 10) {
                islandBrandMark(size: 18)
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color(red: 112 / 255, green: 230 / 255, blue: 155 / 255))
                        .frame(width: 6, height: 6)
                    Text("\(viewModel.displayedMenuBarItems.count) 个")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .foregroundStyle(DynamicIslandTheme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel("展开 HelloX 灵动岛，正在运行 \(viewModel.displayedMenuBarItems.count) 个应用")
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            header
            sectionPicker
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            Group {
                if preferencesStore.value.selectedSection == .menuBar { menuBarContent }
                else { helloXContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
    }

    private func islandShell(size: CGSize) -> some View {
        let shape = DynamicIslandNotchShape(bottomRadius: shellBottomRadius)
        return shape
            .fill(DynamicIslandTheme.background)
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
    }

    private var shellBottomRadius: CGFloat {
        viewModel.isExpanded ? 28 : 12
    }

    private var header: some View {
        HStack(spacing: 9) {
            islandBrandMark(size: 23)
            VStack(alignment: .leading, spacing: 1) {
                Text("HelloX 灵动岛")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("运行中应用与效率工具集中入口")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DynamicIslandTheme.secondaryText)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 112 / 255, green: 230 / 255, blue: 155 / 255))
                    .frame(width: 6, height: 6)
                Text("\(viewModel.displayedMenuBarItems.count) 项")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(DynamicIslandTheme.secondaryText)
            }
            Button(action: viewModel.collapse) {
                HelloXIcon(icon: .close, size: 12)
                    .frame(width: 26, height: 26)
                    .foregroundStyle(DynamicIslandTheme.secondaryText)
                    .background(DynamicIslandTheme.control, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起灵动岛")
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var sectionPicker: some View {
        HXSegmentedControl(
            "灵动岛内容",
            selection: Binding(
                get: { preferencesStore.value.selectedSection },
                set: { viewModel.select($0) }
            ),
            options: [
                HXSegment(.menuBar, "运行中应用"),
                HXSegment(.helloX, "HelloX")
            ]
        )
        .frame(maxWidth: .infinity)
    }

    private var menuBarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("运行中应用")
                    Spacer()
                    Button("刷新", action: overflowService.refreshManually)
                        .buttonStyle(.plain)
                        .foregroundStyle(DynamicIslandTheme.accent)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DynamicIslandTheme.secondaryText)

                if viewModel.displayedMenuBarItems.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("没有正在运行的应用")
                        } icon: {
                            HelloXIcon(icon: .window, size: 32)
                        }
                    } description: {
                        Text("应用启动后会自动显示在这里。")
                    }
                    .foregroundStyle(DynamicIslandTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    LazyVGrid(columns: adaptiveColumns, spacing: 8) {
                        ForEach(viewModel.displayedMenuBarItems) { item in
                            menuBarItemButton(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
        .codexScrollChrome()
    }

    private var helloXContent: some View {
        ScrollView {
            LazyVGrid(columns: adaptiveColumns, spacing: 8) {
                ForEach(preferencesStore.value.helloXActionOrder) { action in
                    helloXActionButton(action)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
        .codexScrollChrome()
    }

    private var adaptiveColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 72, maximum: 112), spacing: 8, alignment: .top),
            count: 6
        )
    }

    private func menuBarItemButton(_ item: MenuBarItemDescriptor) -> some View {
        Button { viewModel.activate(item) } label: {
            islandItemLabel(title: item.title, subtitle: preferencesStore.value.pinnedItemIDs.contains(item.preferenceID) ? "已置顶" : "正在运行") {
                MenuBarItemIcon(item: item)
            }
        }
        .buttonStyle(DynamicIslandItemButtonStyle())
        .help("切换到 \(item.applicationName)")
        .contextMenu {
            let pinned = preferencesStore.value.pinnedItemIDs.contains(item.preferenceID)
            Button(pinned ? "取消置顶" : "置顶") {
                preferencesStore.setPinned(item.preferenceID, pinned: !pinned)
            }
        }
    }

    private func helloXActionButton(_ action: ShortcutAction) -> some View {
        Button { viewModel.perform(action) } label: {
            islandItemLabel(
                title: action.settingsTitle,
                subtitle: appModel.shortcutBindings[action]?.displayName ?? ""
            ) {
                HelloXIcon(icon: action.icon, size: HelloXTheme.iconMedium)
            }
        }
        .buttonStyle(DynamicIslandItemButtonStyle())
        .help(action.settingsDescription)
    }

    private func islandItemLabel<Icon: View>(
        title: String,
        subtitle: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 5) {
            icon()
                .foregroundStyle(DynamicIslandTheme.primaryText)
                .frame(width: 28, height: 28)
                .background(DynamicIslandTheme.control, in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.system(size: 8))
                .foregroundStyle(DynamicIslandTheme.secondaryText)
                .lineLimit(1)
                .frame(height: 9)
        }
        .foregroundStyle(DynamicIslandTheme.primaryText)
        .padding(.horizontal, 5)
        .padding(.top, 7)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(preferencesStore.value.selectedSection == .menuBar
                 ? overflowService.statusMessage
                : "\(ShortcutAction.configurableCases.count) 个 HelloX 功能均可直接启动")
                .font(.system(size: 9.5))
                .foregroundStyle(DynamicIslandTheme.secondaryText)
                .lineLimit(1)
            Spacer()
            footerButton("设置", action: viewModel.openSettings)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .top) { Divider().overlay(DynamicIslandTheme.border) }
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 9.5, weight: .medium))
            .buttonStyle(.plain)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .foregroundStyle(Color.white)
            .background(DynamicIslandTheme.accent, in: RoundedRectangle(cornerRadius: 8))
    }

    private func islandBrandMark(size: CGFloat) -> some View {
        Group {
            if let image = DynamicIslandBrandLogo.image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(DynamicIslandTheme.primaryText)
            } else {
                Image(systemName: "infinity")
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(DynamicIslandTheme.primaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum DynamicIslandBrandLogo {
    static let image: NSImage? = {
        guard let url = HelloXResourceBundle.bundle.url(
            forResource: "HelloXMenuBarIcon",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()
}

private struct MenuBarItemIcon: View {
    let item: MenuBarItemDescriptor

    var body: some View {
        Group {
            if let image = NSRunningApplication(processIdentifier: item.processIdentifier)?.icon {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(4)
            } else if let bundleURL = item.bundleURL {
                Image(nsImage: ApplicationIconCache.icon(for: bundleURL))
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(4)
            } else {
                HelloXIcon(icon: .menuBar, size: HelloXTheme.iconMedium)
            }
        }
        .frame(width: 31, height: 31)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum ApplicationIconCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func icon(for bundleURL: URL) -> NSImage {
        let key = bundleURL as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct DynamicIslandItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? DynamicIslandTheme.pressed
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 11)
            )
    }
}
