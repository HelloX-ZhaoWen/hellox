import Foundation

/// Captures the explicit layout of selected text without treating every visual
/// line as an unrelated translation request. Each semantic unit is translated
/// with full context, then reflowed to the source line-count/width rhythm.
public struct TextLayoutTemplate: Equatable, Sendable {
    public struct Unit: Equatable, Sendable {
        public let sourceText: String
        fileprivate let sourceLineRange: Range<Int>
        fileprivate let lineWidthRatios: [CGFloat]
        fileprivate let lineIndents: [String]
    }

    public let units: [Unit]
    private let sourceLines: [String]

    public init(sourceText: String) {
        let normalized = sourceText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        sourceLines = normalized.components(separatedBy: "\n")
        units = Self.makeUnits(from: sourceLines)
    }

    public func render(translations: [String]) -> String? {
        guard translations.count == units.count else { return nil }
        var renderedByStart: [Int: [String]] = [:]
        for (unit, translation) in zip(units, translations) {
            let semantic = OCRParagraphLayout.semanticText(translation)
            guard !semantic.isEmpty else { return nil }
            let reflowed = Self.matchLineCount(
                OCRParagraphLayout.reflow(
                semantic,
                lineWidthRatios: unit.lineWidthRatios
                ),
                desiredCount: unit.lineWidthRatios.count,
                widthRatios: unit.lineWidthRatios
            )
            let indented = reflowed.enumerated().map { index, line in
                let indent = unit.lineIndents[min(index, unit.lineIndents.count - 1)]
                return indent + line
            }
            renderedByStart[unit.sourceLineRange.lowerBound] = indented
        }

        var output: [String] = []
        var lineIndex = 0
        while lineIndex < sourceLines.count {
            if sourceLines[lineIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                output.append("")
                lineIndex += 1
                continue
            }
            guard let unit = units.first(where: { $0.sourceLineRange.lowerBound == lineIndex }),
                  let rendered = renderedByStart[lineIndex] else { return nil }
            output.append(contentsOf: rendered)
            lineIndex = unit.sourceLineRange.upperBound
        }
        return output.joined(separator: "\n")
    }

    private static func makeUnits(from lines: [String]) -> [Unit] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in lines.indices {
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if let start { ranges.append(start..<index) }
                start = nil
                continue
            }
            if let currentStart = start,
               beginsNewUnit(previous: lines[index - 1], current: lines[index]) {
                ranges.append(currentStart..<index)
                start = index
            } else if start == nil {
                start = index
            }
        }
        if let start { ranges.append(start..<lines.count) }

        return ranges.compactMap { range in
            let values = range.map { lines[$0] }
            let trimmed = values.map { $0.trimmingCharacters(in: .whitespaces) }
            let source = OCRParagraphLayout.semanticText(trimmed.joined(separator: "\n"))
            guard !source.isEmpty else { return nil }
            let widths = trimmed.map { max(1, $0.count) }
            let maximumWidth = CGFloat(widths.max() ?? 1)
            return Unit(
                sourceText: source,
                sourceLineRange: range,
                lineWidthRatios: widths.map { CGFloat($0) / maximumWidth },
                lineIndents: values.map(leadingWhitespace)
            )
        }
    }

    private static func beginsNewUnit(previous: String, current: String) -> Bool {
        let lhs = previous.trimmingCharacters(in: .whitespaces)
        let rhs = current.trimmingCharacters(in: .whitespaces)
        if OCRSemanticContinuity.isSalutation(lhs) { return true }
        if isStructuredLine(lhs) || isStructuredLine(rhs) { return true }
        if isHeading(lhs) || isHeading(rhs) { return true }
        if !OCRSemanticContinuity.isContinuous(previous: lhs, current: rhs) { return true }
        return leadingWhitespace(previous) != leadingWhitespace(current)
            && (!leadingWhitespace(previous).isEmpty || !leadingWhitespace(current).isEmpty)
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

    private static func leadingWhitespace(_ text: String) -> String {
        String(text.prefix { $0 == " " || $0 == "\t" })
    }

    private static func matchLineCount(
        _ text: String,
        desiredCount: Int,
        widthRatios: [CGFloat]
    ) -> [String] {
        var lines = text.components(separatedBy: "\n")
        guard desiredCount > 1 else { return [OCRParagraphLayout.semanticText(text)] }
        if lines.count == desiredCount { return lines }

        let normalized = OCRParagraphLayout.semanticText(text)
        let characters = Array(normalized)
        guard characters.count >= desiredCount else {
            lines = characters.map(String.init)
            lines.append(contentsOf: repeatElement("", count: desiredCount - lines.count))
            return lines
        }

        let weights = Array(widthRatios.prefix(desiredCount)).map { max(0.08, $0) }
        let totalWeight = weights.reduce(0, +)
        var result: [String] = []
        var cursor = 0
        for index in 0..<desiredCount {
            let remainingLines = desiredCount - index
            let remainingCharacters = characters.count - cursor
            let count: Int
            if remainingLines == 1 {
                count = remainingCharacters
            } else {
                let target = Int(round(CGFloat(characters.count) * weights[index] / totalWeight))
                count = min(
                    max(1, target),
                    remainingCharacters - (remainingLines - 1)
                )
            }
            result.append(String(characters[cursor..<(cursor + count)]))
            cursor += count
        }
        return result
    }
}
