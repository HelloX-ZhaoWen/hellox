import CoreGraphics
import Foundation

public struct SelectedTextLayoutToken: Equatable, Sendable {
    public let range: NSRange
    public let boundingBox: CGRect
    /// AX line number for the token when the source element exposes
    /// kAXLineForIndex. Unlike screen-space bounds, this is stable across
    /// displays with different origins and backing scales.
    public let visualLineIndex: Int?
    /// Identifies the AX element that owns visualLineIndex. Line numbers from
    /// different accessibility elements are not directly comparable.
    public let visualLineContext: Int?

    public init(
        range: NSRange,
        boundingBox: CGRect,
        visualLineIndex: Int? = nil,
        visualLineContext: Int? = nil
    ) {
        self.range = range
        self.boundingBox = boundingBox
        self.visualLineIndex = visualLineIndex
        self.visualLineContext = visualLineContext
    }
}

/// Reconstructs visual soft-wraps omitted by AXSelectedText. Explicit source
/// newlines always win; AX line numbers are preferred over screen-space
/// geometry when available.
public enum SelectedTextLayoutReconstructor {
    public static func reconstruct(
        text: String,
        tokens: [SelectedTextLayoutToken]
    ) -> String {
        let source = text as NSString
        let ordered = tokens
            .filter { NSMaxRange($0.range) <= source.length && $0.range.length > 0 }
            .sorted { $0.range.location < $1.range.location }
        guard ordered.count > 1 else { return text }

        let lineAdvances = zip(ordered, ordered.dropFirst()).compactMap { lhs, rhs -> CGFloat? in
            let distance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            let height = max(lhs.boundingBox.height, rhs.boundingBox.height)
            return distance > height * 0.62 ? distance : nil
        }
        let typicalLineAdvance: CGFloat? = {
            guard !lineAdvances.isEmpty else { return nil }
            let sorted = lineAdvances.sorted()
            // Paragraph gaps live at the high end. The lower median remains a
            // stable normal-line estimate even in a short two-paragraph sample.
            return sorted[(sorted.count - 1) / 2]
        }()

        var output = ""
        var cursor = 0
        var previous: SelectedTextLayoutToken?
        for token in ordered {
            guard token.range.location >= cursor else { continue }
            let separatorRange = NSRange(location: cursor, length: token.range.location - cursor)
            var separator = source.substring(with: separatorRange)
            if let previous,
               let visualBreak = visualBreak(
                   previous,
                   token,
                   typicalLineAdvance: typicalLineAdvance
               ) {
                let newlineCount = separator.filter(\.isNewline).count
                switch visualBreak {
                case .line where newlineCount == 0:
                    separator = "\n"
                case .paragraph where newlineCount < 2:
                    separator = paragraphSeparator(preservingIndentFrom: separator)
                default:
                    break
                }
            }
            output += separator
            output += source.substring(with: token.range)
            cursor = NSMaxRange(token.range)
            previous = token
        }
        if cursor < source.length {
            output += source.substring(from: cursor)
        }
        return output
    }

    private enum VisualBreak {
        case line
        case paragraph
    }

    private static func visualBreak(
        _ lhs: SelectedTextLayoutToken,
        _ rhs: SelectedTextLayoutToken,
        typicalLineAdvance: CGFloat?
    ) -> VisualBreak? {
        if let lhsContext = lhs.visualLineContext,
           let rhsContext = rhs.visualLineContext,
           lhsContext == rhsContext,
           let lhsLine = lhs.visualLineIndex,
           let rhsLine = rhs.visualLineIndex {
            // These indices come from the same AX element, so they are the
            // authoritative layout signal even when secondary-display bounds
            // use a different origin or backing scale.
            let advance = abs(rhsLine - lhsLine)
            if advance == 0 { return nil }
            return advance > 1 ? .paragraph : .line
        }
        return geometryBreak(
            lhs.boundingBox,
            rhs.boundingBox,
            typicalLineAdvance: typicalLineAdvance
        )
    }

    private static func geometryBreak(
        _ lhs: CGRect,
        _ rhs: CGRect,
        typicalLineAdvance: CGFloat?
    ) -> VisualBreak? {
        guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return nil }
        let height = max(lhs.height, rhs.height)
        let distance = abs(lhs.midY - rhs.midY)
        guard distance > height * 0.62 else { return nil }
        let paragraphThreshold = max(
            height * 2.15,
            (typicalLineAdvance ?? distance) * 1.45
        )
        return distance > paragraphThreshold ? .paragraph : .line
    }

    private static func paragraphSeparator(preservingIndentFrom separator: String) -> String {
        let trailingIndent: String
        if separator.contains(where: \.isNewline) {
            trailingIndent = separator
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .last
                .map(String.init)?
                .filter { $0 == " " || $0 == "\t" } ?? ""
        } else {
            trailingIndent = ""
        }
        return "\n\n" + trailingIndent
    }
}
