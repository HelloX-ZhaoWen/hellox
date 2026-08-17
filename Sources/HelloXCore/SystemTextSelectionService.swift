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
        case .clipboardFallbackRequired: "当前应用无法直接读取选中文字。"
        case .noSelection: "没有读取到选中文字。"
        case .targetUnavailable: "选中文字所在的应用已经退出或不可用。"
        case .copyBlocked: "目标应用没有响应复制操作，请重新选中文字后重试。"
        case .textTooLong(let limit): "选中文字超过 \(limit) 字符，请缩小选择范围。"
        }
    }
}

@MainActor
public final class SystemTextSelectionService {
    private let maximumCharacters: Int

    public init(maximumCharacters: Int = 10_000) {
        self.maximumCharacters = maximumCharacters
    }

    public func readSelection(processID: pid_t, allowClipboardFallback: Bool) async throws -> SelectedTextContext {
        guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated else {
            throw SelectedTextError.targetUnavailable
        }
        let applicationName = application.localizedName ?? "未知应用"
        if AXIsProcessTrusted() {
            if let direct = try accessibilitySelection(processID: processID, applicationName: applicationName) {
                return try validate(direct)
            }
        } else if !allowClipboardFallback {
            throw SelectedTextError.accessibilityDenied
        }
        guard allowClipboardFallback else { throw SelectedTextError.clipboardFallbackRequired }
        let text = try await clipboardSelection(processID: processID)
        return try validate(SelectedTextContext(
            text: text,
            processID: processID,
            applicationName: applicationName,
            acquisition: .temporaryClipboard,
            anchorRect: nil,
            detectedLanguage: detectLanguage(text)
        ))
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

        return SelectedTextContext(
            text: text,
            processID: processID,
            applicationName: applicationName,
            acquisition: .accessibility,
            anchorRect: anchor,
            detectedLanguage: detectLanguage(text)
        )
    }

    private func clipboardSelection(processID: pid_t) async throws -> String {
        guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated else {
            throw SelectedTextError.targetUnavailable
        }
        _ = application.activate(options: [.activateIgnoringOtherApps])
        try await Task.sleep(nanoseconds: 90_000_000)

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let sentinel = "hellox-selection-\(UUID().uuidString)"
        pasteboard.clearContents()
        guard pasteboard.setString(sentinel, forType: .string) else { throw SelectedTextError.copyBlocked }
        let sentinelChangeCount = pasteboard.changeCount
        postCopy(to: processID, keyDown: true)
        postCopy(to: processID, keyDown: false)

        var copiedChangeCount: Int?
        var text: String?
        for _ in 0..<24 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != sentinelChangeCount {
                copiedChangeCount = pasteboard.changeCount
                let candidate = pasteboard.string(forType: .string)
                if candidate != sentinel { text = candidate }
                break
            }
        }

        if let copiedChangeCount {
            // Give a concurrent user copy a brief chance to win; never overwrite it.
            try await Task.sleep(nanoseconds: 35_000_000)
            if pasteboard.changeCount == copiedChangeCount { snapshot.restore(to: pasteboard) }
        } else if pasteboard.changeCount == sentinelChangeCount {
            snapshot.restore(to: pasteboard)
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
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SelectedTextError.noSelection }
        guard text.count <= maximumCharacters else { throw SelectedTextError.textTooLong(maximumCharacters) }
        return SelectedTextContext(
            text: text,
            processID: context.processID,
            applicationName: context.applicationName,
            acquisition: context.acquisition,
            anchorRect: context.anchorRect,
            detectedLanguage: context.detectedLanguage
        )
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
