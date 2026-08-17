@preconcurrency import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit

public enum ScreenRecordingGeometry {
    public static func outputSize(
        sourceSize: CGSize,
        scale: CGFloat,
        maximumDimension: CGFloat = 3_840
    ) -> CGSize {
        let pixelSize = CGSize(
            width: max(2, sourceSize.width * scale),
            height: max(2, sourceSize.height * scale)
        )
        let reduction = min(1, maximumDimension / max(pixelSize.width, pixelSize.height))
        return CGSize(
            width: evenPixelValue(pixelSize.width * reduction),
            height: evenPixelValue(pixelSize.height * reduction)
        )
    }

    private static func evenPixelValue(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int(value.rounded(.down)) / 2 * 2))
    }
}

public final class ScreenRecordingService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public var onUnexpectedStop: (@Sendable (Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.hellox.screen-recording", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var isStopping = false
    private var receivedFrame = false

    public override init() {
        super.init()
    }

    public func startRecording(
        region: CGRect,
        outputURL: URL,
        excludingWindowIDs: Set<CGWindowID> = []
    ) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelloXError.screenRecordingPermissionDenied
        }
        guard region.width >= 4, region.height >= 4 else {
            throw HelloXError.invalidConfiguration("录屏区域过小")
        }

        let alreadyRecording = stateLock.withLock { self.stream != nil }
        guard !alreadyRecording else {
            throw HelloXError.invalidConfiguration("已有录屏正在进行")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard var display = content.displays.first else {
            throw HelloXError.captureFailed("找不到录屏区域所在的显示器")
        }
        var bestIntersection = Self.intersectionArea(display.frame, region)
        for candidate in content.displays.dropFirst() {
            let area = Self.intersectionArea(candidate.frame, region)
            if area > bestIntersection {
                display = candidate
                bestIntersection = area
            }
        }
        let clipped = region.intersection(display.frame)
        guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else {
            throw HelloXError.invalidConfiguration("录屏区域不在可用显示器内")
        }

        let localRect = CGRect(
            x: clipped.minX - display.frame.minX,
            y: clipped.minY - display.frame.minY,
            width: clipped.width,
            height: clipped.height
        )
        let scale = displayScale(for: display.displayID)
        let outputSize = ScreenRecordingGeometry.outputSize(sourceSize: localRect.size, scale: scale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let excludedWindows = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let writer = try makeWriter(outputURL: outputURL, outputSize: outputSize)
        let input = try makeVideoInput(outputSize: outputSize)
        guard writer.canAdd(input) else {
            throw HelloXError.captureFailed("无法创建视频编码轨道")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? HelloXError.captureFailed("无法启动视频编码器")
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        stateLock.withLock {
            self.stream = stream
            self.writer = writer
            videoInput = input
            self.outputURL = outputURL
            isStopping = false
            receivedFrame = false
        }

        do {
            try await stream.startCapture()
        } catch {
            cleanupFailedRecording(removeFile: true)
            throw error
        }
    }

    @discardableResult
    public func stopRecording() async throws -> URL {
        let currentState: (SCStream, AVAssetWriter, AVAssetWriterInput, URL)? = stateLock.withLock {
            guard let stream, let writer, let input = videoInput, let outputURL, !isStopping else {
                return nil
            }
            isStopping = true
            return (stream, writer, input, outputURL)
        }
        guard let (stream, writer, input, outputURL) = currentState else {
            throw HelloXError.invalidConfiguration("当前没有正在进行的录屏")
        }

        try await stream.stopCapture()
        return try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                guard receivedFrame, writer.status == .writing else {
                    let error = writer.error ?? HelloXError.captureFailed("录屏没有产生有效画面")
                    writer.cancelWriting()
                    cleanupFailedRecording(removeFile: true)
                    continuation.resume(throwing: error)
                    return
                }
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        resetState()
                        continuation.resume(returning: outputURL)
                    } else {
                        let error = writer.error ?? HelloXError.captureFailed("视频保存失败")
                        cleanupFailedRecording(removeFile: true)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func cancelRecording() async {
        let (currentStream, currentWriter) = stateLock.withLock {
            isStopping = true
            return (stream, writer)
        }
        if let currentStream { try? await currentStream.stopCapture() }
        sampleQueue.sync {
            currentWriter?.cancelWriting()
            cleanupFailedRecording(removeFile: true)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let shouldReport = !isStopping
        stateLock.unlock()
        guard shouldReport else { return }
        sampleQueue.async { [self] in
            cleanupFailedRecording(removeFile: true)
            onUnexpectedStop?(error)
        }
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              sampleBuffer.formatDescription != nil,
              isCompleteFrame(sampleBuffer) else { return }

        stateLock.lock()
        let writer = self.writer
        let input = videoInput
        let stopping = isStopping
        stateLock.unlock()
        guard !stopping, let writer, let input, writer.status == .writing else { return }

        if !receivedFrame {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            receivedFrame = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    private func makeWriter(outputURL: URL, outputSize: CGSize) throws -> AVAssetWriter {
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        return try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    }

    private func makeVideoInput(outputSize: CGSize) throws -> AVAssetWriterInput {
        let pixels = max(1, outputSize.width * outputSize.height)
        let bitrate = min(24_000_000, max(4_000_000, Int(pixels * 5)))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let rawValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawValue) else {
            return true
        }
        return status == .complete
    }

    private func displayScale(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        })?.backingScaleFactor ?? 1
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func cleanupFailedRecording(removeFile: Bool) {
        stateLock.lock()
        let url = outputURL
        writer?.cancelWriting()
        stream = nil
        writer = nil
        videoInput = nil
        outputURL = nil
        isStopping = false
        receivedFrame = false
        stateLock.unlock()
        if removeFile, let url { try? FileManager.default.removeItem(at: url) }
    }

    private func resetState() {
        stateLock.lock()
        stream = nil
        writer = nil
        videoInput = nil
        outputURL = nil
        isStopping = false
        receivedFrame = false
        stateLock.unlock()
    }
}
