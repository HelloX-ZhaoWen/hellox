import CoreGraphics
import Foundation

public enum CoordinateMapper {
    /// Converts an AppKit global rectangle (origin bottom-left) into CoreGraphics
    /// display space (origin top-left) using the union of all displays.
    public static func appKitToCoreGraphics(_ rect: CGRect, desktopBounds: CGRect) -> CGRect {
        appKitToCoreGraphics(
            rect,
            appKitDesktopBounds: desktopBounds,
            coreGraphicsDesktopBounds: desktopBounds
        )
    }

    public static func appKitToCoreGraphics(
        _ rect: CGRect,
        appKitDesktopBounds: CGRect,
        coreGraphicsDesktopBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: appKitDesktopBounds.maxY - rect.maxY + coreGraphicsDesktopBounds.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a CoreGraphics global rectangle (origin top-left) back into
    /// AppKit global space (origin bottom-left).
    public static func coreGraphicsToAppKit(
        _ rect: CGRect,
        appKitDesktopBounds: CGRect,
        coreGraphicsDesktopBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: appKitDesktopBounds.maxY - (rect.minY - coreGraphicsDesktopBounds.minY) - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    public static func union(_ rects: [CGRect]) -> CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }

    public static func pixelRect(_ pointRect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (pointRect.origin.x * scale).rounded(.down),
            y: (pointRect.origin.y * scale).rounded(.down),
            width: (pointRect.width * scale).rounded(.up),
            height: (pointRect.height * scale).rounded(.up)
        )
    }
}
