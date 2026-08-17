import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public struct ScrollTarget: Sendable, Equatable {
    public let processID: pid_t
    public let windowID: CGWindowID?
    public let captureRect: CGRect
    public let eventLocation: CGPoint
    public let displayScale: CGFloat

    public init(
        processID: pid_t,
        windowID: CGWindowID? = nil,
        captureRect: CGRect,
        eventLocation: CGPoint? = nil,
        displayScale: CGFloat = 1
    ) {
        self.processID = processID
        self.windowID = windowID
        self.captureRect = captureRect
        self.eventLocation = eventLocation ?? CGPoint(x: captureRect.midX, y: captureRect.midY)
        self.displayScale = displayScale
    }
}

public enum ScrollDirection: String, Sendable, Equatable {
    case up
    case down
    case left
    case right

    public var isHorizontal: Bool {
        self == .left || self == .right
    }
}

public enum ScrollingCaptureState: String, Sendable {
    case preparing
    case capturing
    case paused
    case finishing
    case completed
    case failed
    case cancelled
}

public struct ScrollingCaptureProgress: Sendable, Equatable {
    public let state: ScrollingCaptureState
    public let frameCount: Int
    public let pixelHeight: Int

    public init(state: ScrollingCaptureState, frameCount: Int, pixelHeight: Int) {
        self.state = state
        self.frameCount = frameCount
        self.pixelHeight = pixelHeight
    }
}

public struct ManualScrollingCaptureUpdate: @unchecked Sendable {
    public let stitchedImage: CGImage
    public let latestFrame: CGImage
    public let frameCount: Int
    public let pixelHeight: Int
    public let pixelWidth: Int
    public let direction: ScrollDirection

    public init(
        stitchedImage: CGImage,
        latestFrame: CGImage,
        frameCount: Int,
        pixelHeight: Int,
        pixelWidth: Int? = nil,
        direction: ScrollDirection = .down
    ) {
        self.stitchedImage = stitchedImage
        self.latestFrame = latestFrame
        self.frameCount = frameCount
        self.pixelHeight = pixelHeight
        self.pixelWidth = pixelWidth ?? stitchedImage.width
        self.direction = direction
    }
}

public actor ScrollingCaptureControl {
    private var paused = false
    private var finishRequested = false
    private var cancelRequested = false

    public init() {}

    public func pause() { paused = true }
    public func resume() { paused = false }
    public func finish() { finishRequested = true; paused = false }
    public func cancel() { cancelRequested = true; paused = false }

    func checkpoint() async throws -> Bool {
        while paused && !finishRequested && !cancelRequested {
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        if cancelRequested { throw HelloXError.cancelled }
        return !finishRequested
    }

    func isPaused() -> Bool { paused }
}

public final class ScrollingCaptureService: @unchecked Sendable {
    private let capturer: any ScreenCapturing
    private let stitcher: VerticalStitcher
    private let maximumHeight: Int
    private let stabilityPollNanoseconds: UInt64
    private let stabilityTimeoutNanoseconds: UInt64

    public init(
        capturer: any ScreenCapturing,
        stitcher: VerticalStitcher = VerticalStitcher(),
        maximumHeight: Int = 50_000,
        stabilityPollNanoseconds: UInt64 = 90_000_000,
        stabilityTimeoutNanoseconds: UInt64 = 900_000_000
    ) {
        self.capturer = capturer
        self.stitcher = stitcher
        self.maximumHeight = maximumHeight
        self.stabilityPollNanoseconds = stabilityPollNanoseconds
        self.stabilityTimeoutNanoseconds = stabilityTimeoutNanoseconds
    }

    public func capture(
        target: ScrollTarget,
        control: ScrollingCaptureControl = ScrollingCaptureControl(),
        progress: (@Sendable (ScrollingCaptureProgress) -> Void)? = nil
    ) async throws -> CaptureResult {
        guard AXIsProcessTrusted() else { throw HelloXError.accessibilityPermissionDenied }
        var previous = try await capturer.captureRegion(target.captureRect).image
        var stitched = previous
        var unchangedFrames = 0
        var frameCount = 1
        progress?(.init(state: .capturing, frameCount: frameCount, pixelHeight: stitched.height))

        while stitched.height < maximumHeight {
            try Task.checkCancellation()
            guard try await control.checkpoint() else { break }
            if await control.isPaused() {
                progress?(.init(state: .paused, frameCount: frameCount, pixelHeight: stitched.height))
                continue
            }

            let primaryAmount = max(120, Int(target.captureRect.height * 0.72))
            var next = try await scrollAndWaitForStableFrame(target: target, previous: previous, pixels: primaryAmount)
            var difference = stitcher.frameDifference(previous, next)
            if difference < 1.5, frameCount == 1 {
                // A second, smaller event distinguishes a lost target from a page at its bottom.
                next = try await scrollAndWaitForStableFrame(target: target, previous: previous, pixels: max(80, Int(target.captureRect.height * 0.45)))
                difference = stitcher.frameDifference(previous, next)
                if difference < 1.5 {
                    throw HelloXError.captureFailed("目标页面没有响应滚动，请把鼠标放在可滚动区域后重试")
                }
            }

            if difference < 1.5 {
                unchangedFrames += 1
                if unchangedFrames >= 3 { break }
                continue
            }
            unchangedFrames = 0

            let headerHeight = stitcher.repeatedHeaderHeight(previous, next)
            let footerHeight = stitcher.repeatedFooterHeight(previous, next)
            let stitchableNext = crop(image: next, top: headerHeight, bottom: 0) ?? next
            let matchablePrevious = crop(image: previous, top: 0, bottom: footerHeight) ?? previous
            guard let match = stitcher.bestOverlap(previous: matchablePrevious, next: stitchableNext) else {
                if frameCount == 1 { throw HelloXError.captureFailed("无法识别滚动内容的重叠区域") }
                break
            }

            if footerHeight > 4, let withoutFooter = crop(image: stitched, top: 0, bottom: footerHeight + 2) {
                stitched = withoutFooter
            }
            stitched = try stitcher.append(previous: stitched, next: stitchableNext, overlap: match.overlap)
            previous = next
            frameCount += 1
            progress?(.init(state: .capturing, frameCount: frameCount, pixelHeight: stitched.height))
        }

        progress?(.init(state: .completed, frameCount: frameCount, pixelHeight: stitched.height))
        return CaptureResult(
            image: stitched,
            displayScale: target.displayScale,
            capturedRect: target.captureRect,
            mode: .scrolling
        )
    }

    public func makeManualSession(target: ScrollTarget) -> ManualScrollingCaptureSession {
        ManualScrollingCaptureSession(
            capturer: capturer,
            target: target,
            stitcher: VerticalStitcher(
                // Manual capture must recognize tiny wheel movements and
                // nearly unchanged viewports. Restricting overlap to 85%
                // forced a false 15% seam for dynamic chat/media content.
                minimumOverlapRatio: 0.05,
                maximumOverlapRatio: 0.995,
                sampleStride: 6,
                maximumMeanError: 18
            ),
            maximumHeight: maximumHeight
        )
    }

    /// Compatibility entry point used by existing callers and tests.
    public func capture(rect: CGRect, progress: (@Sendable (Int) -> Void)? = nil) async throws -> CaptureResult {
        let target = ScrollTarget(
            processID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? ProcessInfo.processInfo.processIdentifier,
            captureRect: rect
        )
        return try await capture(target: target) { progress?($0.frameCount) }
    }

    private func scrollAndWaitForStableFrame(
        target: ScrollTarget,
        previous: CGImage,
        pixels: Int
    ) async throws -> CGImage {
        postScroll(target: target, pixels: pixels)
        var last = previous
        var elapsed: UInt64 = 0
        var hasMoved = false
        while elapsed < stabilityTimeoutNanoseconds {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: stabilityPollNanoseconds)
            elapsed += stabilityPollNanoseconds
            let current = try await capturer.captureRegion(target.captureRect).image
            let movement = stitcher.frameDifference(previous, current)
            let settling = stitcher.frameDifference(last, current)
            if movement >= 1.5 { hasMoved = true }
            if hasMoved && settling < 0.65 { return current }
            last = current
        }
        return last
    }

    private func postScroll(target: ScrollTarget, pixels: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-pixels),
            wheel2: 0,
            wheel3: 0
        )
        event?.location = target.eventLocation
        event?.postToPid(target.processID)
    }

    private func crop(image: CGImage, top: Int, bottom: Int) -> CGImage? {
        guard top >= 0, bottom >= 0, top + bottom < image.height else { return nil }
        return image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top - bottom))
    }
}

public actor ManualScrollingCaptureSession {
    private let capturer: any ScreenCapturing
    private let target: ScrollTarget
    private let stitcher: VerticalStitcher
    private let maximumExtent: Int
    private var previous: CGImage?
    private var stitched: CGImage?
    private var frameCount = 0
    private var isHorizontalCapture: Bool?
    private var lastDirection: ScrollDirection?
    private var viewportPosition = 0
    private var minimumCapturedPosition = 0
    private var maximumCapturedPosition = 0
    private var knownViewports: [KnownViewport] = []
    private var verticalSideInsets: (leading: Int, trailing: Int)?

    public init(
        capturer: any ScreenCapturing,
        target: ScrollTarget,
        stitcher: VerticalStitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 6,
            maximumMeanError: 18
        ),
        maximumHeight: Int = 50_000
    ) {
        self.capturer = capturer
        self.target = target
        self.stitcher = stitcher
        self.maximumExtent = maximumHeight
    }

    public func begin() async throws -> ManualScrollingCaptureUpdate {
        if let stitched, let previous {
            return update(stitched: stitched, latest: previous, direction: .down)
        }
        let initial = try await capturer.captureRegion(
            target.captureRect,
            excludingOwnWindows: true
        ).image
        previous = initial
        stitched = initial
        frameCount = 1
        if let fingerprint = FrameFingerprint(image: initial) {
            knownViewports = [KnownViewport(position: 0, fingerprint: fingerprint)]
        }
        return update(stitched: initial, latest: initial, direction: .down)
    }

    public func captureCurrentFrame(directionHint: ScrollDirection? = nil) async throws -> ManualScrollingCaptureUpdate? {
        guard let previous, var stitched else { return try await begin() }
        guard stitched.width < maximumExtent && stitched.height < maximumExtent else {
            throw HelloXError.captureFailed("长截图已达到最大尺寸")
        }

        let next = try await capturer.captureRegion(
            target.captureRect,
            excludingOwnWindows: true
        ).image
        var previousFrame = previous
        var nextFrame = next
        let usesVerticalCapture = directionHint?.isHorizontal == false || isHorizontalCapture == false
        if usesVerticalCapture {
            if verticalSideInsets == nil {
                let detected = stitcher.stationarySideInsets(previous, next)
                let safe = detected.leading + detected.trailing <= Int(Double(previous.width) * 0.35)
                    ? detected
                    : (leading: 0, trailing: 0)
                verticalSideInsets = safe
            }
            if let verticalSideInsets,
               (verticalSideInsets.leading > 0 || verticalSideInsets.trailing > 0),
               stitched.width == previous.width,
               let croppedStitched = cropSides(stitched, insets: verticalSideInsets) {
                // Persist the crop before any early return, otherwise the
                // next stable frame would not match the stitched canvas.
                stitched = croppedStitched
            }
            if let verticalSideInsets,
               let croppedPrevious = cropSides(previous, insets: verticalSideInsets),
               let croppedNext = cropSides(next, insets: verticalSideInsets) {
                previousFrame = croppedPrevious
                nextFrame = croppedNext
                if frameCount == 1, let fingerprint = FrameFingerprint(image: croppedPrevious) {
                    knownViewports = [KnownViewport(position: 0, fingerprint: fingerprint)]
                }
            }
        }

        guard stitcher.frameDifference(previousFrame, nextFrame) >= 3.0 else { return nil }
        guard stitcher.frameChangeCoverage(previousFrame, nextFrame) >= 0.04 else {
            // Keep the stable reference frame. A transient thumbnail update
            // must not become the next overlap baseline.
            return nil
        }
        guard stitcher.activeChangeVerticalBands(previousFrame, nextFrame) >= 3 else {
            // A real vertical scroll moves content across the viewport. Local
            // media animation would otherwise be stitched as a fake segment.
            return nil
        }

        let nextFingerprint = FrameFingerprint(image: nextFrame)
        if let nextFingerprint,
           let known = knownViewports.min(by: {
               $0.fingerprint.difference(from: nextFingerprint) < $1.fingerprint.difference(from: nextFingerprint)
           }),
           known.fingerprint.isSameViewport(as: nextFingerprint) {
            viewportPosition = known.position
            self.previous = next
            if let directionHint {
                isHorizontalCapture = directionHint.isHorizontal
                lastDirection = directionHint
            }
            return nil
        }

        let allowedDirections: [ScrollDirection]
        if let directionHint,
           isHorizontalCapture == nil || isHorizontalCapture == directionHint.isHorizontal {
            allowedDirections = directionHint.isHorizontal ? [.right, .left] : [.down, .up]
        } else if let isHorizontalCapture {
            allowedDirections = isHorizontalCapture ? [.right, .left] : [.down, .up]
        } else {
            allowedDirections = [.down, .up, .right, .left]
        }
        let candidates: [(ScrollDirection, StitchMatch)] = allowedDirections.compactMap { direction in
            stitcher.bestOverlap(previous: previousFrame, next: nextFrame, direction: direction)
                .map { (direction, $0) }
        }
        guard let bestCandidate = candidates.min(by: { $0.1.meanError < $1.1.meanError }) else {
            throw HelloXError.captureFailed("无法识别当前滚动方向或重叠区域，请减小滚动幅度")
        }
        let selectedCandidate: (ScrollDirection, StitchMatch)
        if let directionHint,
           let hintedCandidate = candidates.first(where: { $0.0 == directionHint }),
           hintedCandidate.1.meanError <= bestCandidate.1.meanError + max(0.5, bestCandidate.1.meanError * 0.15) {
            // Prefer wheel intent when image evidence is comparable.
            // Allows up to 15% worse match (or 0.5 absolute) for user's intended direction.
            selectedCandidate = hintedCandidate
        } else if directionHint == nil,
           let lastDirection,
           bestCandidate.0 != lastDirection,
           let currentDirectionCandidate = candidates.first(where: { $0.0 == lastDirection }),
           bestCandidate.1.meanError + 0.5 >= currentDirectionCandidate.1.meanError {
            selectedCandidate = currentDirectionCandidate
        } else {
            selectedCandidate = bestCandidate
        }
        let (direction, match) = selectedCandidate
        isHorizontalCapture = direction.isHorizontal
        lastDirection = direction
        let frameExtent = direction.isHorizontal ? nextFrame.width : nextFrame.height
        let movement = max(1, frameExtent - match.overlap)
        let minimumNewContentExtent = max(12, Int((Double(frameExtent) * 0.025).rounded(.up)))
        guard movement >= minimumNewContentExtent else {
            // Keep the older reference frame so several tiny wheel movements
            // accumulate into one reliable overlap instead of appending 1–2 px
            // strips and gradually duplicating content.
            return nil
        }
        let signedMovement = direction == .down || direction == .right ? movement : -movement
        let nextViewportPosition = viewportPosition + signedMovement

        if nextViewportPosition >= minimumCapturedPosition,
           nextViewportPosition <= maximumCapturedPosition {
            viewportPosition = nextViewportPosition
            self.previous = next
            return nil
        }

        let newContentExtent: Int
        if nextViewportPosition > maximumCapturedPosition {
            newContentExtent = nextViewportPosition - maximumCapturedPosition
            maximumCapturedPosition = nextViewportPosition
        } else {
            newContentExtent = minimumCapturedPosition - nextViewportPosition
            minimumCapturedPosition = nextViewportPosition
        }
        let boundaryOverlap = max(0, frameExtent - newContentExtent)
        stitched = try stitcher.append(
            previous: stitched,
            next: nextFrame,
            overlap: boundaryOverlap,
            direction: direction
        )
        viewportPosition = nextViewportPosition
        self.previous = next
        self.stitched = stitched
        if let nextFingerprint {
            knownViewports.append(KnownViewport(position: nextViewportPosition, fingerprint: nextFingerprint))
            if knownViewports.count > 160 {
                knownViewports.removeFirst(knownViewports.count - 160)
            }
        }
        frameCount += 1
        return update(stitched: stitched, latest: nextFrame, direction: direction)
    }

    public func result() throws -> CaptureResult {
        guard let stitched else { throw HelloXError.captureFailed("尚未捕获长截图内容") }
        return CaptureResult(
            image: stitched,
            displayScale: target.displayScale,
            capturedRect: target.captureRect,
            mode: .scrolling
        )
    }

    private func update(
        stitched: CGImage,
        latest: CGImage,
        direction: ScrollDirection
    ) -> ManualScrollingCaptureUpdate {
        ManualScrollingCaptureUpdate(
            stitchedImage: stitched,
            latestFrame: latest,
            frameCount: frameCount,
            pixelHeight: stitched.height,
            pixelWidth: stitched.width,
            direction: direction
        )
    }

    private func crop(image: CGImage, top: Int, bottom: Int) -> CGImage? {
        guard top >= 0, bottom >= 0, top + bottom < image.height else { return nil }
        return image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top - bottom))
    }

    private func cropSides(
        _ image: CGImage,
        insets: (leading: Int, trailing: Int)
    ) -> CGImage? {
        guard insets.leading >= 0, insets.trailing >= 0,
              insets.leading + insets.trailing < image.width else { return nil }
        return image.cropping(to: CGRect(
            x: insets.leading,
            y: 0,
            width: image.width - insets.leading - insets.trailing,
            height: image.height
        ))
    }
}

private struct KnownViewport: Sendable {
    let position: Int
    let fingerprint: FrameFingerprint
}

/// A compact viewport identity used to recognize scroll-back and elastic
/// bounce frames without retaining hundreds of full-resolution screenshots.
private struct FrameFingerprint: Sendable {
    private static let width = 128
    private static let height = 64
    private let samples: [UInt8]

    init?(image: CGImage) {
        var data = [UInt8](repeating: 0, count: Self.width * Self.height)
        guard let context = CGContext(
            data: &data,
            width: Self.width,
            height: Self.height,
            bitsPerComponent: 8,
            bytesPerRow: Self.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        samples = data
    }

    func difference(from other: FrameFingerprint) -> Double {
        guard samples.count == other.samples.count, !samples.isEmpty else { return .infinity }
        var total = 0
        for index in samples.indices {
            total += abs(Int(samples[index]) - Int(other.samples[index]))
        }
        return Double(total) / Double(samples.count)
    }

    func isSameViewport(as other: FrameFingerprint) -> Bool {
        guard samples.count == other.samples.count, !samples.isEmpty else { return false }
        var total = 0
        var materiallyDifferent = 0
        for index in samples.indices {
            let delta = abs(Int(samples[index]) - Int(other.samples[index]))
            total += delta
            if delta > 8 { materiallyDifferent += 1 }
        }
        let mean = Double(total) / Double(samples.count)
        let changedRatio = Double(materiallyDifferent) / Double(samples.count)
        if mean <= 0.75 && changedRatio <= 0.012 { return true }

        var edgeChanged = 0
        var edgeSamples = 0
        for y in 1..<Self.height {
            for x in 1..<Self.width {
                let index = y * Self.width + x
                let left = index - 1
                let top = index - Self.width
                let ownEdge = abs(Int(samples[index]) - Int(samples[left]))
                    + abs(Int(samples[index]) - Int(samples[top]))
                let otherEdge = abs(Int(other.samples[index]) - Int(other.samples[left]))
                    + abs(Int(other.samples[index]) - Int(other.samples[top]))
                if max(ownEdge, otherEdge) >= 10 {
                    edgeSamples += 1
                    if abs(ownEdge - otherEdge) > 12 { edgeChanged += 1 }
                }
            }
        }
        let edgeChangedRatio = edgeSamples == 0 ? 1 : Double(edgeChanged) / Double(edgeSamples)
        return mean <= 3.5 && changedRatio <= 0.045 && edgeChangedRatio <= 0.08
    }
}
