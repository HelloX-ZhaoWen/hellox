import AppKit
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

    public init(id: UUID = UUID(), text: String, confidence: Float, boundingBox: CGRect) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
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

/// A translated OCR block that keeps Vision's normalized, bottom-left-origin
/// geometry so the translation can be rendered back onto the captured image.
public struct ImageTranslationAppearance: Equatable, Sendable {
    /// Font size in source-image pixels.
    public let fontSize: CGFloat
    public let foregroundColor: RGBAColor
    public let backgroundColor: RGBAColor
    public let lineCount: Int

    public init(
        fontSize: CGFloat,
        foregroundColor: RGBAColor,
        backgroundColor: RGBAColor,
        lineCount: Int
    ) {
        self.fontSize = fontSize
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.lineCount = max(1, lineCount)
    }

    public static let fallback = ImageTranslationAppearance(
        fontSize: 14,
        foregroundColor: .black,
        backgroundColor: .white,
        lineCount: 1
    )
}

public struct ImageTranslationBlock: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let boundingBox: CGRect
    public let appearance: ImageTranslationAppearance

    public init(
        id: UUID = UUID(),
        text: String,
        boundingBox: CGRect,
        appearance: ImageTranslationAppearance = .fallback
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.appearance = appearance
    }
}

public enum ImageTranslationTextLayout {
    /// Screenshot translations favor legibility over strict containment. The
    /// layout engine first finds a shared fitting size, then rendering applies
    /// this explicit readability multiplier consistently in preview and export.
    public static let forcedFontScale: CGFloat = 1.5

    public static func fittedFontSize(
        for text: String,
        in rect: CGRect,
        preferredSize: CGFloat,
        minimumScale: CGFloat = 0.55
    ) -> CGFloat {
        let horizontalPadding = max(2, preferredSize * 0.16)
        let verticalPadding = max(1, preferredSize * 0.10)
        let availableWidth = max(1, rect.width - horizontalPadding * 2)
        let availableHeight = max(1, rect.height - verticalPadding * 2)
        let font = NSFont.systemFont(ofSize: preferredSize, weight: .regular)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let widthScale = availableWidth / max(1, measured.width)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let heightScale = availableHeight / max(1, lineHeight)
        return preferredSize * min(1, max(minimumScale, min(widthScale, heightScale)))
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

public struct LanguagePackManifest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceLanguage: SupportedLanguage
    public let targetLanguage: SupportedLanguage
    public let version: String
    public let downloadURL: URL
    public let compressedBytes: Int64
    public let sha256: String
    public let licenseName: String
    public let attribution: String

    public init(
        id: String,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        version: String,
        downloadURL: URL,
        compressedBytes: Int64,
        sha256: String,
        licenseName: String,
        attribution: String
    ) {
        self.id = id
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.version = version
        self.downloadURL = downloadURL
        self.compressedBytes = compressedBytes
        self.sha256 = sha256
        self.licenseName = licenseName
        self.attribution = attribution
    }
}

public enum HelloXError: LocalizedError, Equatable, Sendable {
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied
    case captureFailed(String)
    case cancelled
    case noTextFound
    case invalidConfiguration(String)
    case authenticationFailed
    case rateLimited
    case network(String)
    case invalidResponse
    case languageNotSupported
    case insufficientDiskSpace(Int64)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied: "需要屏幕录制权限才能截图。"
        case .accessibilityPermissionDenied: "滚动长截图需要辅助功能权限。"
        case .captureFailed(let message): "截图失败：\(message)"
        case .cancelled: "操作已取消。"
        case .noTextFound: "图片中没有识别到文字。"
        case .invalidConfiguration(let message): "配置无效：\(message)"
        case .authenticationFailed: "API Key 无效或没有访问权限。"
        case .rateLimited: "请求过于频繁，请稍后再试。"
        case .network(let message): "网络请求失败：\(message)"
        case .invalidResponse: "服务返回了无法解析的数据。"
        case .languageNotSupported: "不支持所选语言组合。"
        case .insufficientDiskSpace(let bytes): "磁盘空间不足，至少需要 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) 可用空间。"
        }
    }
}
