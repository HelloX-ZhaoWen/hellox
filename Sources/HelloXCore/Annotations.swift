import AppKit
import CoreImage
import Foundation

public enum AnnotationTool: String, CaseIterable, Sendable, Identifiable {
    case select
    case crop
    case rectangle
    case highlight
    case ellipse
    case arrow
    case line
    case pen
    case text
    case step
    case watermark
    case pixelate

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .select: "选择"
        case .crop: "裁剪"
        case .rectangle: "矩形"
        case .highlight: "高亮"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .line: "直线"
        case .pen: "画笔"
        case .text: "文字"
        case .step: "步骤"
        case .watermark: "水印"
        case .pixelate: "马赛克"
        }
    }

    public var isTextual: Bool {
        self == .text || self == .step || self == .watermark
    }
}

public enum StepAnnotationNumbering {
    public static func number(for annotationID: UUID, in annotations: [Annotation]) -> Int? {
        var number = 0
        for annotation in annotations where annotation.tool == .step {
            number += 1
            if annotation.id == annotationID { return number }
        }
        return nil
    }
}

public enum AnnotationTypography {
    public static let minimumFontSize: CGFloat = 10
}

public enum AnnotationHighlightStyle {
    public static let dimOpacity: CGFloat = 0.50
    public static let defaultColor = RGBAColor(
        red: 1,
        green: 0.82,
        blue: 0.12
    )
}

public enum AnnotationHighlightShape: String, CaseIterable, Sendable, Identifiable {
    case rectangle
    case ellipse

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        }
    }
}

public struct StepAnnotationLayoutMetrics: Equatable, Sendable {
    public let bounds: CGRect
    public let badgeRect: CGRect
    public let cardRect: CGRect
    public let textRect: CGRect
    public let connectorStart: CGPoint
    public let connectorEnd: CGPoint

    public init(
        bounds: CGRect,
        badgeRect: CGRect,
        cardRect: CGRect,
        textRect: CGRect,
        connectorStart: CGPoint,
        connectorEnd: CGPoint
    ) {
        self.bounds = bounds
        self.badgeRect = badgeRect
        self.cardRect = cardRect
        self.textRect = textRect
        self.connectorStart = connectorStart
        self.connectorEnd = connectorEnd
    }
}

public enum StepAnnotationLayout {
    public static let defaultCardWidth: CGFloat = 220
    public static let minimumCardWidth: CGFloat = 120
    public static let badgeGap: CGFloat = 6
    public static let horizontalPadding: CGFloat = 10
    public static let verticalPadding: CGFloat = 6
    public static let cornerRadius: CGFloat = 5

    public static func layout(
        text: String,
        number: Int,
        origin: CGPoint,
        totalWidth: CGFloat,
        fontSize: CGFloat,
        badgeOnTrailingEdge: Bool = false,
        badgeCenter: CGPoint? = nil
    ) -> StepAnnotationLayoutMetrics {
        let resolvedFontSize = max(8, fontSize)
        let textFont = NSFont.systemFont(ofSize: resolvedFontSize, weight: .medium)
        let numberFont = NSFont.systemFont(ofSize: resolvedFontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .paragraphStyle: paragraph
        ]
        let numberSize = (String(number) as NSString).size(withAttributes: [.font: numberFont])
        let lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
        let badgeHeight = ceil(lineHeight + verticalPadding * 2)
        let badgeWidth = max(badgeHeight, ceil(numberSize.width + horizontalPadding))
        let availableCardWidth = max(
            minimumCardWidth,
            totalWidth - badgeWidth - badgeGap
        )
        let contentWidth = max(1, availableCardWidth - horizontalPadding * 2)
        let measuredText = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes
        ).integral.size
        let cardHeight = max(
            badgeHeight,
            ceil(measuredText.height) + verticalPadding * 2
        )
        let cardRect: CGRect
        var badgeRect: CGRect
        if badgeOnTrailingEdge {
            cardRect = CGRect(
                x: origin.x,
                y: origin.y,
                width: availableCardWidth,
                height: cardHeight
            )
            badgeRect = CGRect(
                x: cardRect.maxX + badgeGap,
                y: origin.y,
                width: badgeWidth,
                height: badgeHeight
            )
        } else {
            badgeRect = CGRect(
                x: origin.x,
                y: origin.y,
                width: badgeWidth,
                height: badgeHeight
            )
            cardRect = CGRect(
                x: badgeRect.maxX + badgeGap,
                y: origin.y,
                width: availableCardWidth,
                height: cardHeight
            )
        }
        if let badgeCenter {
            badgeRect.origin = CGPoint(
                x: badgeCenter.x - badgeRect.width / 2,
                y: badgeCenter.y - badgeRect.height / 2
            )
        }
        let textRect = cardRect.insetBy(dx: horizontalPadding, dy: verticalPadding)
        let badgeCenter = CGPoint(x: badgeRect.midX, y: badgeRect.midY)
        return StepAnnotationLayoutMetrics(
            bounds: badgeRect.union(cardRect),
            badgeRect: badgeRect,
            cardRect: cardRect,
            textRect: textRect,
            connectorStart: badgeCenter,
            connectorEnd: connectorPoint(on: cardRect, toward: badgeCenter)
        )
    }

    /// Intersects the ray from the card center toward the badge with one of the
    /// card's four edges. The attachment edge changes as the badge moves around it.
    private static func connectorPoint(on rect: CGRect, toward point: CGPoint) -> CGPoint {
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        guard halfWidth > 0, halfHeight > 0 else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        guard dx != 0 || dy != 0 else {
            return CGPoint(x: rect.minX, y: rect.midY)
        }

        let horizontalRatio = abs(dx) / halfWidth
        let verticalRatio = abs(dy) / halfHeight
        if horizontalRatio >= verticalRatio {
            let scale = halfWidth / abs(dx)
            return CGPoint(
                x: dx < 0 ? rect.minX : rect.maxX,
                y: rect.midY + dy * scale
            )
        }

        let scale = halfHeight / abs(dy)
        return CGPoint(
            x: rect.midX + dx * scale,
            y: dy < 0 ? rect.minY : rect.maxY
        )
    }
}

public enum MosaicMode: String, CaseIterable, Sendable, Identifiable {
    case brush
    case rectangle

    public var id: String { rawValue }
}

public enum WatermarkLayout {
    /// Negative in the top-left coordinate system so text rises from left to right.
    public static let rotationDegrees: CGFloat = -45

    public static func tileSpacing(
        textSize: CGSize,
        fontSize: CGFloat,
        spacing: CGFloat = 48
    ) -> CGSize {
        let rotatedExtent = (textSize.width + textSize.height) / sqrt(2)
        let gap = max(8, spacing)
        return CGSize(
            width: max(fontSize * 3, rotatedExtent + gap),
            height: max(fontSize * 2.5, rotatedExtent + gap * 0.75)
        )
    }
}

public struct RGBAColor: Equatable, Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = RGBAColor(red: 0.95, green: 0.18, blue: 0.22)
    public static let blue = RGBAColor(red: 0.12, green: 0.48, blue: 0.96)
    public static let black = RGBAColor(red: 0.08, green: 0.08, blue: 0.10)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)

    public var nsColor: NSColor { NSColor(red: red, green: green, blue: blue, alpha: alpha) }
}

public struct Annotation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let tool: AnnotationTool
    /// Normalized coordinates with a top-left origin.
    public var start: CGPoint
    public var end: CGPoint
    public var points: [CGPoint]
    public var text: String
    public var color: RGBAColor
    /// Width in source image pixels at 1×.
    public var lineWidth: CGFloat
    public var mosaicMode: MosaicMode
    /// Pixel block size in source image pixels. Kept separate from the brush diameter.
    public var mosaicBlockSize: CGFloat
    /// Gap between tiled watermark labels in source image pixels.
    public var watermarkSpacing: CGFloat
    /// Optional independently positioned center of a step number badge.
    public var stepBadgePosition: CGPoint?
    /// Whether a spotlight highlight draws an explicit border around its clear area.
    public var highlightShowsBorder: Bool
    /// Shape of the clear spotlight area and its optional border.
    public var highlightShape: AnnotationHighlightShape

    public init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        start: CGPoint,
        end: CGPoint,
        points: [CGPoint] = [],
        text: String = "",
        color: RGBAColor = .red,
        lineWidth: CGFloat = 4,
        mosaicMode: MosaicMode = .rectangle,
        mosaicBlockSize: CGFloat? = nil,
        watermarkSpacing: CGFloat = 48,
        stepBadgePosition: CGPoint? = nil,
        highlightShowsBorder: Bool = false,
        highlightShape: AnnotationHighlightShape = .rectangle
    ) {
        self.id = id
        self.tool = tool
        self.start = start
        self.end = end
        self.points = points
        self.text = text
        self.color = color
        self.lineWidth = lineWidth
        self.mosaicMode = mosaicMode
        self.mosaicBlockSize = mosaicBlockSize ?? max(6, lineWidth * 2)
        self.watermarkSpacing = watermarkSpacing
        self.stepBadgePosition = stepBadgePosition
        self.highlightShowsBorder = highlightShowsBorder
        self.highlightShape = highlightShape
    }

    public var normalizedRect: CGRect {
        if (tool == .pen || (tool == .pixelate && mosaicMode == .brush)), let first = points.first {
            var minimumX = first.x
            var maximumX = first.x
            var minimumY = first.y
            var maximumY = first.y
            for point in points.dropFirst() {
                minimumX = min(minimumX, point.x)
                maximumX = max(maximumX, point.x)
                minimumY = min(minimumY, point.y)
                maximumY = max(maximumY, point.y)
            }
            return CGRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX,
                height: maximumY - minimumY
            )
        }
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        guard tool == .step, let stepBadgePosition else { return rect }
        return rect.union(CGRect(origin: stepBadgePosition, size: .zero))
    }
}

@MainActor
public enum AnnotationRenderer {
    /// Renders only the requested output area. Annotation coordinates stay tied to the
    /// original capture, then are rebased into the cropped image without being stretched.
    public static func renderOutput(
        baseImage: CGImage,
        annotations: [Annotation],
        normalizedCrop: CGRect?,
        replacementBaseImage: CGImage? = nil,
        screenshotTranslationBlocks: [ScreenshotTranslationBlock] = []
    ) throws -> CGImage {
        guard let normalizedCrop else {
            let outputBaseImage = replacementBaseImage ?? baseImage
            return annotations.isEmpty && screenshotTranslationBlocks.isEmpty
                ? outputBaseImage
                : try render(
                    baseImage: outputBaseImage,
                    annotations: annotations,
                    screenshotTranslationBlocks: screenshotTranslationBlocks
                )
        }
        let crop = normalizedCrop.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard crop.width > 0, crop.height > 0 else { throw HelloXError.captureFailed("裁剪区域太小") }
        let croppedImage = try replacementBaseImage
            ?? self.crop(baseImage: baseImage, normalizedRect: crop)
        let rebased = annotations.compactMap { rebase($0, into: crop) }
        guard !rebased.isEmpty || !screenshotTranslationBlocks.isEmpty else { return croppedImage }
        return try render(
            baseImage: croppedImage,
            annotations: rebased,
            screenshotTranslationBlocks: screenshotTranslationBlocks
        )
    }

    public static func render(
        baseImage: CGImage,
        annotations: [Annotation],
        screenshotTranslationBlocks: [ScreenshotTranslationBlock] = []
    ) throws -> CGImage {
        // Render into a bitmap context with the exact source pixel dimensions.
        // Using NSImage.lockFocus here lets AppKit choose a backing scale (usually
        // the Retina scale of the current window). That can create a larger or
        // smaller intermediate representation and then resample it back to the
        // source size when converting to CGImage, which makes otherwise untouched
        // screenshots look soft. A standalone context keeps the export pixel exact.
        let width = baseImage.width
        let height = baseImage.height
        // Preserve the source color space (e.g. Display P3) to avoid
        // saturation shifts from color management conversion.
        let colorSpace = baseImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HelloXError.captureFailed("无法创建编辑画布") }
        let size = NSSize(width: width, height: height)
        // Draw the captured image directly via CGContext — bypasses NSImage
        // color management so pixel data stays identical (no saturation shift).
        context.interpolationQuality = .none
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Apply a Y-flip so annotations can use a top-left origin (matching
        // the editor canvas).  Text drawn via NSString in the flipped
        // NSGraphicsContext then renders right-side up.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        ScreenshotTranslationDrawing.draw(
            screenshotTranslationBlocks,
            in: CGRect(origin: .zero, size: size),
            sourceImageSize: size
        )
        var pixelationCache: [Int: CGImage] = [:]
        var stepNumber = 0
        for annotation in annotations where annotation.tool != .crop && annotation.tool != .select {
            if annotation.tool == .step { stepNumber += 1 }
            if annotation.tool == .pixelate {
                drawPixelation(
                    baseImage: baseImage,
                    annotation: annotation,
                    canvasHeight: size.height,
                    cache: &pixelationCache
                )
            } else {
                drawVector(
                    annotation,
                    size: size,
                    stepNumber: annotation.tool == .step ? stepNumber : nil
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        guard let output = context.makeImage() else {
            throw HelloXError.captureFailed("无法渲染编辑结果")
        }
        return output
    }

    public static func crop(baseImage: CGImage, normalizedRect: CGRect) throws -> CGImage {
        let bounded = normalizedRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        // Public normalized rectangles use the editor's top-left origin, and
        // CGImage.cropping(to:) measures its rect from the image's top-left
        // corner as well, so no vertical flip is applied here.
        let pixelRect = expandingPixelRect(
            x: bounded.minX * CGFloat(baseImage.width),
            y: bounded.minY * CGFloat(baseImage.height),
            width: bounded.width * CGFloat(baseImage.width),
            height: bounded.height * CGFloat(baseImage.height)
        )
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let image = baseImage.cropping(to: pixelRect) else {
            throw HelloXError.captureFailed("裁剪区域太小")
        }
        return image
    }

    public static func rebase(_ annotation: Annotation, into crop: CGRect) -> Annotation? {
        guard crop.width > 0, crop.height > 0 else { return nil }
        if annotation.tool == .watermark {
            var result = annotation
            result.start = .zero
            result.end = CGPoint(x: 1, y: 1)
            return result
        }
        let bounds = annotation.normalizedRect
        let hasVisibleGeometry = bounds.width == 0 && bounds.height == 0
            ? crop.contains(annotation.start)
            : bounds.intersects(crop)
        guard hasVisibleGeometry else { return nil }

        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(x: (value.x - crop.minX) / crop.width, y: (value.y - crop.minY) / crop.height)
        }
        var result = annotation
        result.start = point(annotation.start)
        result.end = point(annotation.end)
        result.points = annotation.points.map(point)
        result.stepBadgePosition = annotation.stepBadgePosition.map(point)
        if result.tool == .pixelate {
            result.start.x = min(1, max(0, result.start.x))
            result.start.y = min(1, max(0, result.start.y))
            result.end.x = min(1, max(0, result.end.x))
            result.end.y = min(1, max(0, result.end.y))
        }
        return result
    }

    private static func drawVector(
        _ annotation: Annotation,
        size: NSSize,
        stepNumber: Int?
    ) {
        let start = point(annotation.start, size: size)
        let end = point(annotation.end, size: size)
        annotation.color.nsColor.setStroke()
        annotation.color.nsColor.setFill()
        let path = NSBezierPath()
        path.lineWidth = max(1, annotation.lineWidth)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch annotation.tool {
        case .rectangle:
            path.appendRect(rect(annotation.normalizedRect, size: size))
            path.stroke()
        case .highlight:
            let highlightRect = rect(annotation.normalizedRect, size: size)
            path.appendRect(CGRect(origin: .zero, size: size))
            switch annotation.highlightShape {
            case .rectangle: path.appendRect(highlightRect)
            case .ellipse: path.appendOval(in: highlightRect)
            }
            path.windingRule = .evenOdd
            NSColor.black
                .withAlphaComponent(AnnotationHighlightStyle.dimOpacity)
                .setFill()
            path.fill()
            if annotation.highlightShowsBorder {
                let border: NSBezierPath
                switch annotation.highlightShape {
                case .rectangle: border = NSBezierPath(rect: highlightRect)
                case .ellipse: border = NSBezierPath(ovalIn: highlightRect)
                }
                border.lineWidth = max(1, annotation.lineWidth)
                annotation.color.nsColor.setStroke()
                border.stroke()
            }
        case .ellipse:
            path.appendOval(in: rect(annotation.normalizedRect, size: size))
            path.stroke()
        case .line:
            path.move(to: start); path.line(to: end); path.stroke()
        case .arrow:
            path.move(to: start)
            path.line(to: arrowShaftEnd(from: start, to: end, lineWidth: annotation.lineWidth))
            path.stroke()
            drawArrowHead(from: start, to: end, lineWidth: annotation.lineWidth)
        case .pen:
            let points = annotation.points.map { point($0, size: size) }
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            path.stroke()
        case .step:
            drawStep(
                annotation,
                number: stepNumber ?? 1,
                size: size
            )
        case .text, .watermark:
            let fontSize = max(AnnotationTypography.minimumFontSize, annotation.lineWidth * 5)
            let baseFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let font = annotation.tool == .watermark
                ? NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                : baseFont
            let foreground = annotation.tool == .watermark
                ? annotation.color.nsColor.withAlphaComponent(annotation.color.alpha * 0.38)
                : annotation.color.nsColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foreground
            ]
            let text = annotation.text.isEmpty
                ? (annotation.tool == .watermark ? "水印" : "文字")
                : annotation.text
            if annotation.tool == .watermark {
                drawTiledWatermark(
                    text: text,
                    size: size,
                    fontSize: fontSize,
                    watermarkSpacing: annotation.watermarkSpacing,
                    attributes: attributes
                )
                return
            }
            text.draw(
                with: CGRect(
                    x: start.x,
                    y: start.y,
                    width: max(1, size.width - start.x),
                    height: max(1, size.height - start.y)
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        default: break
        }
    }

    private static func drawStep(_ annotation: Annotation, number: Int, size: NSSize) {
        let start = point(annotation.start, size: size)
        let end = point(annotation.end, size: size)
        let badgeOnTrailingEdge = end.x < start.x
        let origin = CGPoint(x: min(start.x, end.x), y: start.y)
        let totalWidth = max(
            StepAnnotationLayout.minimumCardWidth,
            abs(end.x - start.x)
        )
        let fontSize = max(AnnotationTypography.minimumFontSize, annotation.lineWidth * 5)
        let layout = StepAnnotationLayout.layout(
            text: annotation.text,
            number: number,
            origin: origin,
            totalWidth: totalWidth,
            fontSize: fontSize,
            badgeOnTrailingEdge: badgeOnTrailingEdge,
            badgeCenter: annotation.stepBadgePosition.map { point($0, size: size) }
        )
        let connector = NSBezierPath()
        connector.move(to: layout.connectorStart)
        connector.line(to: layout.connectorEnd)
        connector.lineWidth = max(1.5, annotation.lineWidth)
        connector.lineCapStyle = .round
        annotation.color.nsColor.setStroke()
        connector.stroke()
        annotation.color.nsColor.setFill()
        NSBezierPath(
            roundedRect: layout.badgeRect,
            xRadius: layout.badgeRect.height / 2,
            yRadius: layout.badgeRect.height / 2
        ).fill()
        NSColor(srgbRed: 0.38, green: 0.38, blue: 0.38, alpha: 0.92).setFill()
        NSBezierPath(
            roundedRect: layout.cardRect,
            xRadius: StepAnnotationLayout.cornerRadius,
            yRadius: StepAnnotationLayout.cornerRadius
        ).fill()

        let numberFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let numberText = String(number) as NSString
        let numberSize = numberText.size(withAttributes: [.font: numberFont])
        numberText.draw(
            at: CGPoint(
                x: layout.badgeRect.midX - numberSize.width / 2,
                y: layout.badgeRect.midY - numberSize.height / 2
            ),
            withAttributes: [
                .font: numberFont,
                .foregroundColor: NSColor.white
            ]
        )

        guard !annotation.text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        (annotation.text as NSString).draw(
            with: layout.textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func drawTiledWatermark(
        text: String,
        size: NSSize,
        fontSize: CGFloat,
        watermarkSpacing: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let measured = (text as NSString).size(withAttributes: attributes)
        let spacing = WatermarkLayout.tileSpacing(
            textSize: measured,
            fontSize: fontSize,
            spacing: watermarkSpacing
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).addClip()
        var row = 0
        var y = -spacing.height / 2
        while y < size.height + spacing.height / 2 {
            var x = row.isMultiple(of: 2) ? 0 : -spacing.width / 2
            while x < size.width + spacing.width / 2 {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: x, yBy: y)
                transform.rotate(byDegrees: WatermarkLayout.rotationDegrees)
                transform.concat()
                (text as NSString).draw(
                    at: CGPoint(x: -measured.width / 2, y: -measured.height / 2),
                    withAttributes: attributes
                )
                NSGraphicsContext.restoreGraphicsState()
                x += spacing.width
            }
            row += 1
            y += spacing.height
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawArrowHead(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(14, lineWidth * 4.5)
        let halfWidth = max(6, lineWidth * 2)
        let base = NSPoint(
            x: end.x - length * cos(angle),
            y: end.y - length * sin(angle)
        )
        let left = NSPoint(
            x: base.x - halfWidth * sin(angle),
            y: base.y + halfWidth * cos(angle)
        )
        let right = NSPoint(
            x: base.x + halfWidth * sin(angle),
            y: base.y - halfWidth * cos(angle)
        )
        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: left)
        path.line(to: right)
        path.close()
        path.fill()
    }

    private static func arrowShaftEnd(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat) -> NSPoint {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let distance = hypot(deltaX, deltaY)
        guard distance > 0 else { return end }
        let headLength = max(14, lineWidth * 4.5)
        let inset = min(headLength * 0.72, distance * 0.9)
        return NSPoint(
            x: end.x - inset * deltaX / distance,
            y: end.y - inset * deltaY / distance
        )
    }

    public static func pixelatedImage(baseImage: CGImage, blockSize: CGFloat) -> CGImage? {
        let block = max(2, Int(blockSize.rounded()))
        let smallWidth = max(1, baseImage.width / block)
        let smallHeight = max(1, baseImage.height / block)
        let colorSpace = baseImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let smallContext = CGContext(
            data: nil, width: smallWidth, height: smallHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        smallContext.interpolationQuality = .low
        smallContext.draw(baseImage, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let small = smallContext.makeImage() else { return nil }
        guard let output = CGContext(
            data: nil, width: baseImage.width, height: baseImage.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        output.interpolationQuality = .none
        output.draw(small, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        return output.makeImage()
    }

    private static func drawPixelation(
        baseImage: CGImage,
        annotation: Annotation,
        canvasHeight: CGFloat,
        cache: inout [Int: CGImage]
    ) {
        let key = max(2, Int(annotation.mosaicBlockSize.rounded()))
        let pixelated: CGImage
        if let cached = cache[key] {
            pixelated = cached
        } else {
            guard let generated = pixelatedImage(baseImage: baseImage, blockSize: CGFloat(key)) else { return }
            cache[key] = generated
            pixelated = generated
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if annotation.mosaicMode == .brush {
            let sourcePoints = annotation.points.isEmpty
                ? [annotation.start, annotation.end]
                : annotation.points
            guard let first = sourcePoints.first else {
                context.restoreGState()
                return
            }
            let path = CGMutablePath()
            let firstPoint = CGPoint(
                x: first.x * CGFloat(baseImage.width),
                y: first.y * canvasHeight
            )
            if sourcePoints.count == 1 || annotation.start == annotation.end {
                let radius = max(0.5, annotation.lineWidth / 2)
                path.addEllipse(in: CGRect(x: firstPoint.x - radius, y: firstPoint.y - radius, width: radius * 2, height: radius * 2))
                context.addPath(path)
                context.clip()
            } else {
                path.move(to: firstPoint)
                for point in sourcePoints.dropFirst() {
                    path.addLine(to: CGPoint(
                        x: point.x * CGFloat(baseImage.width),
                        y: point.y * canvasHeight
                    ))
                }
                context.addPath(path)
                context.setLineWidth(max(1, annotation.lineWidth))
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.replacePathWithStrokedPath()
                context.clip()
            }
        } else {
            let bounds = annotation.normalizedRect
            let destination = expandingPixelRect(
                x: bounds.minX * CGFloat(baseImage.width),
                y: bounds.minY * canvasHeight,
                width: bounds.width * CGFloat(baseImage.width),
                height: bounds.height * canvasHeight
            )
            guard destination.width >= 2, destination.height >= 2 else {
                context.restoreGState()
                return
            }
            context.clip(to: destination)
        }
        context.interpolationQuality = .none
        context.draw(pixelated, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        context.restoreGState()
    }

    /// Maps a top-left-origin pixel rect to integer pixel coordinates, expanding
    /// outward (floor origin, ceil size) so the exported region covers the same
    /// area as the on-screen preview instead of drifting by a rounding error.
    private static func expandingPixelRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        let minX = floor(x)
        let minY = floor(y)
        let maxX = ceil(x + width)
        let maxY = ceil(y + height)
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func point(_ normalized: CGPoint, size: NSSize) -> NSPoint {
        NSPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private static func rect(_ normalized: CGRect, size: NSSize) -> NSRect {
        NSRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }
}
