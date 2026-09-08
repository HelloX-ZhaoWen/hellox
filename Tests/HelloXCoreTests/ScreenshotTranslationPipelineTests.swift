import CoreGraphics
import Foundation
import Testing
@testable import HelloXCore

struct ScreenshotTranslationPipelineTests {
    @Test func recognizesStepBadgeOCRMarkers() {
        for marker in ["2", "2)", "(2)", "（3）", "V", "V)", "v", "C", "*", "✓", "く", "<"] {
            #expect(VisionOCRService.isStepControlMarkerToken(marker))
        }
        for value in ["20X", "Left", "In", "A1"] {
            #expect(!VisionOCRService.isStepControlMarkerToken(value))
        }
    }

    @Test func removesParenthesizedStepNumberFromTranslationText() {
        #expect(
            ScreenshotTranslationContentPolicy.textForTranslation("(2) In Progress")
                == "In Progress"
        )
        #expect(
            ScreenshotTranslationContentPolicy.textForTranslation("（3） Waiting")
                == "Waiting"
        )
        #expect(
            ScreenshotTranslationContentPolicy.textForTranslation("く Finished")
                == "Finished"
        )
    }

    @Test func normalizesChineseCountdownDirectionWithoutChangingOrdinaryCopy() {
        #expect(ScreenshotTranslationOutputNormalizer.normalize(
            "进行中左00:00:08",
            sourceText: "In Progress Left 00:00:08",
            targetLanguageIdentifier: "zh-Hans"
        ) == "进行中剩余 00:00:08")
        #expect(ScreenshotTranslationOutputNormalizer.normalize(
            "進行中左側：00:00:08",
            sourceText: "In Progress Left 00:00:08",
            targetLanguageIdentifier: "zh-Hant"
        ) == "進行中剩餘 00:00:08")
        #expect(ScreenshotTranslationOutputNormalizer.normalize(
            "左侧导航",
            sourceText: "Left navigation",
            targetLanguageIdentifier: "zh-Hans"
        ) == "左侧导航")
    }

    @Test func acceptsRecoveredMultilineTableCellText() {
        let cell = RecognizedTextBlock(
            text: "Product\nImage",
            confidence: 0.99,
            boundingBox: CGRect(x: 0.13, y: 0.22, width: 0.07, height: 0.49),
            isLayoutIsolated: true
        )

        #expect(!ScreenshotTranslationContentPolicy.shouldPreserveOriginal(cell))
    }

    @Test func translatesDenseTableAbbreviationInsteadOfTreatingItAsAnIcon() {
        let abbreviation = RecognizedTextBlock(
            text: "SSR",
            confidence: 0.99,
            boundingBox: CGRect(x: 0.80, y: 0.42, width: 0.012, height: 0.24),
            isLayoutIsolated: true
        )

        let content = ScreenshotTranslationContentPolicy.translatableContent(
            from: abbreviation,
            imageSize: CGSize(width: 1_565, height: 63)
        )

        #expect(content?.text == "SSR")
    }

    @Test func excludesTrailingTableSortControlFromTranslationText() {
        let value = "Quantity ="

        #expect(ScreenshotTranslationContentPolicy.textForTranslation(value) == "Quantity")
        let range = ScreenshotTranslationContentPolicy.translationContentRange(in: value)
        #expect(range.map { String(value[$0]) } == "Quantity")
    }

    @Test func preservesStandaloneDatesAndKeepsTrailingStatusIconsOutsideTranslation() {
        let date = block(
            "2026-08-10 18:14:54",
            x: 0.78,
            y: 0.80,
            width: 0.07,
            height: 0.013
        )
        let sourceBox = CGRect(x: 0.66, y: 0.80, width: 0.065, height: 0.015)
        let textBox = CGRect(x: 0.66, y: 0.80, width: 0.035, height: 0.013)
        let status = RecognizedTextBlock(
            text: "Unchecked ® G",
            confidence: 0.99,
            boundingBox: sourceBox,
            translatableBoundingBox: textBox
        )

        let content = ScreenshotTranslationContentPolicy.translatableContent(
            from: status,
            imageSize: CGSize(width: 1_920, height: 958)
        )

        #expect(ScreenshotTranslationContentPolicy.shouldPreserveOriginal(date))
        #expect(ScreenshotTranslationContentPolicy.textForTranslation(status.text) == "Unchecked")
        #expect(content?.boundingBox == textBox)
        #expect(content?.text == status.text)
    }

    @Test func preservesSocialMetadataAndEngagementChrome() {
        let blocks = [
            block("Tibo", x: 0.1016, y: 0.9266, width: 0.0918, height: 0.0395),
            block("@thsottiaux • 8h", x: 0.1967, y: 0.9266, width: 0.1869, height: 0.0395),
            block("g ...", x: 0.8787, y: 0.9266, width: 0.0787, height: 0.0395),
            block("Translate me", x: 0.6500, y: 0.9266, width: 0.1600, height: 0.0395),
            block(
                "If you still haven't tried Codex but have considered it in the past, what's the",
                x: 0.1016,
                y: 0.8588,
                width: 0.8459,
                height: 0.0452
            ),
            block("one thing holding you back?", x: 0.1016, y: 0.8023, width: 0.3213, height: 0.0452),
            block("• 2.1K|", x: 0.1015, y: 0.7112, width: 0.0822, height: 0.0466),
            block("17 96", x: 0.2948, y: 0.7162, width: 0.0661, height: 0.0423),
            block("9 2.7K|", x: 0.4918, y: 0.7175, width: 0.0787, height: 0.0395),
            block("it 405K", x: 0.6786, y: 0.7113, width: 0.0985, height: 0.0464)
        ]

        let translatable = ScreenshotTranslationContentPolicy.translatableContents(
            from: blocks,
            imageSize: CGSize(width: 610, height: 354)
        )
        let paragraphs = OCRParagraphLayout.paragraphs(
            from: translatable.filter { $0.text != "Translate me" }
        )

        #expect(translatable.map(\.text) == [
            "Translate me",
            "If you still haven't tried Codex but have considered it in the past, what's the",
            "one thing holding you back?"
        ])
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].blocks.count == 2)
    }

    @Test func metricProtectionDoesNotHideOrdinaryNumberedCopy() {
        let metricValues = ["• 2.1K|", "9 2.7K|", "it 405K", "O 5.1K", "thi 1M", "• 5.4K I"]
        for value in metricValues {
            #expect(ScreenshotTranslationContentPolicy.shouldPreserveOriginal(
                block(value, x: 0.1, y: 0.5, width: 0.1, height: 0.04)
            ))
        }

        #expect(!ScreenshotTranslationContentPolicy.shouldPreserveOriginal(
            block("Ship 20X usage next week", x: 0.1, y: 0.4, width: 0.4, height: 0.04)
        ))
    }

    @Test func preservesStandaloneProductCodesAndCheckboxMarkers() {
        let code = RecognizedTextBlock(
            text: "D-B2B",
            confidence: 0.99,
            boundingBox: CGRect(x: 0.4, y: 0.6, width: 0.08, height: 0.08)
        )
        let checkboxLabel = RecognizedTextBlock(
            text: "0 Forbid Active",
            confidence: 0.99,
            boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.14, height: 0.08)
        )

        #expect(ScreenshotTranslationContentPolicy.shouldPreserveOriginal(code))
        let content = ScreenshotTranslationContentPolicy.translatableContent(
            from: checkboxLabel,
            imageSize: CGSize(width: 1145, height: 126)
        )
        #expect(ScreenshotTranslationContentPolicy.textForTranslation(content?.text ?? "") == "Forbid Active")
        #expect((content?.boundingBox.minX ?? 0) > checkboxLabel.boundingBox.minX)
    }

    @Test func preservesStandaloneLogoDomainButTranslatesBodyDomain() {
        let logo = block("@ONES.com", confidence: 0.5, x: 0.36, y: 0.78, width: 0.30, height: 0.115)
        let body = block(
            "Capabilities have shipped in ONES.com.",
            confidence: 1,
            x: 0.09,
            y: 0.42,
            width: 0.82,
            height: 0.056
        )

        #expect(ScreenshotTranslationContentPolicy.shouldPreserveOriginal(logo))
        #expect(!ScreenshotTranslationContentPolicy.shouldPreserveOriginal(body))
    }

    @Test func excludesSymbolsBrokenTextAndIconLikeOCRFromTranslation() {
        let symbol = block("◆", x: 0.10, y: 0.80, width: 0.03, height: 0.03)
        let misreadIcon = block("A", x: 0.10, y: 0.70, width: 0.03, height: 0.03)
        let broken = block("\u{FFFD}", x: 0.10, y: 0.60, width: 0.05, height: 0.03)
        let ordinaryLabel = block("OK", x: 0.10, y: 0.50, width: 0.12, height: 0.03)

        #expect(ScreenshotTranslationContentPolicy.shouldPreserveOriginal(symbol))
        #expect(ScreenshotTranslationContentPolicy.shouldPreserveOriginal(misreadIcon))
        #expect(ScreenshotTranslationContentPolicy.shouldPreserveOriginal(broken))
        #expect(!ScreenshotTranslationContentPolicy.shouldPreserveOriginal(ordinaryLabel))
    }

    @Test func distinguishesOversizedLeadingIconOCRFromARealInitial() {
        #expect(VisionOCRService.shouldTreatLeadingTokenAsIcon(
            markerText: "B",
            markerPixelSize: CGSize(width: 21, height: 14),
            contentText: "Contacts",
            contentPixelSize: CGSize(width: 63, height: 14)
        ))
        #expect(VisionOCRService.shouldTreatLeadingTokenAsIcon(
            markerText: "I",
            markerPixelSize: CGSize(width: 32, height: 12),
            contentText: "Dashboard",
            contentPixelSize: CGSize(width: 73, height: 12)
        ))
        #expect(!VisionOCRService.shouldTreatLeadingTokenAsIcon(
            markerText: "I",
            markerPixelSize: CGSize(width: 4, height: 14),
            contentText: "Understand",
            contentPixelSize: CGSize(width: 78, height: 14)
        ))
        #expect(!VisionOCRService.shouldTreatLeadingTokenAsIcon(
            markerText: "W",
            markerPixelSize: CGSize(width: 12.77, height: 10.04),
            contentText: "Hotels",
            contentPixelSize: CGSize(width: 41.6, height: 10.04)
        ))
    }

    @Test func keepsLeadingBulletsAndHeadingIconsOutsideTranslatedRegion() {
        let imageSize = CGSize(width: 1_264, height: 176)
        let bullet = block(
            "• Jesse proposed shifting ERP order matching.",
            x: 0.028,
            y: 0.59,
            width: 0.85,
            height: 0.102
        )
        let heading = block(
            "= AI Overview",
            x: 0.028,
            y: 0.79,
            width: 0.081,
            height: 0.080
        )

        let bulletContent = ScreenshotTranslationContentPolicy.translatableContent(
            from: bullet,
            imageSize: imageSize
        )
        let headingContent = ScreenshotTranslationContentPolicy.translatableContent(
            from: heading,
            imageSize: imageSize
        )

        #expect(bulletContent?.text == "• Jesse proposed shifting ERP order matching.")
        #expect(headingContent?.text == "= AI Overview")
        #expect(ScreenshotTranslationContentPolicy.textForTranslation(bulletContent?.text ?? "")
            == "Jesse proposed shifting ERP order matching.")
        #expect(ScreenshotTranslationContentPolicy.textForTranslation(headingContent?.text ?? "")
            == "AI Overview")
        #expect((bulletContent?.boundingBox.minX ?? 0) > bullet.boundingBox.minX)
        #expect((headingContent?.boundingBox.minX ?? 0) > heading.boundingBox.minX)
        #expect(bulletContent?.id == bullet.id)
        #expect(headingContent?.id == heading.id)

        let secondBullet = block(
            "• Amir proposes a staged rollout.",
            x: 0.028,
            y: 0.45,
            width: 0.60,
            height: 0.102
        )
        let structuralBlocks = [bullet, secondBullet].compactMap {
            ScreenshotTranslationContentPolicy.translatableContent(from: $0, imageSize: imageSize)
        }
        #expect(OCRParagraphLayout.paragraphs(from: structuralBlocks).count == 2)
    }

    @Test func usesCharacterLevelContentBoxForNumberedListsAndDropsTrailingCaret() {
        let sourceBox = CGRect(x: 0.03, y: 0.20, width: 0.72, height: 0.06)
        let preciseContentBox = CGRect(x: 0.058, y: 0.20, width: 0.69, height: 0.06)
        let source = RecognizedTextBlock(
            text: "11） USB drives activate only in SE. |",
            confidence: 0.99,
            boundingBox: sourceBox,
            translatableBoundingBox: preciseContentBox
        )

        let content = ScreenshotTranslationContentPolicy.translatableContent(
            from: source,
            imageSize: CGSize(width: 1_214, height: 323)
        )

        #expect(content?.boundingBox == preciseContentBox)
        #expect(ScreenshotTranslationContentPolicy.textForTranslation(content?.text ?? "")
            == "USB drives activate only in SE.")
        let erasableRange = ScreenshotTranslationContentPolicy.erasableContentRange(in: source.text)
        #expect(erasableRange.map { String(source.text[$0]) }
            == "USB drives activate only in SE. |")
    }

    @Test func mixedLanguageSingleLineIsNotMiscounted() {
        let rect = CGRect(x: 0, y: 0, width: 1_050, height: 24)
        let text = "由于性能与维护问题，Jesse 建议将 ERP 订单匹配从实时页面查询改为承运商预匹配。"

        #expect(ScreenshotTranslationTextLayout.wrappedLineCount(
            for: text,
            in: rect,
            fontSize: 17
        ) == 1)
    }

    @Test func protectsGreetingNameAndDomainAcrossTranslation() {
        let greeting = ScreenshotTranslationContentPolicy.protectedText("Hi Rowan Deng,")
        let body = ScreenshotTranslationContentPolicy.protectedText(
            "Three capabilities have shipped in ONES.com."
        )

        #expect(!greeting.text.contains("Rowan Deng"))
        #expect(greeting.restoring(in: "你好，HXKEEP000TOKEN！") == "你好，Rowan Deng！")
        #expect(!body.text.contains("ONES.com"))
        #expect(body.restoring(in: "三个功能已在 H X K E E P 0 0 0 T O K E N 中上线。")
            == "三个功能已在 ONES.com 中上线。")
    }

    @Test func combinesScreenshotParagraphsIntoOneCloudRequest() throws {
        let firstID = UUID()
        let secondID = UUID()
        let batches = try ScreenshotTranslationBatchCodec.batches(for: [
            (firstID, "Hi Rowan Deng,"),
            (secondID, "Capabilities shipped in ONES.com.")
        ])

        #expect(batches.count == 1)
        #expect(batches[0].text.contains("[[[97531000]]]"))
        #expect(!batches[0].text.contains("Rowan Deng"))
        #expect(!batches[0].text.contains("ONES.com"))

        let translated = "你好，HXKEEP000TOKEN！\n［ 9 7 5 3 1 0 0 0 ］\n功能已在 HXKEEP000TOKEN 上线。"
        let translations = try ScreenshotTranslationBatchCodec.translations(
            from: translated,
            for: batches[0]
        )
        #expect(translations[firstID] == "你好，Rowan Deng！")
        #expect(translations[secondID] == "功能已在 ONES.com 上线。")
    }

    @Test func splitsLongScreenshotIntoLengthBoundedCloudRequests() throws {
        let paragraphs = (0..<4).map { _ in
            (id: UUID(), text: String(repeating: "word", count: 10))
        }
        let batches = try ScreenshotTranslationBatchCodec.batches(
            for: paragraphs,
            maximumCharacterCount: 100
        )

        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.text.count <= 100 })
        #expect(batches.flatMap(\.paragraphs).map(\.id) == paragraphs.map(\.id))
    }

    @Test func rejectsCloudBatchResponseWithoutParagraphBoundaries() throws {
        let batches = try ScreenshotTranslationBatchCodec.batches(for: [
            (UUID(), "First paragraph"),
            (UUID(), "Second paragraph")
        ])

        #expect(throws: HelloXError.invalidResponse) {
            try ScreenshotTranslationBatchCodec.translations(
                from: "第一段 第二段",
                for: batches[0]
            )
        }
    }

    @Test func paragraphComposerUsesOneFinalFontSizeAndColor() {
        let paragraphID = UUID()
        let source = [
            block("Since your last look, three capabilities have shipped in ONES.com.", x: 0.091, y: 0.420, width: 0.821, height: 0.0556),
            block("Approval now works in both places project work happens: Wiki", x: 0.091, y: 0.346, width: 0.775, height: 0.0494),
            block("pages and work items. Baseline Management also helps capture a", x: 0.091, y: 0.265, width: 0.814, height: 0.0494),
            block("fixed record of what was agreed.", x: 0.091, y: 0.179, width: 0.407, height: 0.0494)
        ]
        let paragraph = RecognizedTextParagraph(
            id: paragraphID,
            text: source.map(\.text).joined(separator: "\n"),
            boundingBox: source.map(\.boundingBox).dropFirst().reduce(source[0].boundingBox) { $0.union($1) },
            blocks: source
        )
        let sampledSizes: [CGFloat] = [17.94, 15.95, 15.95, 15.95]
        let appearances = Dictionary(uniqueKeysWithValues: source.indices.map { index in
            let block = source[index]
            let size = sampledSizes[index]
            return (block.id, ScreenshotTranslationAppearance(
                fontSize: size,
                foregroundColor: RGBAColor(red: 0.08 + size / 1_000, green: 0.20, blue: 0.35),
                backgroundColor: RGBAColor(
                    red: 0.90 + CGFloat(index) * 0.01,
                    green: 0.95,
                    blue: 0.99
                )
            ))
        })
        let translations = [
            paragraphID: "自上次查看以来，ONES.com 中已经上线三项功能。审批功能现已同时适用于 Wiki 页面和工作项这两个项目工作场景。基线管理也有助于捕获约定内容的固定记录。"
        ]

        let composed = ScreenshotTranslationComposer.blocks(
            paragraphs: [paragraph],
            translations: translations,
            appearances: appearances,
            imageSize: CGSize(width: 614, height: 323)
        )

        #expect(composed.count == 1)
        #expect(composed[0].translatedText == translations[paragraphID])
        #expect(!composed[0].translatedText.contains("\n"))
        #expect(composed[0].backgroundBoxes == source.map(\.boundingBox))
        #expect(composed[0].backgroundRegions.map(\.boundingBox) == source.map(\.boundingBox))
        #expect(composed[0].backgroundRegions.map(\.backgroundColor) == source.map {
            appearances[$0.id]?.backgroundColor ?? .white
        })
        #expect(composed[0].sourceLineCount == 4)
        #expect(composed[0].boundingBox.minY < paragraph.boundingBox.minY)
        let pixelRect = CGRect(
            x: composed[0].boundingBox.minX * 614,
            y: (1 - composed[0].boundingBox.maxY) * 323,
            width: composed[0].boundingBox.width * 614,
            height: composed[0].boundingBox.height * 323
        ).integral
        #expect(ScreenshotTranslationTextLayout.fitsCompletely(
            composed[0].translatedText,
            in: pixelRect,
            fontSize: composed[0].appearance.fontSize,
            maximumLineCount: composed[0].sourceLineCount
        ))
        #expect(ScreenshotTranslationTextLayout.wrappedLineCount(
            for: composed[0].translatedText,
            in: pixelRect,
            fontSize: composed[0].appearance.fontSize
        ) <= 4)
    }

    @Test func composerNormalizesSameStyleAcrossSeparateParagraphs() {
        let greetingBlock = block(
            "Hi Rowan Deng,",
            x: 0.091,
            y: 0.576,
            width: 0.241,
            height: 0.0556
        )
        let bodyBlocks = [
            block("Since your last look, three capabilities have shipped in ONES.com.", x: 0.091, y: 0.420, width: 0.821, height: 0.0556),
            block("Approval now works in both places project work happens: Wiki", x: 0.091, y: 0.346, width: 0.775, height: 0.0494),
            block("pages and work items. Baseline Management also helps capture a", x: 0.091, y: 0.265, width: 0.814, height: 0.0494),
            block("fixed record of what was agreed.", x: 0.091, y: 0.179, width: 0.407, height: 0.0494)
        ]
        let greeting = RecognizedTextParagraph(
            id: UUID(),
            text: greetingBlock.text,
            boundingBox: greetingBlock.boundingBox,
            blocks: [greetingBlock]
        )
        let body = RecognizedTextParagraph(
            id: UUID(),
            text: bodyBlocks.map(\.text).joined(separator: "\n"),
            boundingBox: bodyBlocks.dropFirst().reduce(bodyBlocks[0].boundingBox) { $0.union($1.boundingBox) },
            blocks: bodyBlocks
        )
        let allBlocks = [greetingBlock] + bodyBlocks
        let sampledSizes: [CGFloat] = [17.94, 17.94, 15.95, 15.95, 15.95]
        let appearances = Dictionary(uniqueKeysWithValues: zip(allBlocks, sampledSizes).map {
            ($0.0.id, ScreenshotTranslationAppearance(
                fontSize: $0.1,
                foregroundColor: RGBAColor(red: 0.08, green: 0.20, blue: 0.35),
                backgroundColor: .white
            ))
        })

        let composed = ScreenshotTranslationComposer.blocks(
            paragraphs: [greeting, body],
            translations: [
                greeting.id: "你好，Rowan Deng，",
                body.id: "ONES.com 已上线三项功能。\n审批与基线管理均可直接使用。"
            ],
            appearances: appearances,
            imageSize: CGSize(width: 614, height: 323)
        )

        #expect(composed.count == 2)
        let greetingSize = composed.first { $0.id == greeting.id }?.appearance.fontSize
        let bodyBlock = composed.first { $0.id == body.id }
        let bodySize = bodyBlock?.appearance.fontSize
        #expect(greetingSize != nil)
        #expect(bodySize != nil)
        #expect(abs((greetingSize ?? 0) - (bodySize ?? 1)) < 0.001)
        #expect(bodyBlock?.translatedText == "ONES.com 已上线三项功能。审批与基线管理均可直接使用。")
        #expect(bodyBlock?.backgroundBoxes.count == 4)
    }

    @Test func composerNormalizesAShortInkBoxAcrossDenseTableHeaders() {
        let labels = ["Channel", "Platform", "Status", "Created Time", "Actions"]
        let widths: [CGFloat] = [0.08, 0.08, 0.07, 0.10, 0.08]
        let heights: [CGFloat] = [0.013, 0.013, 0.013, 0.0085, 0.013]
        var x: CGFloat = 0.10
        let blocks = labels.indices.map { index -> RecognizedTextBlock in
            defer { x += widths[index] + 0.05 }
            return block(
                labels[index],
                x: x,
                y: 0.82,
                width: widths[index],
                height: heights[index]
            )
        }
        let paragraphs = blocks.map {
            RecognizedTextParagraph(id: $0.id, text: $0.text, boundingBox: $0.boundingBox, blocks: [$0])
        }
        let appearances = Dictionary(uniqueKeysWithValues: blocks.indices.map { index in
            (
                blocks[index].id,
                ScreenshotTranslationAppearance(
                    fontSize: heights[index] * 958,
                    foregroundColor: RGBAColor(red: 0.27, green: 0.33, blue: 0.41),
                    backgroundColor: RGBAColor(red: 0.97, green: 0.98, blue: 0.99)
                )
            )
        })
        let translations = Dictionary(uniqueKeysWithValues: paragraphs.map { ($0.id, "列") })

        let composed = ScreenshotTranslationComposer.blocks(
            paragraphs: paragraphs,
            translations: translations,
            appearances: appearances,
            imageSize: CGSize(width: 1_920, height: 958)
        )
        let sizes = composed.map(\.appearance.fontSize)

        #expect(sizes.count == labels.count)
        #expect((sizes.max() ?? 0) - (sizes.min() ?? 0) < 0.01)
        #expect(sizes.allSatisfy { $0 > 9 })
    }

    @Test func denseRowNormalizationDoesNotShrinkAnIntentionalLargeLabel() {
        let sizes: [CGFloat] = [24, 12, 12, 12]
        let blocks = sizes.indices.map { index in
            block(
                "Label \(index)",
                x: 0.08 + CGFloat(index) * 0.20,
                y: 0.70,
                width: 0.12,
                height: sizes[index] / 958
            )
        }
        let paragraphs = blocks.map {
            RecognizedTextParagraph(id: $0.id, text: $0.text, boundingBox: $0.boundingBox, blocks: [$0])
        }
        let appearances = Dictionary(uniqueKeysWithValues: blocks.indices.map { index in
            (blocks[index].id, ScreenshotTranslationAppearance(
                fontSize: sizes[index],
                foregroundColor: RGBAColor(red: 0.27, green: 0.33, blue: 0.41),
                backgroundColor: .white
            ))
        })
        let translations = Dictionary(uniqueKeysWithValues: paragraphs.map { ($0.id, "标签") })

        let composed = ScreenshotTranslationComposer.blocks(
            paragraphs: paragraphs,
            translations: translations,
            appearances: appearances,
            imageSize: CGSize(width: 1_920, height: 958)
        )
        let resolved = Dictionary(uniqueKeysWithValues: composed.map { ($0.id, $0.appearance.fontSize) })

        #expect((resolved[paragraphs[0].id] ?? 0) > 20)
        for paragraph in paragraphs.dropFirst() {
            #expect((resolved[paragraph.id] ?? 0) < 14)
        }
    }

    @Test func reconstructedBackgroundRemovesAllSourcePixelsAndPreservesProtectedIcon() throws {
        let width = 96
        let height = 48
        let source = makeImage(width: width, height: height) { x, y in
            if (8..<15).contains(x), (34..<42).contains(y) {
                return (20, 90, 240, 255) // protected icon outside the OCR box
            }
            if (34..<71).contains(x), (4..<16).contains(y) {
                return (0, 0, 0, 255) // simulated source glyph ink
            }
            let value = UInt8(90 + x)
            return (value, UInt8(150 + x / 2), 205, 255)
        }
        let box = CGRect(
            x: 32.0 / CGFloat(width),
            y: 1 - 18.0 / CGFloat(height),
            width: 41.0 / CGFloat(width),
            height: 16.0 / CGFloat(height)
        )

        let result = try ScreenshotTranslationBackgroundReconstructor.eraseText(
            in: source,
            normalizedBoxes: [box]
        )
        let sourcePixels = rgbaPixels(source)
        let outputPixels = rgbaPixels(result)

        #expect(pixel(sourcePixels, x: 40, y: 10, width: width) == (0, 0, 0, 255))
        #expect(pixel(outputPixels, x: 10, y: 37, width: width)
            == pixel(sourcePixels, x: 10, y: 37, width: width))
        #expect(pixel(outputPixels, x: 20, y: 10, width: width)
            == pixel(sourcePixels, x: 20, y: 10, width: width))

        var remainingInk = 0
        var reconstructedColors = Set<UInt32>()
        for y in 4..<16 {
            for x in 34..<71 {
                let value = pixel(outputPixels, x: x, y: y, width: width)
                if value.0 < 20, value.1 < 20, value.2 < 20 { remainingInk += 1 }
                reconstructedColors.insert(
                    UInt32(value.0) << 16 | UInt32(value.1) << 8 | UInt32(value.2)
                )
            }
        }
        #expect(remainingInk == 0)
        #expect(reconstructedColors.count > 8)
    }

    @Test func closelyStackedTextRegionsDoNotBleedIntoReconstructedBackground() throws {
        let width = 180
        let height = 72
        let source = makeImage(width: width, height: height) { x, y in
            let isFirstLine = (32..<160).contains(x) && (18..<30).contains(y)
            let isSecondLine = (32..<150).contains(x) && (34..<46).contains(y)
            return isFirstLine || isSecondLine
                ? (20, 80, 40, 255)
                : (210, 238, 220, 255)
        }
        let boxes = [
            CGRect(x: 30.0 / 180, y: 1 - 32.0 / 72, width: 132.0 / 180, height: 16.0 / 72),
            CGRect(x: 30.0 / 180, y: 1 - 48.0 / 72, width: 122.0 / 180, height: 16.0 / 72)
        ]

        let result = try ScreenshotTranslationBackgroundReconstructor.eraseText(
            in: source,
            normalizedBoxes: boxes
        )
        let output = rgbaPixels(result)
        for y in 18..<46 {
            for x in 32..<150 {
                let value = pixel(output, x: x, y: y, width: width)
                #expect(value.0 > 180 && value.1 > 210 && value.2 > 190)
            }
        }
    }

    @Test func reconstructsColoredControlFillInsteadOfPageBackground() throws {
        let width = 160
        let height = 50
        let green: (UInt8, UInt8, UInt8, UInt8) = (0, 166, 61, 255)
        let source = makeImage(width: width, height: height) { x, y in
            if (20..<125).contains(x), (6..<30).contains(y) {
                if (45..<113).contains(x), (11..<24).contains(y) {
                    return (255, 255, 255, 255) // simulated white badge text
                }
                return green
            }
            return (255, 255, 255, 255)
        }
        let box = CGRect(
            x: 42.0 / CGFloat(width),
            y: 1 - 25.0 / CGFloat(height),
            width: 73.0 / CGFloat(width),
            height: 16.0 / CGFloat(height)
        )

        let result = try ScreenshotTranslationBackgroundReconstructor.eraseText(
            in: source,
            normalizedBoxes: [box]
        )
        let output = rgbaPixels(result)

        #expect(pixel(output, x: 75, y: 17, width: width) == green)
        #expect(pixel(output, x: 10, y: 17, width: width) == (255, 255, 255, 255))
        #expect(pixel(output, x: 25, y: 17, width: width) == green)
    }

    @Test func backgroundHintStabilizesANearlyFullColoredPillAcrossBoxJitter() throws {
        let width = 160
        let height = 50
        let greenBytes: (UInt8, UInt8, UInt8, UInt8) = (0, 166, 61, 255)
        let green = RGBAColor(red: 0, green: 166.0 / 255, blue: 61.0 / 255)
        let source = makeImage(width: width, height: height) { x, y in
            let centerY: Int
            if y < 12 { centerY = 12 }
            else if y > 23 { centerY = 23 }
            else { centerY = y }
            let centerX: Int
            if x < 26 { centerX = 26 }
            else if x > 118 { centerX = 118 }
            else { centerX = x }
            let dx = x - centerX
            let dy = y - centerY
            let insidePill = (20..<125).contains(x)
                && (6..<30).contains(y)
                && dx * dx + dy * dy <= 36
            if insidePill {
                if (35..<116).contains(x), (10..<25).contains(y) {
                    return (255, 255, 255, 255)
                }
                return greenBytes
            }
            return (255, 255, 255, 255)
        }

        for (top, boxHeight) in [(8, 16), (9, 17), (10, 18)] {
            let box = CGRect(
                x: 33.0 / CGFloat(width),
                y: 1 - CGFloat(top + boxHeight) / CGFloat(height),
                width: 84.0 / CGFloat(width),
                height: CGFloat(boxHeight) / CGFloat(height)
            )
            let result = try ScreenshotTranslationBackgroundReconstructor.eraseText(
                in: source,
                normalizedRegions: [ScreenshotTranslationBackgroundRegion(
                    boundingBox: box,
                    backgroundColor: green
                )]
            )
            let output = rgbaPixels(result)
            var restoredGreen = 0
            var checked = 0
            for y in max(10, top)..<min(25, top + boxHeight) {
                for x in 35..<116 {
                    checked += 1
                    if pixel(output, x: x, y: y, width: width) == greenBytes {
                        restoredGreen += 1
                    }
                }
            }
            #expect(restoredGreen * 100 >= checked * 98)
            #expect(pixel(output, x: 10, y: 17, width: width) == (255, 255, 255, 255))
            #expect(pixel(output, x: 22, y: 7, width: width) == (255, 255, 255, 255))
        }
    }

    @Test func backgroundHintPreservesGradientReconstruction() throws {
        let width = 120
        let height = 60
        let source = makeImage(width: width, height: height) { x, y in
            if (20..<100).contains(x), (10..<50).contains(y) {
                if (22..<90).contains(x), (14..<39).contains(y) {
                    return (255, 255, 255, 255) // simulated white label ink
                }
                return (0, UInt8(120 + y), 60, 255)
            }
            return (255, 255, 255, 255)
        }
        let box = CGRect(
            x: 22.0 / CGFloat(width),
            y: 1 - 39.0 / CGFloat(height),
            width: 68.0 / CGFloat(width),
            height: 25.0 / CGFloat(height)
        )
        let hint = RGBAColor(red: 0, green: 148.0 / 255, blue: 60.0 / 255)

        let result = try ScreenshotTranslationBackgroundReconstructor.eraseText(
            in: source,
            normalizedRegions: [ScreenshotTranslationBackgroundRegion(
                boundingBox: box,
                backgroundColor: hint
            )]
        )
        let output = rgbaPixels(result)
        var reconstructedGreens = Set<UInt8>()
        for y in 14..<39 {
            for x in 26..<86 {
                let value = pixel(output, x: x, y: y, width: width)
                #expect(value.0 == 0)
                #expect(value.2 == 60)
                reconstructedGreens.insert(value.1)
            }
        }

        #expect(reconstructedGreens.count > 8)
        #expect(pixel(output, x: 10, y: 25, width: width) == (255, 255, 255, 255))
    }

    @Test func mergesCrossScaleOCRAlternativesForTheSameVisualLine() {
        let oversizedReset = block(
            "c Rosel",
            confidence: 0.5,
            x: 0.450,
            y: 0.883,
            width: 0.029,
            height: 0.042
        )
        let reset = block(
            "& Reset",
            confidence: 0.5,
            x: 0.451,
            y: 0.900,
            width: 0.029,
            height: 0.013
        )
        let shortDate = block(
            "9076-08-1618:4:54",
            confidence: 1,
            x: 0.782,
            y: 0.808,
            width: 0.065,
            height: 0.0063
        )
        let date = block(
            "2026-08-10 18:14:54",
            confidence: 1,
            x: 0.784,
            y: 0.804,
            width: 0.066,
            height: 0.0125
        )

        let resetResult = VisionOCRService.merge([oversizedReset], with: [reset])
        let reversedResetResult = VisionOCRService.merge([reset], with: [oversizedReset])
        let dateResult = VisionOCRService.merge([shortDate], with: [date])
        let reversedDateResult = VisionOCRService.merge([date], with: [shortDate])

        #expect(resetResult.map(\.text) == ["& Reset"])
        #expect(reversedResetResult.map(\.text) == ["& Reset"])
        #expect(dateResult.map(\.text) == ["2026-08-10 18:14:54"])
        #expect(reversedDateResult.map(\.text) == ["2026-08-10 18:14:54"])
    }

    @Test func ordinaryScaleOCRDuplicatesKeepThePrimaryGeometry() {
        let primary = block(
            "Settings",
            confidence: 0.9,
            x: 0.20,
            y: 0.80,
            width: 0.08,
            height: 0.014
        )
        let slightlyShorter = block(
            "Settings",
            confidence: 0.9,
            x: 0.20,
            y: 0.801,
            width: 0.08,
            height: 0.013
        )

        let result = VisionOCRService.merge([primary], with: [slightlyShorter])

        #expect(result.count == 1)
        #expect(result[0].boundingBox == primary.boundingBox)
    }

    @Test func selectionLocksOnlyAfterCompleteTranslationResultExists() {
        #expect(!ScreenshotTranslationInteractionPolicy.locksSelection(
            hasTranslationBlocks: false,
            hasReconstructedBackground: false
        ))
        #expect(!ScreenshotTranslationInteractionPolicy.locksSelection(
            hasTranslationBlocks: true,
            hasReconstructedBackground: false
        ))
        #expect(ScreenshotTranslationInteractionPolicy.locksSelection(
            hasTranslationBlocks: true,
            hasReconstructedBackground: true
        ))
    }

    @MainActor
    @Test func translatedRendererDoesNotPaintBackgroundRectangles() throws {
        let source = makeImage(width: 48, height: 24) { _, _ in (40, 80, 120, 255) }
        let block = ScreenshotTranslationBlock(
            id: UUID(),
            sourceText: "source",
            translatedText: "",
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            appearance: ScreenshotTranslationAppearance(
                fontSize: 12,
                foregroundColor: .black,
                backgroundColor: .white
            )
        )
        let result = try AnnotationRenderer.render(
            baseImage: source,
            annotations: [],
            screenshotTranslationBlocks: [block]
        )
        #expect(rgbaPixels(result) == rgbaPixels(source))
    }

    @MainActor
    @Test func exportedTranslationUsesTheSameReconstructedBaseImage() throws {
        let source = makeImage(width: 80, height: 40) { _, _ in (180, 30, 30, 255) }
        let reconstructed = makeImage(width: 40, height: 20) { x, _ in
            (UInt8(40 + x), 170, 110, 255)
        }
        let result = try AnnotationRenderer.renderOutput(
            baseImage: source,
            annotations: [],
            normalizedCrop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            replacementBaseImage: reconstructed
        )

        #expect(result.width == reconstructed.width)
        #expect(result.height == reconstructed.height)
        #expect(rgbaPixels(result) == rgbaPixels(reconstructed))
    }

    private func block(
        _ text: String,
        confidence: Float = 0.99,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> RecognizedTextBlock {
        RecognizedTextBlock(
            text: text,
            confidence: confidence,
            boundingBox: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixelValue: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixelValue(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = value.0
                bytes[offset + 1] = value.1
                bytes[offset + 2] = value.2
                bytes[offset + 3] = value.3
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8] {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func pixel(
        _ pixels: [UInt8],
        x: Int,
        y: Int,
        width: Int
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }
}
