import CryptoKit
import Foundation

public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    private let components: [Int]

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let numbers = source.split(separator: ".", omittingEmptySubsequences: false)
        guard !numbers.isEmpty, numbers.count <= 3 else { return nil }
        let parsed = numbers.compactMap { Int($0) }
        guard parsed.count == numbers.count, parsed.allSatisfy({ $0 >= 0 }) else { return nil }
        components = parsed + Array(repeating: 0, count: 3 - parsed.count)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct GitHubRelease: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public let name: String
        public let downloadURL: URL

        public init(name: String, downloadURL: URL) {
            self.name = name
            self.downloadURL = downloadURL
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let pageURL: URL
    public let assets: [Asset]

    public init(tagName: String, isDraft: Bool, isPrerelease: Bool, pageURL: URL, assets: [Asset]) {
        self.tagName = tagName
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.pageURL = pageURL
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case pageURL = "html_url"
        case assets
    }
}

public struct AppUpdate: Equatable, Sendable {
    public let version: SemanticVersion
    public let releaseURL: URL
    public let dmgURL: URL
    public let checksumURL: URL

    public init(version: SemanticVersion, releaseURL: URL, dmgURL: URL, checksumURL: URL) {
        self.version = version
        self.releaseURL = releaseURL
        self.dmgURL = dmgURL
        self.checksumURL = checksumURL
    }
}

public enum AppUpdateError: LocalizedError, Equatable, Sendable {
    case invalidCurrentVersion
    case invalidReleaseVersion
    case missingDMG
    case missingChecksum
    case invalidChecksum
    case checksumMismatch
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: "当前应用版本格式无效"
        case .invalidReleaseVersion: "发布版本格式无效"
        case .missingDMG: "发布版本缺少 DMG 安装包"
        case .missingChecksum: "发布版本缺少 SHA-256 校验文件"
        case .invalidChecksum: "SHA-256 校验文件格式无效"
        case .checksumMismatch: "下载文件的 SHA-256 校验失败"
        case .invalidResponse: "更新服务器返回了无效数据"
        case .httpStatus(let status): "更新服务器返回 HTTP \(status)"
        }
    }
}

public final class GitHubReleaseClient: @unchecked Sendable {
    public static let defaultRepository = "HelloX-ZhaoWen/hellox"

    private let repository: String
    private let session: URLSession

    public init(repository: String = GitHubReleaseClient.defaultRepository, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    public func check(currentVersion: String) async throws -> AppUpdate? {
        guard let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw AppUpdateError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HelloX", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else { throw AppUpdateError.httpStatus(httpResponse.statusCode) }
        return try Self.update(from: JSONDecoder().decode(GitHubRelease.self, from: data), currentVersion: currentVersion)
    }

    public func download(_ update: AppUpdate, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (temporaryURL, response) = try await session.download(from: update.dmgURL)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateError.invalidResponse
        }
        let destination = directory.appendingPathComponent(update.dmgURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        let (checksumData, checksumResponse) = try await session.data(from: update.checksumURL)
        guard let checksumHTTPResponse = checksumResponse as? HTTPURLResponse,
              (200..<300).contains(checksumHTTPResponse.statusCode) else {
            throw AppUpdateError.invalidResponse
        }
        guard try Self.sha256(of: destination) == Self.checksum(from: checksumData) else {
            try? FileManager.default.removeItem(at: destination)
            throw AppUpdateError.checksumMismatch
        }
        return destination
    }

    public static func update(from release: GitHubRelease, currentVersion: String) throws -> AppUpdate? {
        guard let current = SemanticVersion(currentVersion) else { throw AppUpdateError.invalidCurrentVersion }
        guard let version = SemanticVersion(release.tagName) else { throw AppUpdateError.invalidReleaseVersion }
        guard !release.isDraft, !release.isPrerelease, version > current else { return nil }

        let baseName = "HelloX-\(version).dmg"
        guard let dmg = release.assets.first(where: { $0.name == baseName }) else {
            throw AppUpdateError.missingDMG
        }
        guard let checksum = release.assets.first(where: { $0.name == "\(baseName).sha256" }) else {
            throw AppUpdateError.missingChecksum
        }
        return AppUpdate(version: version, releaseURL: release.pageURL, dmgURL: dmg.downloadURL, checksumURL: checksum.downloadURL)
    }

    public static func checksum(from data: Data) throws -> String {
        guard let content = String(data: data, encoding: .utf8),
              let token = content.split(whereSeparator: { $0.isWhitespace }).first else {
            throw AppUpdateError.invalidChecksum
        }
        let firstToken = token.lowercased()
        guard
            firstToken.count == 64,
            firstToken.allSatisfy({ $0.isHexDigit }) else {
            throw AppUpdateError.invalidChecksum
        }
        return firstToken
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
