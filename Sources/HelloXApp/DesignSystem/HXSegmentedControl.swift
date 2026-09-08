import SwiftUI

struct HXSegment<Value: Hashable> {
    let value: Value
    let title: String

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

enum HXSegmentedStyle {
    static func track(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0x25 / 255) : Color(white: 0xF6 / 255)
    }

    static func selection(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0x3A / 255) : .white
    }

    static func foreground(isSelected: Bool, for scheme: ColorScheme) -> Color {
        isSelected ? HelloXTheme.primaryText(for: scheme) : HelloXTheme.secondaryText(for: scheme)
    }

    static func shadow(for scheme: ColorScheme) -> Color {
        Color.black.opacity(0.08)
    }
}

/// One compact navigation style for fixed mode choices. The selected segment
/// remains a real button with focus, selected semantics and arrow-key movement.
struct HXSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [HXSegment<Value>]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedValue: Value?
    @Namespace private var selectionAnimation

    init(_ title: String, selection: Binding<Value>, options: [HXSegment<Value>]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        HXSegmentedRowLayout(isRightToLeft: layoutDirection == .rightToLeft) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(!isEnabled ? HelloXTheme.disabledForeground(for: colorScheme) : HXSegmentedStyle.foreground(
                            isSelected: selection == option.value, for: colorScheme
                        ))
                        .frame(height: 16)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if selection == option.value {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isEnabled ? HXSegmentedStyle.selection(for: colorScheme) : HelloXTheme.disabledBackground(for: colorScheme))
                                    .overlay {
                                        if !isEnabled {
                                            RoundedRectangle(cornerRadius: 8).strokeBorder(HelloXTheme.disabledBorder(for: colorScheme), lineWidth: 1)
                                        }
                                    }
                                    .shadow(color: isEnabled ? HXSegmentedStyle.shadow(for: colorScheme) : .clear, radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: selectionAnimation)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(HXSegmentButtonStyle())
                .focused($focusedValue, equals: option.value)
                .focusEffectDisabled()
                .overlay {
                    if isEnabled && focusedValue == option.value {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(HelloXTheme.focusRing, lineWidth: 1.5)
                    }
                }
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(isEnabled ? HXSegmentedStyle.track(for: colorScheme) : HelloXTheme.disabledBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if !isEnabled {
                RoundedRectangle(cornerRadius: 10).strokeBorder(HelloXTheme.disabledBorder(for: colorScheme), lineWidth: 1)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onMoveCommand { direction in
            guard isEnabled, let index = options.firstIndex(where: { $0.value == (focusedValue ?? selection) }) else { return }
            let horizontalStep = direction == .right ? 1 : direction == .left ? -1 : 0
            let step = layoutDirection == .rightToLeft ? -horizontalStep : horizontalStep
            guard step != 0 else { return }
            let next = options[min(max(index + step, 0), options.count - 1)].value
            selection = next
            focusedValue = next
        }
    }
}

/// Match the reference grid: every segment gets the widest label's intrinsic
/// width, with two points between segments instead of stretching the control.
private struct HXSegmentedRowLayout: Layout {
    let isRightToLeft: Bool
    private let spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1)), height: 24)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            let position = isRightToLeft ? subviews.count - 1 - index : index
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(position) * (width + spacing), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: 24)
            )
        }
    }
}

private struct HXSegmentButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isEnabled && configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
