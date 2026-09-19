import AppKit
import Testing
@testable import HelloXCore

struct DropdownTranslationTests {
    @Test func ratioProtectionPreservesCountsAndOrdinaryMarkers() {
        for ratio in ["0 / 12", "3/12", "12 ／ 12"] {
            let source = "\(ratio) countries configured"
            #expect(ScreenshotTranslationContentPolicy.textForTranslation(source) == source)
            let protected = ScreenshotTranslationContentPolicy.protectedText(source)
            #expect(protected.text.contains("HXKEEP"))
            #expect(protected.restoring(in: protected.text) == source)
        }
        #expect(ScreenshotTranslationContentPolicy.textForTranslation("0 Dashboard") == "Dashboard")
        #expect(ScreenshotTranslationContentPolicy.textForTranslation("2. Configure countries") == "Configure countries")
        #expect(ScreenshotTranslationOutputNormalizer.normalize(
            "译文", sourceText: "3/12 countries configured", targetLanguageIdentifier: "zh-Hant"
        ) == "已配置 3/12 個國家")
        #expect(ScreenshotTranslationOutputNormalizer.normalize(
            "unchanged", sourceText: "0/12 countries configured", targetLanguageIdentifier: "fr"
        ) == "unchanged")
        #expect(ScreenshotTranslationOutputNormalizer.normalize(
            "普通译文", sourceText: "12 countries configured", targetLanguageIdentifier: "zh-Hans"
        ) == "普通译文")
    }
    @MainActor
    @Test func countryProgressRetainsRatio() async throws {
        let url = try #require(Bundle.module.url(forResource: "country-progress", withExtension: "png", subdirectory: "Fixtures"))
        let image = try #require(NSImage(contentsOf: url))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try await VisionOCRService().recognizeText(in: cgImage)
        let contents = ScreenshotTranslationContentPolicy.translatableContents(from: result.blocks, imageSize: CGSize(width: cgImage.width, height: cgImage.height))
        #expect(contents.count == 1)
        #expect(contents.first.map { ScreenshotTranslationContentPolicy.textForTranslation($0.text).hasPrefix("0 / 12") } == true)
        let paragraphs = OCRParagraphLayout.paragraphs(from: contents)
        let paragraph = try #require(paragraphs.first)
        let translation = ScreenshotTranslationOutputNormalizer.normalize(
            "已配置12个国家", sourceText: paragraph.text, targetLanguageIdentifier: "zh-Hans"
        )
        #expect(translation == "已配置 0/12 个国家")
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let composed = ScreenshotTranslationComposer.blocks(
            paragraphs: paragraphs, translations: [paragraph.id: translation],
            appearances: ScreenshotTranslationAppearanceExtractor.appearances(for: contents, in: cgImage),
            imageSize: size
        )
        let translated = try #require(composed.first)
        #expect(translated.sourceLineCount == 1)
        // The source ink is about 10 px high; Vision reports a 16 px box.
        #expect(translated.appearance.fontSize <= 13)
        #expect(translated.appearance.fontSize >= 9)
        #expect(ScreenshotTranslationTextLayout.fitsCompletely(
            translation,
            in: ScreenshotTranslationTextLayout.pixelAlignedRect(for: translated.boundingBox, in: CGRect(origin: .zero, size: size)),
            fontSize: translated.appearance.fontSize, maximumLineCount: 1
        ))
        if let path = ProcessInfo.processInfo.environment["HELLOX_COUNTRY_PREVIEW"] {
            try renderPreview(composed, image: cgImage, path: path)
        }

    }
    @MainActor
    @Test func reportedDropdownKeepsEachTranslationInItsOriginalRow() async throws {
        let url = try #require(Bundle.module.url(
            forResource: "pricing-dropdown", withExtension: "png", subdirectory: "Fixtures"
        ))
        let image = try #require(NSImage(contentsOf: url))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try await VisionOCRService().recognizeText(in: cgImage)
        let paragraphs = OCRParagraphLayout.paragraphs(from: result.blocks)
        try #require(paragraphs.count == 4)
        #expect(paragraphs.allSatisfy { $0.blocks.count == 1 })
        #expect(paragraphs[1].text == "Not configured")
        #expect(paragraphs[2].text == "Fixed by weight range")
        #expect(paragraphs[3].text == "Per piece + per kg")

        // Fixed translations isolate layout verification from network providers.
        let translations = ["按重量范围固定", "未配置", "按重量范围固定", "每件费用 + 每公斤费用"]
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let composed = ScreenshotTranslationComposer.blocks(
            paragraphs: paragraphs,
            translations: Dictionary(uniqueKeysWithValues: zip(paragraphs, translations).map { ($0.id, $1) }),
            appearances: ScreenshotTranslationAppearanceExtractor.appearances(for: result.blocks, in: cgImage),
            imageSize: size
        )
        #expect(composed.count == 4)
        #expect(Set(composed.map { $0.appearance.fontSize }).count == 1)
        for (translated, original) in zip(composed, paragraphs) {
            #expect(translated.sourceLineCount == 1)
            #expect(translated.backgroundBoxes == [original.boundingBox])
            #expect(abs(translated.boundingBox.maxY - original.boundingBox.maxY) < 0.0001)
            let box = translated.boundingBox
            let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                              width: box.width * size.width, height: box.height * size.height).integral
            #expect(ScreenshotTranslationTextLayout.fitsCompletely(
                translated.translatedText, in: rect, fontSize: translated.appearance.fontSize,
                maximumLineCount: 1
            ))
        }
        for (upper, lower) in zip(composed, composed.dropFirst()) {
            #expect(upper.boundingBox.minY > lower.boundingBox.maxY)
        }

        if let path = ProcessInfo.processInfo.environment["HELLOX_DROPDOWN_PREVIEW"] {
            try renderPreview(composed, image: cgImage, path: path)
        }
    }

    @MainActor
    private func renderPreview(_ composed: [ScreenshotTranslationBlock], image cgImage: CGImage, path: String) throws {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let clean = try ScreenshotTranslationBackgroundReconstructor.eraseText(
            in: cgImage, normalizedRegions: composed.flatMap(\.backgroundRegions)
        )
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cgImage.width, pixelsHigh: cgImage.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.draw(clean, in: CGRect(origin: .zero, size: size))
        graphics.cgContext.translateBy(x: 0, y: size.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
        ScreenshotTranslationDrawing.draw(composed, in: CGRect(origin: .zero, size: size), sourceImageSize: size)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

    @Test func multiwordWrappedSentenceStillContinues() {
        #expect(OCRSemanticContinuity.isContinuous(previous: "Fixed by weight and", current: "Per item when available"))
        #expect(OCRSemanticContinuity.isContinuous(previous: "Waiting for your response", current: "before continuing the task"))
        #expect(!OCRSemanticContinuity.isContinuous(previous: "Not configured", current: "Fixed by weight range"))
        #expect(!OCRSemanticContinuity.isContinuous(previous: "Fixed by weight range", current: "Per piece + per kg"))
    }
}
