import CoreGraphics
import Foundation

public enum CaptureMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case region
    case window
    case fullScreen
    case scrolling

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .region: "区域截图"
        case .window: "窗口截图"
        case .fullScreen: "全屏截图"
        case .scrolling: "滚动长截图"
        }
    }
}

public struct CaptureResult: @unchecked Sendable {
    public let image: CGImage
    public let pixelSize: CGSize
    public let displayScale: CGFloat
    public let capturedRect: CGRect
    public let createdAt: Date
    public let mode: CaptureMode

    public init(
        image: CGImage,
        displayScale: CGFloat,
        capturedRect: CGRect,
        createdAt: Date = Date(),
        mode: CaptureMode
    ) {
        self.image = image
        self.pixelSize = CGSize(width: image.width, height: image.height)
        self.displayScale = displayScale
        self.capturedRect = capturedRect
        self.createdAt = createdAt
        self.mode = mode
    }
}

public struct RecognizedTextBlock: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let confidence: Float
    /// Vision coordinates: normalized, origin at bottom-left.
    public let boundingBox: CGRect
    /// Character-level Vision rectangle for the semantic content after list
    /// markers and transient carets have been excluded.
    public let translatableBoundingBox: CGRect?
    /// True when OCR recovered this observation as an independent interface
    /// cell. Semantic paragraph grouping must not cross this boundary.
    public let isLayoutIsolated: Bool?

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        boundingBox: CGRect,
        translatableBoundingBox: CGRect? = nil,
        isLayoutIsolated: Bool? = nil
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.translatableBoundingBox = translatableBoundingBox
        self.isLayoutIsolated = isLayoutIsolated
    }
}

public struct OCRResult: Codable, Equatable, Sendable {
    public let text: String
    public let language: String?
    public let averageConfidence: Float
    public let blocks: [RecognizedTextBlock]

    public init(text: String, language: String?, averageConfidence: Float, blocks: [RecognizedTextBlock]) {
        self.text = text
        self.language = language
        self.averageConfidence = averageConfidence
        self.blocks = blocks
    }
}

public struct SupportedLanguage: RawRepresentable, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String

    public static let auto = Self(uncheckedRawValue: "auto")
    public static let simplifiedChinese = Self(uncheckedRawValue: "zh")
    public static let traditionalChinese = Self(uncheckedRawValue: "zh-Hant")
    public static let english = Self(uncheckedRawValue: "en")
    public static let japanese = Self(uncheckedRawValue: "ja")
    public static let korean = Self(uncheckedRawValue: "ko")
    public static let french = Self(uncheckedRawValue: "fr")
    public static let german = Self(uncheckedRawValue: "de")
    public static let spanish = Self(uncheckedRawValue: "es")
    public static let russian = Self(uncheckedRawValue: "ru")
    public static let portuguese = Self(uncheckedRawValue: "pt")
    public static let italian = Self(uncheckedRawValue: "it")
    public static let arabic = Self(uncheckedRawValue: "ar")
    public static let hindi = Self(uncheckedRawValue: "hi")
    public static let thai = Self(uncheckedRawValue: "th")
    public static let vietnamese = Self(uncheckedRawValue: "vi")
    public static let indonesian = Self(uncheckedRawValue: "id")
    public static let turkish = Self(uncheckedRawValue: "tr")
    public static let dutch = Self(uncheckedRawValue: "nl")
    public static let polish = Self(uncheckedRawValue: "pl")
    public static let ukrainian = Self(uncheckedRawValue: "uk")

    private static let chineseLocale = Locale(identifier: "zh-Hans")
    private static let isoLanguageCodes = Set(Locale.LanguageCode.isoLanguageCodes.map { $0.identifier.lowercased() })
    private static let commonLanguageCodes = [
        "auto", "zh", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "ru",
        "pt", "it", "ar", "hi", "th", "vi", "id", "tr", "nl", "pl", "uk",
        "bg", "cs", "da", "el", "fi", "ro", "sv", "nb", "sk", "hu", "he",
        "ca", "hr", "sr", "sl", "et", "lv", "lt", "fa", "ur", "bn", "ta",
        "te", "ml", "mr", "gu", "kn", "pa", "or", "as", "ms", "fil", "my",
        "km", "lo", "ne", "si", "sw", "af", "am", "zu", "xh", "yo", "ig",
        "ha", "so", "rw", "ny", "mg", "is", "ga", "cy", "eu", "gl", "mt",
        "sq", "mk", "bs", "be", "ka", "hy", "az", "kk", "uz", "ky", "tg",
        "tk", "mn", "ps", "ku", "sd", "jv", "su", "ceb", "mi", "la", "eo",
        "lb", "fy", "gd", "yi", "co", "fo", "ht", "qu", "gn", "ay", "sm",
        "to", "fj", "tt", "cv", "sn", "st", "tn", "ts", "nso", "om", "ti",
        "ug", "bo", "dz", "ak", "bm", "ee", "ln", "lg", "wo", "kok", "bho",
        "mai", "sa"
    ]

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    public init?(rawValue: String) {
        let normalized = rawValue.replacingOccurrences(of: "_", with: "-")
        let lowercase = normalized.lowercased()
        if lowercase == "auto" {
            self = .auto
            return
        }
        if lowercase == "zh-hant" || lowercase.hasPrefix("zh-tw") || lowercase.hasPrefix("zh-hk") {
            self = .traditionalChinese
            return
        }
        if lowercase == "zh" || lowercase == "zh-hans" || lowercase.hasPrefix("zh-cn") || lowercase.hasPrefix("zh-sg") {
            self = .simplifiedChinese
            return
        }
        let baseCode = String(lowercase.split(separator: "-").first ?? "")
        guard Self.isoLanguageCodes.contains(baseCode) else { return nil }
        self.init(uncheckedRawValue: baseCode)
    }

    public static var allCases: [SupportedLanguage] {
        commonLanguageCodes.map(Self.init(uncheckedRawValue:))
    }

    public var id: String { rawValue }

    public var displayName: String {
        if self == .auto { return "自动检测" }
        if self == .simplifiedChinese { return "简体中文" }
        if self == .traditionalChinese { return "繁体中文" }
        return Self.chineseLocale.localizedString(forLanguageCode: rawValue) ?? rawValue.uppercased()
    }

    /// The BCP-47 language identifier consumed by macOS Translation.
    /// `nil` asks the system to detect the source language automatically.
    public var systemLanguageIdentifier: String? {
        if self == .auto { return nil }
        if self == .simplifiedChinese { return "zh-Hans" }
        if self == .traditionalChinese { return "zh-Hant" }
        return rawValue
    }

    /// Returns true when the two languages are the same concrete language.
    /// Auto-detection never counts as a match.
    public func isSameLanguage(as other: SupportedLanguage) -> Bool {
        guard self != .auto, other != .auto else { return false }
        if self == other { return true }
        return rawValue == other.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let language = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "未知语言代码：\(rawValue)")
        }
        self = language
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum HelloXError: LocalizedError, Equatable, Sendable {
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied
    case captureFailed(String)
    case cancelled
    case scrollNotAccepted(String)
    case noTextFound
    case invalidConfiguration(String)
    case authenticationFailed
    case rateLimited
    case network(String)
    case invalidResponse
    case languageNotSupported

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied: "需要屏幕录制权限才能截图。"
        case .accessibilityPermissionDenied: "滚动长截图需要辅助功能权限。"
        case .captureFailed(let message): "截图失败：\(message)"
        case .cancelled: "操作已取消。"
        case .scrollNotAccepted(let message): "滚动未生效：\(message)"
        case .noTextFound: "图片中没有识别到文字。"
        case .invalidConfiguration(let message): "配置无效：\(message)"
        case .authenticationFailed: "API Key 无效或没有访问权限。"
        case .rateLimited: "请求过于频繁，请稍后再试。"
        case .network(let message): "网络请求失败：\(message)"
        case .invalidResponse: "服务返回了无法解析的数据。"
        case .languageNotSupported: "不支持所选语言组合。"
        }
    }
}
