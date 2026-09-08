import SwiftUI

/// Content groups and action rows shared by the main window and tool panels.
struct HXSettingsGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty {
                Text(title).font(HXTypography.section)
            }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HelloXTheme.raisedSurface(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: HelloXTheme.cardRadius)
                        .strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 1)
                }
            if let footer {
                Text(footer).font(HXTypography.caption)
                    .foregroundStyle(HXTextStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

struct HXSettingsDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View { Rectangle().fill(HelloXTheme.border(for: colorScheme)).frame(height: 0.5).padding(.horizontal, 16) }
}

/// Native controls need an explicit trailing column outside a Form.
struct HXSettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 16) {
            Text(title).font(HXTypography.label)
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct HXSettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HXSettingsRow(title: title) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(HXSwitchStyle())
        }
    }
}

/// Sidebar proportions follow the user's Codex reference; selection stays neutral.
struct HXSidebarRow: View {
    let title: String
    let icon: HelloXIconKey
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HelloXIcon(icon: icon, size: 16)
                    .foregroundStyle(isEnabled ? HelloXTheme.iconForeground(for: colorScheme) : HelloXTheme.disabledForeground(for: colorScheme))
                    .frame(width: 16)
                Text(title).font(HXTypography.sidebar)
                    .foregroundStyle(isEnabled ? HelloXTheme.primaryText(for: colorScheme) : HelloXTheme.disabledForeground(for: colorScheme))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HXSidebarRowStyle(isSelected: isSelected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HXSidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(!isEnabled ? HelloXTheme.disabledBackground(for: colorScheme) : HelloXTheme.sidebarSelectedBackground(for: colorScheme).opacity(
                configuration.isPressed ? 1.5 : isSelected ? 1 : isHovered ? 0.7 : 0
            ))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(HelloXTheme.disabledBorder(for: colorScheme), lineWidth: 1)
                } else if isFocused {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(HelloXTheme.focusRing, lineWidth: 2)
                }
            }
            .onHover { isHovered = isEnabled && $0 }
    }
}
