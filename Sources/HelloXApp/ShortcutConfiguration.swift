@preconcurrency import Carbon
import Foundation

enum ShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case regionCapture
    case windowCapture
    case fullScreenCapture
    case scrollingCapture
    case screenRecording
    case watermarkImage
    case captureAndOCR
    case textTranslation
    case captureAndTranslate
    case translateSelection
    case csvToExcel
    case base64
    case qrCode
    case password
    case markdown

    static let configurableCases: [ShortcutAction] = [
        .regionCapture,
        .scrollingCapture,
        .screenRecording,
        .watermarkImage,
        .captureAndOCR,
        .textTranslation,
        .captureAndTranslate,
        .translateSelection,
        .csvToExcel,
        .base64,
        .qrCode,
        .password,
        .markdown
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regionCapture: "区域截图"
        case .windowCapture: "窗口截图"
        case .fullScreenCapture: "全屏截图"
        case .scrollingCapture: "滚动长截图"
        case .screenRecording: "选区录屏"
        case .watermarkImage: "图片加水印"
        case .captureAndOCR: "文字提取"
        case .textTranslation: "文本翻译"
        case .captureAndTranslate: "截图翻译"
        case .translateSelection: "划词翻译"
        case .csvToExcel: "CSV 转 Excel"
        case .base64: "Base64 转换"
        case .qrCode: "二维码识别扫码"
        case .password: "密码生成（随机）"
        case .markdown: "Markdown 转换"
        }
    }

    var defaultBinding: ShortcutBinding? {
        switch self {
        case .regionCapture: ShortcutBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey))
        case .scrollingCapture: ShortcutBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | cmdKey))
        case .screenRecording: ShortcutBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey))
        case .watermarkImage: ShortcutBinding(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey | cmdKey))
        case .captureAndOCR: ShortcutBinding(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | cmdKey))
        case .translateSelection: ShortcutBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | cmdKey))
        case .windowCapture, .fullScreenCapture, .textTranslation, .captureAndTranslate, .csvToExcel, .base64, .qrCode, .password, .markdown: nil
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    var displayName: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += Self.keyNames[keyCode] ?? "键码 \(keyCode)"
        return value
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "空格", 50: "`", 51: "Delete", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑"
    ]
}

enum ShortcutConflictDetector {
    static func validationError(
        in bindings: [ShortcutAction: ShortcutBinding],
        changedAction: ShortcutAction? = nil
    ) -> ShortcutRegistrationError? {
        let activeBindings = bindings.compactMapValues { $0 }
        if let duplicate = Dictionary(grouping: activeBindings, by: \.value).first(where: { $0.value.count > 1 }) {
            let action = changedAction ?? duplicate.value[1].key
            let other = duplicate.value.first { $0.key != action }?.key ?? duplicate.value[0].key
            return ShortcutRegistrationError(action: action, reason: "与\(other.title)使用了相同快捷键")
        }
        for action in ShortcutAction.configurableCases {
            guard let binding = activeBindings[action],
                  let description = systemConflictDescription(for: binding) else { continue }
            return ShortcutRegistrationError(action: action, reason: description)
        }
        return nil
    }

    private static func systemConflictDescription(for binding: ShortcutBinding) -> String? {
        let keyCode = binding.keyCode
        let modifiers = normalizedModifiers(binding.modifiers)
        if matches(modifiers, [.command], keyCode, UInt32(kVK_Space)) {
            return "与 Spotlight 搜索冲突"
        }
        if matches(modifiers, [.command, .option], keyCode, UInt32(kVK_Space)) {
            return "与 Finder 搜索窗口冲突"
        }
        if matches(modifiers, [.control], keyCode, UInt32(kVK_Space)) {
            return "与输入法切换快捷键冲突"
        }
        if matches(modifiers, [.command], keyCode, UInt32(kVK_Tab))
            || matches(modifiers, [.command, .shift], keyCode, UInt32(kVK_Tab)) {
            return "与应用切换快捷键冲突"
        }
        if matches(modifiers, [.command], keyCode, UInt32(kVK_ANSI_Grave)) {
            return "与窗口切换快捷键冲突"
        }
        if matches(modifiers, [.command, .option], keyCode, UInt32(kVK_Escape)) {
            return "与强制退出窗口快捷键冲突"
        }
        if isSystemScreenshotShortcut(modifiers: modifiers, keyCode: keyCode) {
            return "与 macOS 截图快捷键冲突"
        }
        if isMissionControlShortcut(modifiers: modifiers, keyCode: keyCode) {
            return "与 Mission Control 或空间切换快捷键冲突"
        }
        if isReservedCommandMenuShortcut(modifiers: modifiers, keyCode: keyCode) {
            return "与 macOS 常用菜单快捷键冲突"
        }
        return nil
    }

    private static func isSystemScreenshotShortcut(modifiers: Set<ShortcutModifier>, keyCode: UInt32) -> Bool {
        guard keyCode == UInt32(kVK_ANSI_3) || keyCode == UInt32(kVK_ANSI_4) || keyCode == UInt32(kVK_ANSI_5) else {
            return false
        }
        return modifiers == [.command, .shift] || modifiers == [.command, .control, .shift]
    }

    private static func isMissionControlShortcut(modifiers: Set<ShortcutModifier>, keyCode: UInt32) -> Bool {
        guard modifiers == [.control] || modifiers == [.control, .shift] else { return false }
        return keyCode == UInt32(kVK_UpArrow)
            || keyCode == UInt32(kVK_DownArrow)
            || keyCode == UInt32(kVK_LeftArrow)
            || keyCode == UInt32(kVK_RightArrow)
    }

    private static func isReservedCommandMenuShortcut(modifiers: Set<ShortcutModifier>, keyCode: UInt32) -> Bool {
        guard modifiers == [.command] || modifiers == [.command, .shift] else { return false }
        let reservedKeys: Set<UInt32> = [
            UInt32(kVK_ANSI_H), UInt32(kVK_ANSI_M), UInt32(kVK_ANSI_Q),
            UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_O),
            UInt32(kVK_ANSI_S), UInt32(kVK_ANSI_P), UInt32(kVK_ANSI_F),
            UInt32(kVK_ANSI_G), UInt32(kVK_ANSI_Z), UInt32(kVK_ANSI_X),
            UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_A),
            UInt32(kVK_ANSI_Comma)
        ]
        return reservedKeys.contains(keyCode)
    }

    private static func normalizedModifiers(_ modifiers: UInt32) -> Set<ShortcutModifier> {
        var result: Set<ShortcutModifier> = []
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }

    private static func matches(
        _ modifiers: Set<ShortcutModifier>,
        _ expected: Set<ShortcutModifier>,
        _ keyCode: UInt32,
        _ expectedKeyCode: UInt32
    ) -> Bool {
        modifiers == expected && keyCode == expectedKeyCode
    }
}

private enum ShortcutModifier: Hashable {
    case command
    case option
    case control
    case shift
}

enum ShortcutPreferences {
    private static let storageKey = "shortcut-bindings-v4"
    private static let previousStorageKey = "shortcut-bindings-v3"
    private static let legacyStorageKey = "shortcut-bindings-v2"

    static var defaults: [ShortcutAction: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
            action.defaultBinding.map { (action, $0) }
        })
    }

    static func load() -> [ShortcutAction: ShortcutBinding] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ShortcutAction: ShortcutBinding].self, from: data) {
            let result = removingRetiredActions(from: decoded)
            if result != decoded { save(result) }
            return result
        }

        if let data = UserDefaults.standard.data(forKey: previousStorageKey),
           let decoded = try? JSONDecoder().decode([ShortcutAction: ShortcutBinding].self, from: data) {
            var migrated = decoded
            migrated[.screenRecording] = ShortcutAction.screenRecording.defaultBinding
            migrated = removingRetiredActions(from: migrated)
            save(migrated)
            return migrated
        }

        if let data = UserDefaults.standard.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode([ShortcutAction: ShortcutBinding].self, from: data) {
            var migrated = decoded
            migrated[.watermarkImage] = ShortcutAction.watermarkImage.defaultBinding
            migrated[.screenRecording] = ShortcutAction.screenRecording.defaultBinding
            migrated = removingRetiredActions(from: migrated)
            save(migrated)
            return migrated
        }

        // One-time migration from the original two-shortcut implementation.
        var migrated = defaults
        if let data = UserDefaults.standard.data(forKey: "shortcut-region"),
           let old = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            migrated[.regionCapture] = old
        }
        if let data = UserDefaults.standard.data(forKey: "shortcut-scrolling"),
           let old = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            migrated[.scrollingCapture] = old
        }
        save(migrated)
        return migrated
    }

    static func save(_ bindings: [ShortcutAction: ShortcutBinding]) {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(removingRetiredActions(from: bindings)),
            forKey: storageKey
        )
    }

    private static func removingRetiredActions(
        from bindings: [ShortcutAction: ShortcutBinding]
    ) -> [ShortcutAction: ShortcutBinding] {
        bindings.filter { ShortcutAction.configurableCases.contains($0.key) }
    }
}

struct ShortcutRegistrationError: LocalizedError, Sendable {
    let action: ShortcutAction
    let reason: String
    var errorDescription: String? { "\(action.title)：\(reason)" }
}
