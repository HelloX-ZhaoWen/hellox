import AppKit
import HelloXCore
import SwiftUI
import Testing
@testable import HelloXApp

struct ThemeTests {
    @MainActor
    @Test func translationVendorsHaveReadableColorArtwork() throws {
        let vendors = TranslationVendor.allCases.filter { $0 != .local }
        for vendor in vendors {
            let image = try #require(TranslationServiceIcon.image(for: vendor))
            #expect(image.isValid)
            #expect(!image.isTemplate)
            #expect(image.size.width > 0 && image.size.height > 0)
        }
        #expect(TranslationServiceIcon.image(for: .local) == nil)
        if let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] {
            let content = VStack(alignment: .leading, spacing: 16) {
                ForEach(vendors, id: \.self) { vendor in
                    HStack(spacing: 12) {
                        TranslationServiceIcon(vendor: vendor, size: 32, logoSize: 24)
                        Text(vendor.displayName)
                    }
                }
            }.padding(20).background(Color.white).environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: content)
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("translation-vendor-icons.png"))
        }
    }

    @MainActor
    @Test func everyFunctionalIconHasVisibleBundledTemplateArtwork() throws {
        for icon in HelloXIconKey.allCases {
            _ = try #require(icon.resourceURL, "Missing SVG: \(icon.rawValue)")
            let image = try #require(HelloXIconImages.image(for: icon), "Unreadable SVG: \(icon.rawValue)")
            #expect(image.isTemplate)
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            let visiblePixels = (0..<32).reduce(0) { total, y in
                total + (0..<32).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
            }
            #expect(visiblePixels > 4, "Empty artwork: \(icon.rawValue)")
            #expect(visiblePixels < 32 * 32, "Opaque box instead of icon: \(icon.rawValue)")
        }
    }

    @MainActor
    @Test func menuBarIconUsesSystemTemplateRendering() {
        #expect(MenuBarIcon.image.isTemplate)
    }

    @MainActor
    @Test func menuBarIconUsesTheBundledBrandArtwork() throws {
        let url = try #require(HelloXResourceBundle.bundle.url(
            forResource: "HelloXMenuBarIcon", withExtension: "png"
        ))
        let expected = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let actual = try #require(MenuBarIcon.image.representations.compactMap {
            $0 as? NSBitmapImageRep
        }.first)
        #expect(MenuBarIcon.image.size == NSSize(width: 18, height: 18))
        #expect(actual.pixelsWide == expected.pixelsWide)
        #expect(actual.pixelsHigh == expected.pixelsHigh)
        for y in 0..<expected.pixelsHigh {
            for x in 0..<expected.pixelsWide {
                #expect(actual.colorAt(x: x, y: y)?.alphaComponent
                    == expected.colorAt(x: x, y: y)?.alphaComponent)
            }
        }
    }

    @MainActor
    @Test func existingHostingViewReturnsToSystemAppearanceOnTheFirstSwitch() {
        let application = NSApplication.shared
        let savedAppearance = application.appearance
        let savedMode = UserDefaults.standard.object(forKey: HelloXAppearance.storageKey)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        var renderedScheme: ColorScheme?
        let hostingView = NSHostingView(rootView: ThemeSchemeProbe { renderedScheme = $0 })
        window.contentView = hostingView
        defer {
            window.close()
            application.appearance = savedAppearance
            UserDefaults.standard.set(savedMode, forKey: HelloXAppearance.storageKey)
        }

        HelloXAppearance.setMode(.system)
        let systemScheme = HelloXAppearance.colorScheme(for: application.effectiveAppearance)
        for mode in [HelloXAppearanceMode.dark, .system, .light, .system, .dark, .light, .system] {
            HelloXAppearance.setMode(mode)
            let expected = mode.colorScheme ?? systemScheme
            #expect(window.appearance == nil)
            #expect(HelloXAppearance.colorScheme(for: window.effectiveAppearance) == expected)
            if mode == .system { #expect(application.appearance == nil) }

            // Let SwiftUI perform its next render without recreating the host,
            // activating the window, or clicking the appearance control again.
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            #expect(renderedScheme == expected)
        }
    }

    @Test func settingsNavigationContainsOnlySettingsPages() {
        #expect(SettingsDestination.allCases == [
            .shortcuts,
            .dynamicIsland,
            .intelligence,
            .software
        ])
        #expect(SettingsDestination.dynamicIsland.title == "灵动岛")
        #expect(SettingsDestination.intelligence.title == "翻译设置")
    }

    @Test func applicationAppearanceFollowsTheSystem() {
        #expect(HelloXAppearance.followsSystem)
    }

    @Test func appearanceModesResolvePredictably() {
        #expect(HelloXAppearanceMode.allCases == [.system, .light, .dark])
        #expect(HelloXAppearance.resolved(for: .light) == .light)
        #expect(HelloXAppearance.resolved(for: .dark) == .dark)
        #expect(HelloXAppearance.resolved(for: .light, mode: .system) == .light)
        #expect(HelloXAppearance.resolved(for: .dark, mode: .system) == .dark)
        #expect(HelloXAppearance.resolved(for: .dark, mode: .light) == .light)
        #expect(HelloXAppearance.resolved(for: .light, mode: .dark) == .dark)
        #expect(HelloXAppearance.colorScheme(for: NSAppearance(named: .aqua)!) == .light)
        #expect(HelloXAppearance.colorScheme(for: NSAppearance(named: .darkAqua)!) == .dark)
    }

    @Test func accentMatchesCodexSwitchBlue() {
        #expect(colorsAreEqual(HelloXTheme.accent, Color(red: 59 / 255, green: 132 / 255, blue: 247 / 255)))
    }

    @Test func paletteAdaptsToTheSystemColorScheme() {
        let pairedColors: [(Color, Color)] = [
            (HelloXTheme.pageBackground(for: .light), HelloXTheme.pageBackground(for: .dark)),
            (HelloXTheme.surface(for: .light), HelloXTheme.surface(for: .dark)),
            (HelloXTheme.raisedSurface(for: .light), HelloXTheme.raisedSurface(for: .dark)),
            (HelloXTheme.primaryText(for: .light), HelloXTheme.primaryText(for: .dark)),
            (HelloXTheme.secondaryText(for: .light), HelloXTheme.secondaryText(for: .dark)),
            (HelloXTheme.selectedBackground(for: .light), HelloXTheme.selectedBackground(for: .dark)),
            (HelloXTheme.controlBackground(for: .light), HelloXTheme.controlBackground(for: .dark))
        ]

        for (light, dark) in pairedColors {
            #expect(!colorsAreEqual(light, dark))
        }
    }

    @Test func palettesMatchTheProvidedCodexReferences() {
        let fixtures: [(ColorScheme, Color, Color, Color)] = [
            (.light, .white, .white, Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255)),
            (.dark, Color(white: 24 / 255), Color(white: 35 / 255), .white)
        ]
        for (scheme, page, group, text) in fixtures {
            #expect(colorsAreEqual(HelloXTheme.pageBackground(for: scheme), page))
            #expect(colorsAreEqual(HelloXTheme.raisedSurface(for: scheme), group))
            #expect(colorsAreEqual(HelloXTheme.primaryText(for: scheme), text))
        }
    }

    @Test func bodyTextMeetsWCAGAAContrast() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(contrastRatio(
                HelloXTheme.primaryText(for: scheme),
                HelloXTheme.surface(for: scheme)
            ) >= 4.5)
            #expect(contrastRatio(
                HelloXTheme.secondaryText(for: scheme),
                HelloXTheme.raisedSurface(for: scheme)
            ) >= 4.5)
        }

    }

    private func colorsAreEqual(_ lhs: Color, _ rhs: Color) -> Bool {
        let left = components(of: lhs)
        let right = components(of: rhs)
        return abs(left.red - right.red) < 0.001
            && abs(left.green - right.green) < 0.001
            && abs(left.blue - right.blue) < 0.001
            && abs(left.alpha - right.alpha) < 0.001
    }

    private func contrastRatio(_ first: Color, _ second: Color) -> CGFloat {
        let foreground = components(of: first)
        let background = components(of: second)
        let composited = Color(red: Double(foreground.red * foreground.alpha + background.red * (1 - foreground.alpha)),
                               green: Double(foreground.green * foreground.alpha + background.green * (1 - foreground.alpha)),
                               blue: Double(foreground.blue * foreground.alpha + background.blue * (1 - foreground.alpha)))
        let bright = max(luminance(of: composited), luminance(of: second))
        let dark = min(luminance(of: composited), luminance(of: second))
        return (bright + 0.05) / (dark + 0.05)
    }

    private func luminance(of color: Color) -> CGFloat {
        let value = components(of: color)
        return 0.2126 * linearized(value.red)
            + 0.7152 * linearized(value.green)
            + 0.0722 * linearized(value.blue)
    }

    private func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private func components(of color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
    }
}

private struct ThemeSchemeProbe: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let onRender: (ColorScheme) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        onRender(colorScheme)
    }
}
