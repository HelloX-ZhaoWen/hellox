import CoreGraphics
import Testing
@testable import HelloXCore

struct OCRParagraphLayoutTests {
    @Test func isolatedTableHeaderCellsNeverMerge() {
        let cells = [
            block("Product\nImage", x: 0.12, y: 0.22, width: 0.07, height: 0.49, isolated: true),
            block("Product\nId", x: 0.20, y: 0.24, width: 0.06, height: 0.47, isolated: true),
            block("Private\nReference", x: 0.72, y: 0.21, width: 0.07, height: 0.50, isolated: true),
            block("Created At", x: 0.79, y: 0.33, width: 0.08, height: 0.28, isolated: true)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: cells)

        #expect(paragraphs.count == 4)
        #expect(paragraphs.allSatisfy { $0.blocks.count == 1 })
    }

    @Test func columnReconstructionDoesNotMergeHeaderWithDataRow() {
        let channel = block("Channel", x: 0.04, y: 0.69, width: 0.055, height: 0.12)
        let support = block("Support", x: 0.04, y: 0.13, width: 0.055, height: 0.12)
        let status = block("Status", x: 0.15, y: 0.69, width: 0.050, height: 0.12)
        let closed = block("Closed", x: 0.15, y: 0.13, width: 0.052, height: 0.12)
        let lastMessage = block("Last Message", x: 0.70, y: 0.70, width: 0.105, height: 0.11)
        let time = block("Time", x: 0.73, y: 0.53, width: 0.040, height: 0.11)
        let timestamp = block("2026-09-03 09:23:40", x: 0.70, y: 0.11, width: 0.145, height: 0.11)

        let reconstructed = VisionOCRService.reconstructColumnCells(
            from: [channel, support, status, closed, lastMessage, time, timestamp]
        )

        #expect(reconstructed.count == 6)
        #expect(reconstructed.contains { $0.text == "Last Message\nTime" })
        #expect(reconstructed.contains { $0.text == "Channel" })
        #expect(reconstructed.contains { $0.text == "Support" })
        #expect(reconstructed.contains { $0.text == "Status" })
        #expect(reconstructed.contains { $0.text == "Closed" })
        #expect(reconstructed.contains { $0.text == "2026-09-03 09:23:40" })
    }

    @Test func columnReconstructionKeepsStepTitlesAndSupportingCopySeparate() {
        let finished = block(
            "Finished",
            x: 0.04,
            y: 0.39,
            width: 0.05,
            height: 0.04,
            isolated: true
        )
        let finishedCopy = block(
            "This is a content.",
            x: 0.04,
            y: 0.32,
            width: 0.08,
            height: 0.034
        )
        let waiting = block("Waiting", x: 0.88, y: 0.18, width: 0.04, height: 0.048)
        let waitingCopy = block(
            "This is a content.",
            x: 0.88,
            y: 0.13,
            width: 0.08,
            height: 0.034
        )

        let reconstructed = VisionOCRService.reconstructColumnCells(
            from: [finished, finishedCopy, waiting, waitingCopy]
        )

        #expect(reconstructed.count == 4)
        #expect(reconstructed.allSatisfy { !$0.text.contains("\n") })
    }

    @Test func prefersUpscaledStructuredHeaderOverMergedLowResolutionOCR() {
        let primary = [
            block("Action/History Product Product Tags Buffer Location", x: 0.01, y: 0.16, width: 0.57, height: 0.60)
        ]
        let structured = [
            block("Action/History", x: 0.01, y: 0.30, width: 0.10, height: 0.28),
            block("Product", x: 0.13, y: 0.44, width: 0.06, height: 0.27),
            block("Image", x: 0.14, y: 0.22, width: 0.05, height: 0.24),
            block("Tags", x: 0.26, y: 0.25, width: 0.04, height: 0.42),
            block("Buffer", x: 0.31, y: 0.36, width: 0.05, height: 0.43)
        ]

        #expect(VisionOCRService.shouldPreferStructuredPass(structured, over: primary))
    }

    @Test func usesColumnReconstructionOnlyForOneVisualBand() {
        let tableHeader = [
            block(
                "Action History Product Image Product Id Tags",
                x: 0.01,
                y: 0.22,
                width: 0.82,
                height: 0.48
            )
        ]
        let stackedControls = [
            block("Search is limited to recent orders", x: 0.02, y: 0.76, width: 0.91, height: 0.10),
            block("With notes INF Orders Dists Orders", x: 0.02, y: 0.50, width: 0.82, height: 0.14),
            block("Create order Merge orders Update address", x: 0.02, y: 0.10, width: 0.84, height: 0.16)
        ]

        #expect(VisionOCRService.shouldUseColumnStructuredPass(tableHeader))
        #expect(!VisionOCRService.shouldUseColumnStructuredPass(stackedControls))
    }

    @Test func keepsDenseNavigationRowAsIndependentControls() {
        let blocks = [
            block("General", x: 0.0205, y: 0.4054, width: 0.0410, height: 0.1622),
            block("My Item", x: 0.0744, y: 0.3756, width: 0.0448, height: 0.1947),
            block("Description", x: 0.1321, y: 0.3729, width: 0.0635, height: 0.2001),
            block("Draft Text", x: 0.2067, y: 0.4054, width: 0.0559, height: 0.1622),
            block("Inventory", x: 0.3073, y: 0.3784, width: 0.0484, height: 0.1622),
            block("Category", x: 0.3631, y: 0.3784, width: 0.0540, height: 0.1892),
            block("Price & DT", x: 0.4283, y: 0.4054, width: 0.0615, height: 0.1622),
            block("Shipping", x: 0.4915, y: 0.3729, width: 0.0598, height: 0.2001),
            block("Competitor", x: 0.5624, y: 0.4054, width: 0.0615, height: 0.1622),
            block("Details", x: 0.6331, y: 0.4016, width: 0.0411, height: 0.1698),
            block("CE checkList", x: 0.6834, y: 0.4054, width: 0.0875, height: 0.1622),
            block("MIds", x: 0.7858, y: 0.4054, width: 0.0317, height: 0.1622),
            block("Reviews", x: 0.8287, y: 0.4054, width: 0.0466, height: 0.1351)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 13)
        #expect(paragraphs.allSatisfy { $0.blocks.count == 1 })
    }

    @Test func keepsRepeatedCardGridLabelsInTheirOwnCells() {
        let blocks = [
            block("Forbid Active", x: 0.0353, y: 0.2381, width: 0.0572, height: 0.0952),
            block("Forbid Active", x: 0.1396, y: 0.2222, width: 0.0576, height: 0.1111),
            block("Forbid Active", x: 0.2321, y: 0.2052, width: 0.0681, height: 0.1293),
            block("Forbid Active", x: 0.3460, y: 0.2381, width: 0.0572, height: 0.0952),
            block("Forbid Active", x: 0.4485, y: 0.2040, width: 0.0577, height: 0.1309),
            block("Forbid Active", x: 0.5410, y: 0.2053, width: 0.0699, height: 0.1291),
            block("Forbid Active", x: 0.6440, y: 0.2063, width: 0.0698, height: 0.1270),
            block("Forbid Active", x: 0.7591, y: 0.2043, width: 0.0577, height: 0.1305),
            block("Forbid Active", x: 0.8626, y: 0.2381, width: 0.0589, height: 0.0952)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 9)
        #expect(paragraphs.allSatisfy { $0.blocks.count == 1 })
    }

    @Test func joinsWrappedBodyLines() {
        let blocks = [
            block("A paragraph that wraps naturally", x: 0.10, y: 0.82, width: 0.66),
            block("across several visual lines without", x: 0.10, y: 0.77, width: 0.64),
            block("starting a new paragraph.", x: 0.10, y: 0.72, width: 0.42)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].blocks.count == 3)
    }

    @Test func splitsParagraphsUsingDocumentLineSpacing() {
        let blocks = [
            block("The first paragraph has a wrapped", x: 0.10, y: 0.84, width: 0.66),
            block("second line.", x: 0.10, y: 0.79, width: 0.28),
            block("The next paragraph starts here and", x: 0.10, y: 0.71, width: 0.65),
            block("continues on this line.", x: 0.10, y: 0.66, width: 0.42)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.map(\.blocks.count) == [2, 2])
    }

    @Test func keepsTwoColumnsIndependent() {
        let blocks = [
            block("Left column first line", x: 0.06, y: 0.82, width: 0.36),
            block("Right column first line", x: 0.56, y: 0.82, width: 0.36),
            block("left column continues", x: 0.06, y: 0.77, width: 0.34),
            block("right column continues", x: 0.56, y: 0.77, width: 0.35)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.allSatisfy { $0.blocks.count == 2 })
        #expect(paragraphs[0].blocks.allSatisfy { $0.boundingBox.minX < 0.5 })
        #expect(paragraphs[1].blocks.allSatisfy { $0.boundingBox.minX > 0.5 })
    }

    @Test func separatesHeadingFromBody() {
        let blocks = [
            block("SCREENSHOT TRANSLATION", x: 0.10, y: 0.84, width: 0.46, height: 0.052),
            block("The body copy begins below the heading", x: 0.10, y: 0.77, width: 0.67),
            block("and remains one continuous paragraph.", x: 0.10, y: 0.72, width: 0.61)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.map(\.blocks.count) == [1, 2])
    }

    @Test func separatesCompactStepTitleFromSupportingSentence() {
        let blocks = [
            block("Finished", x: 0.0465, y: 0.8085, width: 0.0480, height: 0.0403),
            block("This is a content.", x: 0.0480, y: 0.7346, width: 0.0799, height: 0.0363),
            block("く Finished", x: 0.0218, y: 0.3876, width: 0.0610, height: 0.0397),
            block("This is a content.", x: 0.0422, y: 0.3258, width: 0.0814, height: 0.0345)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 4)
        #expect(paragraphs.allSatisfy { $0.blocks.count == 1 })
    }

    @Test func preservesInlineFragmentsButNotColumnGaps() {
        let blocks = [
            block("API", x: 0.10, y: 0.82, width: 0.06),
            block("emphasis", x: 0.215, y: 0.82, width: 0.13),
            block("continues on the next visual line", x: 0.10, y: 0.77, width: 0.55)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].blocks.count == 3)
    }

    @Test func keepsPageTitleSeparateFromSameRowBreadcrumb() {
        let blocks = [
            block("Channel", x: 0.127, y: 0.960, width: 0.0375, height: 0.0190),
            block("Settings > Channel", x: 0.180, y: 0.962, width: 0.0707, height: 0.0146)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.allSatisfy { $0.blocks.count == 1 })
    }

    @Test func keepsTightlySpacedComparisonFragmentsInline() {
        let blocks = [
            block("Condition:", x: 0.10, y: 0.82, width: 0.10),
            block("x > 0", x: 0.207, y: 0.82, width: 0.07)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].blocks.count == 2)
    }

    @Test func fullWidthHeadingDoesNotBridgeColumns() {
        let blocks = [
            block("DOCUMENT OVERVIEW", x: 0.08, y: 0.88, width: 0.78, height: 0.052),
            block("Left column begins", x: 0.08, y: 0.80, width: 0.34),
            block("Right column begins", x: 0.56, y: 0.80, width: 0.34),
            block("left column continues", x: 0.08, y: 0.75, width: 0.35),
            block("right column continues", x: 0.56, y: 0.75, width: 0.35)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 3)
        #expect(paragraphs.map(\.blocks.count).sorted() == [1, 2, 2])
    }

    @Test func joinsWrappedChineseAndSplitsNextParagraph() {
        let blocks = [
            block("截图翻译会先在本地识别连续文字", x: 0.10, y: 0.84, width: 0.66),
            block("再把完整段落发送到翻译服务。", x: 0.10, y: 0.79, width: 0.54),
            block("下一段从这里开始", x: 0.10, y: 0.71, width: 0.38),
            block("并保持原来的视觉排版。", x: 0.10, y: 0.66, width: 0.48)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 2)
        #expect(paragraphs.map(\.blocks.count) == [2, 2])
    }

    @Test func wikiScreenshotSeparatesTitleBodyListAndLink() {
        let blocks = [
            block("Page Approval", x: 0.0544, y: 0.8889, width: 0.2109, height: 0.0432),
            block("For teams that manage project documents, process guides, or", x: 0.0500, y: 0.7955, width: 0.8125, height: 0.0606),
            block("deliverables in ONES Wiki, Page Approval keeps formal review close", x: 0.0544, y: 0.7160, width: 0.8741, height: 0.0556),
            block("to the content itself.", x: 0.0544, y: 0.6420, width: 0.2721, height: 0.0494),
            block("Instead of tracking approvals through separate messages or offline", x: 0.0500, y: 0.5606, width: 0.8750, height: 0.0536),
            block("steps, teams can review the page directly and see:", x: 0.0544, y: 0.4753, width: 0.6599, height: 0.0494),
            block("• what was submitted", x: 0.1156, y: 0.3580, width: 0.2925, height: 0.0432),
            block("• who reviewed it", x: 0.1156, y: 0.2778, width: 0.2415, height: 0.0370),
            block("• whether the page was approved, rejected, or still in progress", x: 0.1156, y: 0.1852, width: 0.8231, height: 0.0556),
            block("Click to view more feature details", x: 0.0544, y: 0.0679, width: 0.4354, height: 0.0432)
        ]

        let paragraphs = OCRParagraphLayout.paragraphs(from: blocks)

        #expect(paragraphs.count == 7)
        #expect(paragraphs.map(\.blocks.count) == [1, 3, 2, 1, 1, 1, 1])
        #expect(OCRParagraphLayout.semanticText(paragraphs[1].text).contains("or deliverables"))
    }

    private func block(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 0.035,
        isolated: Bool? = nil
    ) -> RecognizedTextBlock {
        RecognizedTextBlock(
            text: text,
            confidence: 0.99,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            isLayoutIsolated: isolated
        )
    }
}
