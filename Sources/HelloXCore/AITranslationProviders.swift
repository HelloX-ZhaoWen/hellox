import CryptoKit
import Foundation

public struct VolcengineTranslationConfiguration: Sendable {
    public let baseURL: URL
    public let accessKeyID: String
    public let secretAccessKey: String

    public init(baseURL: URL, accessKeyID: String, secretAccessKey: String) {
        self.baseURL = baseURL
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

public final class VolcengineTranslationProvider: TranslationProvider, @unchecked Sendable {
    public let name = "火山机器翻译"
    private static let region = "cn-north-1"
    private static let service = "translate"
    private static let action = "TranslateText"
    private static let version = "2020-06-01"

    private let configuration: VolcengineTranslationConfiguration
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let currentDate: @Sendable () -> Date

    public init(
        configuration: VolcengineTranslationConfiguration,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = RetryPolicy(),
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.session = session
        self.retryPolicy = retryPolicy
        self.currentDate = currentDate
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HelloXError.invalidConfiguration("翻译文本不能为空") }
        guard !configuration.accessKeyID.isEmpty else {
            throw HelloXError.invalidConfiguration("请填写 Access Key ID")
        }
        guard !configuration.secretAccessKey.isEmpty else {
            throw HelloXError.invalidConfiguration("请填写 Secret Access Key")
        }
        guard request.text.count <= 5_000 else {
            throw HelloXError.invalidConfiguration("火山机器翻译单次最多支持 5000 个字符")
        }
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw HelloXError.invalidConfiguration("Base URL 无效")
        }
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "Action", value: Self.action),
            URLQueryItem(name: "Version", value: Self.version)
        ]
        guard let url = components.url, let hostName = components.host else {
            throw HelloXError.invalidConfiguration("Base URL 无效")
        }
        let host = components.port.map { "\(hostName):\($0)" } ?? hostName

        let payload = VolcengineTranslateRequest(
            sourceLanguage: request.sourceLanguage == .auto ? nil : request.sourceLanguage.rawValue,
            targetLanguage: request.targetLanguage.rawValue,
            textList: [request.text]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(payload)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        VolcengineV4Signer.sign(
            request: &urlRequest,
            body: body,
            host: host,
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: configuration.secretAccessKey,
            date: currentDate(),
            region: Self.region,
            service: Self.service
        )

        let (data, _) = try await HTTPRetrier.perform(urlRequest, session: session, policy: retryPolicy)
        let response = try JSONDecoder().decode(VolcengineTranslateResponse.self, from: data)
        if let error = response.responseMetadata?.error {
            switch error.code {
            case "-415": throw HelloXError.languageNotSupported
            case "-429": throw HelloXError.rateLimited
            default: throw HelloXError.network(error.message ?? error.code)
            }
        }
        guard let translation = response.translationList?.first,
              !translation.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelloXError.invalidResponse
        }
        return TranslationResult(
            text: translation.translation,
            detectedSourceLanguage: translation.detectedSourceLanguage,
            providerName: name
        )
    }
}

public struct NiuTransTranslationConfiguration: Sendable {
    public let baseURL: URL
    public let appID: String
    public let apiKey: String

    public init(baseURL: URL, appID: String, apiKey: String) {
        self.baseURL = baseURL
        self.appID = appID
        self.apiKey = apiKey
    }
}

public final class NiuTransTranslationProvider: TranslationProvider, @unchecked Sendable {
    public let name = "小牛翻译"
    private let configuration: NiuTransTranslationConfiguration
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let currentTimestamp: @Sendable () -> Int64

    public init(
        configuration: NiuTransTranslationConfiguration,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = RetryPolicy(),
        currentTimestamp: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.configuration = configuration
        self.session = session
        self.retryPolicy = retryPolicy
        self.currentTimestamp = currentTimestamp
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HelloXError.invalidConfiguration("翻译文本不能为空") }
        guard !configuration.appID.isEmpty else { throw HelloXError.invalidConfiguration("请填写 APPID") }
        guard !configuration.apiKey.isEmpty else { throw HelloXError.invalidConfiguration("请填写 APIKEY") }
        guard request.text.count <= 5_000 else {
            throw HelloXError.invalidConfiguration("小牛翻译单次最多支持 5000 个字符")
        }
        guard configuration.baseURL.scheme?.lowercased() == "https",
              configuration.baseURL.host != nil else {
            throw HelloXError.invalidConfiguration("小牛翻译必须使用 HTTPS")
        }

        let timestamp = currentTimestamp()
        let parameters: [String: String] = [
            "from": Self.languageCode(for: request.sourceLanguage),
            "to": Self.languageCode(for: request.targetLanguage),
            "appId": configuration.appID,
            "srcText": request.text,
            "timestamp": String(timestamp)
        ]
        let authStr = Self.authorizationDigest(parameters: parameters, apiKey: configuration.apiKey)
        let payload = NiuTransTranslateRequest(
            from: parameters["from"]!,
            to: parameters["to"]!,
            appID: configuration.appID,
            srcText: request.text,
            timestamp: timestamp,
            authStr: authStr
        )
        var urlRequest = URLRequest(url: configuration.baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await HTTPRetrier.perform(urlRequest, session: session, policy: retryPolicy)
        let response = try JSONDecoder().decode(NiuTransTranslateResponse.self, from: data)
        if let code = response.errorCode, !code.isEmpty, code != "0" {
            switch code {
            case "10001": throw HelloXError.rateLimited
            case "10003": throw HelloXError.invalidConfiguration("小牛翻译单次最多支持 5000 个字符")
            case "13005", "13007": throw HelloXError.languageNotSupported
            case "13001", "20001": throw HelloXError.authenticationFailed
            default: throw HelloXError.network(response.errorMsg ?? "小牛翻译错误：\(code)")
            }
        }
        guard let translated = response.tgtText?.trimmingCharacters(in: .whitespacesAndNewlines), !translated.isEmpty else {
            throw HelloXError.invalidResponse
        }
        return TranslationResult(text: translated, detectedSourceLanguage: response.from, providerName: name)
    }

    public static func languageCode(for language: SupportedLanguage) -> String {
        if language == .auto { return "auto" }
        if language == .traditionalChinese { return "cht" }
        return language.rawValue
    }

    public static func authorizationDigest(parameters: [String: String], apiKey: String) -> String {
        var values = parameters.filter { !$0.value.isEmpty }
        if !apiKey.isEmpty { values["apikey"] = apiKey }
        let parameterString = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "&")
        return Data(Insecure.MD5.hash(data: Data(parameterString.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}

private struct NiuTransTranslateRequest: Encodable {
    let from: String
    let to: String
    let appID: String
    let srcText: String
    let timestamp: Int64
    let authStr: String

    enum CodingKeys: String, CodingKey {
        case from, to, appID = "appId", srcText, timestamp, authStr
    }
}

private struct NiuTransTranslateResponse: Decodable {
    let from: String?
    let to: String?
    let tgtText: String?
    let errorCode: String?
    let errorMsg: String?

    enum CodingKeys: String, CodingKey { case from, to, tgtText, srcText, errorCode, errorMsg }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decodeIfPresent(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        tgtText = try container.decodeIfPresent(String.self, forKey: .tgtText)
        errorMsg = try container.decodeIfPresent(String.self, forKey: .errorMsg)
        if let value = try? container.decode(String.self, forKey: .errorCode) { errorCode = value }
        else if let value = try? container.decode(Int.self, forKey: .errorCode) { errorCode = String(value) }
        else { errorCode = nil }
    }
}

private struct VolcengineTranslateRequest: Encodable {
    let sourceLanguage: String?
    let targetLanguage: String
    let textList: [String]

    enum CodingKeys: String, CodingKey {
        case sourceLanguage = "SourceLanguage"
        case targetLanguage = "TargetLanguage"
        case textList = "TextList"
    }
}

private struct VolcengineTranslateResponse: Decodable {
    struct Translation: Decodable {
        let translation: String
        let detectedSourceLanguage: String?

        enum CodingKeys: String, CodingKey {
            case translation = "Translation"
            case detectedSourceLanguage = "DetectedSourceLanguage"
        }
    }

    struct ResponseMetadata: Decodable {
        struct APIError: Decodable {
            let code: String
            let message: String?

            enum CodingKeys: String, CodingKey { case code = "Code"; case message = "Message" }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let value = try? container.decode(String.self, forKey: .code) { code = value }
                else if let value = try? container.decode(Int.self, forKey: .code) { code = String(value) }
                else { code = "unknown" }
                message = try container.decodeIfPresent(String.self, forKey: .message)
            }
        }

        let error: APIError?
        enum CodingKeys: String, CodingKey { case error = "Error" }
    }

    let translationList: [Translation]?
    let responseMetadata: ResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case translationList = "TranslationList"
        case responseMetadata = "ResponseMetadata"
    }
}

private enum VolcengineV4Signer {
    static func sign(
        request: inout URLRequest,
        body: Data,
        host: String,
        accessKeyID: String,
        secretAccessKey: String,
        date: Date,
        region: String,
        service: String
    ) {
        let xDate = timestamp(date)
        let shortDate = String(xDate.prefix(8))
        let payloadHash = sha256Hex(body)
        let contentType = "application/json"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders = [
            "content-type:\(contentType)",
            "host:\(host)",
            "x-content-sha256:\(payloadHash)",
            "x-date:\(xDate)"
        ].joined(separator: "\n")
        let canonicalQuery = request.url?.query ?? ""
        let canonicalRequest = [
            request.httpMethod ?? "POST",
            request.url?.path.isEmpty == false ? request.url!.path : "/",
            canonicalQuery,
            canonicalHeaders,
            "",
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let credentialScope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let dateKey = hmac(key: Data(secretAccessKey.utf8), message: shortDate)
        let regionKey = hmac(key: dateKey, message: region)
        let serviceKey = hmac(key: regionKey, message: service)
        let signingKey = hmac(key: serviceKey, message: "request")
        let signature = hmac(key: signingKey, message: stringToSign).hexEncodedString
        let authorization = "HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexEncodedString
    }

    private static func hmac(key: Data, message: String) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(authenticationCode)
    }
}

private extension Data {
    var hexEncodedString: String { map { String(format: "%02x", $0) }.joined() }
}
