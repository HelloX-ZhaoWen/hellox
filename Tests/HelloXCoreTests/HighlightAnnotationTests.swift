import CoreGraphics
import Testing
@testable import HelloXCore

@Suite("Highlight annotations")
struct HighlightAnnotationTests {
    @MainActor
    @Test func rendererDimsTheOutsideAndPreservesTheHighlightedArea() throws {
        let base = try #require(makeSolidImage(width: 20, height: 20, value: 255))
        let annotation = Annotation(
            tool: .highlight,
            start: CGPoint(x: 0.25, y: 0.25),
            end: CGPoint(x: 0.75, y: 0.75),
            color: AnnotationHighlightStyle.defaultColor
        )

        let rendered = try AnnotationRenderer.render(
            baseImage: base,
            annotations: [annotation]
        )
        let pixels = try #require(rgbaPixels(from: rendered))
        let outside = pixel(x: 2, y: 2, width: rendered.width, pixels: pixels)
        let highlighted = pixel(x: 10, y: 10, width: rendered.width, pixels: pixels)

        #expect(outside.0 < 160)
        #expect(outside.0 == outside.1)
        #expect(outside.1 == outside.2)
        #expect(outside.3 == 255)
        #expect(highlighted.0 == 255)
        #expect(highlighted.1 == 255)
        #expect(highlighted.2 == 255)
        #expect(highlighted.3 == 255)
    }

    @MainActor
    @Test func rendererDrawsAnOptionalColoredBorder() throws {
        let base = try #require(makeSolidImage(width: 40, height: 40, value: 255))
        let annotation = Annotation(
            tool: .highlight,
            start: CGPoint(x: 0.25, y: 0.25),
            end: CGPoint(x: 0.75, y: 0.75),
            color: .red,
            lineWidth: 4,
            highlightShowsBorder: true
        )

        let rendered = try AnnotationRenderer.render(baseImage: base, annotations: [annotation])
        let pixels = try #require(rgbaPixels(from: rendered))
        let border = pixel(x: 10, y: 20, width: rendered.width, pixels: pixels)
        let center = pixel(x: 20, y: 20, width: rendered.width, pixels: pixels)

        #expect(border.0 > border.1)
        #expect(border.0 > border.2)
        #expect(center == (255, 255, 255, 255))
    }

    @MainActor
    @Test func ellipsePreservesOnlyPixelsInsideTheEllipse() throws {
        let base = try #require(makeSolidImage(width: 40, height: 40, value: 255))
        let annotation = Annotation(
            tool: .highlight,
            start: CGPoint(x: 0.25, y: 0.25),
            end: CGPoint(x: 0.75, y: 0.75),
            highlightShape: .ellipse
        )

        let rendered = try AnnotationRenderer.render(baseImage: base, annotations: [annotation])
        let pixels = try #require(rgbaPixels(from: rendered))
        let center = pixel(x: 20, y: 20, width: rendered.width, pixels: pixels)
        let boundingCorner = pixel(x: 11, y: 11, width: rendered.width, pixels: pixels)

        #expect(center == (255, 255, 255, 255))
        #expect(boundingCorner.0 < 160)
        #expect(boundingCorner.1 < 160)
        #expect(boundingCorner.2 < 160)
    }

    private func makeSolidImage(width: Int, height: Int, value: UInt8) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: CGFloat(value) / 255, green: CGFloat(value) / 255, blue: CGFloat(value) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func rgbaPixels(from image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func pixel(
        x: Int,
        y: Int,
        width: Int,
        pixels: [UInt8]
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }
}
