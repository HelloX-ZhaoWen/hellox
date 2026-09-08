@preconcurrency import ApplicationServices
import AppKit
import Foundation
import NaturalLanguage

public enum SelectedTextAcquisition: String, Sendable {
    case accessibility
    case temporaryClipboard
}

public struct SelectedTextContext: Sendable, Equatable {
    public let text: String
    public let processID: pid_t
    public let applicationName: String
    public let acquisition: SelectedTextAcquisition
    /// Global CoreGraphics coordinates (top-left screen origin) when available.
    public let anchorRect: CGRect?
    public let detectedLanguage: SupportedLanguage?

    public init(
        text: String,
        processID: pid_t,
        applicationName: String,
        acquisition: SelectedTextAcquisition,
        anchorRect: CGRect?,
        detectedLanguage: SupportedLanguage?
    ) {
        self.text = text
        self.processID = processID
        self.applicationName = applicationName
        self.acquisition = acquisition
        self.anchorRect = anchorRect
        self.detectedLanguage = detectedLanguage
    }
}

public enum SelectedTextError: LocalizedError, Sendable {
    case accessibilityDenied
    case secureInput
    case clipboardFallbackRequired
    case noSelection
    case targetUnavailable
    case copyBlocked
    case textTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied: "划词翻译需要辅助功能权限。"
        case .secureInput: "出于安全考虑，不能读取密码或安全输入框。"
        case .clipboardFallbackRequired: "为保留原文的段落和换行，需要临时使用剪贴板。"
        case .noSelection: "没有读取到选中文字。"
        case .targetUnavailable: "选中文字所在的应用已经退出或不可用。"
        case .copyBlocked: "目标应用没有响应复制操作，请重新选中文字后重试。"
        case .textTooLong(let limit): "选中文字超过 \(limit) 字符，请缩小选择范围。"
        }
    }
}

@MainActor
public final class SystemTextSelectionService {
    public nonisolated static let clipboardSentinelPrefix = "hellox-selection-"

    private let maximumCharacters: Int
    private let clipboardFallbackCoordinator = ClipboardFallbackCoordinator()

    public init(maximumCharacters: Int = 10_000) {
        self.maximumCharacters = maximumCharacters
    }

    public func readSelection(processID: pid_t, allowClipboardFallback: Bool) async throws -> SelectedTextContext {
        guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated else {
            throw SelectedTextError.targetUnavailable
        }
        let applicationName = application.localizedName ?? "未知应用"
        var accessibilityContext: SelectedTextContext?
        if AXIsProcessTrusted() {
            do {
                accessibilityContext = try accessibilitySelection(
                    processID: processID,
                    applicationName: applicationName
                )
            } catch SelectedTextError.noSelection {
                // Some browser-backed views report an empty AX selection even
                // though Cmd-C can still provide the user's selected text.
                guard allowClipboardFallback else { throw SelectedTextError.noSelection }
            }
        } else if !allowClipboardFallback {
            throw SelectedTextError.accessibilityDenied
        }

        // AXSelectedText is not a stable layout source for browser and PDF
        // content: it may omit semantic newlines or include accessibility-only
        // labels. Once clipboard access is allowed, always use Cmd-C text as the
        // canonical source so the first request and every reuse are identical.
        guard allowClipboardFallback else { throw SelectedTextError.clipboardFallbackRequired }
        do {
            let text = normalizeLineEndings(try await clipboardSelection(processID: processID))
            // Descendant geometry is still useful for positioning the window,
            // but must never replace the clipboard's semantic text layout.
            let recoveredAnchor = accessibilityContext?.anchorRect
                ?? accessibilityDescendantLayout(text: text, processID: processID)?.anchorRect
            return try validate(SelectedTextContext(
                text: text,
                processID: processID,
                applicationName: applicationName,
                acquisition: .temporaryClipboard,
                anchorRect: recoveredAnchor,
                detectedLanguage: detectLanguage(text)
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SelectedTextError {
            switch error {
            case .copyBlocked, .noSelection:
                guard let accessibilityContext else { throw error }
                return try validate(normalizedAccessibilityContext(accessibilityContext))
            default:
                throw error
            }
        }
    }

    private func normalizedAccessibilityContext(_ context: SelectedTextContext) -> SelectedTextContext {
        let text = normalizeLineEndings(context.text)
        return SelectedTextContext(
            text: text,
            processID: context.processID,
            applicationName: context.applicationName,
            acquisition: .accessibility,
            anchorRect: context.anchorRect,
            detectedLanguage: detectLanguage(text)
        )
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func accessibilitySelection(processID: pid_t, applicationName: String) throws -> SelectedTextContext? {
        let app = AXUIElementCreateApplication(processID)
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) != .success {
            let system = AXUIElementCreateSystemWide()
            _ = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        }
        guard let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)

        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, "AXSubrole" as CFString, &subroleValue)
        if let subrole = subroleValue as? String, subrole.localizedCaseInsensitiveContains("secure") {
            throw SelectedTextError.secureInput
        }

        var anchor: CGRect?
        var rangeValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue)

        var selectedValue: CFTypeRef?
        let selectedTextStatus = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        var text = selectedValue as? String
        if (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), let rangeValue {
            var rangeTextValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                focused,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &rangeTextValue
            ) == .success {
                text = rangeTextValue as? String
            }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A supported selected-text attribute with an empty value confirms
            // that the user has no active selection. Do not fall back to Cmd-C.
            if selectedTextStatus == .success { throw SelectedTextError.noSelection }
            return nil
        }

        if let rangeValue {
            var boundsValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                focused,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &boundsValue
            ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() {
                let axValue = unsafeDowncast(boundsValue, to: AXValue.self)
                var rect = CGRect.zero
                if AXValueGetValue(axValue, .cgRect, &rect) { anchor = rect }
            }
        }

        let rangeLayoutText = rangeValue.flatMap {
            textWithVisualLineBreaks(text, focusedElement: focused, rangeValue: $0)
        }
        let descendantLayout = rangeLayoutText == nil
            ? accessibilityDescendantLayout(text: text, roots: [focused, app])
            : nil
        let layoutText = rangeLayoutText ?? descendantLayout?.text ?? text
        if anchor == nil { anchor = descendantLayout?.anchorRect }
        return SelectedTextContext(
            text: layoutText,
            processID: processID,
            applicationName: applicationName,
            acquisition: .accessibility,
            anchorRect: anchor,
            detectedLanguage: detectLanguage(text)
        )
    }

    private func textWithVisualLineBreaks(
        _ text: String,
        focusedElement: AXUIElement,
        rangeValue: CFTypeRef
    ) -> String? {
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let selectedRangeValue = unsafeDowncast(rangeValue, to: AXValue.self)
        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange),
              selectedRange.location >= 0,
              selectedRange.length > 0 else { return nil }

        let source = text as NSString
        guard source.length == selectedRange.length else { return nil }
        let expression = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+|[^\\s]")
        let matches = expression?.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ) ?? []
        // AX parameterized bounds calls are synchronous. Keep normal selections
        // precise without stalling on entire documents.
        guard matches.count > 1, matches.count <= 1_200 else { return nil }

        var tokens: [SelectedTextLayoutToken] = []
        tokens.reserveCapacity(matches.count)
        for match in matches {
            var globalRange = CFRange(
                location: selectedRange.location + match.range.location,
                length: match.range.length
            )
            guard let parameter = AXValueCreate(.cfRange, &globalRange) else { continue }
            var boundsValue: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                focusedElement,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                parameter,
                &boundsValue
            ) == .success,
            let boundsValue,
            CFGetTypeID(boundsValue) == AXValueGetTypeID() else { continue }
            let value = unsafeDowncast(boundsValue, to: AXValue.self)
            var rect = CGRect.zero
            guard AXValueGetValue(value, .cgRect, &rect), rect.width > 0, rect.height > 0 else { continue }
            tokens.append(SelectedTextLayoutToken(
                range: match.range,
                boundingBox: rect,
                visualLineIndex: lineIndex(
                    forCharacterAt: globalRange.location,
                    in: focusedElement
                ),
                visualLineContext: 0
            ))
        }
        guard tokens.count >= 2,
              tokens.count * 4 >= matches.count * 3 else { return nil }
        return SelectedTextLayoutReconstructor.reconstruct(text: text, tokens: tokens)
    }

    private struct RecoveredAccessibilityLayout {
        let text: String
        let anchorRect: CGRect
    }

    private struct TextToken {
        let value: String
        let range: NSRange
    }

    private struct ElementTextMatch {
        let element: AXUIElement
        let selectedTokenRange: Range<Int>
        let elementTokens: [TextToken]
        let elementTokenOffset: Int
    }

    /// Browser and PDF selections often expose only copied text or an opaque
    /// text-marker range. Their descendant static-text nodes still support
    /// AXBoundsForRange, so match the selected token sequence back to those
    /// nodes and recover the actual visual lines locally.
    private func accessibilityDescendantLayout(
        text: String,
        processID: pid_t
    ) -> RecoveredAccessibilityLayout? {
        let app = AXUIElementCreateApplication(processID)
        var roots: [AXUIElement] = []
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            roots.append(unsafeDowncast(focusedValue, to: AXUIElement.self))
        }
        roots.append(app)
        return accessibilityDescendantLayout(text: text, roots: roots)
    }

    private func accessibilityDescendantLayout(
        text: String,
        roots: [AXUIElement]
    ) -> RecoveredAccessibilityLayout? {
        let selectedTokens = lexicalTokens(in: text)
        guard selectedTokens.count > 1, selectedTokens.count <= 1_200 else { return nil }

        var matches: [ElementTextMatch] = []
        var stack = roots
        var visited = Set<CFHashCode>()
        var inspected = 0
        while let element = stack.popLast(), inspected < 6_000 {
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            inspected += 1

            var roleValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            let role = roleValue as? String
            if role == kAXStaticTextRole as String
                || role == kAXTextFieldRole as String
                || role == kAXTextAreaRole as String {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                   let elementText = value as? String {
                    let elementTokens = lexicalTokens(in: elementText)
                    if let match = tokenMatch(
                        selectedTokens: selectedTokens,
                        elementTokens: elementTokens,
                        element: element
                    ) {
                        matches.append(match)
                    }
                }
            }

            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        guard !matches.isEmpty else { return nil }

        matches.sort {
            let lhsCount = $0.selectedTokenRange.count
            let rhsCount = $1.selectedTokenRange.count
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return $0.selectedTokenRange.lowerBound < $1.selectedTokenRange.lowerBound
        }
        var covered = Set<Int>()
        var layoutTokens: [SelectedTextLayoutToken] = []
        for (matchContext, match) in matches.enumerated() {
            let newIndices = match.selectedTokenRange.filter { !covered.contains($0) }
            guard newIndices.count >= min(2, match.selectedTokenRange.count) else { continue }
            for selectedIndex in newIndices {
                let elementIndex = match.elementTokenOffset
                    + selectedIndex - match.selectedTokenRange.lowerBound
                guard match.elementTokens.indices.contains(elementIndex),
                      let bounds = bounds(
                          for: match.elementTokens[elementIndex].range,
                          in: match.element
                      ) else { continue }
                let elementLineIndex = lineIndex(
                    forCharacterAt: match.elementTokens[elementIndex].range.location,
                    in: match.element
                )
                layoutTokens.append(SelectedTextLayoutToken(
                    range: selectedTokens[selectedIndex].range,
                    boundingBox: bounds,
                    visualLineIndex: elementLineIndex,
                    visualLineContext: elementLineIndex == nil ? nil : matchContext
                ))
                covered.insert(selectedIndex)
            }
            if covered.count == selectedTokens.count { break }
        }
        guard layoutTokens.count >= 2 else { return nil }
        let uniqueTokens = Dictionary(
            layoutTokens.map { ($0.range.location, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.range.location < $1.range.location }
        guard uniqueTokens.count >= 2 else { return nil }
        let anchor = uniqueTokens.reduce(CGRect.null) { $0.union($1.boundingBox) }
        guard !anchor.isNull, !anchor.isEmpty else { return nil }
        return RecoveredAccessibilityLayout(
            text: SelectedTextLayoutReconstructor.reconstruct(text: text, tokens: uniqueTokens),
            anchorRect: anchor
        )
    }

    private func lexicalTokens(in text: String) -> [TextToken] {
        let source = text as NSString
        guard let expression = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+|[^\\s]") else {
            return []
        }
        return expression.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map {
            TextToken(value: source.substring(with: $0.range), range: $0.range)
        }
    }

    private func tokenMatch(
        selectedTokens: [TextToken],
        elementTokens: [TextToken],
        element: AXUIElement
    ) -> ElementTextMatch? {
        let selectedValues = selectedTokens.map(\.value)
        let elementValues = elementTokens.map(\.value)
        guard selectedValues.count > 1, elementValues.count > 1 else { return nil }
        if let offset = subsequenceStart(needle: selectedValues, in: elementValues) {
            return ElementTextMatch(
                element: element,
                selectedTokenRange: 0..<selectedValues.count,
                elementTokens: elementTokens,
                elementTokenOffset: offset
            )
        }
        if let offset = subsequenceStart(needle: elementValues, in: selectedValues) {
            return ElementTextMatch(
                element: element,
                selectedTokenRange: offset..<(offset + elementValues.count),
                elementTokens: elementTokens,
                elementTokenOffset: 0
            )
        }
        return nil
    }

    private func subsequenceStart(needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    private func bounds(for range: NSRange, in element: AXUIElement) -> CGRect? {
        var valueRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &valueRange) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(boundsValue, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private func lineIndex(forCharacterAt index: Int, in element: AXUIElement) -> Int? {
        var lineValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: index),
            &lineValue
        ) == .success else { return nil }
        return (lineValue as? NSNumber)?.intValue
    }

    private func clipboardSelection(processID: pid_t) async throws -> String {
        await clipboardFallbackCoordinator.acquire()
        defer {
            Task { await clipboardFallbackCoordinator.release() }
        }

        try Task.checkCancellation()
        guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated else {
            throw SelectedTextError.targetUnavailable
        }
        application.activate()
        try await Task.sleep(nanoseconds: 90_000_000)
        try Task.checkCancellation()

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        var ownedChangeCount: Int?
        var copiedChangeCount: Int?
        defer {
            let currentChangeCount = pasteboard.changeCount
            let currentText = pasteboard.string(forType: .string) ?? ""
            if currentChangeCount == ownedChangeCount ||
                currentChangeCount == copiedChangeCount ||
                Self.isClipboardSentinel(currentText) {
                snapshot.restore(to: pasteboard)
            }
        }
        let sentinel = "\(Self.clipboardSentinelPrefix)\(UUID().uuidString)"
        pasteboard.clearContents()
        ownedChangeCount = pasteboard.changeCount
        guard pasteboard.setString(sentinel, forType: .string) else { throw SelectedTextError.copyBlocked }
        let sentinelChangeCount = pasteboard.changeCount
        ownedChangeCount = sentinelChangeCount
        postCopy(to: processID, keyDown: true)
        postCopy(to: processID, keyDown: false)

        var text: String?
        var lastObservedChangeCount = sentinelChangeCount
        for _ in 0..<24 {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            let changeCount = pasteboard.changeCount
            if changeCount != lastObservedChangeCount {
                lastObservedChangeCount = changeCount
                let candidate = pasteboard.string(forType: .string)
                if let candidate,
                   !Self.isClipboardSentinel(candidate),
                   !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    copiedChangeCount = changeCount
                    ownedChangeCount = changeCount
                    text = candidate
                    break
                }
            }
        }

        if let copiedChangeCount {
            // Give a concurrent user copy a brief chance to win; never overwrite it.
            try await Task.sleep(nanoseconds: 35_000_000)
            if pasteboard.changeCount == copiedChangeCount {
                snapshot.restore(to: pasteboard)
                ownedChangeCount = nil
            }
        } else if pasteboard.changeCount == sentinelChangeCount ||
                    Self.isClipboardSentinel(pasteboard.string(forType: .string) ?? "") {
            snapshot.restore(to: pasteboard)
            ownedChangeCount = nil
        }
        guard copiedChangeCount != nil else { throw SelectedTextError.copyBlocked }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectedTextError.noSelection
        }
        return text
    }

    private func postCopy(to processID: pid_t, keyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: keyDown) else { return }
        event.flags = .maskCommand
        event.postToPid(processID)
    }

    private func validate(_ context: SelectedTextContext) throws -> SelectedTextContext {
        let validationText = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !validationText.isEmpty else { throw SelectedTextError.noSelection }
        guard !Self.isClipboardSentinel(validationText) else { throw SelectedTextError.noSelection }
        guard context.text.count <= maximumCharacters else { throw SelectedTextError.textTooLong(maximumCharacters) }
        return SelectedTextContext(
            text: context.text,
            processID: context.processID,
            applicationName: context.applicationName,
            acquisition: context.acquisition,
            anchorRect: context.anchorRect,
            detectedLanguage: context.detectedLanguage
        )
    }

    public nonisolated static func isClipboardSentinel(_ text: String) -> Bool {
        text.hasPrefix(clipboardSentinelPrefix)
    }

    private func detectLanguage(_ text: String) -> SupportedLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let raw = recognizer.dominantLanguage?.rawValue else { return nil }
        if raw.hasPrefix("zh-Hant") || raw.hasPrefix("zh-TW") || raw.hasPrefix("zh-HK") { return .traditionalChinese }
        if raw.hasPrefix("zh") { return .simplifiedChinese }
        return SupportedLanguage(rawValue: raw)
    }
}

private actor ClipboardFallbackCoordinator {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
private struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }
    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
