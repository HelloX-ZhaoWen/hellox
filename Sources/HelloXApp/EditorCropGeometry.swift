import CoreGraphics
import HelloXCore

enum EditorCropGeometry {
    enum Interaction {
        case create
        case move(CGRect)
        case resize(CGRect, SelectionHandle)
    }

    static let handleSize: CGFloat = 7
    static let handleHitRadius: CGFloat = 10
    private static let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func visibleSelection(draft: Annotation?, selection: CGRect?) -> CGRect? {
        draft?.tool == .crop ? draft?.normalizedRect : selection
    }

    static func normalizedRect(from start: CGPoint, to end: CGPoint, imageRect: CGRect) -> CGRect {
        let first = normalizedPoint(start, in: imageRect)
        let last = normalizedPoint(end, in: imageRect)
        return CGRect(
            x: min(first.x, last.x), y: min(first.y, last.y),
            width: abs(last.x - first.x), height: abs(last.y - first.y)
        )
    }

    static func displayRect(_ rect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    static func handlePosition(_ handle: SelectionHandle, selection: CGRect, imageRect: CGRect) -> CGPoint {
        let rect = displayRect(selection, in: imageRect)
        let point: CGPoint
        switch handle {
        case .topLeft: point = CGPoint(x: rect.minX, y: rect.minY)
        case .top: point = CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .right: point = CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: point = CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: point = CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .left: point = CGPoint(x: rect.minX, y: rect.midY)
        }
        // Keep all of each handle visible when the crop reaches an image edge.
        let inset = min(handleSize / 2 + 0.5, min(imageRect.width, imageRect.height) / 2)
        return CGPoint(
            x: min(max(point.x, imageRect.minX + inset), imageRect.maxX - inset),
            y: min(max(point.y, imageRect.minY + inset), imageRect.maxY - inset)
        )
    }

    static func interaction(at point: CGPoint, selection: CGRect?, imageRect: CGRect) -> Interaction? {
        if let selection {
            let nearest = SelectionHandle.allCases.min { first, second in
                distance(point, handlePosition(first, selection: selection, imageRect: imageRect))
                    < distance(point, handlePosition(second, selection: selection, imageRect: imageRect))
            }
            if let nearest,
               distance(point, handlePosition(nearest, selection: selection, imageRect: imageRect)) <= handleHitRadius {
                return .resize(selection, nearest)
            }
            if displayRect(selection, in: imageRect).contains(point) { return .move(selection) }
        }
        return imageRect.contains(point) ? .create : nil
    }

    static func updatedSelection(
        for interaction: Interaction,
        start: CGPoint,
        end: CGPoint,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> CGRect {
        let translation = CGSize(
            width: (end.x - start.x) / max(1, imageRect.width),
            height: (end.y - start.y) / max(1, imageRect.height)
        )
        switch interaction {
        case .create:
            return normalizedRect(from: start, to: end, imageRect: imageRect)
        case .move(let original):
            return SelectionGeometry.moved(original, by: translation, within: unitBounds)
        case .resize(let original, let handle):
            return SelectionGeometry.resized(
                original, handle: handle, by: translation, within: unitBounds,
                minimumSize: CGSize(
                    width: min(original.width, 1 / max(1, sourceImageSize.width)),
                    height: min(original.height, 1 / max(1, sourceImageSize.height))
                )
            )
        }
    }

    static func isUsable(_ rect: CGRect, sourceImageSize: CGSize) -> Bool {
        rect.width * sourceImageSize.width >= 1 - 0.000_001
            && rect.height * sourceImageSize.height >= 1 - 0.000_001
    }

    private static func normalizedPoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: min(1, max(0, (point.x - imageRect.minX) / max(1, imageRect.width))),
            y: min(1, max(0, (point.y - imageRect.minY) / max(1, imageRect.height)))
        )
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}
