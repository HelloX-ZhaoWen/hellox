import CoreGraphics
import Foundation
import SwiftUI

enum HXTypography {
    /// Match Codex's `-webkit-font-smoothing: antialiased`. CoreText's default
    /// smoothing adds weight to Chinese glyphs even at the same regular font.
    /// Registration is process-local; it does not write system preferences.
    static func configureRendering() {
        UserDefaults.standard.register(defaults: ["AppleFontSmoothing": 0])
    }

    static let body = Font.system(size: 14, weight: .regular)
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12, weight: .regular)
    static let section = Font.system(size: 14, weight: .medium)
    static let title = Font.system(size: 24, weight: .medium)
    static let control = Font.system(size: 14, weight: .medium)
    static let sidebar = Font.system(size: 14, weight: .regular)
}

/// Layout primitives shared by every HelloX surface.
/// Colors remain in `HelloXTheme` while the UI is migrated incrementally.
enum HXSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
}

struct HXTextStyle: ShapeStyle {
    let isSecondary: Bool
    static let primary = HXTextStyle(isSecondary: false)
    static let secondary = HXTextStyle(isSecondary: true)
    func resolve(in environment: EnvironmentValues) -> Color {
        isSecondary ? HelloXTheme.secondaryText(for: environment.colorScheme)
                    : HelloXTheme.primaryText(for: environment.colorScheme)
    }
}
