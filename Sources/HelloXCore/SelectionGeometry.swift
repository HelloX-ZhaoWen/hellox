import CoreGraphics
import Foundation

public enum SelectionHandle: String, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

public enum SelectionGeometry {
    public static func moved(
        _ rect: CGRect,
        by translation: CGSize,
        within bounds: CGRect
    ) -> CGRect {
        let candidate = rect.offsetBy(dx: translation.width, dy: translation.height)
        let x = min(max(candidate.minX, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(candidate.minY, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    public static func resized(
        _ rect: CGRect,
        handle: SelectionHandle,
        by translation: CGSize,
        within bounds: CGRect,
        minimumSize: CGSize = CGSize(width: 24, height: 24)
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if [.topLeft, .left, .bottomLeft].contains(handle) {
            minX = min(max(rect.minX + translation.width, bounds.minX), rect.maxX - minimumSize.width)
        }
        if [.topRight, .right, .bottomRight].contains(handle) {
            maxX = max(min(rect.maxX + translation.width, bounds.maxX), rect.minX + minimumSize.width)
        }
        if [.topLeft, .top, .topRight].contains(handle) {
            minY = min(max(rect.minY + translation.height, bounds.minY), rect.maxY - minimumSize.height)
        }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) {
            maxY = max(min(rect.maxY + translation.height, bounds.maxY), rect.minY + minimumSize.height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func toolbarOrigin(
        selection: CGRect,
        toolbarSize: CGSize,
        within bounds: CGRect,
        spacing: CGFloat = 10,
        margin: CGFloat = 12
    ) -> CGPoint {
        let minX = bounds.minX + margin
        let maxX = max(minX, bounds.maxX - margin - toolbarSize.width)
        let x = min(max(selection.midX - toolbarSize.width / 2, minX), maxX)
        let below = selection.maxY + spacing
        let y: CGFloat
        if below + toolbarSize.height <= bounds.maxY - margin {
            y = below
        } else if selection.minY - spacing - toolbarSize.height >= bounds.minY + margin {
            y = selection.minY - spacing - toolbarSize.height
        } else {
            y = bounds.maxY - margin - toolbarSize.height
        }
        return CGPoint(x: x, y: y)
    }
}
