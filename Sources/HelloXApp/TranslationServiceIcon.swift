import AppKit
import HelloXCore
import SwiftUI

struct TranslationServiceIcon: View {
    let vendor: TranslationVendor
    var size: CGFloat = 28.5
    var logoSize: CGFloat = 21
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let brandImage {
                RoundedRectangle(cornerRadius: 6.75, style: .continuous)
                    .fill(Color.white)
                Image(nsImage: brandImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
            } else {
                HelloXIcon(icon: .localTranslation, size: min(logoSize, HelloXTheme.iconMedium))
                    .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if brandImage != nil {
                RoundedRectangle(cornerRadius: 6.75, style: .continuous)
                    .stroke(HelloXTheme.border(for: colorScheme), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }

    private var brandImage: NSImage? {
        Self.image(for: vendor)
    }

    static func image(for vendor: TranslationVendor) -> NSImage? {
        guard let resourceName = resourceName(for: vendor) else { return nil }
        let url = HelloXResourceBundle.bundle.url(forResource: resourceName, withExtension: "svg", subdirectory: "VendorIcons")
            ?? HelloXResourceBundle.bundle.url(forResource: resourceName, withExtension: "svg")
        let image = url.flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = false
        return image
    }

    private static func resourceName(for vendor: TranslationVendor) -> String? {
        switch vendor {
        case .local: nil
        case .volcengine: "volcengine"
        case .zhipu: "zhipu"
        case .niutrans: "niutrans"
        }
    }
}
