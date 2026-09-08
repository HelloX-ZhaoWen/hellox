import Foundation

/// A length-bounded translation request containing multiple OCR paragraphs.
/// Paragraph boundary tokens let a text-only provider return one response that
/// can still be mapped back to the original screenshot regions.
public struct ScreenshotTranslationBatch: Sendable {
    public struct Paragraph: Sendable {
        public let id: UUID
        public let protectedText: ProtectedTranslationText

        fileprivate init(id: UUID, protectedText: ProtectedTranslationText) {
            self.id = id
            self.protectedText = protectedText
        }
    }

    public let paragraphs: [Paragraph]
    public let text: String

    fileprivate init(paragraphs: [Paragraph], text: String) {
        self.paragraphs = paragraphs
        self.text = text
    }
}

public enum ScreenshotTranslationBatchCodec {
    /// All currently supported cloud translation providers accept at least
    /// 5,000 characters per request.
    public static let defaultMaximumCharacterCount = 5_000

    public static func batches(
        for paragraphs: [(id: UUID, text: String)],
        maximumCharacterCount: Int = defaultMaximumCharacterCount
    ) throws -> [ScreenshotTranslationBatch] {
        guard maximumCharacterCount > 0 else {
            throw HelloXError.invalidConfiguration("翻译批次长度必须大于 0")
        }

        let protectedParagraphs = paragraphs.map {
            ScreenshotTranslationBatch.Paragraph(
                id: $0.id,
                protectedText: ScreenshotTranslationContentPolicy.protectedText($0.text)
            )
        }
        var result: [ScreenshotTranslationBatch] = []
        var current: [ScreenshotTranslationBatch.Paragraph] = []

        for paragraph in protectedParagraphs {
            let candidate = current + [paragraph]
            let candidateText = encodedText(for: candidate)
            if candidateText.count <= maximumCharacterCount {
                current = candidate
                continue
            }

            guard !current.isEmpty else {
                throw HelloXError.invalidConfiguration("截图中的单个段落超过云端翻译长度限制")
            }
            result.append(.init(paragraphs: current, text: encodedText(for: current)))
            current = [paragraph]
            guard encodedText(for: current).count <= maximumCharacterCount else {
                throw HelloXError.invalidConfiguration("截图中的单个段落超过云端翻译长度限制")
            }
        }

        if !current.isEmpty {
            result.append(.init(paragraphs: current, text: encodedText(for: current)))
        }
        return result
    }

    public static func translations(
        from translatedText: String,
        for batch: ScreenshotTranslationBatch
    ) throws -> [UUID: String] {
        guard !batch.paragraphs.isEmpty else { return [:] }
        let pieces = try split(translatedText, paragraphCount: batch.paragraphs.count)
        guard pieces.count == batch.paragraphs.count else { throw HelloXError.invalidResponse }

        var translations: [UUID: String] = [:]
        for (paragraph, piece) in zip(batch.paragraphs, pieces) {
            let restored = paragraph.protectedText.restoring(in: piece)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !restored.isEmpty else { throw HelloXError.invalidResponse }
            translations[paragraph.id] = restored
        }
        return translations
    }

    private static func encodedText(for paragraphs: [ScreenshotTranslationBatch.Paragraph]) -> String {
        var parts: [String] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { parts.append(boundaryToken(at: index - 1)) }
            parts.append(paragraph.protectedText.text)
        }
        return parts.joined(separator: "\n")
    }

    private static func split(_ text: String, paragraphCount: Int) throws -> [String] {
        guard paragraphCount > 1 else { return [text] }
        var pieces: [String] = []
        var lowerBound = text.startIndex

        for index in 0..<(paragraphCount - 1) {
            // Machine translation engines occasionally normalize ASCII
            // brackets or insert spaces. Match the unique numeric marker while
            // requiring the rest of its line to contain punctuation only.
            let digits = boundaryDigits(at: index).map {
                NSRegularExpression.escapedPattern(for: String($0))
            }.joined(separator: #"[\t ]*"#)
            let pattern = #"(?m)^[^\p{L}\p{N}\r\n]*"#
                + digits
                + #"[^\p{L}\p{N}\r\n]*(?:\r?\n|$)"#
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                throw HelloXError.invalidResponse
            }
            let searchRange = NSRange(lowerBound..<text.endIndex, in: text)
            let match = expression.firstMatch(in: text, range: searchRange)
            guard let match, let range = Range(match.range, in: text) else {
                throw HelloXError.invalidResponse
            }
            pieces.append(String(text[lowerBound..<range.lowerBound]))
            lowerBound = range.upperBound
        }
        pieces.append(String(text[lowerBound...]))
        return pieces
    }

    private static func boundaryToken(at index: Int) -> String {
        "[[[\(boundaryDigits(at: index))]]]"
    }

    private static func boundaryDigits(at index: Int) -> String {
        String(format: "97531%03d", index)
    }
}
