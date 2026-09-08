import AppKit
import SwiftUI

/// The reference sidebar uses macOS wallpaper vibrancy, not a painted gradient.
struct HXSidebarMaterial: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // Codex's macOS window uses Electron vibrancy: "menu". The sidebar
        // material is substantially greyer and does not match that backdrop.
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .menu
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.backgroundColor = reduceTransparency
            ? NSColor(HelloXTheme.controlBackground(for: colorScheme)).cgColor : nil
    }
}
