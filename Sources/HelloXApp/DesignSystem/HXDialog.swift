import AppKit
import SwiftUI

/// Tool windows own their size. Automatic preferred-size propagation can feed
/// full-size titlebar safe-area insets back into the window on each layout pass.
@MainActor
final class HXDialogHostingController<Content: View>: NSHostingController<Content> {
    init(rootView: Content, minimumSize: NSSize? = nil) {
        super.init(rootView: rootView)
        sizingOptions = []
        if let minimumSize {
            // AppKit derives window limits from Auto Layout after hosting is
            // attached, replacing a previously assigned NSWindow.minSize.
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.width),
                view.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.height)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Shared chrome for app-owned dialogs, sheets and utility windows.
enum HXDialogStyle {
    static let radius: CGFloat = 20
    static let padding: CGFloat = 20
    static let headerBottomPadding: CGFloat = 12
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.095) : Color(white: 0.985)
    }
}

struct HXDialogHeader: View {
    var showsCloseButton = true
    let title: String
    var subtitle: String? = nil
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isCloseHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsCloseButton {
                Button(action: onClose) {
                    HelloXIcon(icon: .close, size: 16)
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                        .frame(width: 32, height: 32)
                        .background(isCloseHovered ? HelloXTheme.hoverBackground(for: colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help("关闭")
                .accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, HXDialogStyle.padding)
        .padding(.top, HXDialogStyle.padding)
        .padding(.bottom, HXDialogStyle.headerBottomPadding)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct HXDialogSurface<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .font(HXTypography.body)
            .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
            .background(HXDialogStyle.background(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: HXDialogStyle.radius))
            .overlay {
                RoundedRectangle(cornerRadius: HXDialogStyle.radius)
                    .strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct HXDialogWindowContent<Content: View>: View {
    var usesNativeWindowControls = false
    let title: String
    var subtitle: String? = nil
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HXDialogSurface {
            VStack(spacing: 0) {
                HXDialogHeader(showsCloseButton: !usesNativeWindowControls,
                               title: title, subtitle: subtitle, onClose: onClose)
                    .padding(.leading, usesNativeWindowControls ? 80 : 0)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

struct HXDialogButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(!isEnabled ? HelloXTheme.disabledForeground(for: colorScheme)
                : primary ? HelloXTheme.prominentForeground
                : configuration.role == .destructive ? HelloXTheme.error : HelloXTheme.primaryText(for: colorScheme))
            .padding(.horizontal, 16)
            .frame(minWidth: 62, minHeight: 32)
            .background(!isEnabled ? HelloXTheme.disabledBackground(for: colorScheme) : primary
                ? (configuration.isPressed ? HelloXTheme.buttonPressed : isHovered ? HelloXTheme.buttonHovered : HelloXTheme.buttonBackground)
                : (configuration.isPressed ? HelloXTheme.pressedBackground(for: colorScheme) : isHovered ? HelloXTheme.hoverBackground(for: colorScheme) : HelloXTheme.controlBackground(for: colorScheme)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(HelloXTheme.disabledBorder(for: colorScheme), lineWidth: 1)
                } else if isFocused {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(HelloXTheme.focusRing, lineWidth: 2)
                }
            }
            .onHover { isHovered = isEnabled && $0 }
    }
}

/// Keeps NSAlert's response ordering so existing save/permission branches retain
/// their behavior while presentation is owned by the shared dialog components.
@MainActor
final class HelloXAlert {
    var messageText = ""
    var informativeText = ""
    var alertStyle: NSAlert.Style = .informational
    private(set) var buttonTitles: [String] = []

    func addButton(withTitle title: String) { buttonTitles.append(title) }

    static func response(for index: Int) -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    var cancelResponse: NSApplication.ModalResponse {
        if let index = buttonTitles.firstIndex(where: { ["取消", "稍后"].contains($0) }) {
            return Self.response(for: index)
        }
        return buttonTitles.count <= 1 ? .alertFirstButtonReturn : .abort
    }

    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        if buttonTitles.isEmpty { buttonTitles = ["好"] }
        let panel = HXAlertPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = messageText
        panel.appearance = nil
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue,
                                                  (NSApp.keyWindow?.level.rawValue ?? 0) + 1))
        let cancelResponse = cancelResponse
        panel.onCancel = { NSApp.stopModal(withCode: cancelResponse) }
        let rootView = HXAlertContent(title: messageText, message: informativeText,
                                      buttons: buttonTitles, cancelResponse: cancelResponse) { response in
            NSApp.stopModal(withCode: response)
        }
        let host = NSHostingView(rootView: rootView)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let parent = NSApp.keyWindow, let screen = parent.screen {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: max(visible.minX, min(parent.frame.midX - panel.frame.width / 2, visible.maxX - panel.frame.width)),
                y: max(visible.minY, min(parent.frame.midY - panel.frame.height / 2, visible.maxY - panel.frame.height))))
        } else {
            panel.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.close()
        return response
    }
}

private final class HXAlertPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }
}

struct HXAlertContent: View {
    let title: String
    let message: String
    let buttons: [String]
    let cancelResponse: NSApplication.ModalResponse
    let onResponse: (NSApplication.ModalResponse) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HXDialogSurface {
            VStack(alignment: .leading, spacing: 0) {
                HXDialogHeader(title: title, onClose: { onResponse(cancelResponse) })
                if !message.isEmpty {
                    ScrollView {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: messageHeight)
                    .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HelloXTheme.border(for: colorScheme)))
                    .padding(.horizontal, 20)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        secondaryButtons
                        primaryButton
                    }
                    VStack(alignment: .trailing, spacing: 10) {
                        secondaryButtons
                        primaryButton
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(20)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { onResponse(cancelResponse) }
    }

    private var messageHeight: CGFloat {
        let rect = (message as NSString).boundingRect(with: NSSize(width: 448, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(360, ceil(rect.height) + 36)
    }

    private var secondaryButtons: some View {
        ForEach(secondaryIndices, id: \.self) { index in
            Button(buttons[index]) { onResponse(HelloXAlert.response(for: index)) }
                .buttonStyle(HXDialogButtonStyle())
        }
    }

    private var secondaryIndices: [Int] {
        let indices = Array(buttons.indices.dropFirst())
        return indices.filter { HelloXAlert.response(for: $0) != cancelResponse }
            + indices.filter { HelloXAlert.response(for: $0) == cancelResponse }
    }

    private var primaryButton: some View {
        Button(buttons.first ?? "好") { onResponse(.alertFirstButtonReturn) }
            .buttonStyle(HXDialogButtonStyle(primary: true))
            .keyboardShortcut(.defaultAction)
    }
}
