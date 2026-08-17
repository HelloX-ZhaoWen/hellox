import CoreGraphics
import Foundation

/// Derives the small amount of visual context needed to replace an OCR block
/// without imposing a new black-on-white text treatment on the screenshot.
public enum ImageTranslationAppearanceExtractor {
    public static func appearance(for block: RecognizedTextBlock, in image: CGImage) -> ImageTranslationAppearance {
        appearance(for: block, pixels: PixelBuffer(image: image))
    }

    public static func appearances(
        for blocks: [RecognizedTextBlock],
        in image: CGImage
    ) -> [UUID: ImageTranslationAppearance] {
        let pixels = PixelBuffer(image: image)
        return Dictionary(uniqueKeysWithValues: blocks.map { block in
            (block.id, appearance(for: block, pixels: pixels))
        })
    }

    private static func appearance(
        for block: RecognizedTextBlock,
        pixels: PixelBuffer?
    ) -> ImageTranslationAppearance {
        let box = block.boundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let height = max(1, box.height * CGFloat(pixels?.height ?? 1))
        // Vision's box includes some surrounding leading, but translating into a
        // fixed source line must begin close to the source glyph height. Fitting
        // will reduce it only when the translated text genuinely needs it.
        let fontSize = max(10, height * 0.98)
        let sourceLines = block.text.split(separator: "\n", omittingEmptySubsequences: false).count
        guard let pixels,
              let textRect = pixels.topLeftRect(for: box),
              textRect.width >= 2, textRect.height >= 2 else {
            return ImageTranslationAppearance(
                fontSize: fontSize,
                foregroundColor: .black,
                backgroundColor: .white,
                lineCount: sourceLines
            )
        }

        let background = pixels.medianColor(around: textRect)
        let foreground = pixels.highContrastColor(in: textRect, against: background) ?? .black
        return ImageTranslationAppearance(
            fontSize: fontSize,
            foregroundColor: foreground,
            backgroundColor: background,
            lineCount: sourceLines
        )
    }
}

private struct PixelBuffer {
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
        let rect = CGRect(
            x: normalizedBox.minX * CGFloat(width),
            y: (1 - normalizedBox.maxY) * CGFloat(height),
            width: normalizedBox.width * CGFloat(width),
            height: normalizedBox.height * CGFloat(height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        return rect.isEmpty ? nil : rect
    }

    func medianColor(around rect: CGRect) -> RGBAColor {
        let inset = max(1, min(3, Int(min(rect.width, rect.height) / 5)))
        let ring = rect.insetBy(dx: -CGFloat(inset), dy: -CGFloat(inset))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var red: [UInt8] = []
        var green: [UInt8] = []
        var blue: [UInt8] = []
        for y in Int(ring.minY)..<Int(ring.maxY) {
            for x in Int(ring.minX)..<Int(ring.maxX) where !rect.contains(CGPoint(x: x, y: y)) {
                let pixel = color(atX: x, y: y)
                red.append(pixel.0)
                green.append(pixel.1)
                blue.append(pixel.2)
            }
        }
        guard !red.isEmpty else { return .white }
        red.sort()
        green.sort()
        blue.sort()
        let middle = red.count / 2
        return RGBAColor(
            red: CGFloat(red[middle]) / 255,
            green: CGFloat(green[middle]) / 255,
            blue: CGFloat(blue[middle]) / 255
        )
    }

    func highContrastColor(in rect: CGRect, against background: RGBAColor) -> RGBAColor? {
        var candidates: [(score: CGFloat, color: RGBAColor)] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let pixel = color(atX: x, y: y)
                let color = RGBAColor(
                    red: CGFloat(pixel.0) / 255,
                    green: CGFloat(pixel.1) / 255,
                    blue: CGFloat(pixel.2) / 255
                )
                let score = distance(color, background)
                if score > 0.18 { candidates.append((score, color)) }
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.score > $1.score }
        // Sample from the most opaque-looking glyph pixels, avoiding the
        // anti-aliased edge colors that otherwise make text look faded.
        let sampleCount = max(1, min(candidates.count, max(3, candidates.count / 8)))
        let samples = candidates.prefix(sampleCount).map(\.color)
        return RGBAColor(
            red: samples.map(\.red).reduce(0, +) / CGFloat(samples.count),
            green: samples.map(\.green).reduce(0, +) / CGFloat(samples.count),
            blue: samples.map(\.blue).reduce(0, +) / CGFloat(samples.count)
        )
    }

    private func color(atX x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let offset = y * bytesPerRow + x * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    private func distance(_ lhs: RGBAColor, _ rhs: RGBAColor) -> CGFloat {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }
}
