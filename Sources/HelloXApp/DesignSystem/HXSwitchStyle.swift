import SwiftUI

/// Codex's standard 32 × 20 switch, retaining Toggle accessibility behavior.
struct HXSwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? HelloXTheme.accent : HelloXTheme.primaryText(for: colorScheme).opacity(0.1))
                .frame(width: 32, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}
