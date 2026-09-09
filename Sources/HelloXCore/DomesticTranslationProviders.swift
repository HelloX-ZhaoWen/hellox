import CryptoKit
import Foundation

/// Official Baidu general text API. Uses the standard tier's 1000-character limit.
public final class BaiduTranslationProvider: TranslationProvider, Sendable {
    public let name = "百度翻译"
    private let profile: TranslationProfile
    private let apiKey: String
    private let session: URLSession

    public init(profile: TranslationProfile, apiKey: String, session: URLSession = .shared) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        let urlRequest = try makeRequest(request, salt: UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let (data, _) = try await HTTPRetrier.perform(urlRequest, session: session, policy: RetryPolicy())
        return try decodeResponse(data)
    }

    func makeRequest(_ request: TranslationRequest, salt: String) throws -> URLRequest {
        guard profile.vendor == .baidu else { throw HelloXError.invalidConfiguration("翻译服务类型不匹配") }
        try profile.validate(hasAPIKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try DomesticTranslationHTTP.validate(request, limit: 1000, name: name)
        let appID = (profile.options["appID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let signatureInput = appID + request.text + salt + apiKey
        let signature = Insecure.MD5.hash(data: Data(signatureInput.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let parameters = [
            "q": request.text,
            "from": try Self.languageCode(request.sourceLanguage),
            "to": try Self.languageCode(request.targetLanguage),
            "appid": appID, "salt": salt, "sign": signature
        ]
        return DomesticTranslationHTTP.formRequest(url: URL(string: profile.baseURL)!, parameters: parameters)
    }

    // Common language codes supported by the standard and personal tiers. Fail before
    // sending other languages instead of guessing ISO codes that Baidu does not use.
    private static let languageCodes: [String: String] = [
        "auto": "auto", "zh": "zh", "zh-Hant": "cht", "en": "en", "ja": "jp",
        "ko": "kor", "fr": "fra", "es": "spa", "th": "th", "ar": "ara",
        "ru": "ru", "pt": "pt", "de": "de", "it": "it", "el": "el",
        "nl": "nl", "pl": "pl", "bg": "bul", "et": "est", "da": "dan",
        "fi": "fin", "cs": "cs", "ro": "rom", "sl": "slo", "sv": "swe",
        "hu": "hu", "vi": "vie", "yue": "yue"
    ]

    static func languageCode(_ language: SupportedLanguage) throws -> String {
        guard let code = languageCodes[language.rawValue] else { throw HelloXError.languageNotSupported }
        return code
    }

    func decodeResponse(_ data: Data) throws -> TranslationResult {
        let response = try DomesticTranslationHTTP.object(data)
        if let code = DomesticTranslationHTTP.code(response["error_code"]), code != "52000" {
            switch code {
            case "52003", "54001", "58000": throw HelloXError.authenticationFailed
            case "54003", "54005": throw HelloXError.rateLimited
            case "58001": throw HelloXError.languageNotSupported
            case "54004": throw HelloXError.invalidConfiguration("百度翻译额度或余额不足，请查看服务商控制台")
            case "58002": throw HelloXError.invalidConfiguration("百度翻译服务已关闭，请在服务商控制台检查开通状态")
            default: throw HelloXError.network("百度翻译错误（\(code)），请查看服务商控制台")
            }
        }
        guard let rows = response["trans_result"] as? [[String: Any]], !rows.isEmpty else {
            throw HelloXError.invalidResponse
        }
        let translations = try rows.map { row -> String in
            guard let text = row["dst"] as? String else { throw HelloXError.invalidResponse }
            return text
        }
        let text = translations.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HelloXError.invalidResponse }
        let detected = (response["from"] as? String).flatMap { code in
            Self.languageCodes.first { $0.value == code }?.key
        }
        return TranslationResult(text: text, detectedSourceLanguage: detected, providerName: name)
    }
}

/// Alibaba Cloud TranslateGeneral, RPC API version 2018-10-12.
public final class AliyunTranslationProvider: TranslationProvider, Sendable {
    public let name = "阿里云翻译"
    private let profile: TranslationProfile
    private let apiKey: String
    private let session: URLSession

    public init(profile: TranslationProfile, apiKey: String, session: URLSession = .shared) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        let urlRequest = try makeRequest(request, date: Date(), nonce: UUID().uuidString)
        let (data, _) = try await HTTPRetrier.perform(urlRequest, session: session, policy: RetryPolicy())
        return try decodeResponse(data)
    }

    func makeRequest(_ request: TranslationRequest, date: Date, nonce: String) throws -> URLRequest {
        guard profile.vendor == .aliyun else { throw HelloXError.invalidConfiguration("翻译服务类型不匹配") }
        try profile.validate(hasAPIKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try DomesticTranslationHTTP.validate(request, limit: 5000, name: name)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var parameters = [
            "Action": "TranslateGeneral", "Version": "2018-10-12", "Format": "JSON",
            "AccessKeyId": (profile.options["accessKeyID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "SignatureMethod": "HMAC-SHA1", "SignatureVersion": "1.0",
            "SignatureNonce": nonce, "Timestamp": formatter.string(from: date),
            "FormatType": "text", "Scene": "general", "SourceText": request.text,
            "SourceLanguage": Self.languageCode(request.sourceLanguage),
            "TargetLanguage": Self.languageCode(request.targetLanguage)
        ]
        parameters["Signature"] = Self.signature(parameters: parameters, secret: apiKey)
        guard var components = URLComponents(string: profile.baseURL) else { throw HelloXError.invalidResponse }
        components.path = "/"
        let bodyKeys: Set<String> = ["FormatType", "Scene", "SourceText", "SourceLanguage", "TargetLanguage"]
        components.percentEncodedQuery = DomesticTranslationHTTP.form(parameters.filter { !bodyKeys.contains($0.key) })
        components.fragment = nil
        guard let url = components.url else { throw HelloXError.invalidResponse }
        return DomesticTranslationHTTP.formRequest(url: url, parameters: parameters.filter { bodyKeys.contains($0.key) })
    }

    static func languageCode(_ language: SupportedLanguage) -> String {
        language == .traditionalChinese ? "zh-tw" : language.rawValue
    }

    static func signature(parameters: [String: String], secret: String) -> String {
        let canonical = DomesticTranslationHTTP.form(parameters.filter { $0.key != "Signature" })
        let input = "POST&%2F&" + DomesticTranslationHTTP.percentEncode(canonical)
        return Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(input.utf8), using: SymmetricKey(data: Data((secret + "&").utf8))
        )).base64EncodedString()
    }

    func decodeResponse(_ data: Data) throws -> TranslationResult {
        let response = try DomesticTranslationHTTP.object(data)
        guard let code = DomesticTranslationHTTP.code(response["Code"]) else { throw HelloXError.invalidResponse }
        if code != "200" {
            switch code {
            case "10005", "10006": throw HelloXError.languageNotSupported
            case "10009", "InvalidAccessKeyId.NotFound", "SignatureDoesNotMatch": throw HelloXError.authenticationFailed
            case "Throttling", "Throttling.User", "Throttling.Api": throw HelloXError.rateLimited
            case "10010", "10013":
                throw HelloXError.invalidConfiguration("阿里云翻译服务未开通或额度 / 余额不足，请查看服务商控制台")
            case "10008": throw HelloXError.invalidConfiguration("阿里云翻译单次最多支持 5000 个字符")
            default: throw HelloXError.network("阿里云翻译错误（\(code)），请查看服务商控制台")
            }
        }
        guard let result = response["Data"] as? [String: Any],
              let text = result["Translated"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HelloXError.invalidResponse }
        let detected = result["DetectedLanguage"] as? String
        return TranslationResult(
            text: text, detectedSourceLanguage: detected == "zh-tw" ? "zh-Hant" : detected, providerName: name
        )
    }
}

private enum DomesticTranslationHTTP {
    static func validate(_ request: TranslationRequest, limit: Int, name: String) throws {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelloXError.invalidConfiguration("翻译文本不能为空")
        }
        guard request.targetLanguage != .auto else { throw HelloXError.languageNotSupported }
        // UTF-16 is conservative for provider limits and does not undercount emoji
        // or combined characters as Swift's grapheme-cluster count would.
        guard request.text.utf16.count <= limit else {
            throw HelloXError.invalidConfiguration("\(name)单次最多支持 \(limit) 个字符")
        }
    }

    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))!
    }

    static func form(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { "\(percentEncode($0))=\(percentEncode(parameters[$0]!))" }.joined(separator: "&")
    }

    static func formRequest(url: URL, parameters: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form(parameters).utf8)
        return request
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelloXError.invalidResponse
        }
        return object
    }

    static func code(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
