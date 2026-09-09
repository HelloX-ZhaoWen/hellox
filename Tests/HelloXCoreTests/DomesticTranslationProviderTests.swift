import Foundation
import Testing
@testable import HelloXCore

struct DomesticTranslationProviderTests {
    private func baidu() -> BaiduTranslationProvider {
        BaiduTranslationProvider(profile: TranslationProfile(name: "百度", vendor: .baidu,
            options: ["appID": "2015063000000001"]), apiKey: "1234567890")
    }

    private func aliyun() -> AliyunTranslationProvider {
        AliyunTranslationProvider(profile: TranslationProfile(name: "阿里", vendor: .aliyun,
            options: ["accessKeyID": "testid"]), apiKey: "testsecret")
    }

    private func parameters(_ request: URLRequest) throws -> [String: String] {
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        var components = URLComponents()
        components.percentEncodedQuery = [request.url?.query, body].compactMap { $0 }.joined(separator: "&")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func baiduMatchesOfficialSignatureExample() throws {
        let request = try baidu().makeRequest(.init(text: "apple", sourceLanguage: .english,
            targetLanguage: .simplifiedChinese), salt: "65478")
        let params = try parameters(request)
        #expect(params["sign"] == "a1a7461d92e5194c5cae3182b5b24de1")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test func baiduSignsRawUnicodeThenEncodesFormAndMapsLanguages() throws {
        let text = "你好 + &🙂\nHello"
        let request = try baidu().makeRequest(.init(text: text, sourceLanguage: .japanese,
            targetLanguage: .traditionalChinese), salt: "65478")
        let params = try parameters(request)
        #expect(params["q"] == text)
        // Independent Python hashlib fixture, including reserved URL characters.
        #expect(params["sign"] == "3e0a31dd357cb6d4713a290e17651ae8")
        #expect(params["from"] == "jp")
        #expect(params["to"] == "cht")
        #expect(try BaiduTranslationProvider.languageCode(.korean) == "kor")
        #expect(try BaiduTranslationProvider.languageCode(.french) == "fra")
        #expect(throws: HelloXError.languageNotSupported) { try BaiduTranslationProvider.languageCode(.hindi) }
    }

    @Test func aliyunSignsQueryAndBodyWithIndependentHMACFixture() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-09T00:00:00Z"))
        let text = "你好 + &🙂\nHello"
        let request = try aliyun().makeRequest(.init(text: text, sourceLanguage: .auto,
            targetLanguage: .traditionalChinese), date: date, nonce: "fixed-nonce")
        let params = try parameters(request)
        #expect(params["Signature"] == "CAu5RG6ZPM7HBZlu9tet0b9J+LQ=")
        #expect(params["Action"] == "TranslateGeneral")
        #expect(params["SourceText"] == text)
        #expect(params["TargetLanguage"] == "zh-tw")
        #expect(params["Scene"] == "general")
        #expect(params["Timestamp"] == "2026-09-09T00:00:00Z")
        #expect(request.url?.query?.contains("SourceText") == false)
        #expect(request.url?.absoluteString.contains("testsecret") == false)
    }

    @Test func decodesMultipleParagraphsAndNormalizesDetectedLanguage() throws {
        let result = try baidu().decodeResponse(Data(#"{"from":"jp","trans_result":[{"dst":"你好"},{"dst":"世界"}]}"#.utf8))
        #expect(result.text == "你好\n世界")
        #expect(result.detectedSourceLanguage == "ja")
        let ali = try aliyun().decodeResponse(Data(#"{"Code":200,"Data":{"Translated":"你好\n世界","DetectedLanguage":"zh-tw"}}"#.utf8))
        #expect(ali.text == "你好\n世界")
        #expect(ali.detectedSourceLanguage == "zh-Hant")
    }

    @Test func handlesProviderErrorsAndMalformedResponses() throws {
        for code in ["54003", "54005"] {
            #expect(throws: HelloXError.rateLimited) {
                try baidu().decodeResponse(Data("{\"error_code\":\"\(code)\"}".utf8))
            }
        }
        #expect(throws: HelloXError.authenticationFailed) {
            try baidu().decodeResponse(Data(#"{"error_code":54001}"#.utf8))
        }
        #expect(throws: HelloXError.languageNotSupported) {
            try aliyun().decodeResponse(Data(#"{"Code":"10005"}"#.utf8))
        }
        #expect(throws: HelloXError.invalidConfiguration("阿里云翻译服务未开通或额度 / 余额不足，请查看服务商控制台")) {
            try aliyun().decodeResponse(Data(#"{"Code":10013}"#.utf8))
        }
        for json in ["{}", "[]", "not json", #"{"trans_result":[]}"#, #"{"trans_result":[{"dst":" "}]}"#] {
            #expect(throws: HelloXError.invalidResponse) { try baidu().decodeResponse(Data(json.utf8)) }
        }
        #expect(throws: HelloXError.invalidResponse) {
            try aliyun().decodeResponse(Data(#"{"Code":200,"Data":{"Translated":""}}"#.utf8))
        }
    }

    @Test func rejectsMissingCredentialsInsecureEndpointsAndOversizedInput() throws {
        for vendor in [TranslationVendor.baidu, .aliyun] {
            var profile = TranslationProfile.preset(vendor)
            #expect(throws: (any Error).self) { try profile.validate(hasAPIKey: true) }
            profile.options = ["appID": "test", "accessKeyID": "test"]
            #expect(throws: (any Error).self) { try profile.validate(hasAPIKey: false) }
            profile.baseURL = "http://example.com"
            #expect(throws: (any Error).self) { try profile.validate(hasAPIKey: true) }
            profile.baseURL = "https:///"
            #expect(throws: (any Error).self) { try profile.validate(hasAPIKey: true) }
        }
        for text in ["  \n", String(repeating: "🙂", count: 501)] {
            #expect(throws: (any Error).self) {
                try baidu().makeRequest(.init(text: text, sourceLanguage: .auto, targetLanguage: .english), salt: "salt")
            }
        }
        #expect(throws: HelloXError.languageNotSupported) {
            try baidu().makeRequest(.init(text: "Hello", sourceLanguage: .english, targetLanguage: .auto), salt: "salt")
        }
        #expect(throws: (any Error).self) {
            try aliyun().makeRequest(.init(text: String(repeating: "a", count: 5001), sourceLanguage: .auto,
                targetLanguage: .english), date: Date(), nonce: "nonce")
        }
    }

    @Test func screenshotBatchesRespectBaiduLimitIncludingUnicodeAndMarkers() throws {
        let paragraphs = (0..<4).map { _ in (id: UUID(), text: String(repeating: "🙂", count: 300)) }
        let batches = try ScreenshotTranslationBatchCodec.batches(
            for: paragraphs, maximumCharacterCount: TranslationVendor.baidu.maximumRequestCharacterCount
        )
        #expect(batches.count == 4)
        #expect(batches.allSatisfy { $0.text.utf16.count <= 1000 })
        for batch in batches {
            _ = try baidu().makeRequest(.init(text: batch.text, sourceLanguage: .auto,
                targetLanguage: .english, purpose: .screenshotBatch), salt: "salt")
        }
    }

    @Test func factoryRoutesBothServicesThroughURLSessionAndProfilesRoundTrip() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DomesticTranslationURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for vendor in [TranslationVendor.baidu, .aliyun] {
            let profile = TranslationProfile(name: vendor.displayName, vendor: vendor,
                options: ["appID": "test", "accessKeyID": "test"])
            let saved = try JSONDecoder().decode(TranslationProfile.self, from: JSONEncoder().encode(profile))
            #expect(saved == profile)
            let provider = try TranslationProviderFactory.make(profile: saved, apiKey: "fixture-secret", session: session)
            let result = try await provider.translate(.init(text: "Hello", sourceLanguage: .auto, targetLanguage: .simplifiedChinese))
            #expect(result.text == "你好")
            #expect(result.providerName == vendor.displayName)
        }
    }
}

private final class DomesticTranslationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json = request.url?.host == "fanyi-api.baidu.com"
            ? #"{"from":"en","trans_result":[{"dst":"你好"}]}"#
            : #"{"Code":200,"Data":{"Translated":"你好","DetectedLanguage":"en"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
