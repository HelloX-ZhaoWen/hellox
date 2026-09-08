import SwiftUI

/// A shared settings input: a leading label above a single-line field. Secure
/// credentials use the same layout while retaining SecureField's masking.
struct HXFormField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var isSecure = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>, placeholder: String, isSecure: Bool = false) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(HXTypography.label)
                .foregroundStyle(HXTextStyle.primary)
            Group {
                if isSecure {
                    SecureField(title, text: $text, prompt: prompt)
                } else {
                    TextField(title, text: $text, prompt: prompt)
                }
            }
            .textFieldStyle(.plain)
            .font(HXTypography.body)
            .foregroundStyle(HXTextStyle.primary)
            .multilineTextAlignment(.leading)
            .autocorrectionDisabled()
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
            .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? HelloXTheme.focusRing : HelloXTheme.border(for: colorScheme),
                                  lineWidth: isFocused ? 1.5 : 1)
            }
            .accessibilityLabel(title)
        }
        .opacity(isEnabled ? 1 : 0.6)
    }

    private var prompt: Text {
        Text(placeholder).foregroundColor(HelloXTheme.secondaryText(for: colorScheme))
    }
}
