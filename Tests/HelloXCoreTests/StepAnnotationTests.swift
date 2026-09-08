import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import HelloXCore

@Suite("Step annotations")
struct StepAnnotationTests {
    @Test func numberingStaysContinuousAfterRemovingAMiddleStep() {
        let first = step(id: UUID())
        let middle = step(id: UUID())
        let last = step(id: UUID())
        let rectangle = Annotation(
            tool: .rectangle,
            start: .zero,
            end: CGPoint(x: 0.2, y: 0.2)
        )
        let annotations = [first, rectangle, middle, last]

        #expect(StepAnnotationNumbering.number(for: first.id, in: annotations) == 1)
        #expect(StepAnnotationNumbering.number(for: middle.id, in: annotations) == 2)
        #expect(StepAnnotationNumbering.number(for: last.id, in: annotations) == 3)

        let afterDeletion = annotations.filter { $0.id != middle.id }
        #expect(StepAnnotationNumbering.number(for: last.id, in: afterDeletion) == 2)
    }

    @Test func fixedWidthTextWrapsAndGrowsVertically() {
        let short = StepAnnotationLayout.layout(
            text: "简短说明",
            number: 1,
            origin: .zero,
            totalWidth: 260,
            fontSize: 16
        )
        let long = StepAnnotationLayout.layout(
            text: String(repeating: "这是一段需要自动换行的步骤说明", count: 8),
            number: 1,
            origin: .zero,
            totalWidth: 260,
            fontSize: 16
        )

        #expect(short.cardRect.width == long.cardRect.width)
        #expect(long.cardRect.height > short.cardRect.height)
        #expect(long.textRect.width == short.textRect.width)
    }

    @Test func multiDigitBadgeExpandsWithoutShrinkingTheCard() {
        let oneDigit = StepAnnotationLayout.layout(
            text: "说明",
            number: 1,
            origin: .zero,
            totalWidth: 260,
            fontSize: 16
        )
        let manyDigits = StepAnnotationLayout.layout(
            text: "说明",
            number: 10_000,
            origin: .zero,
            totalWidth: 260,
            fontSize: 16
        )

        #expect(manyDigits.badgeRect.width > oneDigit.badgeRect.width)
        #expect(manyDigits.cardRect.width >= StepAnnotationLayout.minimumCardWidth)
    }

    @Test func trailingBadgePlacesTheCardOnItsLeft() {
        let layout = StepAnnotationLayout.layout(
            text: "右侧说明",
            number: 3,
            origin: CGPoint(x: 100, y: 40),
            totalWidth: 260,
            fontSize: 16,
            badgeOnTrailingEdge: true
        )

        #expect(layout.cardRect.minX == layout.bounds.minX)
        #expect(layout.cardRect.maxX < layout.badgeRect.minX)
        #expect(layout.badgeRect.maxX == layout.bounds.maxX)
    }

    @Test func connectorAutomaticallyUsesTheFacingCardEdge() {
        let base = StepAnnotationLayout.layout(
            text: "方向",
            number: 1,
            origin: CGPoint(x: 100, y: 100),
            totalWidth: 260,
            fontSize: 16
        )
        let card = base.cardRect
        let cases: [(CGPoint, CGPoint)] = [
            (
                CGPoint(x: card.midX, y: card.minY - 100),
                CGPoint(x: card.midX, y: card.minY)
            ),
            (
                CGPoint(x: card.maxX + 100, y: card.midY),
                CGPoint(x: card.maxX, y: card.midY)
            ),
            (
                CGPoint(x: card.midX, y: card.maxY + 100),
                CGPoint(x: card.midX, y: card.maxY)
            ),
            (
                CGPoint(x: card.minX - 100, y: card.midY),
                CGPoint(x: card.minX, y: card.midY)
            )
        ]

        for (badgeCenter, expectedEnd) in cases {
            let layout = StepAnnotationLayout.layout(
                text: "方向",
                number: 1,
                origin: CGPoint(x: 100, y: 100),
                totalWidth: 260,
                fontSize: 16,
                badgeCenter: badgeCenter
            )
            #expect(layout.connectorEnd == expectedEnd)
        }
    }

    @MainActor
    @Test func rendererPaintsBadgeBackgroundAndWrappedText() throws {
        let image = try #require(makeWhiteImage(width: 500, height: 240))
        let annotation = Annotation(
            tool: .step,
            start: CGPoint(x: 0.08, y: 0.18),
            end: CGPoint(x: 0.72, y: 0.70),
            text: "显示导入失败的个数及其明细，并支持自动换行",
            color: .red,
            lineWidth: 4
        )

        let rendered = try AnnotationRenderer.render(baseImage: image, annotations: [annotation])
        let layout = StepAnnotationLayout.layout(
            text: annotation.text,
            number: 1,
            origin: CGPoint(x: 40, y: 43.2),
            totalWidth: 320,
            fontSize: 20
        )
        let badgePixel = try #require(pixel(
            in: rendered,
            x: Int(layout.badgeRect.minX + 4),
            y: Int(layout.badgeRect.midY)
        ))
        let cardPixel = try #require(pixel(
            in: rendered,
            x: Int(layout.cardRect.maxX - 5),
            y: Int(layout.cardRect.midY)
        ))

        #expect(badgePixel.red > badgePixel.green)
        #expect(badgePixel.red > badgePixel.blue)
        #expect(cardPixel.red < 220)
        #expect(cardPixel.green < 220)
        #expect(cardPixel.blue < 220)
    }

    @MainActor
    @Test func rendererKeepsATrailingBadgeAtTheRightEdge() throws {
        let image = try #require(makeWhiteImage(width: 500, height: 180))
        let annotation = Annotation(
            tool: .step,
            start: CGPoint(x: 0.98, y: 0.20),
            end: CGPoint(x: 0.50, y: 0.55),
            text: "右侧标记",
            color: .red,
            lineWidth: 4
        )
        let rendered = try AnnotationRenderer.render(baseImage: image, annotations: [annotation])
        let layout = StepAnnotationLayout.layout(
            text: annotation.text,
            number: 1,
            origin: CGPoint(x: 250, y: 36),
            totalWidth: 240,
            fontSize: 20,
            badgeOnTrailingEdge: true
        )
        let badgePixel = try #require(pixel(
            in: rendered,
            x: Int(layout.badgeRect.maxX - 4),
            y: Int(layout.badgeRect.midY)
        ))
        let cardPixel = try #require(pixel(
            in: rendered,
            x: Int(layout.cardRect.minX + 4),
            y: Int(layout.cardRect.midY)
        ))

        #expect(badgePixel.red > badgePixel.green)
        #expect(badgePixel.red > badgePixel.blue)
        #expect(cardPixel.red < 220)
        #expect(cardPixel.green < 220)
        #expect(cardPixel.blue < 220)
    }

    @MainActor
    @Test func rendererDrawsAnIndependentlyPositionedBadgeAndConnector() throws {
        let image = try #require(makeWhiteImage(width: 500, height: 240))
        let annotation = Annotation(
            tool: .step,
            start: CGPoint(x: 0.08, y: 0.18),
            end: CGPoint(x: 0.72, y: 0.50),
            text: "可自由定位",
            color: .red,
            lineWidth: 4,
            stepBadgePosition: CGPoint(x: 0.90, y: 0.75)
        )
        let layout = StepAnnotationLayout.layout(
            text: annotation.text,
            number: 1,
            origin: CGPoint(x: 40, y: 43.2),
            totalWidth: 320,
            fontSize: 20,
            badgeCenter: CGPoint(x: 450, y: 180)
        )

        let rendered = try AnnotationRenderer.render(baseImage: image, annotations: [annotation])
        let badgePixel = try #require(pixel(
            in: rendered,
            x: Int(layout.badgeRect.minX + 4),
            y: Int(layout.badgeRect.midY)
        ))
        let connectorPixel = try #require(pixel(
            in: rendered,
            x: Int((layout.connectorStart.x + layout.connectorEnd.x) / 2),
            y: Int((layout.connectorStart.y + layout.connectorEnd.y) / 2)
        ))

        #expect(layout.badgeRect.midX == 450)
        #expect(layout.badgeRect.midY == 180)
        #expect(badgePixel.red > badgePixel.green)
        #expect(connectorPixel.red > connectorPixel.green)
    }

    private func step(id: UUID) -> Annotation {
        Annotation(
            id: id,
            tool: .step,
            start: CGPoint(x: 0.1, y: 0.1),
            end: CGPoint(x: 0.5, y: 0.3),
            text: "步骤"
        )
    }

    private func makeWhiteImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard x >= 0, x < image.width, y >= 0, y < image.height,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}
