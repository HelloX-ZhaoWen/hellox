import CoreGraphics
import Foundation

public struct RecognizedTextParagraph: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let boundingBox: CGRect
    public let blocks: [RecognizedTextBlock]

    public init(
        id: UUID,
        text: String,
        boundingBox: CGRect,
        blocks: [RecognizedTextBlock]
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.blocks = blocks
    }
}

public enum OCRParagraphLayout {
    /// Produces OCR display/copy text using recovered natural paragraphs.
    /// Visual wrapping inside one semantic paragraph is removed, while
    /// headings, lists, completed sentences, columns, and isolated symbols
    /// retain explicit line boundaries.
    public static func semanticJoin(_ blocks: [RecognizedTextBlock]) -> String {
        let paragraphs = paragraphs(from: blocks)
        let consumedIDs = Set(paragraphs.flatMap(\.blocks).map(\.id))
        var units: [(box: CGRect, text: String)] = paragraphs.map {
            ($0.boundingBox, semanticText($0.text))
        }
        units.append(contentsOf: blocks.compactMap { block in
            guard !consumedIDs.contains(block.id) else { return nil }
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (block.boundingBox, text)
        })
        return units.sorted { lhs, rhs in
            let tolerance = max(lhs.box.height, rhs.box.height) * 0.55
            if abs(lhs.box.midY - rhs.box.midY) > tolerance {
                return lhs.box.midY > rhs.box.midY
            }
            return lhs.box.minX < rhs.box.minX
        }
        .map(\.text)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    public static func paragraphs(from blocks: [RecognizedTextBlock]) -> [RecognizedTextParagraph] {
        let ordered = blocks
            .filter {
                let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && !isStandaloneSymbol(text)
            }
            .sorted(by: VisionOCRService.readingOrder)
        guard !ordered.isEmpty else { return [] }

        // Keep the spatial detector and semantic correction pass independent so
        // callers can test each decision. The old union-find implementation was
        // too eager around columns and could merge unrelated UI labels.
        let spatialGroups = ImageParagraphDetector.detect(from: ordered)
        let correctedGroups = TextParagraphCorrector.correct(spatialGroups)
        return correctedGroups.map(makeParagraph).sorted { lhs, rhs in
            let tolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.12
            if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > tolerance {
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    /// Reflows text using caller-provided widths.
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
        // Fewer words than lines. Only character-split when the text has no
        // word boundaries (e.g. CJK); otherwise keep whole words so a
        // translation is never broken mid-word.
        if words.count == 1, words[0] == normalized {
            return balancedLines(tokens: normalized.map(String.init), separator: "", lineWidthRatios: widths)
        }
        return balancedLines(tokens: words, separator: " ", lineWidthRatios: widths)
    }

    /// Returns true when a block is made entirely from standalone symbols,
    /// punctuation, emoji-like characters, combining marks, or private-use
    /// glyphs. Text containing a letter or number is intentionally excluded so
    /// URLs, amounts, identifiers, and code remain translatable.
    public static func isStandaloneSymbol(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard !scalars.isEmpty else { return false }

        let isEmojiSequence = scalars.contains {
            $0.properties.isEmojiPresentation
                || $0.value == 0x200D
                || $0.value == 0xFE0F
                || $0.value == 0x20E3
        }
        if isEmojiSequence {
            let containsOrdinaryLetter = scalars.contains {
                CharacterSet.letters.contains($0)
                    && !$0.properties.isEmoji
                    && $0.value != 0x200D
                    && $0.value != 0xFE0F
                    && $0.value != 0x20E3
            }
            if !containsOrdinaryLetter { return true }
        }

        var hasSymbol = false
        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) ||
                CharacterSet.letters.contains(scalar) ||
                CharacterSet.decimalDigits.contains(scalar) {
                return false
            }
            if CharacterSet.symbols.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar) ||
                CharacterSet.nonBaseCharacters.contains(scalar) ||
                (0xE000...0xF8FF).contains(scalar.value) {
                hasSymbol = true
                continue
            }
            return false
        }
        return hasSymbol
    }

    /// Removes OCR line breaks that are only visual wrapping hints while
    /// retaining explicit list-like structure.
    public static func semanticText(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return lines.first ?? "" }

        var result = ""
        for line in lines {
            if result.isEmpty {
                result = line
                continue
            }
            if isStructuredLine(line) {
                result.append("\n")
            } else if needsSpace(after: result.last, before: line.first) {
                result.append(" ")
            }
            result.append(line)
        }
        return result
    }

    /// Removes all visual line wrapping from one semantic paragraph. Natural
    /// layout is decided later from the paragraph rectangle, so cloud or OCR
    /// line breaks can never force an early break or strand the final words.
    public static func continuousText(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result = ""
        for line in lines {
            if needsSpace(after: result.last, before: line.first) { result.append(" ") }
            result.append(line)
        }
        return result
    }

    private static func makeParagraph(from blocks: [RecognizedTextBlock]) -> RecognizedTextParagraph {
        let ordered = blocks.sorted(by: VisionOCRService.readingOrder)
        return RecognizedTextParagraph(
            id: ordered[0].id,
            text: paragraphText(from: ordered),
            boundingBox: union(of: ordered.map(\.boundingBox)),
            blocks: ordered
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

    private static func isStructuredLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, "-•*·".contains(first) { return true }
        return trimmed.range(of: "^\\d+[.)]\\s+", options: .regularExpression) != nil
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
