import AppKit
import Combine
import SwiftUI

enum SettingsWindowLayout {
    /// The 2110 × 1344 reference screenshot at 2× display scale.
    static let defaultSize = NSSize(width: 1055, height: 672)
    static let minimumSize = NSSize(width: 760, height: 560)
    static let sidebarWidth: CGFloat = 200
    // Apply the reference size once, then remember the user's resizing.
    static let frameAutosaveName = "HelloX.Settings.ReferenceSize"
}

extension Font {
    static func settingsSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(
            size: size,
            weight: weight,
            design: design
        )
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        let window = HelloXWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.mainDestination.title
        window.minSize = SettingsWindowLayout.minimumSize
        window.contentMinSize = SettingsWindowLayout.minimumSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        HelloXWindowStyle.applySettingsReference(to: window)
        let hostingController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(model)
        )
        // The sidebar draws behind the traffic lights. Opt out at the hosting
        // boundary as well; ignoresSafeArea alone leaves an AppKit titlebar gap.
        hostingController.safeAreaRegions = []
        window.contentViewController = hostingController
        window.contentView?.layoutSubtreeIfNeeded()
        // Hosting the split view can apply its intrinsic minimum. Restore the
        // saved frame after attaching it so first launch keeps the intended size.
        if !window.setFrameUsingName(SettingsWindowLayout.frameAutosaveName) {
            window.setContentSize(SettingsWindowLayout.defaultSize)
            window.center()
        }
        window.setFrameAutosaveName(SettingsWindowLayout.frameAutosaveName)
        super.init(window: window)
        window.delegate = self
        model.$mainDestination.removeDuplicates().sink { [weak window] destination in
            window?.title = destination.title
            window?.titleVisibility = .hidden
        }.store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        HelloXWindowStyle.positionSettingsWindowControls(in: window)
    }
}
