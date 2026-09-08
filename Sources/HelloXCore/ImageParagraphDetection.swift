import CoreGraphics
import Foundation
import NaturalLanguage

/// Groups OCR lines by their spatial layout before translation. Vision gives us
/// individual observations; this detector uses line height, horizontal overlap,
/// and the ratio between line and paragraph gaps to recover visual paragraphs.
public enum ImageParagraphDetector {
    public struct Configuration: Sendable {
        public var maximumLineGapRatio: CGFloat
        public var minimumColumnOverlap: CGFloat
        public var maximumHeightRatio: CGFloat

        public init(
            maximumLineGapRatio: CGFloat = 2.4,
            minimumColumnOverlap: CGFloat = 0.20,
            maximumHeightRatio: CGFloat = 1.8
        ) {
            self.maximumLineGapRatio = maximumLineGapRatio
            self.minimumColumnOverlap = minimumColumnOverlap
            self.maximumHeightRatio = maximumHeightRatio
        }
    }

    public static func detect(
        from blocks: [RecognizedTextBlock],
        configuration: Configuration = Configuration()
    ) -> [[RecognizedTextBlock]] {
        let blocks = blocks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: VisionOCRService.readingOrder)
        guard !blocks.isEmpty else { return [] }

        // Vision normally returns one observation per visual line, but mixed
        // fonts and inline emphasis can split one line into several blocks.
        // Recover visual lines first so same-row fragments do not look like
        // independent columns or paragraphs.
        let lines = makeVisualLines(from: blocks, configuration: configuration)

        var groups: [[VisualLine]] = []
        for line in lines {
            if line.blocks.contains(where: { $0.isLayoutIsolated == true }) {
                groups.append([line])
                continue
            }
            let candidates = groups.indices.compactMap { index -> (Int, CGFloat)? in
                guard let anchor = bestAnchor(for: line, in: groups[index], configuration: configuration) else {
                    return nil
                }
                return (index, connectionScore(line, anchor))
            }
            guard let index = candidates.min(by: { $0.1 < $1.1 })?.0 else {
                groups.append([line])
                continue
            }
            groups[index].append(line)
        }
        return groups.map { group in
            group
                .sorted(by: visualReadingOrder)
                .flatMap { $0.blocks.sorted(by: VisionOCRService.readingOrder) }
        }
    }

    private struct VisualLine {
        var blocks: [RecognizedTextBlock]
        var boundingBox: CGRect
    }

    private static func makeVisualLines(
        from blocks: [RecognizedTextBlock],
        configuration: Configuration
    ) -> [VisualLine] {
        let independentlyPositionedIDs = denseControlRowBlockIDs(
            in: blocks,
            configuration: configuration
        )
        var lines: [VisualLine] = []
        for block in blocks {
            // Navigation bars, segmented controls, card grids, and table-like
            // rows contain many independent labels on one baseline. Never
            // collapse those labels into a single visual line: each OCR box is
            // its own layout constraint and must be translated in place.
            if block.isLayoutIsolated == true || independentlyPositionedIDs.contains(block.id) {
                lines.append(VisualLine(blocks: [block], boundingBox: block.boundingBox))
                continue
            }
            let candidates = lines.indices.filter { index in
                let box = lines[index].boundingBox
                let height = max(box.height, block.boundingBox.height)
                let heightRatio = height / max(0.0001, min(box.height, block.boundingBox.height))
                guard heightRatio <= configuration.maximumHeightRatio,
                      abs(box.midY - block.boundingBox.midY) <= height * 0.55 else { return false }
                return isPlausibleInlineGap(
                    between: lines[index].blocks,
                    and: block,
                    combinedBox: box
                )
            }
            if let index = candidates.min(by: {
                horizontalGap(lines[$0].boundingBox, block.boundingBox)
                    < horizontalGap(lines[$1].boundingBox, block.boundingBox)
            }) {
                lines[index].blocks.append(block)
                lines[index].boundingBox = lines[index].boundingBox.union(block.boundingBox)
            } else {
                lines.append(VisualLine(blocks: [block], boundingBox: block.boundingBox))
            }
        }
        return lines.sorted(by: visualReadingOrder)
    }

    private static func denseControlRowBlockIDs(
        in blocks: [RecognizedTextBlock],
        configuration: Configuration
    ) -> Set<UUID> {
        var rows: [[RecognizedTextBlock]] = []
        var rowBoxes: [CGRect] = []
        for block in blocks.sorted(by: VisionOCRService.readingOrder) {
            let candidates = rows.indices.filter { index in
                let box = rowBoxes[index]
                let height = max(box.height, block.boundingBox.height)
                let heightRatio = height / max(0.0001, min(box.height, block.boundingBox.height))
                return heightRatio <= configuration.maximumHeightRatio
                    && abs(box.midY - block.boundingBox.midY) <= height * 0.55
            }
            if let index = candidates.min(by: {
                abs(rowBoxes[$0].midY - block.boundingBox.midY)
                    < abs(rowBoxes[$1].midY - block.boundingBox.midY)
            }) {
                rows[index].append(block)
                rowBoxes[index] = rowBoxes[index].union(block.boundingBox)
            } else {
                rows.append([block])
                rowBoxes.append(block.boundingBox)
            }
        }
        return Set(rows.filter { $0.count >= 4 }.flatMap { $0.map(\.id) })
    }

    private static func bestAnchor(
        for line: VisualLine,
        in group: [VisualLine],
        configuration: Configuration
    ) -> VisualLine? {
        guard !line.blocks.contains(where: { $0.isLayoutIsolated == true }),
              !group.contains(where: { visualLine in
                  visualLine.blocks.contains(where: { $0.isLayoutIsolated == true })
              }) else { return nil }
        // A semantic paragraph cannot contain two independent visual lines on
        // the same row. This prevents a full-width heading (or banner) above
        // two columns from becoming a bridge that joins both columns.
        let alreadyOccupiesRow = group.contains { existing in
            let height = max(existing.boundingBox.height, line.boundingBox.height)
            return abs(existing.boundingBox.midY - line.boundingBox.midY) <= height * 0.55
        }
        guard !alreadyOccupiesRow else { return nil }
        return group
            .filter { canFollow(line, after: $0, configuration: configuration) }
            .min { connectionScore(line, $0) < connectionScore(line, $1) }
    }

    private static func canFollow(
        _ lowerLine: VisualLine,
        after upperLine: VisualLine,
        configuration: Configuration
    ) -> Bool {
        let lhs = upperLine.boundingBox
        let rhs = lowerLine.boundingBox
        let height = max(lhs.height, rhs.height)
        let heightRatio = max(lhs.height, rhs.height) / max(0.0001, min(lhs.height, rhs.height))
        guard heightRatio <= configuration.maximumHeightRatio else { return false }

        // A paragraph connection is directional. Same-row items belong to
        // separate columns once visual-line recovery has finished.
        guard lhs.midY > rhs.midY + height * 0.55 else { return false }
        let gap = lhs.minY - rhs.maxY
        guard gap >= -height * 0.35,
              gap <= height * configuration.maximumLineGapRatio else { return false }

        let overlap = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        let overlapRatio = overlap / max(0.0001, min(lhs.width, rhs.width))
        let leftAligned = abs(lhs.minX - rhs.minX) <= height * 1.9
        let rightAligned = abs(lhs.maxX - rhs.maxX) <= height * 1.6
        return leftAligned || rightAligned || overlapRatio >= configuration.minimumColumnOverlap
    }

    private static func connectionScore(_ lower: VisualLine, _ upper: VisualLine) -> CGFloat {
        let lhs = upper.boundingBox
        let rhs = lower.boundingBox
        let height = max(0.0001, max(lhs.height, rhs.height))
        let gapRatio = max(0, lhs.minY - rhs.maxY) / height
        let leftDelta = abs(lhs.minX - rhs.minX) / height
        let overlap = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        let overlapRatio = overlap / max(0.0001, min(lhs.width, rhs.width))
        let heightPenalty = abs(lhs.height - rhs.height) / height
        return gapRatio * 1.8 + min(4, leftDelta) * 0.32 + heightPenalty * 0.7 - overlapRatio * 0.9
    }

    private static func visualReadingOrder(_ lhs: VisualLine, _ rhs: VisualLine) -> Bool {
        let tolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.55
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > tolerance {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    private static func horizontalGap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX)
    }

    /// Vision can report compact UI labels with a line-height-sized box. A
    /// pure line-height threshold therefore joins every label in a horizontal
    /// card grid into one paragraph. Compare the empty gap with the observed
    /// character advance as well: real inline fragments are only a few glyph
    /// widths apart, while independent controls are separated by many.
    private static func isPlausibleInlineGap(
        between existing: [RecognizedTextBlock],
        and candidate: RecognizedTextBlock,
        combinedBox: CGRect
    ) -> Bool {
        let gap = horizontalGap(combinedBox, candidate.boundingBox)
        guard gap > 0 else { return true }
        let height = max(combinedBox.height, candidate.boundingBox.height)
        // Breadcrumb paths are complete UI controls, not continuations of a
        // neighbouring page title on the same baseline (for example,
        // "Channel" followed by "Settings > Channel"). Keep tightly spaced
        // mathematical or styled fragments such as "x > 0" eligible to join.
        if gap > height * 0.5,
           isBreadcrumbPath(candidate.text)
            || existing.contains(where: { isBreadcrumbPath($0.text) }) {
            return false
        }
        guard gap <= height * 2 else { return false }

        let advances = (existing + [candidate]).compactMap(estimatedCharacterAdvance)
        guard let typicalAdvance = advances.max(), typicalAdvance > 0 else { return false }
        return gap <= typicalAdvance * 3.5
    }

    private static func isBreadcrumbPath(_ text: String) -> Bool {
        text.range(
            of: #"\S+\s*[>›»]\s*\S+"#,
            options: .regularExpression
        ) != nil
    }

    private static func estimatedCharacterAdvance(_ block: RecognizedTextBlock) -> CGFloat? {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = text.filter { !$0.isWhitespace }.count
        guard count > 0, block.boundingBox.width > 0 else { return nil }
        return block.boundingBox.width / CGFloat(count)
    }
}

/// Local semantic continuity scoring for adjacent OCR lines. Geometry decides
/// which lines are plausible neighbours; this pass decides whether the words
/// read as one continuing thought or two independent labels/paragraphs.
public enum OCRSemanticContinuity {
    public static func isContinuous(previous: String, current: String) -> Bool {
        let lhs = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty,
              !isSalutation(lhs),
              !isStructuredLine(rhs),
              !isHeading(lhs),
              !isHeading(rhs) else { return false }

        var score = 0
        if hasOpenSentence(lhs) { score += 2 } else { score -= 3 }
        if beginsWithContinuation(rhs) { score += 3 }
        if endsWithConnector(lhs) { score += 3 }
        if beginsWithClosingPunctuation(rhs) { score += 2 }

        let leftLanguage = dominantLanguage(of: lhs)
        let rightLanguage = dominantLanguage(of: rhs)
        if let leftLanguage, let rightLanguage {
            score += leftLanguage == rightLanguage ? 1 : -1
        }

        if beginsWithUppercaseLatin(rhs), !endsWithConnector(lhs) { score -= 1 }
        if lexicalLength(lhs) <= 10, lexicalLength(rhs) <= 10,
           !beginsWithContinuation(rhs) { score -= 1 }
        return score >= 2
    }

    /// A greeting is a complete discourse unit even though it commonly ends
    /// with a comma or colon. Treating that punctuation as an open sentence
    /// merges email salutations into the first body paragraph.
    public static func isSalutation(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 80 else { return false }
        let normalized = value.lowercased()
        let latinPrefixes = [
            "hi ", "hello ", "hey ", "dear ", "good morning ",
            "good afternoon ", "good evening "
        ]
        if latinPrefixes.contains(where: { normalized.hasPrefix($0) }),
           let last = value.last,
           ",:!，：！".contains(last) {
            return true
        }
        let cjkPrefixes = ["你好", "您好", "亲爱的", "尊敬的", "各位", "致"]
        return cjkPrefixes.contains(where: { value.hasPrefix($0) })
            && value.last.map { ",:!，：！".contains($0) } == true
    }

    private static func hasOpenSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return !".!?;:。！？；：".contains(last)
    }

    static func beginsWithContinuation(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        if first.isLowercase || first.isNumber || "，、,)]}）】」』".contains(first) {
            return true
        }
        let normalized = text.lowercased()
        let latin = [
            "and ", "or ", "but ", "because ", "so ", "then ", "which ",
            "that ", "with ", "without ", "for ", "to ", "of ", "in "
        ]
        if latin.contains(where: { normalized.hasPrefix($0) }) { return true }
        let cjk = ["而", "并", "且", "但", "或", "及", "与", "和", "以及", "因此", "所以", "然后", "其中", "通过", "用于", "以便"]
        return cjk.contains(where: { text.hasPrefix($0) })
    }

    private static func endsWithConnector(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let latin = [" and", " or", " but", " because", " with", " without", " for", " to", " of", " in", "-"]
        if latin.contains(where: { normalized.hasSuffix($0) }) { return true }
        return ["，", "、", ",", "（", "(", "的", "和", "与", "及", "为", "在", "是", "将", "把"].contains {
            normalized.hasSuffix($0)
        }
    }

    private static func beginsWithClosingPunctuation(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return "，。！？；：、,.!?;:)]}）】」』".contains(first)
    }

    private static func beginsWithUppercaseLatin(_ text: String) -> Bool {
        guard let first = text.first(where: { $0.isLetter }) else { return false }
        return first.isUppercase && first.unicodeScalars.allSatisfy { $0.value < 128 }
    }

    private static func dominantLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    private static func lexicalLength(_ text: String) -> Int {
        text.filter { $0.isLetter || $0.isNumber }.count
    }

    private static func isStructuredLine(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return "-•*·".contains(first)
            || text.range(of: "^\\d+[.)]\\s+", options: .regularExpression) != nil
    }

    private static func isHeading(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        return !letters.isEmpty && letters.allSatisfy { $0.isUppercase } && text.count <= 80
    }
}

/// A conservative text pass that repairs obvious OCR paragraph boundaries.
/// It merges adjacent lines when punctuation/casing shows continuation, while
/// preserving lists, headings, and large spatial gaps as separate paragraphs.
public enum TextParagraphCorrector {
    public static func correct(_ groups: [[RecognizedTextBlock]]) -> [[RecognizedTextBlock]] {
        let metrics = layoutMetrics(for: groups)
        var result: [[RecognizedTextBlock]] = []
        for group in groups {
            // Spatial groups represent independent columns or disconnected
            // regions. Once layout or semantics establishes a paragraph break,
            // a later text-only pass must not join across that boundary.
            result.append(contentsOf: split(group, metrics: metrics))
        }
        return result
    }

    private struct LayoutMetrics {
        let typicalGapRatio: CGFloat
    }

    private static func split(
        _ group: [RecognizedTextBlock],
        metrics: LayoutMetrics
    ) -> [[RecognizedTextBlock]] {
        let lines = correctionLines(from: group)
        guard lines.count > 1 else { return group.isEmpty ? [] : [group] }
        var segments: [[RecognizedTextBlock]] = []
        var current: [RecognizedTextBlock] = []
        var previous: CorrectionLine?
        for line in lines {
            if let previous, shouldSplit(previous, line, metrics: metrics) {
                segments.append(current)
                current = []
            }
            current.append(contentsOf: line.blocks)
            previous = line
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private struct CorrectionLine {
        var blocks: [RecognizedTextBlock]
        var boundingBox: CGRect

        var text: String {
            blocks
                .sorted(by: VisionOCRService.readingOrder)
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private static func correctionLines(from blocks: [RecognizedTextBlock]) -> [CorrectionLine] {
        var lines: [CorrectionLine] = []
        for block in blocks.sorted(by: VisionOCRService.readingOrder) {
            let candidates = lines.indices.filter { index in
                let box = lines[index].boundingBox
                let height = max(box.height, block.boundingBox.height)
                guard abs(box.midY - block.boundingBox.midY) <= height * 0.55 else { return false }
                return isPlausibleInlineGap(
                    between: lines[index].blocks,
                    and: block,
                    combinedBox: box
                )
            }
            if let index = candidates.min(by: {
                horizontalGap(lines[$0].boundingBox, block.boundingBox)
                    < horizontalGap(lines[$1].boundingBox, block.boundingBox)
            }) {
                lines[index].blocks.append(block)
                lines[index].boundingBox = lines[index].boundingBox.union(block.boundingBox)
            } else {
                lines.append(CorrectionLine(blocks: [block], boundingBox: block.boundingBox))
            }
        }
        return lines.sorted { lhs, rhs in
            let tolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.55
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > tolerance {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    private static func shouldSplit(
        _ left: CorrectionLine,
        _ right: CorrectionLine,
        metrics: LayoutMetrics
    ) -> Bool {
        let leftText = left.text
        let rightText = right.text
        if isBoundaryPrefix(rightText) || hasStrongHeadingShape(rightText) || hasStrongHeadingShape(leftText) { return true }
        if OCRSemanticContinuity.isSalutation(leftText) { return true }
        let semanticallyContinuous = OCRSemanticContinuity.isContinuous(
            previous: leftText,
            current: rightText
        )
        let sizeRatio = left.boundingBox.height / max(0.0001, right.boundingBox.height)
        if leftText.count <= 40, sizeRatio >= 1.28 { return true }
        let height = max(left.boundingBox.height, right.boundingBox.height)
        let upper = left.boundingBox.midY > right.boundingBox.midY ? left.boundingBox : right.boundingBox
        let lower = left.boundingBox.midY > right.boundingBox.midY ? right.boundingBox : left.boundingBox
        let gap = upper.minY - lower.maxY
        let gapRatio = gap / max(0.0001, height)
        let alignedLeftEdge = abs(left.boundingBox.minX - right.boundingBox.minX) <= height * 1.4
        let compactTitleWithSupportingCopy = leftText.count <= 32
            && leftText.split(whereSeparator: { $0.isWhitespace }).count <= 3
            && rightText.count > leftText.count
            && left.boundingBox.width <= right.boundingBox.width * 0.92
            && alignedLeftEdge
            && gapRatio > 0.30
            && endsSentence(rightText)
            && !OCRSemanticContinuity.beginsWithContinuation(rightText)
        if compactTitleWithSupportingCopy { return true }
        // Compare with the document-wide wrapped-line rhythm. The previous
        // hard floor of 1.0 line-height missed the common case where paragraph
        // spacing is only 1.5–2x the ordinary inter-line gap.
        let strongParagraphGap = min(1.05, max(0.48, metrics.typicalGapRatio * 1.70 + 0.14))
        if gapRatio > strongParagraphGap { return true }
        let shortLeadFollowedByBody = left.boundingBox.width < right.boundingBox.width * 0.70
            && alignedLeftEdge
            && (endsSentence(leftText) || gapRatio > metrics.typicalGapRatio + 0.12)
        if shortLeadFollowedByBody { return true }
        // Short title-case headings do not necessarily have a larger Vision
        // bounding-box height (bold glyphs can even produce a shorter box).
        // A very short, left-aligned line followed by a full-width line is a
        // reliable visual boundary for headings and paragraph tail lines.
        let strongShortLead = left.blocks.count == 1
            && left.boundingBox.width < right.boundingBox.width * 0.45
            && alignedLeftEdge
            && gapRatio > 0.28
        if strongShortLead { return true }
        if gap > height * 2.4 { return true }
        if gap > height * 1.35, !semanticallyContinuous { return true }
        if gap > height * 0.80, endsSentence(leftText), !semanticallyContinuous { return true }
        let indentation = abs(left.boundingBox.minX - right.boundingBox.minX)
        if indentation > height * 1.25,
           gapRatio > max(0.28, metrics.typicalGapRatio * 0.85),
           !semanticallyContinuous { return true }
        let overlap = max(0, min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX))
        let overlapRatio = overlap / max(0.0001, min(upper.width, lower.width))
        return overlapRatio < 0.08 && !semanticallyContinuous && !leftText.isEmpty
    }

    private static func layoutMetrics(for groups: [[RecognizedTextBlock]]) -> LayoutMetrics {
        var ratios: [CGFloat] = []
        for group in groups {
            let lines = correctionLines(from: group)
            for (upperLine, lowerLine) in zip(lines, lines.dropFirst()) {
                let upper = upperLine.boundingBox.midY > lowerLine.boundingBox.midY
                    ? upperLine.boundingBox : lowerLine.boundingBox
                let lower = upperLine.boundingBox.midY > lowerLine.boundingBox.midY
                    ? lowerLine.boundingBox : upperLine.boundingBox
                let height = max(upper.height, lower.height)
                guard abs(upper.midY - lower.midY) > height * 0.55 else { continue }
                let ratio = max(0, upper.minY - lower.maxY) / max(0.0001, height)
                ratios.append(ratio)
            }
        }
        guard !ratios.isEmpty else { return LayoutMetrics(typicalGapRatio: 0.45) }
        let sorted = ratios.sorted()
        // Use the tighter half: paragraph gaps are outliers and must not raise
        // the baseline that represents ordinary wrapped-line spacing.
        let tightCount = max(1, (sorted.count + 1) / 2)
        let tight = Array(sorted.prefix(tightCount))
        let typical = tight[tight.count / 2]
        return LayoutMetrics(typicalGapRatio: min(0.85, max(0.18, typical)))
    }

    private static func horizontalGap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX)
    }

    private static func isPlausibleInlineGap(
        between existing: [RecognizedTextBlock],
        and candidate: RecognizedTextBlock,
        combinedBox: CGRect
    ) -> Bool {
        let gap = horizontalGap(combinedBox, candidate.boundingBox)
        guard gap > 0 else { return true }
        let height = max(combinedBox.height, candidate.boundingBox.height)
        guard gap <= height * 2 else { return false }
        let advances = (existing + [candidate]).compactMap { block -> CGFloat? in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = text.filter { !$0.isWhitespace }.count
            guard count > 0, block.boundingBox.width > 0 else { return nil }
            return block.boundingBox.width / CGFloat(count)
        }
        guard let typicalAdvance = advances.max(), typicalAdvance > 0 else { return false }
        return gap <= typicalAdvance * 3.5
    }

    private static func isBoundaryPrefix(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return "-•*·".contains(first) || text.range(of: "^\\d+[.)]\\s+", options: .regularExpression) != nil
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?;:。！？；：".contains(last)
    }

    private static func hasStrongHeadingShape(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        return !letters.isEmpty && letters.allSatisfy { $0.isUppercase } && text.count <= 80
    }
}
