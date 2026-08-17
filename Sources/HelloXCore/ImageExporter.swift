import AppKit
import Foundation
import UniformTypeIdentifiers

public enum ImageExportFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    public var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }
    public var contentType: UTType { self == .png ? .png : .jpeg }
}

public enum PasteboardWriteResult: Equatable, Sendable {
    case success(changeCount: Int)
    case failure(String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case .failure(let message) = self { return message }
        return nil
    }
}

@MainActor
public protocol PasteboardWriting: AnyObject {
    var changeCount: Int { get }
    func clearContents()
    func writeImage(pngData: Data, tiffData: Data) -> Bool
    func containsImage() -> Bool
}

@MainActor
public final class SystemPasteboardWriter: PasteboardWriting {
    public static let shared = SystemPasteboardWriter()
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }
    public func clearContents() { pasteboard.clearContents() }

    public func writeImage(pngData: Data, tiffData: Data) -> Bool {
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setData(tiffData, forType: .tiff)
        return pasteboard.writeObjects([item])
    }

    public func containsImage() -> Bool {
        pasteboard.data(forType: .png) != nil
            && pasteboard.data(forType: .tiff) != nil
            && NSImage(pasteboard: pasteboard) != nil
    }
}

public enum ImageExporter {
    private struct PasteboardData: Sendable {
        let png: Data
        let tiff: Data
    }

    public static func data(from image: CGImage, format: ImageExportFormat, quality: CGFloat = 1) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        let data: Data?
        switch format {
        case .png:
            data = representation.representation(using: .png, properties: [:])
        case .jpeg:
            data = representation.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        guard let data else { throw HelloXError.captureFailed("无法编码图片") }
        return data
    }

    public static func write(_ image: CGImage, to url: URL, format: ImageExportFormat, quality: CGFloat = 1) throws {
        try data(from: image, format: format, quality: quality).write(to: url, options: .atomic)
    }

    public static func writeAsync(
        _ image: CGImage,
        to url: URL,
        format: ImageExportFormat,
        quality: CGFloat = 1
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try data(from: image, format: format, quality: quality).write(to: url, options: .atomic)
        }.value
    }

    @MainActor
    public static func copyToPasteboardAsync(
        _ image: CGImage,
        writer: any PasteboardWriting = SystemPasteboardWriter.shared
    ) async -> PasteboardWriteResult {
        let encoded: PasteboardData
        do {
            encoded = try await Task.detached(priority: .userInitiated) {
                let representation = NSBitmapImageRep(cgImage: image)
                guard let png = representation.representation(using: .png, properties: [:]),
                      let tiff = representation.tiffRepresentation else {
                    throw HelloXError.captureFailed("无法编码剪贴板图片")
                }
                return PasteboardData(png: png, tiff: tiff)
            }.value
        } catch {
            return .failure(error.localizedDescription)
        }
        let previousChangeCount = writer.changeCount
        writer.clearContents()
        guard writer.writeImage(pngData: encoded.png, tiffData: encoded.tiff) else {
            return .failure("系统剪贴板拒绝写入图片")
        }
        let newChangeCount = writer.changeCount
        guard newChangeCount != previousChangeCount, writer.containsImage() else {
            return .failure("剪贴板中没有可读取的 PNG/TIFF 图片")
        }
        return .success(changeCount: newChangeCount)
    }

    @MainActor
    public static func copyToPasteboard(
        _ image: CGImage,
        writer: any PasteboardWriting = SystemPasteboardWriter.shared
    ) -> PasteboardWriteResult {
        do {
            let representation = NSBitmapImageRep(cgImage: image)
            guard let pngData = representation.representation(using: .png, properties: [:]),
                  let tiffData = representation.tiffRepresentation else {
                return .failure("无法编码剪贴板图片")
            }
            let previousChangeCount = writer.changeCount
            writer.clearContents()
            guard writer.writeImage(pngData: pngData, tiffData: tiffData) else {
                return .failure("系统剪贴板拒绝写入图片")
            }
            let newChangeCount = writer.changeCount
            guard newChangeCount != previousChangeCount, writer.containsImage() else {
                return .failure("剪贴板中没有可读取的 PNG/TIFF 图片")
            }
            return .success(changeCount: newChangeCount)
        }
    }
}
