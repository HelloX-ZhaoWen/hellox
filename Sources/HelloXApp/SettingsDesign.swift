import AppKit
import HelloXCore
import SwiftUI

enum HelloXBrand {
    static let slogan = "把时间留给真正的自己。"
}

enum HelloXTheme {
    static let accent = Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
    static let accentPressed = Color(red: 29 / 255, green: 78 / 255, blue: 216 / 255)
    static let accentBlue = Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
    static let error = Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255)
    static let success = Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255)
    static let warning = Color(red: 217 / 255, green: 119 / 255, blue: 6 / 255)

    static let windowRadius: CGFloat = 14
    static let cardRadius: CGFloat = 13
    static let controlRadius: CGFloat = 10
    static let compactRadius: CGFloat = 8
    static let iconSmall: CGFloat = 16
    static let iconMedium: CGFloat = 19
    static let iconLarge: CGFloat = 24
    static let minimumHitSize: CGFloat = 44

    private static let lightPage = Color(red: 251 / 255, green: 252 / 255, blue: 254 / 255)
    private static let lightSurface = Color.white
    private static let lightRaisedSurface = Color.white
    private static let lightText = Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255)
    private static let lightSecondary = Color(red: 71 / 255, green: 85 / 255, blue: 105 / 255)
    private static let lightSelection = Color(red: 234 / 255, green: 241 / 255, blue: 1)
    private static let lightControl = Color(red: 244 / 255, green: 247 / 255, blue: 251 / 255)

    private static let darkPage = Color(red: 7 / 255, green: 16 / 255, blue: 33 / 255)
    private static let darkSurface = Color(red: 15 / 255, green: 31 / 255, blue: 55 / 255).opacity(0.94)
    private static let darkRaisedSurface = Color(red: 20 / 255, green: 39 / 255, blue: 68 / 255).opacity(0.98)
    private static let darkText = Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255)
    private static let darkSecondary = Color(red: 174 / 255, green: 190 / 255, blue: 214 / 255)
    private static let darkSelection = Color(red: 24 / 255, green: 58 / 255, blue: 105 / 255)
    private static let darkControl = Color(red: 20 / 255, green: 42 / 255, blue: 73 / 255).opacity(0.9)

    static func pageBackground(for scheme: ColorScheme) -> Color { scheme == .dark ? darkPage : lightPage }
    static func sidebarBackground(for scheme: ColorScheme) -> Color { surface(for: scheme) }
    static func surface(for scheme: ColorScheme) -> Color { scheme == .dark ? darkSurface : lightSurface }
    static func raisedSurface(for scheme: ColorScheme) -> Color { scheme == .dark ? darkRaisedSurface : lightRaisedSurface }
    static func primaryText(for scheme: ColorScheme) -> Color { scheme == .dark ? darkText : lightText }
    static func secondaryText(for scheme: ColorScheme) -> Color { scheme == .dark ? darkSecondary : lightSecondary }
    static func selectedBackground(for scheme: ColorScheme) -> Color { scheme == .dark ? darkSelection : lightSelection }
    static func controlBackground(for scheme: ColorScheme) -> Color { scheme == .dark ? darkControl : lightControl }

    static func border(for scheme: ColorScheme) -> Color {
        .clear
    }

    static var accentGradient: Color { accent }

    static func cardGradient(for scheme: ColorScheme) -> Color { raisedSurface(for: scheme) }

    static func shadow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.075)
    }
}

enum HelloXIconKey: String, CaseIterable {
    case capture = "crosshair"
    case shortcuts = "command"
    case intelligence = "sparkles"
    case settings = "settings"
    case window = "app-window"
    case screen = "monitor"
    case scrolling = "scroll-capture"
    case recording = "recording"
    case qrCode = "scan-line"
    case textRecognition = "scan-text"
    case translation = "languages"
    case update = "refresh-cw"
    case arrowRight = "arrow-right"
    case chevronRight = "chevron-right"
    case undo = "undo-2"
    case redo = "redo-2"
    case copy = "copy"
    case save = "download"
    case close = "x"
    case confirm = "check"
    case pin = "pin"
    case play = "play"
    case add = "plus"
    case cloud = "cloud"
    case info = "info"
    case warning = "triangle-alert"
    case success = "circle-check"
    case link = "link"
    case privacy = "shield-check"
    case rectangle = "square"
    case ellipse = "circle"
    case arrow = "move-up-right"
    case line = "minus"
    case pen = "brush"
    case edit = "pen-tool"
    case text = "type"
    case watermark = "watermark"
    case pixelate = "mosaic"
    case crop = "crop"
    case document = "file-text"
    case preview = "eye"

    var fallbackSystemName: String {
        switch self {
        case .capture: "viewfinder"
        case .shortcuts: "command"
        case .intelligence: "sparkles"
        case .settings: "gearshape"
        case .window: "macwindow"
        case .screen: "display"
        case .scrolling: "arrow.down.to.line.compact"
        case .recording: "record.circle"
        case .qrCode: "qrcode.viewfinder"
        case .textRecognition: "text.viewfinder"
        case .translation: "character.bubble"
        case .update: "arrow.triangle.2.circlepath"
        case .arrowRight: "arrow.right"
        case .chevronRight: "chevron.right"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .close: "xmark"
        case .confirm: "checkmark"
        case .pin: "pin"
        case .play: "play.fill"
        case .add: "plus"
        case .cloud: "cloud"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .link: "link"
        case .privacy: "hand.raised"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pen: "pencil.tip"
        case .edit: "pencil"
        case .text: "textformat"
        case .watermark: "drop"
        case .pixelate: "square.grid.3x3"
        case .crop: "crop"
        case .document: "doc.text"
        case .preview: "eye"
        }
    }

    var resourceURL: URL? {
        HelloXResourceBundle.bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "Icons")
            ?? HelloXResourceBundle.bundle.url(forResource: rawValue, withExtension: "svg")
    }
}

enum HelloXResourceBundle {
    static let bundle: Bundle = {
        let bundleName = "HelloX_HelloXApp.bundle"
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName, isDirectory: true))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true))
        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(bundleName, isDirectory: true)
            )
        }
        for candidate in candidates {
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return Bundle.module
    }()
}

extension AnnotationTool {
    var helloXIcon: HelloXIconKey {
        switch self {
        case .select: .capture
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .pen: .pen
        case .text: .text
        case .watermark: .watermark
        case .pixelate: .pixelate
        case .crop: .crop
        }
    }

    var helloXToolbarHelp: String {
        self == .watermark ? "添加水印" : localizedName
    }
}

struct HelloXIcon: View {
    let icon: HelloXIconKey
    var size: CGFloat = HelloXTheme.iconMedium

    var body: some View {
        Group {
            if let image = resourceImage {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: icon.fallbackSystemName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var resourceImage: NSImage? {
        guard let url = icon.resourceURL,
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}

struct HelloXGlowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HelloXTheme.pageBackground(for: colorScheme)
                RadialGradient(
                    colors: [HelloXTheme.accent.opacity(colorScheme == .dark ? 0.10 : 0.065), .clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.62
                )
                RadialGradient(
                    colors: [HelloXTheme.accentBlue.opacity(colorScheme == .dark ? 0.06 : 0.04), .clear],
                    center: .bottomTrailing,
                    startRadius: 8,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.52
                )
            }
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct HelloXCard<Content: View>: View {
    var padding: CGFloat = 20
    var cornerRadius: CGFloat = HelloXTheme.cardRadius
    var showsBorder = true
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HelloXTheme.cardGradient(for: colorScheme), in: shape)
            .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 12, y: 6)
    }
}

struct HelloXSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var showsBorder = true
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
            }
            HelloXCard(showsBorder: showsBorder, content: { content })
        }
    }
}

struct HelloXRowIcon: View {
    let icon: HelloXIconKey
    var size: CGFloat = 38
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelloXIcon(icon: icon, size: min(20, size * 0.5))
            .foregroundStyle(HelloXTheme.accent)
            .frame(width: size, height: size)
            .background(HelloXTheme.selectedBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius, style: .continuous))
    }
}

struct HelloXStatusBanner: View {
    enum Kind { case info, success, error }
    let message: String
    var kind: Kind = .info

    private var color: Color {
        switch kind {
        case .info: HelloXTheme.accent
        case .success: HelloXTheme.success
        case .error: HelloXTheme.error
        }
    }

    private var icon: HelloXIconKey {
        switch kind {
        case .info: .info
        case .success: .success
        case .error: .warning
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            HelloXIcon(icon: icon, size: 16)
            Text(message)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous))
    }
}

private struct HelloXBorderlessFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .frame(minHeight: 36)
            .background(
                HelloXTheme.controlBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
            )
    }
}

extension View {
    func helloXBorderlessFieldChrome() -> some View {
        modifier(HelloXBorderlessFieldModifier())
    }
}

struct HelloXFloatingPanel<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous)
        content
            .background(HelloXTheme.cardGradient(for: colorScheme), in: shape)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.16), radius: 24, y: 10)
    }
}

enum HelloXButtonRole { case neutral, accent, destructive }

struct HelloXButtonStyle: ButtonStyle {
    var role: HelloXButtonRole = .neutral
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 15)
            .frame(minHeight: HelloXTheme.minimumHitSize)
            .background(background(isPressed: configuration.isPressed), in: shape)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private var borderColor: Color {
        switch role {
        case .accent: .clear
        case .destructive: HelloXTheme.error.opacity(0.18)
        case .neutral: HelloXTheme.border(for: colorScheme)
        }
    }

    private var foreground: Color {
        switch role {
        case .accent: .white
        case .destructive: HelloXTheme.error
        case .neutral: HelloXTheme.primaryText(for: colorScheme)
        }
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        switch role {
        case .accent:
            if isPressed { AnyShapeStyle(HelloXTheme.accentPressed) }
            else { AnyShapeStyle(HelloXTheme.accentGradient) }
        case .destructive:
            AnyShapeStyle(HelloXTheme.error.opacity(isPressed ? 0.18 : 0.10))
        case .neutral:
            AnyShapeStyle(isPressed ? HelloXTheme.selectedBackground(for: colorScheme) : HelloXTheme.controlBackground(for: colorScheme))
        }
    }
}

enum HelloXUtilityButtonMetrics {
    static let width: CGFloat = 88
    static let height: CGFloat = 34
    static let fontSize: CGFloat = 11.5
}

struct HelloXUtilityButtonLabel: View {
    let title: String
    var role: HelloXButtonRole = .neutral
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
        Text(title)
            .font(.system(size: HelloXUtilityButtonMetrics.fontSize, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .frame(
                width: HelloXUtilityButtonMetrics.width,
                height: HelloXUtilityButtonMetrics.height
            )
            .background(background, in: shape)
    }

    private var foreground: Color {
        switch role {
        case .neutral: HelloXTheme.secondaryText(for: colorScheme)
        case .accent: .white
        case .destructive: HelloXTheme.error
        }
    }

    private var background: Color {
        switch role {
        case .neutral: HelloXTheme.controlBackground(for: colorScheme)
        case .accent: HelloXTheme.accent
        case .destructive: HelloXTheme.error.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch role {
        case .neutral: HelloXTheme.border(for: colorScheme)
        case .accent: .clear
        case .destructive: HelloXTheme.error.opacity(0.18)
        }
    }
}

struct HelloXUtilityTextButton: View {
    let title: String
    let help: String
    var role: HelloXButtonRole = .neutral
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HelloXUtilityButtonLabel(title: title, role: role)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct HelloXIconButton: View {
    let icon: HelloXIconKey
    let help: String
    var isSelected = false
    var role: HelloXButtonRole = .neutral
    var size: CGFloat = HelloXTheme.minimumHitSize
    var iconSize: CGFloat = HelloXTheme.iconMedium
    var isBorderless = false
    var usesWhiteBackground = false
    var onHoverChange: ((Bool) -> Void)?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HelloXIcon(icon: icon, size: iconSize)
                .frame(width: size, height: size)
        }
        .buttonStyle(HelloXIconButtonStyle(
            isSelected: isSelected,
            isHovered: isHovered,
            role: role,
            isBorderless: isBorderless,
            usesWhiteBackground: usesWhiteBackground
        ))
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            isHovered = hovering
            onHoverChange?(hovering)
        }
    }
}

private struct HelloXIconButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool
    let role: HelloXButtonRole
    let isBorderless: Bool
    let usesWhiteBackground: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
        configuration.label
            .foregroundStyle(foreground)
            .background(background(isPressed: configuration.isPressed), in: shape)
            .shadow(color: hoverShadow, radius: isHovered && !isBorderless ? 5 : 0, y: isHovered && !isBorderless ? 2 : 0)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: isHovered)
    }

    private var borderColor: Color {
        if role == .destructive { return HelloXTheme.error.opacity(0.18) }
        return HelloXTheme.border(for: colorScheme)
    }

    private var foreground: Color {
        if isSelected || role == .accent { return .white }
        if role == .destructive { return HelloXTheme.error }
        if usesWhiteBackground {
            return isHovered ? HelloXTheme.accentBlue : Color(red: 0.28, green: 0.33, blue: 0.40)
        }
        if isHovered { return HelloXTheme.accentBlue }
        return HelloXTheme.secondaryText(for: colorScheme)
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        if isSelected || role == .accent {
            if isPressed { return AnyShapeStyle(HelloXTheme.accentPressed) }
            return AnyShapeStyle(HelloXTheme.accentGradient)
        }
        if usesWhiteBackground {
            if role == .destructive, isPressed || isHovered {
                return AnyShapeStyle(
                    isPressed
                        ? Color(red: 1.00, green: 0.88, blue: 0.88)
                        : Color(red: 1.00, green: 0.94, blue: 0.94)
                )
            }
            return AnyShapeStyle(isPressed ? Color(red: 0.94, green: 0.96, blue: 0.98) : Color.white)
        }
        if role == .destructive {
            return AnyShapeStyle(HelloXTheme.error.opacity(isPressed ? 0.22 : (isHovered ? 0.17 : 0.11)))
        }
        if isPressed || isHovered {
            return AnyShapeStyle(HelloXTheme.selectedBackground(for: colorScheme))
        }
        if isBorderless { return AnyShapeStyle(Color.clear) }
        return AnyShapeStyle(HelloXTheme.controlBackground(for: colorScheme))
    }

    private var hoverShadow: Color {
        if role == .destructive { return HelloXTheme.error.opacity(0.16) }
        return HelloXTheme.accentBlue.opacity(0.18)
    }
}

private struct SeamlessTextEditorScrollChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let marker = ScrollChromeMarkerView(frame: .zero)
        DispatchQueue.main.async { configureScrollView(around: marker) }
        return marker
    }

    func updateNSView(_ marker: NSView, context: Context) {
        DispatchQueue.main.async { configureScrollView(around: marker) }
    }

    private func configureScrollView(around marker: NSView) {
        guard let root = marker.window?.contentView else { return }
        let markerPoint = marker.convert(
            CGPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            to: nil
        )
        guard let scrollView = scrollViews(in: root)
            .filter({ $0.convert($0.bounds, to: nil).contains(markerPoint) })
            .min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }

        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.reduce(into: view is NSScrollView ? [view as! NSScrollView] : []) { result, child in
            result.append(contentsOf: scrollViews(in: child))
        }
    }
}

final class HelloXOverlayScroller: NSScroller {
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knobRect = rect(for: .knob).insetBy(dx: 4, dy: 1)
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        let opacity: CGFloat = isHovered || isHighlighted ? 0.42 : 0.16
        NSColor.labelColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobRect.width / 2,
            yRadius: knobRect.width / 2
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        super.mouseExited(with: event)
    }
}

private struct VisibleScrollChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let marker = ScrollChromeMarkerView(frame: .zero)
        DispatchQueue.main.async { configureScrollView(around: marker) }
        return marker
    }

    func updateNSView(_ marker: NSView, context: Context) {
        DispatchQueue.main.async { configureScrollView(around: marker) }
    }

    private func configureScrollView(around marker: NSView) {
        guard let root = marker.window?.contentView else { return }
        let markerPoint = marker.convert(
            CGPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            to: nil
        )
        guard let scrollView = scrollViews(in: root)
            .filter({ $0.convert($0.bounds, to: nil).contains(markerPoint) })
            .min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }

        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.hasHorizontalScroller = false
        if scrollView.verticalScroller is HelloXOverlayScroller == false {
            scrollView.verticalScroller = HelloXOverlayScroller(frame: .zero)
        }
        scrollView.verticalScroller?.isHidden = false
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.reduce(into: view is NSScrollView ? [view as! NSScrollView] : []) { result, child in
            result.append(contentsOf: scrollViews(in: child))
        }
    }
}

final class ScrollChromeMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func seamlessTextEditorChrome() -> some View {
        scrollIndicators(.hidden)
            .background(SeamlessTextEditorScrollChrome())
    }

    func seamlessScrollChrome() -> some View {
        background(SeamlessTextEditorScrollChrome())
    }

    func visibleScrollChrome() -> some View {
        scrollIndicators(.visible)
            .background(VisibleScrollChrome())
    }
}
