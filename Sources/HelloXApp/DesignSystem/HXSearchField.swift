import SwiftUI

/// The same search affordance in the sidebar, pages and selection panels.
struct HXSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.focus = focus
    }

    var body: some View {
        HStack(spacing: 8) {
            HelloXIcon(icon: .search, size: 18)
                .foregroundStyle(HelloXTheme.sidebarSearchForeground(for: colorScheme))
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                    if let focus { focus.wrappedValue = true }
                    else { internalFocus = true }
                } label: {
                    HelloXIcon(icon: .close, size: 12)
                        .foregroundStyle(HelloXTheme.sidebarSearchForeground(for: colorScheme))
                        .frame(width: 20, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(HelloXTheme.sidebarSearchBackground(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var field: some View {
        if let focus {
            textField.focused(focus)
        } else {
            textField.focused($internalFocus)
        }
    }

    private var textField: some View {
        TextField(placeholder, text: $text,
                  prompt: Text(placeholder)
                    .foregroundStyle(HelloXTheme.sidebarSearchForeground(for: colorScheme)))
            .textFieldStyle(.plain)
            .font(HXTypography.sidebar)
            .foregroundStyle(HXTextStyle.primary)
            .accessibilityLabel(placeholder)
    }
}
