@preconcurrency import Vision
import CoreGraphics
import CoreImage
import Foundation
import NaturalLanguage

public protocol TextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> OCRResult
}

public struct VisionOCRService: TextRecognizing, Sendable {
    public init() {}

    public func recognizeText(in image: CGImage) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            let primary = try Self.recognizePass(in: image)
            var blocks = primary

            if Self.needsEnhancement(primary)
                || (Self.isShallowInterfaceImage(image)
                    && Self.hasSuspiciousMergedObservation(primary)) {
                var preferredStructuredPass = false
                if Self.isShallowInterfaceImage(image),
                   Self.shouldUseColumnStructuredPass(primary),
                   let upscaled = Self.upscaledImage(from: image) {
                    let fullWidthStructured = try Self.recognizePass(
                        in: upscaled,
                        splitCompoundsByColumns: true
                    ).filter { !Self.isLikelyCrossColumnCompound($0, image: image) }
                    let tiledStructured = try Self.shallowInterfaceStructuredPass(in: image)
                    // Full-width OCR retains columns that happen to sit on a tile
                    // boundary, while narrow overlapping tiles prevent Vision from
                    // joining several neighbouring headers into one observation.
                    // Keep both sources and only collapse true geometric duplicates.
                    let combinedStructured = Self.mergeStructured(
                        fullWidthStructured,
                        with: tiledStructured
                    )
                    let separatedWideRows = combinedStructured.flatMap {
                        Self.splitWideRowCompound($0, image: image)
                    }
                    let separatedStructured = Self.splitAlignedTwoWordCompounds(
                        separatedWideRows,
                        image: image
                    )
                    let structured = Self.removeRedundantStructuredFragments(
                        Self.mergeStructured([], with: separatedStructured)
                    )
                    if Self.shouldPreferStructuredPass(structured, over: primary) {
                        blocks = Self.reconstructColumnCells(from: structured)
                        preferredStructuredPass = true
                    } else {
                        blocks = Self.merge(blocks, with: structured)
                    }
                }
                if !preferredStructuredPass {
                    for tile in Self.enhancementTiles(for: image) {
                        guard let cropped = Self.crop(image, toVisionRect: tile) else { continue }
                        let tileBlocks = try Self.recognizePass(in: cropped)
                            .filter { Self.isCompleteTileObservation($0.boundingBox, tile: tile) }
                            .map { Self.map($0, from: tile) }
                        blocks = Self.merge(blocks, with: tileBlocks)
                    }

                    if let enhanced = Self.contrastEnhancedImage(from: image) {
                        blocks = Self.merge(blocks, with: try Self.recognizePass(in: enhanced))
                    }
                }
            }

            blocks.sort(by: Self.readingOrder)
            guard !blocks.isEmpty else { throw HelloXError.noTextFound }
            let text = Self.join(blocks)
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let language = recognizer.dominantLanguage?.rawValue
            let average = blocks.reduce(Float.zero) { $0 + $1.confidence } / Float(blocks.count)
            return OCRResult(text: text, language: language, averageConfidence: average, blocks: blocks)
        }.value
    }

    /// Merges overlapping OCR passes while preferring the most complete,
    /// highest-confidence observation for each visual line.
    public static func merge(
        _ existing: [RecognizedTextBlock],
        with candidates: [RecognizedTextBlock]
    ) -> [RecognizedTextBlock] {
        var result = existing.sorted(by: readingOrder)
        for candidate in candidates.sorted(by: readingOrder) {
            let spansExistingIsolatedControl = result.contains { block in
                guard block.isLayoutIsolated == true,
                      candidate.boundingBox.width > block.boundingBox.width * 1.35 else {
                    return false
                }
                let intersection = block.boundingBox.intersection(candidate.boundingBox)
                guard !intersection.isNull else { return false }
                let horizontal = intersection.width / max(0.0001, block.boundingBox.width)
                let vertical = intersection.height / max(0.0001, block.boundingBox.height)
                return horizontal >= 0.65 && vertical >= 0.55
            }
            if spansExistingIsolatedControl { continue }
            let coveredIndices = result.indices.filter { index in
                let block = result[index]
                let intersection = block.boundingBox.intersection(candidate.boundingBox)
                guard !intersection.isNull else { return false }
                return intersection.width / max(0.0001, block.boundingBox.width) >= 0.55
                    && intersection.height / max(0.0001, block.boundingBox.height) >= 0.55
            }
            if coveredIndices.count >= 2 {
                let covered = coveredIndices.map { result[$0] }
                if covered.contains(where: { $0.isLayoutIsolated == true }) {
                    continue
                }
                let maximumHeight = covered.map(\.boundingBox.height).max() ?? 0
                let minimumMidY = covered.map(\.boundingBox.midY).min() ?? 0
                let maximumMidY = covered.map(\.boundingBox.midY).max() ?? 0
                let oneVisualLine = maximumMidY - minimumMidY <= maximumHeight * 0.55
                    && candidate.boundingBox.height <= maximumHeight * 1.65
                if oneVisualLine,
                   candidate.text.count >= covered.map(\.text.count).reduce(0, +) {
                    for index in coveredIndices.sorted(by: >) { result.remove(at: index) }
                    result.append(candidate)
                }
                continue
            }

            let duplicates = result.indices.filter { sameTextRegion(result[$0], candidate) }
            if let index = duplicates.min(by: {
                overlapScore(result[$0].boundingBox, candidate.boundingBox)
                    > overlapScore(result[$1].boundingBox, candidate.boundingBox)
            }) {
                result[index] = preferred(result[index], candidate)
                continue
            }
            result.append(candidate)
        }
        return result.sorted(by: readingOrder)
    }

    public static func readingOrder(_ lhs: RecognizedTextBlock, _ rhs: RecognizedTextBlock) -> Bool {
        let lineTolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.55
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > lineTolerance {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    public static func join(_ blocks: [RecognizedTextBlock]) -> String {
        OCRParagraphLayout.semanticJoin(blocks)
    }

    private static func recognizePass(
        in image: CGImage,
        splitCompoundsByColumns: Bool = false
    ) throws -> [RecognizedTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.003
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).compactMap { observation -> TextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextObservation(candidate: candidate, boundingBox: observation.boundingBox)
        }
        return observations.flatMap { observation -> [RecognizedTextBlock] in
            if let status = recognizedStatusControlChunks(
                in: observation,
                image: image
            ) {
                return status
            }
            if let controls = recognizedControlChunks(
                in: observation,
                image: image
            ) {
                return controls
            }
            if let content = recognizedLeadingIconContent(
                in: observation,
                image: image
            ) {
                return [content]
            }
            if splitCompoundsByColumns,
               (shouldSplitAcrossColumns(observation, among: observations)
                || hasLargeInterwordGap(observation)) {
                let words = wordRanges(in: observation.candidate.string).compactMap {
                    recognizedWord($0, from: observation.candidate)
                }
                if words.count >= 2 { return words }
            }
            return [RecognizedTextBlock(
                text: observation.candidate.string,
                confidence: observation.candidate.confidence,
                boundingBox: observation.boundingBox,
                translatableBoundingBox: preciseTranslatableBox(for: observation.candidate)
            )]
        }.sorted(by: readingOrder)
    }

    private struct TextObservation {
        let candidate: VNRecognizedText
        let boundingBox: CGRect
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { break }
            let start = cursor
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            ranges.append(start..<cursor)
        }
        return ranges
    }

    private static func recognizedWord(
        _ range: Range<String.Index>,
        from candidate: VNRecognizedText
    ) -> RecognizedTextBlock? {
        guard let box = try? candidate.boundingBox(for: range)?.boundingBox,
              box.width > 0,
              box.height > 0 else { return nil }
        return RecognizedTextBlock(
            text: String(candidate.string[range]),
            confidence: candidate.confidence,
            boundingBox: box,
            translatableBoundingBox: box
        )
    }

    /// OCR occasionally folds a sidebar icon into its label as one oversized
    /// leading Latin character (for example, "I Dashboard" or "B Contacts").
    /// Character geometry distinguishes that artifact from an actual initial:
    /// the icon token is wider than both the line height and normal glyphs in
    /// the following label. Keep the icon pixels and return only the text box.
    private static func recognizedLeadingIconContent(
        in observation: TextObservation,
        image: CGImage
    ) -> RecognizedTextBlock? {
        let ranges = wordRanges(in: observation.candidate.string)
        guard ranges.count == 2 else { return nil }
        let markerRange = ranges[0]
        let contentRange = ranges[1]
        let marker = String(observation.candidate.string[markerRange])
        let content = String(observation.candidate.string[contentRange])
        guard let markerBox = try? observation.candidate.boundingBox(for: markerRange)?.boundingBox,
              let contentBox = try? observation.candidate.boundingBox(for: contentRange)?.boundingBox,
              shouldTreatLeadingTokenAsIcon(
                markerText: marker,
                markerPixelSize: CGSize(
                    width: markerBox.width * CGFloat(image.width),
                    height: markerBox.height * CGFloat(image.height)
                ),
                contentText: content,
                contentPixelSize: CGSize(
                    width: contentBox.width * CGFloat(image.width),
                    height: contentBox.height * CGFloat(image.height)
                )
              ) else { return nil }
        return RecognizedTextBlock(
            text: content,
            confidence: observation.candidate.confidence,
            boundingBox: contentBox,
            translatableBoundingBox: contentBox
        )
    }

    /// Step controls are commonly folded into their adjacent title by Vision:
    /// a numbered circle becomes "2", "2)" or "(2)", while a checkmark can
    /// become "V", "C" or "*". Exclude that compact leading token from the
    /// repaint rectangle and isolate the title from its supporting copy. A
    /// countdown suffix is returned as a separate block so its lighter color
    /// and smaller visual role survive translation.
    private static func recognizedStatusControlChunks(
        in observation: TextObservation,
        image: CGImage
    ) -> [RecognizedTextBlock]? {
        let ranges = wordRanges(in: observation.candidate.string)
        guard ranges.count >= 2 else { return nil }

        var contentStartIndex = 0
        let leadingText = String(observation.candidate.string[ranges[0]])
        if isStepControlMarkerToken(leadingText),
           let markerBox = try? observation.candidate.boundingBox(for: ranges[0])?.boundingBox,
           let nextBox = try? observation.candidate.boundingBox(for: ranges[1])?.boundingBox {
            let markerPixelSize = CGSize(
                width: markerBox.width * CGFloat(image.width),
                height: markerBox.height * CGFloat(image.height)
            )
            let nextPixelHeight = nextBox.height * CGFloat(image.height)
            let compactMarker = markerPixelSize.width <= max(markerPixelSize.height, nextPixelHeight) * 2.2
            let precedesContent = markerBox.maxX <= nextBox.minX + max(markerBox.height, nextBox.height) * 0.35
            if compactMarker, precedesContent { contentStartIndex = 1 }
        }

        let fullText = observation.candidate.string
        let contentStart = ranges[contentStartIndex].lowerBound
        let contentRange = contentStart..<fullText.endIndex
        let countdown = fullText.range(
            of: #"(?i)\b(?:left|remaining)\s+\d{1,3}:\d{2}(?::\d{2})?\s*$"#,
            options: .regularExpression,
            range: contentRange
        )
        guard contentStartIndex > 0 || countdown != nil else { return nil }

        var semanticRanges: [Range<String.Index>] = []
        if let countdown {
            var titleEnd = countdown.lowerBound
            while contentStart < titleEnd, fullText[fullText.index(before: titleEnd)].isWhitespace {
                titleEnd = fullText.index(before: titleEnd)
            }
            if contentStart < titleEnd { semanticRanges.append(contentStart..<titleEnd) }
            semanticRanges.append(countdown)
        } else {
            semanticRanges.append(contentRange)
        }

        let chunks = semanticRanges.compactMap { range -> RecognizedTextBlock? in
            let value = fullText[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  let box = try? observation.candidate.boundingBox(for: range)?.boundingBox,
                  box.width > 0,
                  box.height > 0 else { return nil }
            return RecognizedTextBlock(
                text: value,
                confidence: observation.candidate.confidence,
                boundingBox: box,
                translatableBoundingBox: box,
                isLayoutIsolated: true
            )
        }
        return chunks.isEmpty ? nil : chunks
    }

    static func isStepControlMarkerToken(_ token: String) -> Bool {
        token.range(
            of: #"^(?:[\(\[（]?\d{1,3}[\)\]）.]?|[VvCc*✓✔☑く‹<][\).）]?)$"#,
            options: .regularExpression
        ).map { $0 == token.startIndex..<token.endIndex } == true
    }

    static func shouldTreatLeadingTokenAsIcon(
        markerText: String,
        markerPixelSize: CGSize,
        contentText: String,
        contentPixelSize: CGSize
    ) -> Bool {
        let markerScalars = markerText.unicodeScalars
        guard markerScalars.count == 1,
              let scalar = markerScalars.first,
              (65...90).contains(scalar.value) else { return false }
        let contentCharacters = contentText.filter { !$0.isWhitespace }.count
        guard contentCharacters >= 4,
              markerPixelSize.width > 0,
              markerPixelSize.height > 0,
              contentPixelSize.width > 0 else { return false }
        let typicalAdvance = contentPixelSize.width / CGFloat(contentCharacters)
        let lineHeight = max(markerPixelSize.height, contentPixelSize.height)
        return markerPixelSize.width >= lineHeight * 1.30
            && markerPixelSize.width >= typicalAdvance * 2.0
    }

    /// Vision often returns an entire toolbar/filter row as one sentence even
    /// though visible whitespace separates independent controls. Split only at
    /// gaps substantially wider than ordinary word spacing, retaining phrases
    /// inside each button or checkbox label.
    private static func recognizedControlChunks(
        in observation: TextObservation,
        image: CGImage
    ) -> [RecognizedTextBlock]? {
        let ranges = wordRanges(in: observation.candidate.string)
        guard ranges.count >= 4 else { return nil }
        let words = ranges.compactMap { range -> (range: Range<String.Index>, box: CGRect, count: Int)? in
            guard let box = try? observation.candidate.boundingBox(for: range)?.boundingBox else {
                return nil
            }
            let count = observation.candidate.string[range].count
            return count > 0 ? (range, box, count) : nil
        }
        guard words.count == ranges.count else { return nil }

        let pixelWidth = observation.boundingBox.width * CGFloat(image.width)
        let pixelHeight = observation.boundingBox.height * CGFloat(image.height)
        guard pixelWidth / max(1, pixelHeight) >= 4 else { return nil }

        let tokens = words.map { String(observation.candidate.string[$0.range]) }
        let markerStarts = tokens.indices.filter { isControlMarkerToken(tokens[$0]) }
        let actionStarts = tokens.indices.filter { isCommonActionStarter(tokens[$0]) }
        var textualStarts: [Int] = []
        if markerStarts.count >= 2 {
            textualStarts = markerStarts + tokens.indices.filter {
                isCommonFilterStarter(tokens[$0])
            }
            if markerStarts[0] > 0 { textualStarts.insert(0, at: 0) }
        } else if actionStarts.count >= 2 || actionStarts.first.map({ $0 <= 1 }) == true {
            textualStarts = [0]
            for actionIndex in actionStarts where actionIndex > 0 {
                let precedingIndex = actionIndex - 1
                textualStarts.append(
                    isInlineActionIconToken(tokens[precedingIndex]) ? precedingIndex : actionIndex
                )
            }
        }

        let cleansSingleLeadingMarker = textualStarts.count < 2
            && actionStarts.first == 1
            && isInlineActionIconToken(tokens[0])
        let groups: [[Int]]
        if textualStarts.count >= 2 || cleansSingleLeadingMarker {
            if cleansSingleLeadingMarker { textualStarts = [0] }
            let starts = Array(Set(textualStarts)).sorted()
            groups = starts.enumerated().map { offset, start in
                let end = offset + 1 < starts.count ? starts[offset + 1] : words.count
                return Array(start..<end)
            }
        } else {
            return nil
        }

        return groups.compactMap { indices -> RecognizedTextBlock? in
            guard let firstIndex = indices.first, let lastIndex = indices.last else { return nil }
            var contentIndex = firstIndex
            let firstText = String(observation.candidate.string[words[firstIndex].range])
            if indices.count >= 2, isInlineActionIconToken(firstText) {
                contentIndex += 1
            }
            guard contentIndex <= lastIndex else { return nil }
            let contentRange = words[contentIndex].range.lowerBound..<words[lastIndex].range.upperBound
            guard let box = try? observation.candidate.boundingBox(for: contentRange)?.boundingBox,
                  box.width > 0,
                  box.height > 0 else { return nil }
            return RecognizedTextBlock(
                text: String(observation.candidate.string[contentRange]),
                confidence: observation.candidate.confidence,
                boundingBox: box,
                translatableBoundingBox: box,
                isLayoutIsolated: true
            )
        }
    }

    private static func isControlMarkerToken(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1 else { return false }
        if let scalar = value.unicodeScalars.first,
           !CharacterSet.alphanumerics.contains(scalar) {
            return true
        }
        return ["0", "O", "o", "D", "C"].contains(value)
    }

    private static func isInlineActionIconToken(_ token: String) -> Bool {
        isControlMarkerToken(token) || ["a", "i", "I"].contains(token)
    }

    private static func isCommonActionStarter(_ token: String) -> Bool {
        [
            "Add", "Approve", "Cancel", "Close", "Copy", "Create", "Delete",
            "Download", "Edit", "Export", "Import", "Merge", "Open", "Print",
            "Receipts", "Refresh", "Reject", "Remove", "Save", "Send", "Submit",
            "Update", "Upload"
        ].contains(token)
    }

    private static func isCommonFilterStarter(_ token: String) -> Bool {
        ["Late"].contains(token)
    }

    /// A compound observation in a shallow table header can span neighbouring
    /// columns even though its words belong to different cells. Split only
    /// when another observation above or below aligns with a proper word-sized
    /// portion of it; ordinary phrases such as “Created At” remain intact.
    private static func shouldSplitAcrossColumns(
        _ observation: TextObservation,
        among observations: [TextObservation]
    ) -> Bool {
        let ranges = wordRanges(in: observation.candidate.string)
        guard ranges.count >= 2 else { return false }
        let wordBoxes = ranges.compactMap {
            try? observation.candidate.boundingBox(for: $0)?.boundingBox
        }.compactMap { $0 }
        guard wordBoxes.count == ranges.count else { return false }

        var alignedWordIndices = Set<Int>()
        var alignedObservationIndices = Set<Int>()
        for (wordIndex, wordBox) in wordBoxes.enumerated() {
            for (otherIndex, other) in observations.enumerated() {
                guard other.candidate !== observation.candidate else { continue }
                let verticalSeparation = abs(other.boundingBox.midY - wordBox.midY)
                let height = max(other.boundingBox.height, wordBox.height)
                guard verticalSeparation > height * 0.28 else { continue }
                let overlap = max(
                    0,
                    min(wordBox.maxX, other.boundingBox.maxX)
                        - max(wordBox.minX, other.boundingBox.minX)
                )
                let overlapRatio = overlap / max(0.0001, min(wordBox.width, other.boundingBox.width))
                if overlapRatio >= 0.28 {
                    alignedWordIndices.insert(wordIndex)
                    alignedObservationIndices.insert(otherIndex)
                }
            }
        }
        return !alignedWordIndices.isEmpty
            && (alignedWordIndices.count < wordBoxes.count || alignedObservationIndices.count >= 2)
    }

    private static func hasLargeInterwordGap(_ observation: TextObservation) -> Bool {
        let ranges = wordRanges(in: observation.candidate.string)
        guard ranges.count >= 2 else { return false }
        let words = ranges.compactMap { range -> (box: CGRect, count: Int)? in
            guard let box = try? observation.candidate.boundingBox(for: range)?.boundingBox else {
                return nil
            }
            let count = observation.candidate.string[range].filter { !$0.isWhitespace }.count
            return count > 0 ? (box, count) : nil
        }.sorted { $0.box.minX < $1.box.minX }
        guard words.count == ranges.count else { return false }
        for pair in zip(words, words.dropFirst()) {
            let gap = pair.1.box.minX - pair.0.box.maxX
            guard gap > 0 else { continue }
            let leftAdvance = pair.0.box.width / CGFloat(pair.0.count)
            let rightAdvance = pair.1.box.width / CGFloat(pair.1.count)
            if gap > max(leftAdvance, rightAdvance) * 0.75 { return true }
        }
        return false
    }

    private static func isShallowInterfaceImage(_ image: CGImage) -> Bool {
        image.height < 180 && CGFloat(image.width) / max(1, CGFloat(image.height)) >= 4
    }

    private static func upscaledImage(from image: CGImage) -> CGImage? {
        let scale = min(4, max(2, 150 / CGFloat(max(1, image.height))))
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ]
        )
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(
            output,
            from: output.extent
        )
    }

    private static func shallowInterfaceStructuredPass(
        in image: CGImage
    ) throws -> [RecognizedTextBlock] {
        var blocks: [RecognizedTextBlock] = []
        for targetWidth in shallowInterfaceTileWidths(for: image) {
            for tile in shallowInterfaceTiles(width: targetWidth) {
                guard let cropped = crop(image, toVisionRect: tile),
                      let upscaled = upscaledImage(from: cropped) else { continue }
                let candidates = try recognizePass(
                    in: upscaled,
                    splitCompoundsByColumns: true
                )
                .filter { isCompleteTileObservation($0.boundingBox, tile: tile) }
                .map { map($0, from: tile) }
                .filter { !isLikelyCrossColumnCompound($0, image: image) }
                blocks = mergeStructured(blocks, with: candidates)
            }
        }
        return blocks.sorted(by: readingOrder)
    }

    private static func shallowInterfaceTileWidths(for image: CGImage) -> [CGFloat] {
        let narrow = min(
            0.12,
            max(0.04, 64 / max(1, CGFloat(image.width)))
        )
        return abs(narrow - 0.12) < 0.01 ? [0.12] : [narrow, 0.12]
    }

    private static func shallowInterfaceTiles(width: CGFloat) -> [CGRect] {
        let stride = width * 0.62
        var starts: [CGFloat] = []
        var x: CGFloat = 0
        while x + width < 1 {
            starts.append(x)
            x += stride
        }
        let finalStart = 1 - width
        if starts.last.map({ abs($0 - finalStart) > 0.01 }) ?? true {
            starts.append(finalStart)
        }
        return starts.map { CGRect(x: $0, y: 0, width: width, height: 1) }
    }

    /// Structured passes intentionally produce many overlapping observations.
    /// The normal merge routine may replace two neighbouring cells with one
    /// longer OCR observation, which is exactly what table reconstruction must
    /// avoid. Here duplicates must cover nearly the same rectangle in both
    /// directions; partial/composite overlaps remain available as evidence.
    private static func mergeStructured(
        _ existing: [RecognizedTextBlock],
        with candidates: [RecognizedTextBlock]
    ) -> [RecognizedTextBlock] {
        var result = existing
        for candidate in candidates {
            if let index = result.indices.first(where: {
                structuredDuplicate(result[$0], candidate)
            }) {
                result[index] = preferred(result[index], candidate)
            } else {
                result.append(candidate)
            }
        }
        return result.sorted(by: readingOrder)
    }

    private static func structuredDuplicate(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> Bool {
        let leftText = lhs.text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        let rightText = rhs.text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        if leftText == rightText {
            let left = lhs.boundingBox.standardized
            let right = rhs.boundingBox.standardized
            let intersection = left.intersection(right)
            guard !intersection.isNull else { return false }
            let horizontal = intersection.width / max(0.0001, min(left.width, right.width))
            let vertical = intersection.height / max(0.0001, min(left.height, right.height))
            if horizontal >= 0.62 && vertical >= 0.40 { return true }
        }
        return strictSameTextRegion(lhs, rhs)
    }

    private static func strictSameTextRegion(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> Bool {
        let left = lhs.boundingBox.standardized
        let right = rhs.boundingBox.standardized
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return false }
        let horizontalLeft = intersection.width / max(0.0001, left.width)
        let horizontalRight = intersection.width / max(0.0001, right.width)
        let verticalLeft = intersection.height / max(0.0001, left.height)
        let verticalRight = intersection.height / max(0.0001, right.height)
        return horizontalLeft >= 0.68
            && horizontalRight >= 0.68
            && verticalLeft >= 0.68
            && verticalRight >= 0.68
    }

    private static func isLikelyCrossColumnCompound(
        _ block: RecognizedTextBlock,
        image: CGImage
    ) -> Bool {
        let wordCount = block.text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 4 else { return false }
        let pixelWidth = block.boundingBox.width * CGFloat(image.width)
        let pixelHeight = block.boundingBox.height * CGFloat(image.height)
        return pixelWidth / max(1, pixelHeight) >= 4.0
    }

    private static func splitWideRowCompound(
        _ block: RecognizedTextBlock,
        image: CGImage
    ) -> [RecognizedTextBlock] {
        let words = block.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count == 3 else { return [block] }
        let pixelWidth = block.boundingBox.width * CGFloat(image.width)
        let pixelHeight = block.boundingBox.height * CGFloat(image.height)
        guard pixelWidth / max(1, pixelHeight) >= 4.0 else { return [block] }

        let totalUnits = CGFloat(words.reduce(0) { $0 + $1.count } + words.count - 1)
        var cursor = block.boundingBox.minX
        return words.map { word in
            let width = block.boundingBox.width * CGFloat(word.count) / totalUnits
            let result = RecognizedTextBlock(
                text: word,
                confidence: block.confidence,
                boundingBox: CGRect(
                    x: cursor,
                    y: block.boundingBox.minY,
                    width: width,
                    height: block.boundingBox.height
                ),
                translatableBoundingBox: CGRect(
                    x: cursor,
                    y: block.boundingBox.minY,
                    width: width,
                    height: block.boundingBox.height
                )
            )
            cursor += width + block.boundingBox.width / totalUnits
            return result
        }
    }

    private static func splitAlignedTwoWordCompounds(
        _ blocks: [RecognizedTextBlock],
        image: CGImage
    ) -> [RecognizedTextBlock] {
        blocks.flatMap { block in
            let words = block.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count == 2 else { return [block] }
            let pixelWidth = block.boundingBox.width * CGFloat(image.width)
            let pixelHeight = block.boundingBox.height * CGFloat(image.height)
            guard pixelWidth / max(1, pixelHeight) >= 3.0 else { return [block] }

            let totalUnits = CGFloat(words.reduce(0) { $0 + $1.count } + 1)
            var cursor = block.boundingBox.minX
            let pieces = words.map { word -> RecognizedTextBlock in
                let width = block.boundingBox.width * CGFloat(word.count) / totalUnits
                let piece = RecognizedTextBlock(
                    text: word,
                    confidence: block.confidence,
                    boundingBox: CGRect(
                        x: cursor,
                        y: block.boundingBox.minY,
                        width: width,
                        height: block.boundingBox.height
                    ),
                    translatableBoundingBox: CGRect(
                        x: cursor,
                        y: block.boundingBox.minY,
                        width: width,
                        height: block.boundingBox.height
                    )
                )
                cursor += width + block.boundingBox.width / totalUnits
                return piece
            }
            let alignedIndices = pieces.compactMap { piece -> Int? in
                blocks.indices.first { index in
                    let other = blocks[index]
                    guard other.id != block.id else { return false }
                    let verticalDistance = abs(other.boundingBox.midY - piece.boundingBox.midY)
                    let height = max(other.boundingBox.height, piece.boundingBox.height)
                    guard verticalDistance > height * 0.28 else { return false }
                    let overlap = max(
                        0,
                        min(piece.boundingBox.maxX, other.boundingBox.maxX)
                            - max(piece.boundingBox.minX, other.boundingBox.minX)
                    )
                    return overlap / max(0.0001, piece.boundingBox.width) >= 0.28
                }
            }
            return Set(alignedIndices).count >= 2 ? pieces : [block]
        }
    }

    private static func removeRedundantStructuredFragments(
        _ blocks: [RecognizedTextBlock]
    ) -> [RecognizedTextBlock] {
        func normalized(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        return blocks.enumerated().compactMap { index, block in
            let value = normalized(block.text)
            guard !value.isEmpty else { return block }
            let isFragment = blocks.enumerated().contains { otherIndex, other in
                guard otherIndex != index else { return false }
                let otherValue = normalized(other.text)
                guard otherValue.count > value.count else { return false }
                let intersection = block.boundingBox.intersection(other.boundingBox)
                guard !intersection.isNull else { return false }
                let horizontal = intersection.width / max(0.0001, block.boundingBox.width)
                let vertical = intersection.height / max(0.0001, block.boundingBox.height)
                guard horizontal >= 0.72 && vertical >= 0.35 else { return false }
                if otherValue.contains(value) { return true }
                let sharedPrefix = zip(value, otherValue).prefix { $0 == $1 }.count
                if sharedPrefix * 10 >= value.count * 7 { return true }
                if value.count <= 3, sharedPrefix >= 2 { return true }
                let fragmentTokens = block.text.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                let otherTokens = other.text.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                return !fragmentTokens.isEmpty
                    && fragmentTokens.allSatisfy { fragment in
                        otherTokens.contains { token in
                            token.hasPrefix(fragment)
                                && fragment.count * 10 >= min(3, token.count) * 10
                        }
                    }
            }
            return isFragment ? nil : block
        }
    }

    static func shouldPreferStructuredPass(
        _ structured: [RecognizedTextBlock],
        over primary: [RecognizedTextBlock]
    ) -> Bool {
        let mergedPrimary = hasSuspiciousMergedObservation(primary)
        guard mergedPrimary else { return false }
        let requiredGain = max(3, primary.count / 3)
        guard structured.count >= primary.count + requiredGain else { return false }
        let primaryCharacters = primary.reduce(0) {
            $0 + $1.text.filter { !$0.isWhitespace }.count
        }
        let structuredCharacters = structured.reduce(0) {
            $0 + $1.text.filter { !$0.isWhitespace }.count
        }
        return structuredCharacters * 4 >= primaryCharacters * 3
    }

    /// Column reconstruction is only valid for a single visual band such as a
    /// table header or navigation row. A shallow screenshot can also contain
    /// several stacked rows (help text, filters and action buttons); slicing
    /// that image vertically would incorrectly join unrelated controls that
    /// happen to share an x coordinate.
    static func shouldUseColumnStructuredPass(
        _ blocks: [RecognizedTextBlock]
    ) -> Bool {
        guard hasSuspiciousMergedObservation(blocks), !blocks.isEmpty else { return false }
        let minimumY = blocks.map(\.boundingBox.minY).min() ?? 0
        let maximumY = blocks.map(\.boundingBox.maxY).max() ?? 1
        return maximumY - minimumY <= 0.70
    }

    private static func hasSuspiciousMergedObservation(
        _ blocks: [RecognizedTextBlock]
    ) -> Bool {
        blocks.contains { block in
            block.boundingBox.width >= 0.14
                && block.text.split(whereSeparator: { $0.isWhitespace }).count >= 4
        }
    }

    /// Reassembles the word observations from a shallow, upscaled OCR pass
    /// into vertical table-header cells. Same-row neighbours remain separate;
    /// vertically aligned words such as “Product / Image” share one cell.
    static func reconstructColumnCells(
        from blocks: [RecognizedTextBlock]
    ) -> [RecognizedTextBlock] {
        guard blocks.count >= 4 else { return blocks }
        var parents = Array(blocks.indices)

        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current { current = parents[current] }
            return current
        }

        func shouldShareColumn(_ lhs: RecognizedTextBlock, _ rhs: RecognizedTextBlock) -> Bool {
            guard lhs.isLayoutIsolated != true, rhs.isLayoutIsolated != true else { return false }
            let left = lhs.boundingBox
            let right = rhs.boundingBox
            let height = min(left.height, right.height)
            let maximumHeight = max(left.height, right.height)
            let verticalGap = max(left.minY, right.minY) - min(left.maxY, right.maxY)
            guard abs(left.midY - right.midY) > height * 0.28,
                  // Wrapped lines inside one cell sit close together. Header
                  // and data rows in a shallow table can share the same x
                  // position too, but the row gap is materially larger. A
                  // bounded gap prevents column reconstruction from turning
                  // "Channel" and "Support" into one translated paragraph.
                  verticalGap <= maximumHeight * 1.15,
                  !isCompactTitleAndSupportingCopy(lhs, rhs) else { return false }
            let overlap = max(0, min(left.maxX, right.maxX) - max(left.minX, right.minX))
            let overlapRatio = overlap / max(0.0001, min(left.width, right.width))
            let centerDistance = abs(left.midX - right.midX)
            let centerTolerance = max(min(left.width, right.width) * 0.65, 0.018)
            return overlapRatio >= 0.20 && centerDistance <= centerTolerance
        }

        for leftIndex in blocks.indices {
            for rightIndex in blocks.indices where rightIndex > leftIndex {
                guard shouldShareColumn(blocks[leftIndex], blocks[rightIndex]) else { continue }
                let leftRoot = root(leftIndex)
                let rightRoot = root(rightIndex)
                if leftRoot != rightRoot { parents[rightRoot] = leftRoot }
            }
        }

        var groups: [Int: [RecognizedTextBlock]] = [:]
        for index in blocks.indices { groups[root(index), default: []].append(blocks[index]) }
        return groups.values.map { originalGroup in
            let group = originalGroup.enumerated().compactMap { index, block in
                let value = block.text.lowercased().filter { $0.isLetter || $0.isNumber }
                let isDuplicateFragment = originalGroup.enumerated().contains { otherIndex, other in
                    guard otherIndex != index else { return false }
                    let otherValue = other.text.lowercased().filter {
                        $0.isLetter || $0.isNumber
                    }
                    return otherValue.count > value.count
                        && value.count <= 3
                        && otherValue.hasPrefix(value)
                }
                return isDuplicateFragment ? nil : block
            }
            guard group.count > 1 else {
                let block = group[0]
                return RecognizedTextBlock(
                    id: block.id,
                    text: block.text,
                    confidence: block.confidence,
                    boundingBox: block.boundingBox,
                    translatableBoundingBox: block.translatableBoundingBox,
                    isLayoutIsolated: true
                )
            }
            let ordered = group.sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            let box = ordered.dropFirst().reduce(ordered[0].boundingBox) {
                $0.union($1.boundingBox)
            }
            let confidence = ordered.reduce(Float.zero) { $0 + $1.confidence }
                / Float(ordered.count)
            return RecognizedTextBlock(
                id: ordered[0].id,
                text: ordered.map(\.text).joined(separator: "\n"),
                confidence: confidence,
                boundingBox: box,
                translatableBoundingBox: box,
                isLayoutIsolated: true
            )
        }.sorted(by: readingOrder)
    }

    private static func isCompactTitleAndSupportingCopy(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> Bool {
        let upper = lhs.boundingBox.midY > rhs.boundingBox.midY ? lhs : rhs
        let lower = lhs.boundingBox.midY > rhs.boundingBox.midY ? rhs : lhs
        let upperText = upper.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerText = lower.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upperText.isEmpty,
              upperText.count <= 40,
              lowerText.last.map({ ".!?。！？".contains($0) }) == true else { return false }
        let maximumHeight = max(upper.boundingBox.height, lower.boundingBox.height)
        let alignedLeft = abs(upper.boundingBox.minX - lower.boundingBox.minX) <= maximumHeight * 1.6
        let compactUpper = upper.boundingBox.width <= lower.boundingBox.width * 0.92
        return alignedLeft && compactUpper
    }

    private static func needsEnhancement(_ blocks: [RecognizedTextBlock]) -> Bool {
        guard !blocks.isEmpty else { return true }
        let average = blocks.reduce(Float.zero) { $0 + $1.confidence } / Float(blocks.count)
        let lowConfidenceCount = blocks.filter { $0.confidence < 0.65 }.count
        let containsSmallText = blocks.contains { $0.boundingBox.height < 0.025 }
        return average < 0.78
            || lowConfidenceCount * 5 >= blocks.count
            || containsSmallText
    }

    private static func enhancementTiles(for image: CGImage) -> [CGRect] {
        guard image.width >= 240, image.height >= 160 else { return [] }
        let length: CGFloat = 0.62
        let starts: [CGFloat] = [0, 1 - length]
        return starts.flatMap { y in
            starts.map { x in CGRect(x: x, y: y, width: length, height: length) }
        }
    }

    private static func crop(_ image: CGImage, toVisionRect rect: CGRect) -> CGImage? {
        let pixelRect = CGRect(
            x: rect.minX * CGFloat(image.width),
            y: (1 - rect.maxY) * CGFloat(image.height),
            width: rect.width * CGFloat(image.width),
            height: rect.height * CGFloat(image.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixelRect.width >= 2 && pixelRect.height >= 2 ? image.cropping(to: pixelRect) : nil
    }

    private static func map(_ block: RecognizedTextBlock, from tile: CGRect) -> RecognizedTextBlock {
        let box = block.boundingBox
        return RecognizedTextBlock(
            id: block.id,
            text: block.text,
            confidence: block.confidence,
            boundingBox: CGRect(
                x: tile.minX + box.minX * tile.width,
                y: tile.minY + box.minY * tile.height,
                width: box.width * tile.width,
                height: box.height * tile.height
            ),
            translatableBoundingBox: block.translatableBoundingBox.map { contentBox in
                CGRect(
                    x: tile.minX + contentBox.minX * tile.width,
                    y: tile.minY + contentBox.minY * tile.height,
                    width: contentBox.width * tile.width,
                    height: contentBox.height * tile.height
                )
            },
            isLayoutIsolated: block.isLayoutIsolated
        )
    }

    private static func preciseTranslatableBox(for candidate: VNRecognizedText) -> CGRect? {
        guard let range = ScreenshotTranslationContentPolicy.translationContentRange(
            in: candidate.string
        ) else { return nil }
        return try? candidate.boundingBox(for: range)?.boundingBox
    }

    private static func isCompleteTileObservation(_ box: CGRect, tile: CGRect) -> Bool {
        let margin: CGFloat = 0.012
        if tile.minX > 0, box.minX <= margin { return false }
        if tile.maxX < 1, box.maxX >= 1 - margin { return false }
        if tile.minY > 0, box.minY <= margin { return false }
        if tile.maxY < 1, box.maxY >= 1 - margin { return false }
        return true
    }

    private static func contrastEnhancedImage(from image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.45
            ]
        )
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
    }

    private static func sameTextRegion(_ lhs: RecognizedTextBlock, _ rhs: RecognizedTextBlock) -> Bool {
        let lhsBox = lhs.boundingBox.standardized
        let rhsBox = rhs.boundingBox.standardized
        let heightRatio = max(lhsBox.height, rhsBox.height) / max(0.0001, min(lhsBox.height, rhsBox.height))
        let intersection = lhsBox.intersection(rhsBox)
        guard !intersection.isNull else { return false }
        let areaRatio = intersection.width * intersection.height
            / max(0.0001, min(lhsBox.width * lhsBox.height, rhsBox.width * rhsBox.height))
        let verticalRatio = intersection.height / max(0.0001, min(lhsBox.height, rhsBox.height))
        let horizontalRatio = intersection.width / max(0.0001, min(lhsBox.width, rhsBox.width))
        if heightRatio <= 1.90 {
            return areaRatio >= 0.52 || (verticalRatio >= 0.72 && horizontalRatio >= 0.48)
        }

        // Enhancement tiles occasionally map one visual line back with a box
        // two to four times too tall (or too short). Those observations still
        // cover the same glyphs, but the old height-ratio gate let both copies
        // survive into translation and repainting. Accept only strong nested
        // overlap with nearby centers at these larger scale differences.
        let horizontalCenterDistance = abs(lhsBox.midX - rhsBox.midX)
        let verticalCenterDistance = abs(lhsBox.midY - rhsBox.midY)
        let hasRelatedText = normalizedTextSimilarity(lhs.text, rhs.text) >= 0.45
        return heightRatio <= 4.5
            && horizontalRatio >= 0.72
            && verticalRatio >= 0.72
            && horizontalCenterDistance <= max(lhsBox.width, rhsBox.width) * 0.35
            && verticalCenterDistance <= max(lhsBox.height, rhsBox.height) * 0.20
            && (heightRatio >= 2.5 || hasRelatedText)
    }

    private static func overlapScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
            / max(0.0001, min(lhs.width * lhs.height, rhs.width * rhs.height))
    }

    private static func preferred(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> RecognizedTextBlock {
        if rhs.confidence > lhs.confidence + 0.05 { return rhs }
        if lhs.confidence > rhs.confidence + 0.05 { return lhs }
        let lhsText = lhs.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsText = rhs.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rhsText.count != lhsText.count {
            return rhsText.count > lhsText.count ? rhs : lhs
        }
        // Equal-length alternatives are common when a tiled OCR pass reads a
        // control icon as a letter. Prefer the tighter single-line geometry so
        // an oversized hallucinated box cannot erase neighbouring UI.
        let heightRatio = max(lhs.boundingBox.height, rhs.boundingBox.height)
            / max(0.0001, min(lhs.boundingBox.height, rhs.boundingBox.height))
        if heightRatio >= 2.5,
           !lhsText.contains("\n"), !rhsText.contains("\n") {
            return rhs.boundingBox.height < lhs.boundingBox.height ? rhs : lhs
        }
        return lhs
    }

    private static func normalizedTextSimilarity(_ lhs: String, _ rhs: String) -> CGFloat {
        let left = Array(lhs.lowercased().filter { $0.isLetter || $0.isNumber })
        let right = Array(rhs.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        let distance = previous[right.count]
        return 1 - CGFloat(distance) / CGFloat(max(left.count, right.count))
    }
}
