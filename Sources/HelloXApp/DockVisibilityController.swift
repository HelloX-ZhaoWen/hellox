import AppKit

/// Only normal work windows participate. The island, pinned images, capture
/// overlays and temporary popovers remain menu-bar utilities without a Dock icon.
@MainActor
final class DockVisibilityController {
    static let shared = DockVisibilityController { policy in
        guard NSApp.activationPolicy() != policy else { return }
        if NSApp.setActivationPolicy(policy), policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private let windows = NSHashTable<NSWindow>.weakObjects()
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Void
    private var started = false
    private var currentPolicy: NSApplication.ActivationPolicy?

    init(applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Void) {
        self.applyPolicy = applyPolicy
    }

    func start(windows initialWindows: [NSWindow] = []) {
        guard !started else { return }
        started = true
        for window in initialWindows { windows.add(window) }
        updatePolicy()
    }

    func windowWillShow(_ window: NSWindow) {
        guard started else { return }
        windows.add(window)
        updatePolicy()
    }

    func windowDidClose(_ window: NSWindow) {
        guard started else { return }
        windows.remove(window)
        updatePolicy()
    }

    private func updatePolicy() {
        // Track open windows, not visibility: minimizing or hiding the app
        // must preserve its Dock entry so the user can restore those windows.
        let policy: NSApplication.ActivationPolicy = windows.allObjects.isEmpty ? .accessory : .regular
        guard policy != currentPolicy else { return }
        currentPolicy = policy
        applyPolicy(policy)
    }
}
