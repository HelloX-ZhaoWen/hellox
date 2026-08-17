import AppKit
import CoreImage
import Foundation

public enum AnnotationTool: String, CaseIterable, Sendable, Identifiable {
    case select
    case crop
    case rectangle
    case ellipse
    case arrow
    case line
    case pen
    case text
    case watermark
    case pixelate

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .select: "选择"
        case .crop: "裁剪"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .line: "直线"
        case .pen: "画笔"
        case .text: "文字"
        case .watermark: "水印"
        case .pixelate: "马赛克"
        }
    }

    public var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .watermark: "drop"
        case .pixelate: "square.grid.3x3"
        }
    }

    public var isTextual: Bool {
        self == .text || self == .watermark
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
        watermarkSpacing: CGFloat = 48
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
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
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
        translatedBlocks: [ImageTranslationBlock] = []
    ) throws -> CGImage {
        guard let normalizedCrop else {
            return annotations.isEmpty && translatedBlocks.isEmpty
                ? baseImage
                : try render(baseImage: baseImage, annotations: annotations, translatedBlocks: translatedBlocks)
        }
        let crop = normalizedCrop.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard crop.width > 0, crop.height > 0 else { throw HelloXError.captureFailed("裁剪区域太小") }
        let croppedImage = try self.crop(baseImage: baseImage, normalizedRect: crop)
        let rebased = annotations.compactMap { rebase($0, into: crop) }
        guard !rebased.isEmpty || !translatedBlocks.isEmpty else { return croppedImage }
        return try render(baseImage: croppedImage, annotations: rebased, translatedBlocks: translatedBlocks)
    }

    public static func render(
        baseImage: CGImage,
        annotations: [Annotation],
        translatedBlocks: [ImageTranslationBlock] = []
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

        var pixelationCache: [Int: CGImage] = [:]
        for annotation in annotations where annotation.tool != .crop && annotation.tool != .select {
            if annotation.tool == .pixelate {
                drawPixelation(
                    baseImage: baseImage,
                    annotation: annotation,
                    canvasHeight: size.height,
                    cache: &pixelationCache
                )
            } else {
                drawVector(annotation, size: size)
            }
        }
        drawTranslatedTextBlocks(translatedBlocks, size: size)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        guard let output = context.makeImage() else {
            throw HelloXError.captureFailed("无法渲染编辑结果")
        }
        return output
    }

    public static func crop(baseImage: CGImage, normalizedRect: CGRect) throws -> CGImage {
        let bounded = normalizedRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixelRect = CGRect(
            x: bounded.minX * CGFloat(baseImage.width),
            y: bounded.minY * CGFloat(baseImage.height),
            width: bounded.width * CGFloat(baseImage.width),
            height: bounded.height * CGFloat(baseImage.height)
        ).integral
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
        if result.tool == .pixelate {
            result.start.x = min(1, max(0, result.start.x))
            result.start.y = min(1, max(0, result.start.y))
            result.end.x = min(1, max(0, result.end.x))
            result.end.y = min(1, max(0, result.end.y))
        }
        return result
    }

    private static func drawVector(_ annotation: Annotation, size: NSSize) {
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
        case .ellipse:
            path.appendOval(in: rect(annotation.normalizedRect, size: size))
            path.stroke()
        case .line:
            path.move(to: start); path.line(to: end); path.stroke()
        case .arrow:
            path.move(to: start); path.line(to: end); path.stroke()
            drawArrowHead(from: start, to: end, lineWidth: annotation.lineWidth)
        case .pen:
            let points = annotation.points.map { point($0, size: size) }
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            path.stroke()
        case .text, .watermark:
            let fontSize = max(14, annotation.lineWidth * 5)
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

    private static func drawTranslatedTextBlocks(_ blocks: [ImageTranslationBlock], size: NSSize) {
        for block in blocks where !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let box = block.boundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard box.width > 0, box.height > 0 else { continue }
            let rect = CGRect(
                x: box.minX * size.width,
                y: (1 - box.maxY) * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            ).integral
            guard rect.width >= 2, rect.height >= 2 else { continue }

            let appearance = block.appearance
            let fittedFontSize = ImageTranslationTextLayout.fittedFontSize(
                for: block.text,
                in: rect,
                preferredSize: appearance.fontSize
            )
            let fontSize = fittedFontSize * ImageTranslationTextLayout.forcedFontScale
            let horizontalPadding = max(2, fontSize * 0.16)
            let verticalPadding = max(1, fontSize * 0.10)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            paragraph.alignment = .left
            let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: appearance.foregroundColor.nsColor,
                .paragraphStyle: paragraph
            ]
            appearance.backgroundColor.nsColor.setFill()
            NSBezierPath(rect: rect).fill()
            block.text.draw(
                with: rect.insetBy(dx: horizontalPadding, dy: verticalPadding),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }
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
        let length = max(12, lineWidth * 4)
        let left = NSPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6))
        let right = NSPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))
        let path = NSBezierPath()
        path.lineWidth = max(1, lineWidth)
        path.lineCapStyle = .round
        path.move(to: left); path.line(to: end); path.line(to: right); path.stroke()
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
            let destination = CGRect(
                x: bounds.minX * CGFloat(baseImage.width),
                y: bounds.minY * canvasHeight,
                width: bounds.width * CGFloat(baseImage.width),
                height: bounds.height * canvasHeight
            ).integral
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
