import SwiftUI

/// Compact document navigation; the web preview continues to own scrolling.
struct MarkdownTableOfContents: View {
    @ObservedObject var document: MarkdownDocumentTab
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHeadingID: String?

    var body: some View {
        Group {
            if document.isTableOfContentsExpanded {
                expandedOutline
            } else {
                collapsedOutline
            }
        }
        .frame(width: document.isTableOfContentsExpanded ? 230 : 44)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(HelloXTheme.controlBackground(for: colorScheme))
        .overlay(alignment: .trailing) {
            Rectangle().fill(HelloXTheme.border(for: colorScheme))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文档目录")
        .onChange(of: document.id) { _, _ in selectedHeadingID = nil }
        .onChange(of: document.headings) { _, _ in
            // Positional heading IDs can refer to a different section after editing.
            selectedHeadingID = nil
        }
    }

    private var expandedOutline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("目录")
                    .font(HXTypography.label)
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                Spacer(minLength: 8)
                Text("\(document.headings.count)")
                    .font(HXTypography.caption)
                    .monospacedDigit()
                    .foregroundStyle(HelloXTheme.sidebarSectionForeground(for: colorScheme))
                    .accessibilityLabel("\(document.headings.count) 个标题")
                HelloXIconButton(icon: .chevronRight, help: "收起目录", iconSize: 14) {
                    document.isTableOfContentsExpanded = false
                }
                .rotationEffect(.degrees(180))
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 36)

            if document.headings.isEmpty {
                Text("文档中没有标题")
                    .font(HXTypography.caption)
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(document.outlineRows) { row in
                            MarkdownOutlineNavigationRow(
                                row: row,
                                isCollapsed: document.collapsedHeadingIDs.contains(row.id),
                                isSelected: selectedHeadingID == row.id,
                                onToggle: { document.toggleHeading(row.id) },
                                onSelect: {
                                    selectedHeadingID = row.id
                                    document.previewModel.scroll(to: row.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
                .scrollContentBackground(.hidden)
                .visibleScrollChrome()
            }
        }
    }

    private var collapsedOutline: some View {
        VStack(spacing: 0) {
            HelloXIconButton(icon: .chevronRight, help: "展开目录", iconSize: 14) {
                document.isTableOfContentsExpanded = true
            }
            .frame(height: 36)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MarkdownOutlineNavigationRow: View {
    let row: MarkdownOutlineRow
    let isCollapsed: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if row.hasChildren {
                Button(action: onToggle) {
                    HelloXIcon(icon: .chevronRight, size: 11)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(isEnabled ? HelloXTheme.secondaryText(for: colorScheme) : HelloXTheme.disabledForeground(for: colorScheme))
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MarkdownOutlineNavigationButtonStyle())
                .help("\(isCollapsed ? "展开" : "收起")子目录")
                .accessibilityLabel("\(isCollapsed ? "展开" : "收起")\(row.heading.title)的子目录")
                .accessibilityValue(isCollapsed ? "已收起" : "已展开")
            } else {
                Color.clear.frame(width: 20, height: 28)
                    .accessibilityHidden(true)
            }

            Button(action: onSelect) {
                Text(row.heading.title)
                    .font(.system(size: 13, weight: row.depth == 0 ? .medium : .regular))
                    .foregroundStyle(isEnabled ? HelloXTheme.primaryText(for: colorScheme) : HelloXTheme.disabledForeground(for: colorScheme))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .padding(.trailing, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MarkdownOutlineNavigationButtonStyle())
            .help(row.heading.title)
            .accessibilityLabel(row.heading.title)
            .accessibilityValue("\(row.heading.level) 级标题")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        // Keep at least 150 points for text at the deepest Markdown levels.
        .padding(.leading, CGFloat(min(row.depth, 4)) * 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = isEnabled && $0 }
        .accessibilityElement(children: .contain)
    }

    private var background: Color {
        if isSelected { return HelloXTheme.selectedBackground(for: colorScheme) }
        if isEnabled && isHovered { return HelloXTheme.hoverBackground(for: colorScheme) }
        return .clear
    }
}

private struct MarkdownOutlineNavigationButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isEnabled && configuration.isPressed ? HelloXTheme.pressedBackground(for: colorScheme) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isEnabled && isFocused {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(HelloXTheme.focusRing, lineWidth: 1.5)
                }
            }
    }
}
