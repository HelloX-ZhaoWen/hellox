import Foundation

public struct ProtectedTranslationText: Sendable {
    fileprivate struct Replacement: Sendable {
        let token: String
        let original: String
    }

    public let text: String
    private let replacements: [Replacement]

    fileprivate init(text: String, replacements: [Replacement]) {
        self.text = text
        self.replacements = replacements
    }

    public func restoring(in translatedText: String) -> String {
        var result = translatedText
        for replacement in replacements {
            let exactPattern = NSRegularExpression.escapedPattern(for: replacement.token)
            let flexiblePattern = replacement.token.map {
                NSRegularExpression.escapedPattern(for: String($0))
            }.joined(separator: #"\s*"#)
            for pattern in [exactPattern, flexiblePattern] {
                guard let expression = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ) else { continue }
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = expression.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement.original)
                )
            }
        }
        return result
    }
}

/// Protects content that should remain visually and textually unchanged during
/// screenshot translation. OCR can combine a logo glyph and a domain into one
/// low-confidence observation, while translation engines can transliterate
/// personal names or alter product domains unless they are replaced first.
public enum ScreenshotTranslationContentPolicy {
    /// Filters a complete OCR result while retaining layout context. Some UI
    /// metadata is only recognizable as a unit: an author name looks like
    /// ordinary prose in isolation, but belongs to the untouched chrome when
    /// it shares a row with an @handle and timestamp.
    public static func translatableContents(
        from blocks: [RecognizedTextBlock],
        imageSize: CGSize
    ) -> [RecognizedTextBlock] {
        let protectedRowIDs = socialMetadataRowIDs(in: blocks)
        return blocks.compactMap { block in
            guard !protectedRowIDs.contains(block.id) else { return nil }
            return translatableContent(from: block, imageSize: imageSize)
        }
    }

    public static func shouldPreserveOriginal(_ block: RecognizedTextBlock) -> Bool {
        let value = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        let compactCharacterCount = value.filter { !$0.isWhitespace }.count
        let isDenseLayoutLabel = block.isLayoutIsolated == true
            && compactCharacterCount >= 2
            && value.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        return fullMatch(value, pattern: standaloneAddressPattern)
            || fullMatch(value, pattern: standaloneIdentifierPattern)
            || fullMatch(value, pattern: standaloneSocialHandlePattern)
            || isNumericOrDateLike(value)
            || isEngagementMetricLike(value)
            || fullMatch(value, pattern: overflowControlPattern)
            || OCRParagraphLayout.isStandaloneSymbol(value)
            || containsUnparseableScalars(value)
            || (!isDenseLayoutLabel && isLikelyIcon(value, boundingBox: block.boundingBox))
    }

    public static func protectedText(_ text: String) -> ProtectedTranslationText {
        let source = text as NSString
        var ranges: [NSRange] = []
        ranges.append(contentsOf: captureRanges(
            in: text,
            pattern: addressPattern,
            captureGroup: 0
        ))
        ranges.append(contentsOf: captureRanges(
            in: text,
            pattern: greetingNamePattern,
            captureGroup: 1
        ))

        let uniqueRanges = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { lhs, rhs in
                if lhs.location == rhs.location { return lhs.length > rhs.length }
                return lhs.location < rhs.location
            }
            .reduce(into: [NSRange]()) { accepted, candidate in
                guard !accepted.contains(where: { NSIntersectionRange($0, candidate).length > 0 }) else {
                    return
                }
                accepted.append(candidate)
            }

        var protected = text
        var replacements: [ProtectedTranslationText.Replacement] = []
        for (index, range) in uniqueRanges.enumerated().reversed() {
            let original = source.substring(with: range)
            let token = String(format: "HXKEEP%03dTOKEN", index)
            guard let swiftRange = Range(range, in: protected) else { continue }
            protected.replaceSubrange(swiftRange, with: token)
            replacements.append(.init(token: token, original: original))
        }
        return ProtectedTranslationText(text: protected, replacements: replacements)
    }

    /// Returns only the translatable content of an OCR observation. Leading
    /// bullets, list numbers, and icon-like glyphs stay in the source image;
    /// their horizontal area is excluded from both translation and repainting.
    public static func translatableContent(
        from block: RecognizedTextBlock,
        imageSize: CGSize
    ) -> RecognizedTextBlock? {
        guard !shouldPreserveOriginal(block) else { return nil }
        let value = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentRange = translationContentRange(in: value) else { return nil }
        guard !String(value[contentRange]).isEmpty else { return nil }

        let contentBox: CGRect
        if let preciseBox = block.translatableBoundingBox {
            contentBox = preciseBox
        } else if let prefixRange = leadingMarkerRange(in: value) {
            contentBox = estimatedContentBox(
                for: block,
                text: value,
                prefixRange: prefixRange,
                imageSize: imageSize
            )
        } else {
            contentBox = block.boundingBox
        }
        return RecognizedTextBlock(
            id: block.id,
            // Retain the marker in the logical text until paragraph detection;
            // it is structural evidence that keeps adjacent list items apart.
            text: value,
            confidence: block.confidence,
            boundingBox: contentBox,
            translatableBoundingBox: contentBox,
            isLayoutIsolated: block.isLayoutIsolated
        )
    }

    /// Removes structural markers only after paragraph detection. The cloud
    /// service receives content, while bullets/icons remain untouched pixels.
    public static func textForTranslation(_ text: String) -> String {
        let contentLines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            guard let range = translationContentRange(in: value) else { return nil }
            return String(value[range])
        }
        return OCRParagraphLayout.continuousText(contentLines.joined(separator: "\n"))
    }

    static func translationContentRange(in text: String) -> Range<String.Index>? {
        guard let erasableRange = erasableContentRange(in: text) else { return nil }
        let lowerBound = erasableRange.lowerBound
        var upperBound = erasableRange.upperBound
        if let caret = text.range(
            of: trailingCaretPattern,
            options: .regularExpression,
            range: lowerBound..<upperBound
        ) {
            upperBound = caret.lowerBound
        }
        if let control = text.range(
            of: trailingControlPattern,
            options: .regularExpression,
            range: lowerBound..<upperBound
        ) {
            upperBound = control.lowerBound
        }
        while lowerBound < upperBound {
            let previous = text.index(before: upperBound)
            guard text[previous].isWhitespace else { break }
            upperBound = previous
        }
        return lowerBound < upperBound ? lowerBound..<upperBound : nil
    }

    static func erasableContentRange(in text: String) -> Range<String.Index>? {
        var lowerBound = text.startIndex
        var upperBound = text.endIndex
        if let marker = leadingMarkerRange(in: text) { lowerBound = marker.upperBound }
        while lowerBound < upperBound, text[lowerBound].isWhitespace {
            lowerBound = text.index(after: lowerBound)
        }
        while lowerBound < upperBound {
            let previous = text.index(before: upperBound)
            guard text[previous].isWhitespace else { break }
            upperBound = previous
        }
        return lowerBound < upperBound ? lowerBound..<upperBound : nil
    }

    private static func estimatedContentBox(
        for block: RecognizedTextBlock,
        text: String,
        prefixRange: Range<String.Index>,
        imageSize: CGSize
    ) -> CGRect {
        let prefix = String(text[prefixRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineHeightPixels = block.boundingBox.height * max(1, imageSize.height)
        let shiftPixels: CGFloat
        if prefix.range(of: #"^\d{1,3}[.)、）．]$"#, options: .regularExpression) != nil {
            let digitCount = prefix.prefix { $0.isNumber }.count
            shiftPixels = lineHeightPixels * (0.55 * CGFloat(digitCount) + 0.55)
        } else {
            shiftPixels = lineHeightPixels * 1.15
        }
        let horizontalShift = min(
            block.boundingBox.width * 0.24,
            (shiftPixels + 1) / max(1, imageSize.width)
        )
        return CGRect(
            x: block.boundingBox.minX + horizontalShift,
            y: block.boundingBox.minY,
            width: max(0.0001, block.boundingBox.width - horizontalShift),
            height: block.boundingBox.height
        )
    }

    private static let addressPattern = #"(?i)(?:https?://|www\.)[^\s]+|[\p{L}\p{N}_%+.-]+@[\p{L}\p{N}.-]+\.[A-Za-z]{2,24}|(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,24}"#
    private static let standaloneAddressPattern = #"(?i)^\s*[@#©®™]?\s*(?:(?:https?://|www\.)[^\s]+|[\p{L}\p{N}_%+.-]+@[\p{L}\p{N}.-]+\.[A-Za-z]{2,24}|(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,24})\s*$"#
    private static let standaloneIdentifierPattern = #"^\s*[A-Z0-9]{1,8}(?:[-_/][A-Z0-9]{1,8})+\s*$"#
    private static let standaloneSocialHandlePattern = #"^\s*@[\p{L}\p{N}_.-]{1,64}(?:\s*[·•・]\s*.+)?\s*$"#
    private static let overflowControlPattern = #"^\s*[\p{L}\p{N}]{0,3}\s*(?:…|\.{2,})\s*$"#
    private static let greetingNamePattern = #"(?i)^\s*(?:hi|hello|hey|dear|good\s+morning|good\s+afternoon|good\s+evening)\s+([\p{L}][\p{L}'’.-]*(?:\s+[\p{L}][\p{L}'’.-]*){0,4})(?=\s*[,!:，：！])"#
    private static let leadingSymbolPattern = #"^\s*[^\p{L}\p{N}\s]{1,6}\s+"#
    private static let leadingListPattern = #"^\s*(?:[\(（]\d{1,3}[\)）]|\d{1,3}[.)、）．]|[A-Za-z][.)）．])\s+"#
    private static let leadingControlPattern = #"^\s*(?:0|O|o|V|v|C|c|く|‹|<|\*|○|◯|●|◉|☐|☑|☒|✓|✔|✕|✖|×)\s+"#
    private static let trailingCaretPattern = #"\s+[|｜¦┃│❘丨]+\s*$"#
    private static let trailingControlPattern = #"\s+(?:[=<>⌃⌄↑↓↕↔⇅⇵▲▼△▽⋮⋯]+|[©®™ⓘ]\s*[A-Za-z]?)\s*$"#

    private static func leadingMarkerRange(in text: String) -> Range<String.Index>? {
        for pattern in [leadingSymbolPattern, leadingListPattern, leadingControlPattern] {
            if let range = text.range(of: pattern, options: .regularExpression) { return range }
        }
        return nil
    }

    private static func containsUnparseableScalars(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 0xFFFD
                || (CharacterSet.controlCharacters.contains(scalar)
                    && scalar.value != 0x09
                    && scalar.value != 0x0A
                    && scalar.value != 0x0D)
                || (0xE000...0xF8FF).contains(scalar.value)
        }
    }

    private static func isNumericOrDateLike(_ text: String) -> Bool {
        guard let range = translationContentRange(in: text) else { return false }
        let scalars = text[range].unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard scalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
            return false
        }
        return scalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }

    /// Social engagement rows are frequently recognized as a short fake word
    /// for the icon followed by a count (for example, "it 405K" or
    /// "O 5.1K"). Translating and repainting these observations destroys the
    /// original icon, so keep the entire compact metric untouched.
    private static func isEngagementMetricLike(_ text: String) -> Bool {
        fullMatch(
            text,
            pattern: #"(?i)^\s*(?:\S{1,3}\s+)?\d+(?:[.,]\d+)?\s*[KMB]?\s*[I|｜]?\s*$"#
        )
    }

    private static func socialMetadataRowIDs(
        in blocks: [RecognizedTextBlock]
    ) -> Set<UUID> {
        let anchors = blocks.filter {
            fullMatch(
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                pattern: standaloneSocialHandlePattern
            )
        }
        guard !anchors.isEmpty else { return [] }

        return Set(blocks.compactMap { block -> UUID? in
            let sharesMetadataRow = anchors.contains { anchor in
                let height = max(anchor.boundingBox.height, block.boundingBox.height)
                guard abs(anchor.boundingBox.midY - block.boundingBox.midY) <= height * 0.55 else {
                    return false
                }
                if block.id == anchor.id { return true }
                let horizontalGap = max(
                    anchor.boundingBox.minX,
                    block.boundingBox.minX
                ) - min(
                    anchor.boundingBox.maxX,
                    block.boundingBox.maxX
                )
                return horizontalGap <= height
            }
            return sharesMetadataRow ? block.id : nil
        })
    }

    private static func isLikelyIcon(_ text: String, boundingBox: CGRect) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        guard !characters.isEmpty, characters.count <= 3 else { return false }
        let aspectRatio = boundingBox.width / max(0.0001, boundingBox.height)
        if characters.count == 1 { return aspectRatio <= 2.2 }
        if characters.count == 2 { return aspectRatio <= 1.7 }
        return aspectRatio <= 1.3
    }

    private static func fullMatch(_ text: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ) else { return false }
        return match.range.location == 0 && match.range.length == (text as NSString).length
    }

    private static func captureRanges(
        in text: String,
        pattern: String,
        captureGroup: Int
    ) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard captureGroup < match.numberOfRanges else { return nil }
            let value = match.range(at: captureGroup)
            return value.location == NSNotFound ? nil : value
        }
    }
}

/// Repairs a small set of context-sensitive UI terms that generic and offline
/// translation engines routinely interpret as directions. The transformation
/// is source-gated so ordinary translated prose containing the same characters
/// is never rewritten.
public enum ScreenshotTranslationOutputNormalizer {
    public static func normalize(
        _ translatedText: String,
        sourceText: String,
        targetLanguageIdentifier: String,
        sourceContext: [String] = []
    ) -> String {
        let source = ScreenshotTranslationContentPolicy.textForTranslation(sourceText)
        let target = targetLanguageIdentifier.lowercased()
        guard target == "zh" || target.hasPrefix("zh-") else { return translatedText }
        let traditional = target.contains("hant") || target.contains("tw") || target.contains("hk")
        // Standalone words such as "Sent" and "More" are ambiguous to text
        // translators. Only apply mailbox terminology when the surrounding
        // independent labels establish that context; never rewrite prose.
        let context = Set(sourceContext.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if context.contains("inbox"),
           !context.isDisjoint(with: ["starred", "snoozed"]),
           !context.isDisjoint(with: ["sent", "drafts"]) {
            let terms = traditional
                ? ["inbox": "收件匣", "starred": "已加星號", "snoozed": "已延後",
                   "sent": "寄件備份", "drafts": "草稿", "categories": "類別", "more": "更多"]
                : ["inbox": "收件箱", "starred": "已加星标", "snoozed": "已延后",
                   "sent": "已发送", "drafts": "草稿", "categories": "类别", "more": "更多"]
            if let label = terms[source.lowercased()] { return label }
        }
        guard source.range(
            of: #"(?i)\b(?:left|remaining)\s+\d{1,3}:\d{2}(?::\d{2})?\b"#,
            options: .regularExpression
        ) != nil else { return translatedText }

        let remaining = traditional ? "剩餘 " : "剩余 "
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:向\s*)?左(?:侧|側)?\s*[:：]?\s*(?=\d{1,3}:\d{2}(?::\d{2})?)"#
        ) else { return translatedText }
        let range = NSRange(translatedText.startIndex..<translatedText.endIndex, in: translatedText)
        return expression.stringByReplacingMatches(
            in: translatedText,
            range: range,
            withTemplate: remaining
        )
    }
}
