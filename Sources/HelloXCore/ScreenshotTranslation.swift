import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Visual properties used when a translated paragraph is placed back over a screenshot.
public struct ScreenshotTranslationAppearance: Equatable, Sendable {
    /// Preferred font size in source-image pixels.
    public let fontSize: CGFloat
    public let foregroundColor: RGBAColor
    public let backgroundColor: RGBAColor

    public init(
        fontSize: CGFloat,
        foregroundColor: RGBAColor,
        backgroundColor: RGBAColor
    ) {
        self.fontSize = fontSize
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }

    public static let fallback = ScreenshotTranslationAppearance(
        fontSize: 14,
        foregroundColor: .black,
        backgroundColor: .white
    )
}

public struct ScreenshotTranslationBackgroundRegion: Equatable, Sendable {
    public let boundingBox: CGRect
    public let backgroundColor: RGBAColor

    public init(boundingBox: CGRect, backgroundColor: RGBAColor) {
        self.boundingBox = boundingBox
        self.backgroundColor = backgroundColor
    }
}

/// A translated semantic paragraph anchored to Vision's normalized coordinate space.
public struct ScreenshotTranslationBlock: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceText: String
    public let translatedText: String
    /// Vision coordinates: normalized, origin at bottom-left.
    public let boundingBox: CGRect
    /// Exact OCR regions removed from the reconstructed clean plate. Keeping
    /// these separate from the paragraph rectangle preserves icons and other
    /// artwork in the whitespace around ragged source lines.
    public let backgroundBoxes: [CGRect]
    /// Per-source-box color sampled before any pixels are removed. Compact
    /// controls need this hint because their OCR box can nearly fill the badge
    /// or button, leaving mostly page pixels outside the erase rectangle.
    public let backgroundRegions: [ScreenshotTranslationBackgroundRegion]
    /// Number of visual source lines available to this semantic paragraph.
    public let sourceLineCount: Int
    public let appearance: ScreenshotTranslationAppearance

    public init(
        id: UUID,
        sourceText: String,
        translatedText: String,
        boundingBox: CGRect,
        backgroundBoxes: [CGRect]? = nil,
        backgroundRegions: [ScreenshotTranslationBackgroundRegion]? = nil,
        sourceLineCount: Int = 1,
        appearance: ScreenshotTranslationAppearance
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.boundingBox = boundingBox
        let regions = backgroundRegions ?? (backgroundBoxes ?? [boundingBox]).map {
            ScreenshotTranslationBackgroundRegion(
                boundingBox: $0,
                backgroundColor: appearance.backgroundColor
            )
        }
        self.backgroundRegions = regions
        self.backgroundBoxes = regions.map(\.boundingBox)
        self.sourceLineCount = max(1, sourceLineCount)
        self.appearance = appearance
    }
}

/// Reconstructs the pixels behind OCR text before translated text is drawn.
/// The output is a real clean plate: source glyph pixels are no longer present
/// underneath the translation layer.
public enum ScreenshotTranslationBackgroundReconstructor {
    public static func eraseText(
        in image: CGImage,
        normalizedBoxes: [CGRect]
    ) throws -> CGImage {
        try eraseText(
            in: image,
            requests: normalizedBoxes.map {
                ReconstructionRequest(boundingBox: $0, backgroundColor: nil)
            }
        )
    }

    public static func eraseText(
        in image: CGImage,
        normalizedRegions: [ScreenshotTranslationBackgroundRegion]
    ) throws -> CGImage {
        try eraseText(
            in: image,
            requests: normalizedRegions.map {
                ReconstructionRequest(
                    boundingBox: $0.boundingBox,
                    backgroundColor: rgbaBytes($0.backgroundColor)
                )
            }
        )
    }

    private struct ReconstructionRequest {
        let boundingBox: CGRect
        let backgroundColor: (UInt8, UInt8, UInt8, UInt8)?
    }

    private struct ReconstructionRegion {
        let rect: CGRect
        let backgroundColor: (UInt8, UInt8, UInt8, UInt8)?
    }

    private static func eraseText(
        in image: CGImage,
        requests: [ReconstructionRequest]
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw HelloXError.captureFailed("无法重建截图背景")
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw HelloXError.captureFailed("无法重建截图背景")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var regions: [ReconstructionRegion] = []
        for request in requests {
            guard let rect = pixelRect(
                for: request.boundingBox,
                width: width,
                height: height
            ) else { continue }
            // Vision boxes tightly follow glyph ink. Expand slightly so every
            // antialiased edge pixel is removed as well.
            let safety = max(2, min(4, Int(ceil(rect.height * 0.10))))
            let expanded = rect.insetBy(dx: -CGFloat(safety), dy: -CGFloat(safety))
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !expanded.isNull, expanded.width >= 1, expanded.height >= 1 {
                regions.append(ReconstructionRegion(
                    rect: expanded.integral,
                    backgroundColor: request.backgroundColor
                ))
            }
        }
        guard !regions.isEmpty else { return image }

        // OCR text regions are long and shallow. Reconstruct each one from
        // clean rows immediately above and below it. Vertical interpolation
        // preserves solid colors and gradients while preventing list-marker ink
        // at a rectangle's left edge from diffusing across the whole paragraph.
        for region in regions.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            reconstruct(
                region.rect,
                preferredBackground: region.backgroundColor,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixels: &pixels
            )
        }

        guard let result = context.makeImage() else {
            throw HelloXError.captureFailed("无法生成无文字截图")
        }
        return result
    }

    private static func pixelRect(for box: CGRect, width: Int, height: Int) -> CGRect? {
        let normalized = box.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return nil }
        return CGRect(
            x: normalized.minX * CGFloat(width),
            y: (1 - normalized.maxY) * CGFloat(height),
            width: normalized.width * CGFloat(width),
            height: normalized.height * CGFloat(height)
        ).integral
    }

    private static func reconstruct(
        _ region: CGRect,
        preferredBackground: (UInt8, UInt8, UInt8, UInt8)?,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: inout [UInt8]
    ) {
        let minX = max(0, Int(floor(region.minX)))
        let maxX = min(width, Int(ceil(region.maxX)))
        let minY = max(0, Int(floor(region.minY)))
        let maxY = min(height, Int(ceil(region.maxY)))
        guard minX < maxX, minY < maxY else { return }

        let sampledBackground = surroundingBackground(
            region,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: pixels
        )
        let background: BackgroundEstimate
        if let preferredBackground,
           colorDistance(sampledBackground.color, preferredBackground) > 55 {
            // The sampling ring crossed a high-contrast component boundary.
            // Trust the color captured from the original OCR box instead of
            // replacing a compact control with its surrounding page color.
            background = BackgroundEstimate(
                color: preferredBackground,
                variation: sampledBackground.variation
            )
        } else {
            background = sampledBackground
        }
        if background.variation <= 8 {
            fill(
                region: region,
                color: background.color,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixels: &pixels
            )
            return
        }
        let fallback = background.color
        let topRows = max(0, minY - 3)..<minY
        let bottomRows = maxY..<min(height, maxY + 3)
        for y in minY..<maxY {
            let progress = CGFloat(y - minY + 1) / CGFloat(maxY - minY + 1)
            for x in minX..<maxX {
                let top = boundarySample(
                    x: x,
                    rows: topRows,
                    width: width,
                    bytesPerRow: bytesPerRow,
                    pixels: pixels,
                    fallback: fallback
                )
                let bottom = boundarySample(
                    x: x,
                    rows: bottomRows,
                    width: width,
                    bytesPerRow: bytesPerRow,
                    pixels: pixels,
                    fallback: fallback
                )
                let value: (UInt8, UInt8, UInt8, UInt8)
                switch (top, bottom) {
                case let (.some(top), .some(bottom)):
                    value = interpolate(top, bottom, progress: progress)
                case let (.some(top), nil):
                    value = top
                case let (nil, .some(bottom)):
                    value = bottom
                case (nil, nil):
                    continue
                }
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = value.0
                pixels[offset + 1] = value.1
                pixels[offset + 2] = value.2
                pixels[offset + 3] = value.3
            }
        }
    }

    private static func boundarySample(
        x: Int,
        rows: Range<Int>,
        width: Int,
        bytesPerRow: Int,
        pixels: [UInt8],
        fallback: (UInt8, UInt8, UInt8, UInt8)
    ) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard !rows.isEmpty else { return nil }
        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0
        var count = 0
        for y in rows {
            for sampleX in max(0, x - 4)...min(width - 1, x + 4) {
                let offset = y * bytesPerRow + sampleX * 4
                let sample = (
                    pixels[offset],
                    pixels[offset + 1],
                    pixels[offset + 2],
                    pixels[offset + 3]
                )
                guard colorDistance(sample, fallback) <= 55 else { continue }
                red += Int(sample.0)
                green += Int(sample.1)
                blue += Int(sample.2)
                alpha += Int(sample.3)
                count += 1
            }
        }
        guard count > 0 else { return fallback }
        return (
            UInt8(clamping: red / count),
            UInt8(clamping: green / count),
            UInt8(clamping: blue / count),
            UInt8(clamping: alpha / count)
        )
    }

    private struct BackgroundEstimate {
        let color: (UInt8, UInt8, UInt8, UInt8)
        let variation: Int
    }

    private static func surroundingBackground(
        _ region: CGRect,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: [UInt8]
    ) -> BackgroundEstimate {
        // Sample immediately outside the already-expanded glyph rectangle.
        // A wide ring escapes compact surfaces such as badges and buttons, so
        // the surrounding page color can outvote the control's actual fill.
        // The tight ring still sits beyond antialiased glyph pixels because
        // `eraseText` adds its safety inset before reconstruction.
        let radius = max(2, min(4, Int(ceil(region.height * 0.12))))
        let outer = region.insetBy(dx: -CGFloat(radius), dy: -CGFloat(radius))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var alpha = [Int](repeating: 0, count: 256)
        var count = 0
        for y in Swift.stride(
            from: max(0, Int(floor(outer.minY))),
            to: min(height, Int(ceil(outer.maxY))),
            by: 2
        ) {
            for x in Swift.stride(
                from: max(0, Int(floor(outer.minX))),
                to: min(width, Int(ceil(outer.maxX))),
                by: 2
            ) {
                guard !region.contains(CGPoint(x: x, y: y)) else { continue }
                let offset = y * bytesPerRow + x * 4
                red[Int(pixels[offset])] += 1
                green[Int(pixels[offset + 1])] += 1
                blue[Int(pixels[offset + 2])] += 1
                alpha[Int(pixels[offset + 3])] += 1
                count += 1
            }
        }
        guard count > 0 else {
            return BackgroundEstimate(color: (255, 255, 255, 255), variation: 0)
        }
        let color = (
            percentile(red, count: count, fraction: 0.5),
            percentile(green, count: count, fraction: 0.5),
            percentile(blue, count: count, fraction: 0.5),
            percentile(alpha, count: count, fraction: 0.5)
        )
        let channelVariations = [
            Int(percentile(red, count: count, fraction: 0.60))
                - Int(percentile(red, count: count, fraction: 0.40)),
            Int(percentile(green, count: count, fraction: 0.60))
                - Int(percentile(green, count: count, fraction: 0.40)),
            Int(percentile(blue, count: count, fraction: 0.60))
                - Int(percentile(blue, count: count, fraction: 0.40))
        ]
        let variation = channelVariations.max() ?? 0
        return BackgroundEstimate(color: color, variation: variation)
    }

    private static func percentile(
        _ histogram: [Int],
        count: Int,
        fraction: Double
    ) -> UInt8 {
        let target = max(0, min(count - 1, Int(Double(count - 1) * fraction)))
        var accumulated = 0
        for value in histogram.indices {
            accumulated += histogram[value]
            if accumulated > target { return UInt8(value) }
        }
        return 255
    }

    private static func fill(
        region: CGRect,
        color: (UInt8, UInt8, UInt8, UInt8),
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: inout [UInt8]
    ) {
        let minX = max(0, Int(floor(region.minX)))
        let maxX = min(width, Int(ceil(region.maxX)))
        let minY = max(0, Int(floor(region.minY)))
        let maxY = min(height, Int(ceil(region.maxY)))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = color.3
            }
        }
    }

    private static func colorDistance(
        _ lhs: (UInt8, UInt8, UInt8, UInt8),
        _ rhs: (UInt8, UInt8, UInt8, UInt8)
    ) -> CGFloat {
        let red = CGFloat(lhs.0) - CGFloat(rhs.0)
        let green = CGFloat(lhs.1) - CGFloat(rhs.1)
        let blue = CGFloat(lhs.2) - CGFloat(rhs.2)
        return sqrt(red * red + green * green + blue * blue)
    }

    private static func interpolate(
        _ top: (UInt8, UInt8, UInt8, UInt8),
        _ bottom: (UInt8, UInt8, UInt8, UInt8),
        progress: CGFloat
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        func channel(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
            UInt8(clamping: Int((CGFloat(lhs) * (1 - progress) + CGFloat(rhs) * progress).rounded()))
        }
        return (
            channel(top.0, bottom.0),
            channel(top.1, bottom.1),
            channel(top.2, bottom.2),
            channel(top.3, bottom.3)
        )
    }

    private static func rgbaBytes(
        _ color: RGBAColor
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        (
            UInt8(clamping: Int((color.red * 255).rounded())),
            UInt8(clamping: Int((color.green * 255).rounded())),
            UInt8(clamping: Int((color.blue * 255).rounded())),
            UInt8(clamping: Int((color.alpha * 255).rounded()))
        )
    }
}

public enum ScreenshotTranslationInteractionPolicy {
    public static func locksSelection(
        hasTranslationBlocks: Bool,
        hasReconstructedBackground: Bool
    ) -> Bool {
        hasTranslationBlocks && hasReconstructedBackground
    }
}

public enum ScreenshotTranslationTextLayout {
    static func pixelAlignedRect(for boundingBox: CGRect, in destination: CGRect) -> CGRect {
        let box = boundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull else { return .zero }
        // Rounding a normalized bottom edge can expand the rectangle by one
        // pixel beyond the image. Fit against the actual drawable area, not
        // that extra pixel which the export bitmap will inevitably clip.
        return CGRect(
            x: destination.minX + box.minX * destination.width,
            y: destination.minY + (1 - box.maxY) * destination.height,
            width: box.width * destination.width,
            height: box.height * destination.height
        ).integral.intersection(destination)
    }

    public static func insets(for fontSize: CGFloat) -> NSEdgeInsets {
        NSEdgeInsets(
            top: max(0.10, fontSize * 0.015),
            left: max(0.25, fontSize * 0.05),
            bottom: max(0.10, fontSize * 0.015),
            right: max(0.25, fontSize * 0.05)
        )
    }

    /// Finds the largest readable multiline font that fits the paragraph rectangle.
    public static func fittedFontSize(
        for text: String,
        in rect: CGRect,
        preferredSize: CGFloat,
        minimumSize: CGFloat = 6,
        maximumScale: CGFloat = 1.28,
        maximumLineCount: Int? = nil
    ) -> CGFloat {
        guard rect.width > 2, rect.height > 2 else { return max(0.25, minimumSize) }
        let requestedMinimum = max(0.25, min(minimumSize, preferredSize))
        var lower = requestedMinimum
        while lower > 0.25, !fits(
            text,
            in: rect,
            fontSize: lower,
            maximumLineCount: maximumLineCount
        ) {
            lower *= 0.78
        }
        guard fits(text, in: rect, fontSize: lower, maximumLineCount: maximumLineCount) else {
            return 0.25
        }

        // Search up to a controlled amount above the sampled source size. This
        // favors a slightly larger result without clipping or ellipsis.
        var upper = max(lower, preferredSize * max(1, maximumScale))
        if fits(text, in: rect, fontSize: upper, maximumLineCount: maximumLineCount) {
            return upper
        }
        for _ in 0..<12 {
            let candidate = (lower + upper) / 2
            if fits(text, in: rect, fontSize: candidate, maximumLineCount: maximumLineCount) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return lower
    }

    public static func fitsCompletely(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        maximumLineCount: Int? = nil
    ) -> Bool {
        let insets = insets(for: fontSize)
        let width = max(1, rect.width - insets.left - insets.right)
        let height = max(1, rect.height - insets.top - insets.bottom)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.alignment = .left
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            // Use the same typographic leading as both preview and export. A
            // small size reduction is preferable to dropping the final line.
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )
        let measuredLineCount = wrappedLineCount(text: text, width: width, font: font)
        let respectsLineCount = maximumLineCount.map { measuredLineCount <= max(1, $0) } ?? true
        return respectsLineCount
            && ceil(bounds.height) <= height
            && ceil(bounds.width) <= width + 1
    }

    public static func wrappedLineCount(
        for text: String,
        in rect: CGRect,
        fontSize: CGFloat
    ) -> Int {
        let insets = insets(for: fontSize)
        let width = max(1, rect.width - insets.left - insets.right)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        return wrappedLineCount(text: text, width: width, font: font)
    }

    private static func wrappedLineCount(text: String, width: CGFloat, font: NSFont) -> Int {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var location = 0
        var lines = 0
        while location < attributed.length {
            let count = CTTypesetterSuggestClusterBreak(typesetter, location, Double(width))
            location += max(1, count)
            lines += 1
        }
        return max(1, lines)
    }

    private static func fits(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        maximumLineCount: Int?
    ) -> Bool {
        fitsCompletely(
            text,
            in: rect,
            fontSize: fontSize,
            maximumLineCount: maximumLineCount
        )
    }
}

/// One AppKit renderer shared by the live editor and exported image. Keeping
/// measurement and drawing in the same text engine prevents line-height drift,
/// overlapping rows, and preview-only truncation.
@MainActor
public enum ScreenshotTranslationDrawing {
    public static func draw(
        _ blocks: [ScreenshotTranslationBlock],
        in destinationRect: CGRect,
        sourceImageSize: CGSize
    ) {
        let scale = destinationRect.height / max(1, sourceImageSize.height)
        for block in blocks {
            let rect = displayRect(for: block.boundingBox, in: destinationRect)
            guard rect.width >= 2, rect.height >= 2 else { continue }

            let appearance = block.appearance
            let preferredSize = max(0.25, appearance.fontSize * scale)
            let fontSize = ScreenshotTranslationTextLayout.fittedFontSize(
                for: block.translatedText,
                in: rect,
                preferredSize: preferredSize,
                minimumSize: min(6 * scale, preferredSize),
                maximumScale: 1,
                maximumLineCount: block.sourceLineCount
            )
            let insets = ScreenshotTranslationTextLayout.insets(for: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            paragraph.alignment = .left
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: appearance.foregroundColor.nsColor,
                .paragraphStyle: paragraph
            ]

            guard !block.translatedText.isEmpty else { continue }
            block.translatedText.draw(
                with: CGRect(
                    x: rect.minX + insets.left,
                    y: rect.minY + insets.top,
                    width: max(1, rect.width - insets.left - insets.right),
                    height: max(1, rect.height - insets.top - insets.bottom)
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
        }
    }

    private static func displayRect(for boundingBox: CGRect, in destination: CGRect) -> CGRect {
        ScreenshotTranslationTextLayout.pixelAlignedRect(for: boundingBox, in: destination)
    }
}

/// Places each semantic translation in one paragraph rectangle. The renderer
/// performs natural wrapping across the full rectangle instead of imposing the
/// source OCR line breaks. Source glyphs have already been removed from a clean
/// plate before this text-only renderer runs.
public enum ScreenshotTranslationComposer {
    public static func blocks(
        paragraphs: [RecognizedTextParagraph],
        translations: [UUID: String],
        appearances: [UUID: ScreenshotTranslationAppearance],
        imageSize: CGSize
    ) -> [ScreenshotTranslationBlock] {
        let resolvedParagraphSizes = paragraphStyleSizes(
            paragraphs: paragraphs,
            appearances: appearances,
            imageSize: imageSize
        )
        let prepared = paragraphs.compactMap { paragraph -> PreparedParagraph? in
            guard let translation = translations[paragraph.id],
                  !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let sourceBlocks = paragraph.blocks.sorted(by: VisionOCRService.readingOrder)
            guard !sourceBlocks.isEmpty else { return nil }
            let continuousText = OCRParagraphLayout.continuousText(translation)
            guard !continuousText.isEmpty else { return nil }

            let sampled = sourceBlocks.map { appearances[$0.id] ?? .fallback }
            let paragraphSize = resolvedParagraphSizes[paragraph.id]
                ?? median(sampled.map(\.fontSize))
            let foreground = medianColor(sampled.map(\.foregroundColor), forcedAlpha: nil)
            let background = medianColor(sampled.map(\.backgroundColor), forcedAlpha: 1)
            let paragraphBox = sourceBlocks.dropFirst().reduce(sourceBlocks[0].boundingBox) {
                $0.union($1.boundingBox)
            }
            let layoutBox = paragraphBoxWithBottomSafety(
                paragraphBox,
                fontSize: paragraphSize,
                imageSize: imageSize
            )
            let sourceLineCount = visualLineCount(in: sourceBlocks)
            let finalSize = ScreenshotTranslationTextLayout.fittedFontSize(
                for: continuousText,
                in: pixelRect(for: layoutBox, imageSize: imageSize),
                preferredSize: paragraphSize,
                minimumSize: min(6, paragraphSize),
                maximumScale: 1.06,
                maximumLineCount: sourceLineCount
            )

            return PreparedParagraph(
                id: paragraph.id,
                sourceText: ScreenshotTranslationContentPolicy.textForTranslation(paragraph.text),
                translatedText: continuousText,
                boundingBox: layoutBox,
                backgroundBoxes: sourceBlocks.map(\.boundingBox),
                backgroundRegions: zip(sourceBlocks, sampled).map {
                    ScreenshotTranslationBackgroundRegion(
                        boundingBox: $0.0.boundingBox,
                        backgroundColor: $0.1.backgroundColor
                    )
                },
                sourceLineCount: sourceLineCount,
                preferredSize: paragraphSize,
                fittedSize: finalSize,
                foreground: foreground,
                background: background
            )
        }

        // Paragraph detection is semantic, not visual: a greeting and the body
        // can be separate paragraphs while still sharing the source font. Use
        // the largest common size that fits every paragraph in the same style
        // cluster so OCR box-height noise cannot create visibly different type.
        var commonSizes: [Int: CGFloat] = [:]
        for item in prepared {
            let key = styleKey(for: item.preferredSize)
            commonSizes[key] = min(commonSizes[key] ?? item.fittedSize, item.fittedSize)
        }

        return prepared.flatMap { item in
            let finalSize = commonSizes[styleKey(for: item.preferredSize)] ?? item.fittedSize
            return [ScreenshotTranslationBlock(
                id: item.id,
                sourceText: item.sourceText,
                translatedText: item.translatedText,
                boundingBox: item.boundingBox,
                backgroundBoxes: item.backgroundBoxes,
                backgroundRegions: item.backgroundRegions,
                sourceLineCount: item.sourceLineCount,
                appearance: ScreenshotTranslationAppearance(
                    fontSize: max(0.25, finalSize),
                    foregroundColor: item.foreground,
                    backgroundColor: item.background
                )
            )]
        }
    }

    private struct PreparedParagraph {
        let id: UUID
        let sourceText: String
        let translatedText: String
        let boundingBox: CGRect
        let backgroundBoxes: [CGRect]
        let backgroundRegions: [ScreenshotTranslationBackgroundRegion]
        let sourceLineCount: Int
        let preferredSize: CGFloat
        let fittedSize: CGFloat
        let foreground: RGBAColor
        let background: RGBAColor
    }

    private struct ParagraphStyleEntry {
        let id: UUID
        let size: CGFloat
        let boundingBox: CGRect
        let isSingleVisualLine: Bool
        let foreground: RGBAColor
        let background: RGBAColor
    }

    private static func styleKey(for size: CGFloat) -> Int {
        Int((size * 100).rounded())
    }

    private static func visualLineCount(in blocks: [RecognizedTextBlock]) -> Int {
        var lines: [CGRect] = []
        for block in blocks.sorted(by: VisionOCRService.readingOrder) {
            let candidates = lines.indices.filter { index in
                let tolerance = max(lines[index].height, block.boundingBox.height) * 0.55
                return abs(lines[index].midY - block.boundingBox.midY) <= tolerance
            }
            if let index = candidates.min(by: {
                abs(lines[$0].midY - block.boundingBox.midY)
                    < abs(lines[$1].midY - block.boundingBox.midY)
            }) {
                lines[index] = lines[index].union(block.boundingBox)
            } else {
                lines.append(block.boundingBox)
            }
        }
        let embeddedLineBreaks = blocks.reduce(0) { total, block in
            total + max(
                0,
                block.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.count - 1
            )
        }
        return max(1, lines.count + embeddedLineBreaks)
    }

    private static func paragraphBoxWithBottomSafety(
        _ box: CGRect,
        fontSize: CGFloat,
        imageSize: CGSize
    ) -> CGRect {
        let bottomPadding = max(2, fontSize * 0.28) / max(1, imageSize.height)
        let minY = max(0, box.minY - bottomPadding)
        return CGRect(
            x: box.minX,
            y: minY,
            width: box.width,
            height: min(1 - minY, box.maxY - minY)
        )
    }

    private static func pixelRect(for boundingBox: CGRect, imageSize: CGSize) -> CGRect {
        ScreenshotTranslationTextLayout.pixelAlignedRect(
            for: boundingBox, in: CGRect(origin: .zero, size: imageSize)
        )
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return ScreenshotTranslationAppearance.fallback.fontSize }
        let values = values.sorted()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private static func paragraphStyleSizes(
        paragraphs: [RecognizedTextParagraph],
        appearances: [UUID: ScreenshotTranslationAppearance],
        imageSize: CGSize
    ) -> [UUID: CGFloat] {
        let detailedEntries = paragraphs.map { paragraph in
            let paragraphAppearances = paragraph.blocks.map {
                appearances[$0.id] ?? .fallback
            }
            return ParagraphStyleEntry(
                id: paragraph.id,
                size: median(paragraphAppearances.map(\.fontSize)),
                boundingBox: paragraph.boundingBox,
                isSingleVisualLine: visualLineCount(in: paragraph.blocks) == 1,
                foreground: medianColor(paragraphAppearances.map(\.foregroundColor), forcedAlpha: nil),
                background: medianColor(paragraphAppearances.map(\.backgroundColor), forcedAlpha: 1)
            )
        }
        let entries = detailedEntries.map { (id: $0.id, size: $0.size) }
            .sorted { $0.size < $1.size }
        guard !entries.isEmpty else { return [:] }

        var clusters: [[(id: UUID, size: CGFloat)]] = []
        for entry in entries {
            guard var cluster = clusters.popLast() else {
                clusters.append([entry])
                continue
            }
            let clusterSize = median(cluster.map(\.size))
            if entry.size / max(0.25, clusterSize) <= 1.22 {
                cluster.append(entry)
                clusters.append(cluster)
            } else {
                clusters.append(cluster)
                clusters.append([entry])
            }
        }

        var resolved: [UUID: CGFloat] = [:]
        for cluster in clusters {
            let styleSize = median(cluster.map(\.size))
            for entry in cluster { resolved[entry.id] = styleSize }
        }

        // Dense UI rows (especially table headers) share one font even when
        // Vision reports a shorter ink box for glyphs without descenders. Use
        // the row/style median so one header such as "Created Time" cannot be
        // redrawn several pixels smaller than all of its neighbours.
        var rows: [[ParagraphStyleEntry]] = []
        let rowEntries = detailedEntries.filter(\.isSingleVisualLine)
        for entry in rowEntries.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let index = rows.indices.first(where: { rowIndex in
                guard let anchor = rows[rowIndex].first else { return false }
                let height = min(anchor.boundingBox.height, entry.boundingBox.height)
                return abs(anchor.boundingBox.midY - entry.boundingBox.midY) <= height * 0.55
            }) {
                rows[index].append(entry)
            } else {
                rows.append([entry])
            }
        }
        for row in rows where row.count >= 4 {
            var styleGroups: [[ParagraphStyleEntry]] = []
            for entry in row {
                if let index = styleGroups.indices.first(where: { groupIndex in
                    guard let anchor = styleGroups[groupIndex].first else { return false }
                    return colorDistance(entry.foreground, anchor.foreground) <= 0.12
                        && colorDistance(entry.background, anchor.background) <= 0.12
                }) {
                    styleGroups[index].append(entry)
                } else {
                    styleGroups.append([entry])
                }
            }
            for group in styleGroups where group.count >= 4 {
                let rowSize = median(group.map(\.size))
                for entry in group {
                    resolved[entry.id] = max(resolved[entry.id] ?? entry.size, rowSize)
                }
            }
        }

        // Vertically stacked menu labels also share a font. Ink-box heights
        // vary with ascenders/descenders, and selected rows may use different
        // text and fill colors, so identify the column by alignment and spacing.
        let textByID = Dictionary(uniqueKeysWithValues: paragraphs.map { ($0.id, $0.text) })
        var columns: [[ParagraphStyleEntry]] = []
        for entry in rowEntries.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            guard let text = textByID[entry.id], text.count <= 32,
                  text.split(whereSeparator: { $0.isWhitespace }).count <= 3,
                  text.last.map({ !".!?;:。！？；：".contains($0) }) == true else { continue }
            let box = pixelRect(for: entry.boundingBox, imageSize: imageSize)
            if let index = columns.indices.first(where: { index in
                guard let previous = columns[index].last else { return false }
                let upper = pixelRect(for: previous.boundingBox, imageSize: imageSize)
                let height = max(upper.height, box.height)
                let gap = box.minY - upper.maxY
                let sizes = columns[index].map(\.size) + [entry.size]
                return abs(upper.minX - box.minX) <= max(2, height * 0.25)
                    && gap > height * 0.45 && gap <= height * 2.4
                    && (sizes.max() ?? 1) / max(0.25, sizes.min() ?? 1) <= 1.6
                    && !OCRSemanticContinuity.isContinuous(
                        previous: textByID[previous.id] ?? "", current: text
                    )
            }) {
                columns[index].append(entry)
            } else {
                columns.append([entry])
            }
        }
        for column in columns where column.count >= 4 {
            let size = median(column.map(\.size))
            for entry in column { resolved[entry.id] = size }
        }
        return resolved
    }

    private static func colorDistance(_ lhs: RGBAColor, _ rhs: RGBAColor) -> CGFloat {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }

    private static func medianColor(
        _ colors: [RGBAColor],
        forcedAlpha: CGFloat?
    ) -> RGBAColor {
        guard !colors.isEmpty else { return .black }
        return RGBAColor(
            red: median(colors.map(\.red)),
            green: median(colors.map(\.green)),
            blue: median(colors.map(\.blue)),
            alpha: forcedAlpha ?? median(colors.map(\.alpha))
        )
    }
}

/// Samples the source screenshot once and derives stable OCR-line colors and sizing.
public enum ScreenshotTranslationAppearanceExtractor {
    public static func appearances(
        for blocks: [RecognizedTextBlock],
        in image: CGImage
    ) -> [UUID: ScreenshotTranslationAppearance] {
        let pixels = ScreenshotPixelBuffer(image: image)
        return Dictionary(uniqueKeysWithValues: blocks.map { block in
            let sourceHeight = max(1, block.boundingBox.height * CGFloat(image.height))
            // The Vision rectangle is a tight glyph-ink box. With device-metric
            // fitting, its pixel height is the closest stable starting size.
            let preferredSize = max(8, sourceHeight)
            guard let pixels,
                  let rect = pixels.topLeftRect(for: block.boundingBox) else {
                return (block.id, ScreenshotTranslationAppearance(
                    fontSize: preferredSize,
                    foregroundColor: .black,
                    backgroundColor: .white
                ))
            }
            let background = pixels.medianColor(around: rect)
            let foreground = pixels.highContrastColor(in: rect, against: background)
                ?? readableForeground(on: background)
            return (block.id, ScreenshotTranslationAppearance(
                fontSize: preferredSize,
                foregroundColor: foreground,
                backgroundColor: RGBAColor(
                    red: background.red,
                    green: background.green,
                    blue: background.blue,
                    alpha: 1
                )
            ))
        })
    }

    private static func readableForeground(on background: RGBAColor) -> RGBAColor {
        let luminance = 0.2126 * background.red + 0.7152 * background.green + 0.0722 * background.blue
        return luminance > 0.52 ? .black : .white
    }
}

private struct ScreenshotPixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]

    init?(image: CGImage) {
        width = image.width
        height = image.height
        bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        guard let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        data = bytes
    }

    func topLeftRect(for normalizedBox: CGRect) -> CGRect? {
        let box = normalizedBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rect = CGRect(
            x: box.minX * CGFloat(width),
            y: (1 - box.maxY) * CGFloat(height),
            width: box.width * CGFloat(width),
            height: box.height * CGFloat(height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        return rect.width >= 2 && rect.height >= 2 ? rect : nil
    }

    func medianColor(around rect: CGRect) -> RGBAColor {
        let inset = max(2, min(6, Int(min(rect.width, rect.height) * 0.18)))
        let outer = rect.insetBy(dx: -CGFloat(inset), dy: -CGFloat(inset))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var red: [UInt8] = []
        var green: [UInt8] = []
        var blue: [UInt8] = []
        let stride = max(1, Int(max(outer.width, outer.height) / 180))
        for y in Swift.stride(from: Int(outer.minY), to: Int(outer.maxY), by: stride) {
            for x in Swift.stride(from: Int(outer.minX), to: Int(outer.maxX), by: stride) {
                guard !rect.contains(CGPoint(x: x, y: y)) else { continue }
                let offset = y * bytesPerRow + x * 4
                red.append(data[offset])
                green.append(data[offset + 1])
                blue.append(data[offset + 2])
            }
        }
        guard !red.isEmpty else { return .white }
        red.sort(); green.sort(); blue.sort()
        let middle = red.count / 2
        return RGBAColor(
            red: CGFloat(red[middle]) / 255,
            green: CGFloat(green[middle]) / 255,
            blue: CGFloat(blue[middle]) / 255
        )
    }

    func highContrastColor(in rect: CGRect, against background: RGBAColor) -> RGBAColor? {
        var candidates: [(distance: CGFloat, color: RGBAColor)] = []
        let sampleStride = max(1, Int(max(rect.width, rect.height) / 160))
        for y in Swift.stride(from: Int(rect.minY), to: Int(rect.maxY), by: sampleStride) {
            for x in Swift.stride(from: Int(rect.minX), to: Int(rect.maxX), by: sampleStride) {
                let offset = y * bytesPerRow + x * 4
                let color = RGBAColor(
                    red: CGFloat(data[offset]) / 255,
                    green: CGFloat(data[offset + 1]) / 255,
                    blue: CGFloat(data[offset + 2]) / 255
                )
                let distance = colorDistance(color, background)
                if distance >= 0.16 { candidates.append((distance, color)) }
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.distance > $1.distance }
        // Average the strongest glyph-color samples. Anti-aliased edge pixels
        // rank lower, so the result stays close to the source text color.
        let count = max(1, min(candidates.count, max(4, candidates.count / 7)))
        let colors = candidates.prefix(count).map(\.color)
        return RGBAColor(
            red: colors.map(\.red).reduce(0, +) / CGFloat(colors.count),
            green: colors.map(\.green).reduce(0, +) / CGFloat(colors.count),
            blue: colors.map(\.blue).reduce(0, +) / CGFloat(colors.count)
        )
    }

    private func colorDistance(_ lhs: RGBAColor, _ rhs: RGBAColor) -> CGFloat {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }
}
