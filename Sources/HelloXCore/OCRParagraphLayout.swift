import CoreGraphics
import Foundation

public struct RecognizedTextParagraph: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let boundingBox: CGRect
    public let blocks: [RecognizedTextBlock]
    public let lineCount: Int
    /// Relative widths of source lines, from top to bottom. These let translated
    /// text retain the source paragraph's visual rhythm after one full-paragraph
    /// translation request.
    public let lineWidthRatios: [CGFloat]

    public init(
        id: UUID,
        text: String,
        boundingBox: CGRect,
        blocks: [RecognizedTextBlock],
        lineCount: Int,
        lineWidthRatios: [CGFloat]
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.blocks = blocks
        self.lineCount = max(1, lineCount)
        self.lineWidthRatios = lineWidthRatios.isEmpty ? [1] : lineWidthRatios
    }
}

public enum OCRParagraphLayout {
    public static func paragraphs(from blocks: [RecognizedTextBlock]) -> [RecognizedTextParagraph] {
        let ordered = blocks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: VisionOCRService.readingOrder)
        guard !ordered.isEmpty else { return [] }

        // Vision's reading order interleaves lines from adjacent columns. Build
        // spatially connected components instead of walking that order so each
        // column still becomes a complete paragraph.
        var parent = Array(ordered.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current { current = parent[current] }
            return current
        }
        func join(_ lhs: Int, _ rhs: Int) {
            let lhsRoot = root(lhs)
            let rhsRoot = root(rhs)
            if lhsRoot != rhsRoot { parent[rhsRoot] = lhsRoot }
        }
        for lhs in ordered.indices {
            for rhs in ordered.indices where rhs > lhs {
                if blocksBelongToSameParagraph(ordered[lhs], ordered[rhs]) {
                    join(lhs, rhs)
                }
            }
        }
        var groups: [Int: [RecognizedTextBlock]] = [:]
        for index in ordered.indices {
            groups[root(index), default: []].append(ordered[index])
        }
        return groups.values.map(makeParagraph).sorted { lhs, rhs in
            let tolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.12
            if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > tolerance {
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    /// Restores visual line breaks after translating a complete paragraph. The
    /// original line widths act as proportional targets, so short first/last
    /// lines and numbered lists keep their original rhythm.
    public static func reflow(_ text: String, lineWidthRatios: [CGFloat]) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let widths = lineWidthRatios.map { max(0.08, $0) }
        let desiredLines = max(1, widths.count)
        guard desiredLines > 1, normalized.count > 1 else { return normalized }

        let words = normalized.split(separator: " ").map(String.init)
        if words.count >= desiredLines {
            return balancedLines(tokens: words, separator: " ", lineWidthRatios: widths)
        }
        return balancedLines(tokens: normalized.map(String.init), separator: "", lineWidthRatios: widths)
    }

    /// Distributes one complete paragraph translation back into its original OCR
    /// boxes. Translation gets full context; the on-image placement stays tied
    /// to the exact source boxes, preserving columns, controls and background.
    public static func distribute(
        _ text: String,
        across sourceBlocks: [RecognizedTextBlock]
    ) -> [String] {
        let ordered = sourceBlocks.sorted(by: VisionOCRService.readingOrder)
        let explicitLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if explicitLines.count == ordered.count {
            return explicitLines
        }
        let widths = ordered.map { max(0.08, $0.boundingBox.width) }
        let reflowed = reflow(text, lineWidthRatios: widths)
        let lines = reflowed.components(separatedBy: "\n")
        guard lines.count == ordered.count else { return [reflowed] }
        return lines
    }

    private static func blocksBelongToSameParagraph(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> Bool {
        let lhsBox = lhs.boundingBox
        let rhsBox = rhs.boundingBox
        let maximumHeight = max(lhsBox.height, rhsBox.height)
        let minimumHeight = max(0.0001, min(lhsBox.height, rhsBox.height))
        let heightRatio = maximumHeight / minimumHeight
        let sameLine = abs(lhsBox.midY - rhsBox.midY) <= maximumHeight * 0.55

        if sameLine {
            let horizontalGap = max(lhsBox.minX, rhsBox.minX) - min(lhsBox.maxX, rhsBox.maxX)
            return horizontalGap <= max(0.015, maximumHeight * 1.25)
        }

        let upperBox = lhsBox.midY > rhsBox.midY ? lhsBox : rhsBox
        let lowerBox = lhsBox.midY > rhsBox.midY ? rhsBox : lhsBox
        let verticalGap = upperBox.minY - lowerBox.maxY
        guard verticalGap >= -maximumHeight * 0.35,
              verticalGap <= maximumHeight * 2.5,
              heightRatio <= 1.65 else { return false }

        let overlap = max(0, min(upperBox.maxX, lowerBox.maxX) - max(upperBox.minX, lowerBox.minX))
        let overlapRatio = overlap / max(0.0001, min(upperBox.width, lowerBox.width))
        let leftAligned = abs(upperBox.minX - lowerBox.minX) <= max(0.025, maximumHeight * 1.6)
        return leftAligned || overlapRatio >= 0.30
    }

    private static func makeParagraph(from blocks: [RecognizedTextBlock]) -> RecognizedTextParagraph {
        let ordered = blocks.sorted(by: VisionOCRService.readingOrder)
        return RecognizedTextParagraph(
            id: ordered[0].id,
            text: paragraphText(from: ordered),
            boundingBox: union(of: ordered.map(\.boundingBox)),
            blocks: ordered,
            lineCount: spatialLineCount(in: ordered),
            lineWidthRatios: lineWidthRatios(in: ordered)
        )
    }

    private static func paragraphText(from blocks: [RecognizedTextBlock]) -> String {
        blocks
            .sorted(by: VisionOCRService.readingOrder)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func needsSpace(after lhs: Character?, before rhs: Character?) -> Bool {
        guard let lhs, let rhs else { return false }
        if isCJK(lhs) || isCJK(rhs) { return false }
        if ",.!?;:)]}，。！？；：、".contains(rhs) { return false }
        if "([{“‘".contains(lhs) { return false }
        return true
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                true
            default:
                false
            }
        }
    }

    private static func spatialLineCount(in blocks: [RecognizedTextBlock]) -> Int {
        guard let first = blocks.first else { return 1 }
        var count = max(1, first.text.components(separatedBy: "\n").count)
        var previous = first
        for block in blocks.dropFirst() {
            let tolerance = max(previous.boundingBox.height, block.boundingBox.height) * 0.55
            if abs(previous.boundingBox.midY - block.boundingBox.midY) > tolerance {
                count += max(1, block.text.components(separatedBy: "\n").count)
            }
            previous = block
        }
        return count
    }

    private static func lineWidthRatios(in blocks: [RecognizedTextBlock]) -> [CGFloat] {
        let lines = spatialLines(in: blocks)
        let widest = max(0.0001, lines.map(\.width).max() ?? 1)
        return lines.map { max(0.08, $0.width / widest) }
    }

    private static func spatialLines(in blocks: [RecognizedTextBlock]) -> [CGRect] {
        guard let first = blocks.first else { return [] }
        var lines = [first.boundingBox]
        for block in blocks.dropFirst() {
            let tolerance = max(lines[lines.count - 1].height, block.boundingBox.height) * 0.55
            if abs(lines[lines.count - 1].midY - block.boundingBox.midY) <= tolerance {
                lines[lines.count - 1] = lines[lines.count - 1].union(block.boundingBox)
            } else {
                lines.append(block.boundingBox)
            }
        }
        return lines
    }

    private static func balancedLines(
        tokens: [String],
        separator: String,
        lineWidthRatios: [CGFloat]
    ) -> String {
        guard !tokens.isEmpty else { return "" }
        let actualLineCount = min(lineWidthRatios.count, tokens.count)
        let widths = Array(lineWidthRatios.prefix(actualLineCount))
        let totalWidth = widths.reduce(0, +)
        let totalLength = tokens.reduce(0) { $0 + $1.count }
            + max(0, tokens.count - 1) * separator.count
        var lines: [String] = []
        var index = 0
        for lineIndex in 0..<actualLineCount {
            let linesRemaining = actualLineCount - lineIndex
            if linesRemaining == 1 {
                lines.append(tokens[index...].joined(separator: separator))
                break
            }
            let targetLength = max(1, Int(round(CGFloat(totalLength) * widths[lineIndex] / totalWidth)))
            var lineTokens: [String] = []
            var lineLength = 0
            while index < tokens.count - (linesRemaining - 1) {
                let token = tokens[index]
                let nextLength = lineLength + (lineTokens.isEmpty ? 0 : separator.count) + token.count
                if !lineTokens.isEmpty, nextLength > targetLength { break }
                lineTokens.append(token)
                lineLength = nextLength
                index += 1
            }
            lines.append(lineTokens.joined(separator: separator))
        }
        return lines.joined(separator: "\n")
    }

    private static func union(of boxes: [CGRect]) -> CGRect {
        boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    }
}
