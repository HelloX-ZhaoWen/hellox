import AppKit
import HelloXCore
import SwiftUI

enum HelloXBrand {
    static let slogan = "让你的可能，无限延伸"
}

enum HelloXAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "暗黑"
        }
    }

    var appKitAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum HelloXResolvedAppearance {
    case light
    case dark
}

enum HelloXAppearance {
    static let storageKey = "hello-x-appearance-mode"
    static let followsSystem = true

    static var mode: HelloXAppearanceMode {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey) else { return .system }
        if rawValue == "dim" || rawValue == "lightsOut" { return .dark }
        return HelloXAppearanceMode(rawValue: rawValue) ?? .system
    }

    static func resolved(
        for systemScheme: ColorScheme,
        mode: HelloXAppearanceMode? = nil
    ) -> HelloXResolvedAppearance {
        // Theme views already receive the selected appearance through their
        // SwiftUI color-scheme environment. Falling back to the persisted
        // preference here can leave custom colors one mode behind native
        // controls during a live switch.
        switch mode ?? .system {
        case .system: systemScheme == .dark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }

    static func colorScheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    @MainActor
    static func applyGlobally() {
        apply(mode)
    }

    @MainActor
    static func setMode(_ mode: HelloXAppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
        apply(mode)
    }

    @MainActor
    private static func apply(_ mode: HelloXAppearanceMode) {
        let appearance = mode.appKitAppearanceName.flatMap(NSAppearance.init(named:))
        let application = NSApplication.shared
        application.appearance = appearance
        for window in application.windows {
            // Inherit the application appearance so existing and newly opened
            // windows use the same source, including live system changes.
            window.appearance = nil
        }
    }
}

enum HelloXTheme {
    // Matched to the installed Codex UI tokens and the supplied light/dark references.
    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
    private static func palette(_ light: UInt32, _ dark: UInt32, for scheme: ColorScheme,
                                mode: HelloXAppearanceMode? = nil, alpha: Double = 1) -> Color {
        Color(nsColor: rgb(HelloXAppearance.resolved(for: scheme, mode: mode) == .dark ? dark : light,
                          alpha: alpha))
    }
    static let windowBackground = NSColor(name: nil) { appearance in
        rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0x181818 : 0xFFFFFF)
    }
    static let accent = Color(red: 59 / 255, green: 132 / 255, blue: 247 / 255)
    static let accentBlue = accent
    static let prominentForeground = adaptive(0xFFFFFF, 0x181818)
    static let buttonBackground = adaptive(0x1A1C1F, 0xDFDFDF)
    static let buttonHovered = adaptive(0x393939, 0xFFFFFF)
    static let buttonPressed = adaptive(0x414141, 0xCDCDCD)
    static let focusRing = accent
    static let error = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let windowRadius: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let compactRadius: CGFloat = 8
    static let iconMedium: CGFloat = 16
    static let minimumHitSize: CGFloat = 28
    static func pageBackground(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0xFFFFFF, 0x181818, for: scheme, mode: appearance)
    }
    static func surface(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0xFFFFFF, 0x232323, for: scheme, mode: appearance)
    }
    static func raisedSurface(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0xFFFFFF, 0x232323, for: scheme, mode: appearance)
    }
    static func primaryText(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0x1A1C1F, 0xFFFFFF, for: scheme, mode: appearance)
    }
    static func secondaryText(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0x6A6B6D, 0xB2B2B2, for: scheme, mode: appearance)
    }
    static func selectedBackground(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0x1A1C1F, 0xFFFFFF, for: scheme, mode: appearance, alpha: 0.08)
    }
    static func iconForeground(for scheme: ColorScheme) -> Color { primaryText(for: scheme) }
    static func sidebarSearchForeground(for scheme: ColorScheme) -> Color {
        palette(0x8D8D8D, 0xA1A1A1, for: scheme)
    }
    static func sidebarSectionForeground(for scheme: ColorScheme) -> Color {
        palette(0xA7A7A7, 0x787878, for: scheme)
    }
    static func sidebarSearchBackground(for scheme: ColorScheme) -> Color {
        palette(0xF2F2F2, 0x333333, for: scheme)
    }
    static func sidebarSelectedBackground(for scheme: ColorScheme) -> Color {
        palette(0x1A1C1F, 0xFFFFFF, for: scheme, alpha: scheme == .dark ? 0.08 : 0.05)
    }
    static func controlBackground(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0xF4F4F4, 0x2E2E2E, for: scheme, mode: appearance)
    }
    static func disabledForeground(for scheme: ColorScheme) -> Color {
        palette(0x9B9B9B, 0x777777, for: scheme)
    }
    static func disabledBackground(for scheme: ColorScheme) -> Color {
        palette(0xF4F4F4, 0x262626, for: scheme)
    }
    static func disabledBorder(for scheme: ColorScheme) -> Color {
        palette(0xE8E8E8, 0x333333, for: scheme)
    }
    static func hoverBackground(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0x1A1C1F, 0xFFFFFF, for: scheme, mode: appearance, alpha: 0.05)
    }
    static func pressedBackground(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0x1A1C1F, 0xFFFFFF, for: scheme, mode: appearance, alpha: 0.12)
    }
    static func border(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        palette(0xEDEDED, 0x353535, for: scheme, mode: appearance)
    }
    static func cardGradient(for scheme: ColorScheme) -> Color { raisedSurface(for: scheme) }
    static func shadow(for scheme: ColorScheme, appearance: HelloXAppearanceMode? = nil) -> Color {
        Color.black.opacity(HelloXAppearance.resolved(for: scheme, mode: appearance) == .dark ? 0.2 : 0.06)
    }
}

enum HelloXIconKey: String, CaseIterable {
    case capture = "crosshair"
    case dynamicIsland = "panel-top"
    case shortcuts = "command"
    case intelligence = "sparkles"
    case settings = "settings"
    case window = "app-window"
    case screen = "monitor"
    case scrolling = "scroll-capture"
    case recording = "recording"
    case qrCode = "scan-line"
    case colorPicker = "pipette"
    case textRecognition = "ocr-text"
    case translation = "languages"
    case selectionTranslation = "highlight"
    case update = "refresh-cw"
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
    case info = "info"
    case warning = "triangle-alert"
    case success = "circle-check"
    case rectangle = "square"
    case highlight = "lightbulb"
    case ellipse = "circle"
    case arrow = "move-up-right"
    case line = "minus"
    case pen = "brush"
    case edit = "edit"
    case text = "type"
    case step = "list-ordered"
    case watermark = "watermark"
    case pixelate = "mosaic"
    case crop = "crop"
    case document = "file-text"
    case preview = "eye"
    case search = "search"

    case upload = "upload"
    case spreadsheet = "table"
    case code = "code"
    case password = "key"
    case markdown = "markdown"
    case diagram = "workflow"
    case chevronUp = "chevron-up"
    case chevronDown = "chevron-down"
    case accessibility = "accessibility"
    case menuBar = "menu-bar"
    case localTranslation = "local-translation"

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
        case .highlight: .highlight
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .pen: .pen
        case .text: .text
        case .step: .step
        case .watermark: .watermark
        case .pixelate: .pixelate
        case .crop: .crop
        }
    }

    var helloXToolbarHelp: String {
        switch self {
        case .watermark: "添加水印"
        case .step: "添加步骤说明"
        default: localizedName
        }
    }
}

/// A single template-image path keeps the original SVG geometry and padding.
/// Resource coverage is verified for every key, so no surface falls back to a
/// heavier SF Symbol when an asset is missing.
@MainActor
enum HelloXIconImages {
    private static var cache: [HelloXIconKey: NSImage] = [:]

    static func image(for icon: HelloXIconKey) -> NSImage? {
        if let image = cache[icon] { return image }
        guard let url = icon.resourceURL, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[icon] = image
        return image
    }

    /// Native drawing surfaces use the same vector artwork as SwiftUI.
    static func tintedImage(for icon: HelloXIconKey, color: NSColor, size: CGFloat) -> NSImage? {
        guard let source = image(for: icon) else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}

struct HelloXIcon: View {
    let icon: HelloXIconKey
    var size: CGFloat = HelloXTheme.iconMedium

    var body: some View {
        Group {
            if let image = HelloXIconImages.image(for: icon) ?? HelloXIconImages.image(for: .info) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct HelloXCard<Content: View>: View {
    var padding: CGFloat = 15
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
            .overlay {
                if showsBorder {
                    shape.stroke(HelloXTheme.border(for: colorScheme), lineWidth: 1)
                }
            }
    }
}

struct HelloXRowIcon: View {
    let icon: HelloXIconKey
    var size: CGFloat = 28.5
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelloXIcon(icon: icon, size: min(16, size))
            .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
            .frame(width: size, height: size)
    }
}

struct HelloXStatusBanner: View {
    enum Kind { case info, success, error }
    let message: String
    var kind: Kind = .info
    @Environment(\.colorScheme) private var colorScheme

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
        HStack(spacing: 6.75) {
            HelloXIcon(icon: icon, size: 12)
                .foregroundStyle(kind == .info ? HelloXTheme.iconForeground(for: colorScheme) : color)
            Text(message)
                .font(.settingsSystem(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10.5)
        .padding(.vertical, 8.25)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

enum HelloXButtonRole { case neutral, accent, destructive, success, warning }

struct HelloXButtonStyle: ButtonStyle {
    var isOutlined = false
    var role: HelloXButtonRole = .neutral
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let primary = role == .accent
        configuration.label
            .font(HXTypography.control)
            .foregroundStyle(!isEnabled ? HelloXTheme.disabledForeground(for: colorScheme)
                : primary ? HelloXTheme.prominentForeground
                : role == .destructive ? HelloXTheme.error : HelloXTheme.primaryText(for: colorScheme))
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(!isEnabled ? HelloXTheme.disabledBackground(for: colorScheme) : primary
                ? (configuration.isPressed ? HelloXTheme.buttonPressed : isHovered ? HelloXTheme.buttonHovered : HelloXTheme.buttonBackground)
                : isOutlined ? HelloXTheme.raisedSurface(for: colorScheme) : HelloXTheme.controlBackground(for: colorScheme))
            .overlay {
                if isOutlined || !isEnabled {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                        isEnabled ? HelloXTheme.border(for: colorScheme) : HelloXTheme.disabledBorder(for: colorScheme), lineWidth: 1)
                }
            }
            .overlay {
                if isEnabled && !primary && (isHovered || configuration.isPressed) {
                    HelloXTheme.hoverBackground(for: colorScheme).allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if isEnabled && isFocused { RoundedRectangle(cornerRadius: 10).strokeBorder(HelloXTheme.focusRing, lineWidth: 2) }
            }
            .onHover { isHovered = isEnabled && $0 }
    }
}

struct HelloXUtilityTextButton: View {
    let title: String
    let help: String
    var role: HelloXButtonRole = .neutral
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(title, action: action)
            .buttonStyle(HelloXButtonStyle(role: role))
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
    var isBorderless = true
    var usesWhiteBackground = false
    var usesPureWhiteIconInDarkMode = false
    var onHoverChange: ((Bool) -> Void)?
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

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
            usesWhiteBackground: usesWhiteBackground,
            usesPureWhiteIconInDarkMode: usesPureWhiteIconInDarkMode
        ))
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            isHovered = isEnabled && hovering
            onHoverChange?(isHovered)
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                isHovered = false
                onHoverChange?(false)
            }
        }
    }
}

private struct HelloXIconButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool
    let role: HelloXButtonRole
    let isBorderless: Bool
    let usesWhiteBackground: Bool
    let usesPureWhiteIconInDarkMode: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: HelloXTheme.compactRadius)
        configuration.label
            .foregroundStyle(foreground)
            .background(background(isPressed: configuration.isPressed), in: shape)
            .overlay {
                shape.stroke(
                    isEnabled && isFocused ? HelloXTheme.focusRing : borderColor,
                    lineWidth: isEnabled && isFocused ? 2 : ((!isEnabled && hasDisabledBackground) || !isBorderless ? 1 : 0)
                )
            }
    }

    private var borderColor: Color {
        if !isEnabled { return hasDisabledBackground ? HelloXTheme.disabledBorder(for: colorScheme) : .clear }
        return isBorderless ? .clear : HelloXTheme.border(for: colorScheme)
    }

    private var hasDisabledBackground: Bool {
        !isBorderless || usesWhiteBackground || isSelected || role == .accent
    }

    private var foreground: Color {
        if !isEnabled { return HelloXTheme.disabledForeground(for: colorScheme) }
        if role == .accent { return HelloXTheme.prominentForeground }
        if usesPureWhiteIconInDarkMode, colorScheme == .dark { return .white }
        if role == .destructive, isHovered { return HelloXTheme.error }
        return HelloXTheme.iconForeground(for: colorScheme)
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        if !isEnabled {
            return AnyShapeStyle(hasDisabledBackground ? HelloXTheme.disabledBackground(for: colorScheme) : .clear)
        }
        if role == .accent {
            return AnyShapeStyle(isPressed ? HelloXTheme.buttonPressed
                : isHovered ? HelloXTheme.buttonHovered : HelloXTheme.buttonBackground)
        }
        if isPressed { return AnyShapeStyle(HelloXTheme.pressedBackground(for: colorScheme)) }
        if isSelected { return AnyShapeStyle(HelloXTheme.selectedBackground(for: colorScheme)) }
        if isHovered { return AnyShapeStyle(HelloXTheme.hoverBackground(for: colorScheme)) }
        if isBorderless && !usesWhiteBackground { return AnyShapeStyle(Color.clear) }
        return AnyShapeStyle(HelloXTheme.controlBackground(for: colorScheme))
    }

}
