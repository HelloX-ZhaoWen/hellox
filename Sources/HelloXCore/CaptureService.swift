@preconcurrency import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import ScreenCaptureKit
import Darwin

public protocol ScreenCapturing: Sendable {
    func captureRegion(_ rect: CGRect) async throws -> CaptureResult
    func captureRegion(_ rect: CGRect, excludingOwnWindows: Bool) async throws -> CaptureResult
    func captureDisplay(containing point: CGPoint?) async throws -> CaptureResult
    func captureWindow(at point: CGPoint?) async throws -> CaptureResult
}

public extension ScreenCapturing {
    /// Test capturers do not composite app windows, so their normal region
    /// capture is already equivalent to an overlay-free capture.
    func captureRegion(_ rect: CGRect, excludingOwnWindows: Bool) async throws -> CaptureResult {
        try await captureRegion(rect)
    }
}

public final class ScreenCaptureService: NSObject, ScreenCapturing, @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    public override init() {
        super.init()
    }

    public func captureRegion(_ rect: CGRect) async throws -> CaptureResult {
        try await captureRegion(rect, excludingOwnWindows: false)
    }

    public func captureRegion(
        _ rect: CGRect,
        excludingOwnWindows: Bool
    ) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelloXError.screenRecordingPermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { display in
            CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                   width: display.frame.width, height: display.frame.height).intersects(rect)
        }) else {
            throw HelloXError.captureFailed("找不到选区所在的显示器")
        }

        let displayFrame = CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                                  width: display.frame.width, height: display.frame.height)
        let clipped = rect.intersection(displayFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw HelloXError.captureFailed("截图区域无效")
        }
        let localRect = CGRect(
            x: clipped.minX - displayFrame.minX,
            y: clipped.minY - displayFrame.minY,
            width: clipped.width,
            height: clipped.height
        )
        let scale = displayScale(for: display)
        let configuration = makeConfiguration(sourceRect: localRect, scale: scale)

        let excludedWindows: [SCWindow]
        if excludingOwnWindows {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            excludedWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        } else {
            // Preserve transient system pop-ups for ordinary region captures.
            excludedWindows = []
        }
        let filter = SCContentFilter(
            display: display,
            excludingWindows: excludedWindows
        )
        let image = try await capture(filter: filter, configuration: configuration)
        return CaptureResult(image: image, displayScale: scale, capturedRect: clipped, mode: .region)
    }



    public func captureDisplay(containing point: CGPoint? = nil) async throws -> CaptureResult {
        try await captureDisplay(containing: point, excludingOwnApplication: true)
    }

    public func captureDisplay(containing point: CGPoint? = nil, excludingOwnApplication: Bool) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelloXError.screenRecordingPermissionDenied
        }
        let targetPoint = point ?? coreGraphicsPoint(fromAppKit: NSEvent.mouseLocation)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays.first(where: { $0.frame.contains(targetPoint) }) ?? content.displays.first
        guard let display else { throw HelloXError.captureFailed("找不到显示器") }
        let scale = displayScale(for: display)
        let configuration = makeConfiguration(
            sourceRect: CGRect(origin: .zero, size: display.frame.size),
            scale: scale
        )
        let image: CGImage
        if excludingOwnApplication {
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications(in: content),
                exceptingWindows: []
            )
            image = try await capture(filter: filter, configuration: configuration)
        } else {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            image = try await captureDisplayFrame(
                displayFrame: display.frame,
                fallbackFilter: filter,
                fallbackConfiguration: configuration
            )
        }
        let actualScale = display.frame.width > 0
            ? CGFloat(image.width) / display.frame.width
            : scale
        return CaptureResult(image: image, displayScale: actualScale, capturedRect: display.frame, mode: .fullScreen)
    }

    public func captureWindow(at point: CGPoint? = nil) async throws -> CaptureResult {
        try await captureWindow(at: point, excludingOwnApplication: true)
    }

    public func captureWindow(at point: CGPoint? = nil, excludingOwnApplication: Bool) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelloXError.screenRecordingPermissionDenied
        }
        let targetPoint = point ?? coreGraphicsPoint(fromAppKit: NSEvent.mouseLocation)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { window in
            (!excludingOwnApplication || window.owningApplication?.processID != ownPID) &&
            window.frame.contains(targetPoint) &&
            window.frame.width > 40 && window.frame.height > 40
        }
        guard let window = candidates.min(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) ?? content.windows.first(where: {
            !excludingOwnApplication || $0.owningApplication?.processID != ownPID
        }) else {
            throw HelloXError.captureFailed("鼠标位置没有可截图的窗口")
        }
        let targetDisplay = content.displays.max { lhs, rhs in
            let lhsIntersection = lhs.frame.intersection(window.frame)
            let rhsIntersection = rhs.frame.intersection(window.frame)
            return lhsIntersection.width * lhsIntersection.height
                < rhsIntersection.width * rhsIntersection.height
        }
        let scale = targetDisplay.map(displayScale(for:))
            ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })?.backingScaleFactor
            ?? 1
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        Self.configureSDRColorOutput(configuration)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await capture(filter: filter, configuration: configuration)
        return CaptureResult(image: image, displayScale: scale, capturedRect: window.frame, mode: .window)
    }

    private func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
    }

    private func makeConfiguration(sourceRect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width * scale))
        configuration.height = max(1, Int(sourceRect.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        Self.configureSDRColorOutput(configuration)
        return configuration
    }

    private func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let image: CGImage
        if #available(macOS 14.0, *) {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } else {
            let receiver = SingleFrameReceiver(ciContext: ciContext)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            image = try await withTaskCancellationHandler {
                try await receiver.capture(from: stream)
            } onCancel: {
                receiver.cancel()
                Task { try? await stream.stopCapture() }
            }
        }
        return normalizedToSRGB(image)
    }

    /// Core Graphics composites the currently visible desktop, including transient
    /// pop-up menus. The selection overlay is shown immediately after this frame is
    /// captured, so retaining this image keeps a context menu in the final crop.
    private func captureDisplayFrame(
        displayFrame: CGRect,
        fallbackFilter: SCContentFilter,
        fallbackConfiguration: SCStreamConfiguration
    ) async throws -> CGImage {
        if let image = legacyDisplayComposite(
            displayFrame: displayFrame,
            listOptions: .optionOnScreenOnly,
            imageOptions: [.bestResolution, .boundsIgnoreFraming]
        ) {
            return normalizedToSRGB(image)
        }
        return try await capture(filter: fallbackFilter, configuration: fallbackConfiguration)
    }

    private func legacyDisplayComposite(
        displayFrame: CGRect,
        listOptions: CGWindowListOption,
        imageOptions: CGWindowImageOption
    ) -> CGImage? {
        typealias CreateImage = @convention(c) (
            CGRect,
            CGWindowListOption,
            CGWindowID,
            CGWindowImageOption
        ) -> CGImage?
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        return createImage(displayFrame, listOptions, kCGNullWindowID, imageOptions)
    }

    static func configureSDRColorOutput(_ configuration: SCStreamConfiguration) {
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureDynamicRange = .SDR
    }

    private func normalizedToSRGB(_ image: CGImage) -> CGImage {
        guard image.colorSpace?.name != CGColorSpace.sRGB,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let input = CIImage(cgImage: image)
        return ciContext.createCGImage(
            input,
            from: input.extent,
            format: .BGRA8,
            colorSpace: colorSpace
        ) ?? image
    }

    private func displayScale(for display: SCDisplay) -> CGFloat {
        // SCDisplay.width/height are logical points on Retina displays (for
        // example 1512x982 for a 3024x1964 panel), so prefer AppKit's backing
        // scale when the display IDs can be matched.
        let backingScale = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        })?.backingScaleFactor
        return Self.captureScale(
            backingScale: backingScale,
            reportedSize: CGSize(width: display.width, height: display.height),
            frameSize: display.frame.size
        )
    }

    static func captureScale(
        backingScale: CGFloat?,
        reportedSize: CGSize,
        frameSize: CGSize
    ) -> CGFloat {
        if let backingScale, backingScale.isFinite, backingScale >= 1 { return backingScale }
        let horizontalScale = frameSize.width > 0
            ? reportedSize.width / frameSize.width
            : 0
        let verticalScale = frameSize.height > 0
            ? reportedSize.height / frameSize.height
            : 0
        let nativeScale = max(horizontalScale, verticalScale)
        if nativeScale.isFinite, nativeScale >= 1 { return nativeScale }
        return 1
    }

    private func coreGraphicsPoint(fromAppKit point: CGPoint) -> CGPoint {
        let appKitBounds = CoordinateMapper.union(NSScreen.screens.map(\.frame))
        let coreGraphicsBounds = coreGraphicsDesktopBounds()
        return CGPoint(x: point.x, y: appKitBounds.maxY - point.y + coreGraphicsBounds.minY)
    }

    private func coreGraphicsDesktopBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CoordinateMapper.union(NSScreen.screens.map(\.frame))
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return CoordinateMapper.union(NSScreen.screens.map(\.frame))
        }
        return CoordinateMapper.union(displays.map(CGDisplayBounds))
    }
}

private final class SingleFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.hellox.single-frame")
    private let ciContext: CIContext
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var finished = false

    init(ciContext: CIContext) {
        self.ciContext = ciContext
    }

    func capture(from stream: SCStream) async throws -> CGImage {
        self.stream = stream
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            Task {
                do { try await stream.startCapture() }
                catch { self.finish(.failure(error)) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        finish(.success(image))
        Task { try? await stream.stopCapture() }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
