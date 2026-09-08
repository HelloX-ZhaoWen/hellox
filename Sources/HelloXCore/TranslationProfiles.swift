import Foundation

public enum TranslationVendor: String, CaseIterable, Codable, Sendable, Identifiable {
    case local
    case volcengine
    case zhipu
    case niutrans

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "本地离线"
        case .volcengine: "火山机器翻译"
        case .zhipu: "智谱免费翻译"
        case .niutrans: "小牛翻译"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .local: ""
        case .volcengine: "https://translate.volcengineapi.com"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .niutrans: "https://api.niutrans.com/v2/text/translate"
        }
    }

    public var defaultModel: String {
        switch self {
        case .zhipu: "glm-4.7-flash"
        default: ""
        }
    }

    public var requiresModel: Bool { self == .zhipu }
    public var requiresAPIKey: Bool { self != .local }
    public var supportsTextTranslation: Bool { self != .local }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        // Removed cloud vendors decode as local so the preferences migration can discard them.
        self = Self(rawValue: rawValue) ?? .local
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TranslationProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var vendor: TranslationVendor
    public var baseURL: String
    public var model: String
    public var isEnabled: Bool
    public var options: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        vendor: TranslationVendor,
        baseURL: String? = nil,
        model: String = "",
        isEnabled: Bool = true,
        options: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.baseURL = baseURL ?? vendor.defaultBaseURL
        self.model = model
        self.isEnabled = isEnabled
        self.options = options
    }

    public static func preset(_ vendor: TranslationVendor) -> TranslationProfile {
        return TranslationProfile(
            name: vendor.displayName,
            vendor: vendor,
            model: vendor.defaultModel,
            isEnabled: vendor == .local
        )
    }

    public func validate(hasAPIKey: Bool) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelloXError.invalidConfiguration("配置名称不能为空")
        }
        if vendor != .local {
            guard let url = URL(string: baseURL) else { throw HelloXError.invalidConfiguration("Base URL 无效") }
            if [.volcengine, .niutrans].contains(vendor),
               url.scheme?.lowercased() != "https" {
                throw HelloXError.invalidConfiguration("\(vendor.displayName)必须使用 HTTPS")
            }
        }
        if vendor.requiresModel && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HelloXError.invalidConfiguration("请填写模型名称")
        }
        if vendor == .volcengine,
           options["accessKeyID"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw HelloXError.invalidConfiguration("请填写 Access Key ID")
        }
        if vendor == .niutrans,
           options["appID"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw HelloXError.invalidConfiguration("请填写 APPID")
        }
        if vendor.requiresAPIKey && !hasAPIKey {
            let credentialName: String
            switch vendor {
            case .volcengine: credentialName = "Secret Access Key"
            case .niutrans: credentialName = "APIKEY"
            default: credentialName = "API Key"
            }
            throw HelloXError.invalidConfiguration("请填写 \(credentialName)")
        }
    }
}

public enum TranslationProviderFactory {
    public static func make(
        profile: TranslationProfile,
        apiKey: String?,
        session: URLSession = .shared
    ) throws -> any TranslationProvider {
        let key = apiKey ?? ""
        try profile.validate(hasAPIKey: !key.isEmpty)
        switch profile.vendor {
        case .local:
            throw HelloXError.invalidConfiguration("本地语言包功能已移除")
        case .volcengine:
            return VolcengineTranslationProvider(
                configuration: VolcengineTranslationConfiguration(
                    baseURL: URL(string: profile.baseURL)!,
                    accessKeyID: (profile.options["accessKeyID"] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    secretAccessKey: key
                ),
                session: session
            )
        case .zhipu:
            return ZhipuTranslationProvider(
                configuration: ZhipuTranslationConfiguration(baseURL: URL(string: profile.baseURL)!, model: profile.model, apiKey: key),
                session: session
            )
        case .niutrans:
            return NiuTransTranslationProvider(
                configuration: NiuTransTranslationConfiguration(
                    baseURL: URL(string: profile.baseURL)!,
                    appID: (profile.options["appID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: key
                ),
                session: session
            )
        }
    }
}
