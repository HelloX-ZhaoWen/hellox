@preconcurrency import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import ScreenCaptureKit
import Darwin

public protocol ScreenCapturing: Sendable {
    func captureRegion(_ rect: CGRect) async throws -> CaptureResult
    func captureRegion(_ rect: CGRect, excludingOwnWindows: Bool) async throws -> CaptureResult
    func prepareRegionCapture(
        _ rect: CGRect,
        excludingOwnWindows: Bool
    ) async throws -> any RegionFrameCapturing
    func captureDisplay(containing point: CGPoint?) async throws -> CaptureResult
    func captureWindow(at point: CGPoint?) async throws -> CaptureResult
}

public protocol RegionFrameCapturing: Sendable {
    func capture() async throws -> CaptureResult
}

struct PixelAlignedCaptureRegion: Sendable, Equatable {
    let sourceRect: CGRect
    let capturedRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

public extension ScreenCapturing {
    /// Test capturers do not composite app windows, so their normal region
    /// capture is already equivalent to an overlay-free capture.
    func captureRegion(_ rect: CGRect, excludingOwnWindows: Bool) async throws -> CaptureResult {
        try await captureRegion(rect)
    }

    /// Test and custom capturers keep their existing implementation. The
    /// ScreenCaptureKit capturer overrides this to reuse one prepared filter
    /// throughout a scrolling session.
    func prepareRegionCapture(
        _ rect: CGRect,
        excludingOwnWindows: Bool
    ) async throws -> any RegionFrameCapturing {
        PassthroughRegionFrameCapturer(
            capturer: self,
            rect: rect,
            excludingOwnWindows: excludingOwnWindows
        )
    }
}

private actor PassthroughRegionFrameCapturer: RegionFrameCapturing {
    private let capturer: any ScreenCapturing
    private let rect: CGRect
    private let excludingOwnWindows: Bool

    init(capturer: any ScreenCapturing, rect: CGRect, excludingOwnWindows: Bool) {
        self.capturer = capturer
        self.rect = rect
        self.excludingOwnWindows = excludingOwnWindows
    }

    func capture() async throws -> CaptureResult {
        try await capturer.captureRegion(rect, excludingOwnWindows: excludingOwnWindows)
    }
}

public final class ScreenCaptureService: NSObject, ScreenCapturing, @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    public override init() {
        super.init()
    }

    /// Captures the visible WindowServer composition without yielding to the
    /// run loop. Global hot-key handlers use this before returning so transient
    /// windows (notably context menus) cannot disappear before the frame is
    /// frozen.
    public func captureVisibleDisplaysImmediately(
        excludingOwnApplication: Bool = false
    ) -> [CaptureResult] {
        guard CGPreflightScreenCaptureAccess() else { return [] }

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else { return [] }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return []
        }

        return displayIDs.compactMap { displayID in
            let frame = CGDisplayBounds(displayID)
            guard frame.width > 0, frame.height > 0 else { return nil }
            let image: CGImage?
            if excludingOwnApplication {
                image = legacyDisplayComposite(
                    displayFrame: frame,
                    listOptions: .optionOnScreenOnly,
                    imageOptions: [.bestResolution, .boundsIgnoreFraming],
                    excludingProcessID: ProcessInfo.processInfo.processIdentifier
                )
            } else {
                image = legacyDisplayComposite(
                    displayFrame: frame,
                    listOptions: .optionOnScreenOnly,
                    imageOptions: [.bestResolution, .boundsIgnoreFraming]
                )
            }
            guard let image else { return nil }
            let normalizedImage = normalizedToSRGB(image)
            return CaptureResult(
                image: normalizedImage,
                displayScale: Self.resolvedDisplayScale(
                    backingScale: 1,
                    imageWidth: normalizedImage.width,
                    frameWidth: frame.width
                ),
                capturedRect: frame,
                mode: .fullScreen
            )
        }
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
        let backingScale = displayScale(for: display)
        guard let alignedRegion = Self.pixelAlignedRegion(
            rect,
            displayFrame: displayFrame,
            scale: backingScale
        ) else {
            throw HelloXError.captureFailed("截图区域无效")
        }
        let configuration = makeConfiguration(
            sourceRect: alignedRegion.sourceRect,
            pixelWidth: alignedRegion.pixelWidth,
            pixelHeight: alignedRegion.pixelHeight
        )

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
        let scale = Self.resolvedDisplayScale(
            backingScale: backingScale,
            imageWidth: image.width,
            frameWidth: alignedRegion.capturedRect.width
        )
        return CaptureResult(
            image: image,
            displayScale: scale,
            capturedRect: alignedRegion.capturedRect,
            mode: .region
        )
    }

    public func prepareRegionCapture(
        _ rect: CGRect,
        excludingOwnWindows: Bool
    ) async throws -> any RegionFrameCapturing {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelloXError.screenRecordingPermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { display in
            CGRect(
                x: display.frame.origin.x,
                y: display.frame.origin.y,
                width: display.frame.width,
                height: display.frame.height
            ).intersects(rect)
        }) else {
            throw HelloXError.captureFailed("找不到选区所在的显示器")
        }

        let displayFrame = CGRect(
            x: display.frame.origin.x,
            y: display.frame.origin.y,
            width: display.frame.width,
            height: display.frame.height
        )
        let backingScale = displayScale(for: display)
        guard let alignedRegion = Self.pixelAlignedRegion(
            rect,
            displayFrame: displayFrame,
            scale: backingScale
        ) else {
            throw HelloXError.captureFailed("截图区域无效")
        }
        let configuration = makeConfiguration(
            sourceRect: alignedRegion.sourceRect,
            pixelWidth: alignedRegion.pixelWidth,
            pixelHeight: alignedRegion.pixelHeight
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedWindows = excludingOwnWindows
            ? content.windows.filter { $0.owningApplication?.processID == ownPID }
            : []
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let resolvedScale = Self.resolvedDisplayScale(
            backingScale: backingScale,
            imageWidth: alignedRegion.pixelWidth,
            frameWidth: alignedRegion.capturedRect.width
        )
        return ScreenCaptureKitRegionFrameCapturer(
            filter: filter,
            configuration: configuration,
            displayScale: resolvedScale,
            capturedRect: alignedRegion.capturedRect
        )
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
        let actualScale = Self.resolvedDisplayScale(
            backingScale: scale,
            imageWidth: image.width,
            frameWidth: display.frame.width
        )
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
        let candidates = content.windows.enumerated().compactMap { index, window -> (index: Int, window: SCWindow)? in
            guard (!excludingOwnApplication || window.owningApplication?.processID != ownPID),
                  window.isOnScreen,
                  window.windowLayer >= 0,
                  window.frame.contains(targetPoint),
                  window.frame.width > 40,
                  window.frame.height > 40 else {
                return nil
            }
            return (index, window)
        }

        // SCShareableContent can expose several windows for one app (for
        // example a title-bar/content child window and the actual app window).
        // Picking the smallest rectangle can therefore drop the top or bottom
        // of the visible window. Prefer the active/front layer first, then the
        // larger containing window so the full frame is retained.
        guard let window = (candidates.sorted(by: { lhs, rhs in
            if lhs.window.isActive != rhs.window.isActive {
                return lhs.window.isActive && !rhs.window.isActive
            }
            if lhs.window.windowLayer != rhs.window.windowLayer {
                return lhs.window.windowLayer < rhs.window.windowLayer
            }
            let lhsArea = lhs.window.frame.width * lhs.window.frame.height
            let rhsArea = rhs.window.frame.width * rhs.window.frame.height
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            // Keep ScreenCaptureKit's original ordering as the final tie
            // breaker; it is the compositor's front-to-back order.
            return lhs.index < rhs.index
        }).first?.window ?? content.windows.first(where: {
            (!excludingOwnApplication || $0.owningApplication?.processID != ownPID) &&
            $0.isOnScreen && $0.frame.width > 40 && $0.frame.height > 40
        })) else {
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
        configuration.width = max(1, Int(ceil(window.frame.width * scale)))
        configuration.height = max(1, Int(ceil(window.frame.height * scale)))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        Self.configureSDRColorOutput(configuration)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await capture(filter: filter, configuration: configuration)
        // Recompute the scale from the actual image pixels: ScreenCaptureKit may
        // return a different resolution than frame * backingScale, and a stale
        // scale would stretch the image in the editor and misalign annotations.
        let actualScale = Self.resolvedDisplayScale(
            backingScale: scale,
            imageWidth: image.width,
            frameWidth: window.frame.width
        )
        return CaptureResult(image: image, displayScale: actualScale, capturedRect: window.frame, mode: .window)
    }

    private func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
    }

    private func makeConfiguration(sourceRect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let pixelWidth = max(1, Int((sourceRect.width * scale).rounded()))
        let pixelHeight = max(1, Int((sourceRect.height * scale).rounded()))
        return makeConfiguration(
            sourceRect: sourceRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private func makeConfiguration(
        sourceRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, pixelWidth)
        configuration.height = max(1, pixelHeight)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = false
        Self.configureSDRColorOutput(configuration)
        return configuration
    }

    /// Snaps a global point-space selection outward to the display's physical
    /// pixel grid. ScreenCaptureKit otherwise resamples fractional source
    /// bounds into a separately rounded output size, softening every edge in
    /// the captured frame.
    static func pixelAlignedRegion(
        _ rect: CGRect,
        displayFrame: CGRect,
        scale: CGFloat
    ) -> PixelAlignedCaptureRegion? {
        guard scale.isFinite, scale >= 1,
              displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let clipped = rect.intersection(displayFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }

        let local = CGRect(
            x: clipped.minX - displayFrame.minX,
            y: clipped.minY - displayFrame.minY,
            width: clipped.width,
            height: clipped.height
        )
        let localDisplay = CGRect(origin: .zero, size: displayFrame.size)
        let aligned = CGRect(
            x: floor(local.minX * scale) / scale,
            y: floor(local.minY * scale) / scale,
            width: ceil(local.maxX * scale) / scale - floor(local.minX * scale) / scale,
            height: ceil(local.maxY * scale) / scale - floor(local.minY * scale) / scale
        ).intersection(localDisplay)
        guard !aligned.isNull, aligned.width >= 1, aligned.height >= 1 else { return nil }

        let pixelWidth = Int((aligned.width * scale).rounded())
        let pixelHeight = Int((aligned.height * scale).rounded())
        guard pixelWidth >= 1, pixelHeight >= 1 else { return nil }
        return PixelAlignedCaptureRegion(
            sourceRect: aligned,
            capturedRect: aligned.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
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
        // ScreenCaptureKit does not reliably composite transient windows such
        // as context menus. Capture the visible WindowServer composition first
        // so the frozen frame retains exactly what was on screen when the
        // shortcut fired. Keep ScreenCaptureKit as the compatibility fallback
        // when the legacy compositor is unavailable.
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
        imageOptions: CGWindowImageOption,
        excludingProcessID: pid_t? = nil
    ) -> CGImage? {
        if let excludingProcessID {
            return legacyDisplayComposite(
                displayFrame: displayFrame,
                listOptions: listOptions,
                imageOptions: imageOptions,
                excludingProcessID: excludingProcessID
            )
        }
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
        defer { dlclose(handle) }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        return createImage(displayFrame, listOptions, kCGNullWindowID, imageOptions)
    }

    private func legacyDisplayComposite(
        displayFrame: CGRect,
        listOptions: CGWindowListOption,
        imageOptions: CGWindowImageOption,
        excludingProcessID: pid_t
    ) -> CGImage? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            listOptions,
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let windowIDs = windowInfo.compactMap { info -> NSNumber? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    != excludingProcessID,
                  let windowID = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            return windowID
        }
        guard !windowIDs.isEmpty else { return nil }

        typealias CreateImageFromArray = @convention(c) (
            CGRect,
            CFArray,
            CGWindowImageOption
        ) -> CGImage?
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImageFromArray") else {
            return nil
        }
        defer { dlclose(handle) }
        let createImage = unsafeBitCast(symbol, to: CreateImageFromArray.self)
        return createImage(displayFrame, windowIDs as CFArray, imageOptions)
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

    /// Resolves the scale used to interpret a captured image. Prefers the
    /// actual pixel-to-point ratio of the returned image, falling back to the
    /// display's backing scale so mixed-resolution captures stay aligned with
    /// the editor's annotation coordinates.
    static func resolvedDisplayScale(
        backingScale: CGFloat,
        imageWidth: Int,
        frameWidth: CGFloat
    ) -> CGFloat {
        let actual = frameWidth > 0 ? CGFloat(imageWidth) / frameWidth : 0
        if actual.isFinite, actual >= 1 { return actual }
        if backingScale.isFinite, backingScale >= 1 { return backingScale }
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

private final class ScreenCaptureKitRegionFrameCapturer: RegionFrameCapturing, @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let displayScale: CGFloat
    private let capturedRect: CGRect
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        displayScale: CGFloat,
        capturedRect: CGRect
    ) {
        self.filter = filter
        self.configuration = configuration
        self.displayScale = displayScale
        self.capturedRect = capturedRect
    }

    func capture() async throws -> CaptureResult {
        let source = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let image: CGImage
        if source.colorSpace?.name != CGColorSpace.sRGB,
           let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
            let input = CIImage(cgImage: source)
            image = ciContext.createCGImage(
                input,
                from: input.extent,
                format: .BGRA8,
                colorSpace: colorSpace
            ) ?? source
        } else {
            image = source
        }
        return CaptureResult(
            image: image,
            displayScale: displayScale,
            capturedRect: capturedRect,
            mode: .region
        )
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
