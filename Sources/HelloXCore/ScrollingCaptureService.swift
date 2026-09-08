import ApplicationServices
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

/// Resolves wheel intent across a gesture without permanently choosing an
/// axis from its first (often noisy) trackpad sample.
///
/// The returned direction may be provisional while the accumulator gathers
/// enough evidence to lock the gesture axis. An isolated cross-axis sample is
/// ignored after that, while sustained cross-axis evidence can replace the
/// lock without waiting for `idleResetInterval`.
public struct ScrollingWheelIntentAccumulator: Sendable {
    private enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
    }

    public let idleResetInterval: TimeInterval

    private var lastEventTimestamp: TimeInterval?
    private var accumulatedHorizontalDistance: CGFloat = 0
    private var accumulatedVerticalDistance: CGFloat = 0
    private var validSampleCount = 0
    private var resolvedAxis: Axis?
    private var challengingAxis: Axis?
    private var challengingDistance: CGFloat = 0
    private var challengingSampleCount = 0

    private let noiseFloor: CGFloat = 0.18
    private let axisDecisionDistance: CGFloat = 1.25
    private let axisDominanceRatio: CGFloat = 1.5
    private let provisionalDistance: CGFloat = 0.75
    private let provisionalDominanceRatio: CGFloat = 2

    public init(idleResetInterval: TimeInterval = 0.18) {
        self.idleResetInterval = max(0, idleResetInterval)
    }

    /// Adds one wheel sample. `timestamp` should use the monotonic timestamp
    /// supplied by the input event. Shift-wheel should set
    /// `explicitHorizontalIntent`, which resolves immediately because it is
    /// user intent rather than inferred trackpad motion.
    public mutating func resolve(
        deltaX: CGFloat,
        deltaY: CGFloat,
        explicitHorizontalIntent: Bool,
        timestamp: TimeInterval
    ) -> ScrollDirection? {
        if let lastEventTimestamp,
           timestamp < lastEventTimestamp || timestamp - lastEventTimestamp >= idleResetInterval {
            resetAccumulatedIntent()
        }
        lastEventTimestamp = timestamp

        if explicitHorizontalIntent {
            let horizontalDelta = abs(deltaX) > abs(deltaY) ? deltaX : deltaY
            guard abs(horizontalDelta) >= noiseFloor else { return nil }
            resolvedAxis = .horizontal
            resetAxisEvidence()
            resetChallenge()
            return horizontalDelta < 0 ? .right : .left
        }

        let effectiveDeltaX = abs(deltaX) >= noiseFloor ? deltaX : 0
        let effectiveDeltaY = abs(deltaY) >= noiseFloor ? deltaY : 0
        guard effectiveDeltaX != 0 || effectiveDeltaY != 0 else { return nil }

        if let resolvedAxis,
           let eventAxis = dominantAxis(
               horizontal: abs(effectiveDeltaX),
               vertical: abs(effectiveDeltaY),
               ratio: provisionalDominanceRatio
           ),
           eventAxis != resolvedAxis {
            if challengingAxis != eventAxis {
                resetChallenge()
                challengingAxis = eventAxis
            }
            challengingDistance += eventAxis == .horizontal
                ? abs(effectiveDeltaX)
                : abs(effectiveDeltaY)
            challengingSampleCount += 1
            guard challengingSampleCount >= 2,
                  challengingDistance >= axisDecisionDistance else { return nil }
            self.resolvedAxis = eventAxis
            resetAxisEvidence()
            resetChallenge()
            return direction(
                for: eventAxis,
                deltaX: effectiveDeltaX,
                deltaY: effectiveDeltaY
            )
        }

        if let resolvedAxis {
            resetChallenge()
            return direction(
                for: resolvedAxis,
                deltaX: effectiveDeltaX,
                deltaY: effectiveDeltaY
            )
        }

        accumulatedHorizontalDistance += abs(effectiveDeltaX)
        accumulatedVerticalDistance += abs(effectiveDeltaY)
        validSampleCount += 1

        if validSampleCount >= 2,
           max(accumulatedHorizontalDistance, accumulatedVerticalDistance) >= axisDecisionDistance,
           let accumulatedAxis = dominantAxis(
               horizontal: accumulatedHorizontalDistance,
               vertical: accumulatedVerticalDistance,
               ratio: axisDominanceRatio
           ),
           let accumulatedDirection = direction(
               for: accumulatedAxis,
               deltaX: effectiveDeltaX,
               deltaY: effectiveDeltaY
           ) {
            resolvedAxis = accumulatedAxis
            resetAxisEvidence()
            resetChallenge()
            return accumulatedDirection
        }

        // A single decisive mouse-wheel tick should still start capture, but
        // it remains provisional and therefore cannot poison later samples.
        guard max(abs(effectiveDeltaX), abs(effectiveDeltaY)) >= provisionalDistance,
              let provisionalAxis = dominantAxis(
                  horizontal: abs(effectiveDeltaX),
                  vertical: abs(effectiveDeltaY),
                  ratio: provisionalDominanceRatio
              ) else { return nil }
        return direction(
            for: provisionalAxis,
            deltaX: effectiveDeltaX,
            deltaY: effectiveDeltaY
        )
    }

    public mutating func reset() {
        lastEventTimestamp = nil
        resetAccumulatedIntent()
    }

    private func dominantAxis(
        horizontal: CGFloat,
        vertical: CGFloat,
        ratio: CGFloat
    ) -> Axis? {
        if horizontal >= vertical * ratio { return .horizontal }
        if vertical >= horizontal * ratio { return .vertical }
        return nil
    }

    private func direction(
        for axis: Axis,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> ScrollDirection? {
        switch axis {
        case .horizontal:
            guard abs(deltaX) >= noiseFloor else { return nil }
            return deltaX < 0 ? .right : .left
        case .vertical:
            guard abs(deltaY) >= noiseFloor else { return nil }
            return deltaY < 0 ? .down : .up
        }
    }

    private mutating func resetAccumulatedIntent() {
        resetAxisEvidence()
        resetChallenge()
        resolvedAxis = nil
    }

    private mutating func resetAxisEvidence() {
        accumulatedHorizontalDistance = 0
        accumulatedVerticalDistance = 0
        validSampleCount = 0
    }

    private mutating func resetChallenge() {
        challengingAxis = nil
        challengingDistance = 0
        challengingSampleCount = 0
    }
}

public struct ManualScrollingCaptureUpdate: @unchecked Sendable {
    /// A bounded-size composite intended for live UI preview. The full-size
    /// image is produced only by `ManualScrollingCaptureSession.result()`.
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

public final class ScrollingCaptureService: @unchecked Sendable {
    private let capturer: any ScreenCapturing
    private let maximumHeight: Int

    public init(
        capturer: any ScreenCapturing,
        maximumHeight: Int = 50_000
    ) {
        self.capturer = capturer
        self.maximumHeight = maximumHeight
    }

    public func makeManualSession(target: ScrollTarget) -> ManualScrollingCaptureSession {
        ManualScrollingCaptureSession(
            capturer: capturer,
            target: target,
            stitcher: VerticalStitcher(
                // With leading-edge sampling a valid adjacent frame retains
                // ample overlap. Reject tiny, weak overlaps because sparse
                // chat rows can otherwise align to the wrong repeated bubble.
                minimumOverlapRatio: 0.12,
                maximumOverlapRatio: 0.995,
                sampleStride: 6,
                maximumMeanError: 18
            ),
            maximumHeight: maximumHeight
        )
    }

}

public actor ManualScrollingCaptureSession {
    private static let minimumAcceptedFrameDifference = 3.0

    private struct CapturedTile: @unchecked Sendable {
        /// Position on the captured document's scrolling axis. The initial
        /// viewport starts at zero; later tiles contain only newly exposed
        /// pixels, so retained memory grows with the final image rather than
        /// with `viewport size × frame count`.
        let position: Int
        let image: CGImage
    }

    private let capturer: any ScreenCapturing
    private let target: ScrollTarget
    private let stitcher: VerticalStitcher
    private let maximumExtent: Int
    private let stabilityPollNanoseconds: UInt64
    private let stabilityTimeoutNanoseconds: UInt64
    private let previewMaximumLongEdge: Int
    private var frameCapturer: (any RegionFrameCapturing)?
    private var previous: CGImage?
    private var capturedTiles: [CapturedTile] = []
    private var previewImage: CGImage?
    private var frameCount = 0
    private var isHorizontalCapture: Bool?
    private var lastDirection: ScrollDirection?
    private var viewportPosition = 0
    private var minimumCapturedPosition = 0
    private var maximumCapturedPosition = 0
    private var knownViewports: [KnownViewport] = []
    private var verticalSideInsets: (leading: Int, trailing: Int)?
    private var fixedVerticalInsets: (top: Int, bottom: Int)?

    public init(
        capturer: any ScreenCapturing,
        target: ScrollTarget,
        stitcher: VerticalStitcher = VerticalStitcher(
            minimumOverlapRatio: 0.12,
            maximumOverlapRatio: 0.995,
            sampleStride: 6,
            maximumMeanError: 18
        ),
        maximumHeight: Int = 50_000,
        stabilityPollNanoseconds: UInt64 = 16_000_000,
        stabilityTimeoutNanoseconds: UInt64 = 160_000_000,
        previewMaximumLongEdge: Int = 4_096
    ) {
        self.capturer = capturer
        self.target = target
        self.stitcher = stitcher
        self.maximumExtent = maximumHeight
        self.stabilityPollNanoseconds = stabilityPollNanoseconds
        self.stabilityTimeoutNanoseconds = stabilityTimeoutNanoseconds
        self.previewMaximumLongEdge = max(512, previewMaximumLongEdge)
    }

    public func begin() async throws -> ManualScrollingCaptureUpdate {
        if let previewImage, let previous {
            return update(preview: previewImage, latest: previous, direction: .down)
        }
        let frameCapturer = try await capturer.prepareRegionCapture(
            target.captureRect,
            excludingOwnWindows: true
        )
        self.frameCapturer = frameCapturer
        let initial = try await frameCapturer.capture().image
        previous = initial
        capturedTiles = [CapturedTile(position: 0, image: initial)]
        previewImage = initial
        frameCount = 1
        if let fingerprint = FrameFingerprint(image: initial) {
            knownViewports = [KnownViewport(position: 0, fingerprint: fingerprint)]
        }
        return update(preview: initial, latest: initial, direction: .down)
    }

    public func captureCurrentFrame(
        directionHint: ScrollDirection? = nil,
        waitsForMovement: Bool = true
    ) async throws -> ManualScrollingCaptureUpdate? {
        guard let previous, previewImage != nil else { return try await begin() }
        let currentExtent = compositePixelSize()
        guard currentExtent.width < CGFloat(maximumExtent),
              currentExtent.height < CGFloat(maximumExtent) else {
            throw HelloXError.captureFailed("长截图已达到最大尺寸")
        }

        let next = try await captureResponsiveFrame(
            reference: previous,
            waitsForMovement: waitsForMovement
        )
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
            if fixedVerticalInsets == nil {
                let detected = (
                    top: stitcher.repeatedHeaderHeight(previous, next),
                    bottom: stitcher.repeatedFooterHeight(previous, next)
                )
                let safe = detected.top + detected.bottom <= Int(Double(previous.height) * 0.35)
                    ? detected
                    : (top: 0, bottom: 0)
                fixedVerticalInsets = safe
            }
            if let verticalSideInsets, let fixedVerticalInsets,
               let croppedPrevious = cropViewport(
                   previous,
                   sideInsets: verticalSideInsets,
                   verticalInsets: fixedVerticalInsets
               ),
               let croppedNext = cropViewport(
                   next,
                   sideInsets: verticalSideInsets,
                   verticalInsets: fixedVerticalInsets
               ) {
                previousFrame = croppedPrevious
                nextFrame = croppedNext
                if frameCount == 1 {
                    capturedTiles = [CapturedTile(position: 0, image: croppedPrevious)]
                    previewImage = croppedPrevious
                }
                if frameCount == 1, let fingerprint = FrameFingerprint(image: croppedPrevious) {
                    knownViewports = [KnownViewport(position: 0, fingerprint: fingerprint)]
                }
            }
        }

        guard stitcher.frameDifference(previousFrame, nextFrame) >= Self.minimumAcceptedFrameDifference else {
            return nil
        }
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
           let known = knownViewports.filter({ known in
               guard let directionHint else { return true }
               switch directionHint {
               case .down, .right: return known.position > viewportPosition
               case .up, .left: return known.position < viewportPosition
               }
           }).min(by: {
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
            // Wheel intent is authoritative. Trying the opposite direction is
            // unsafe for repeated chat rows: a visually similar bubble can
            // score slightly better and reverse an upward capture mid-session.
            allowedDirections = [directionHint]
        } else if let isHorizontalCapture {
            allowedDirections = isHorizontalCapture ? [.right, .left] : [.down, .up]
        } else {
            allowedDirections = [.down, .up, .right, .left]
        }
        let candidates: [(ScrollDirection, StitchMatch)] = allowedDirections.compactMap { direction in
            stitcher.bestOverlap(previous: previousFrame, next: nextFrame, direction: direction)
                .map { (direction, $0) }
        }
        // A single wheel event can coincide with a video frame, lazy-loaded
        // content, or a scroll jump that has no usable overlap. Treat that as
        // a recoverable sample and keep the older reference so the next wheel
        // event can still accumulate into a match.
        guard let bestCandidate = candidates.min(by: { $0.1.meanError < $1.1.meanError }) else { return nil }
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
        let validation = stitcher.validateMatch(
            match,
            frameExtent: frameExtent,
            minimumNewContentRatio: 0.025,
            minimumNewContentAbsolute: 12,
            minimumConfidenceGap: 0.5
        )
        let movement: Int
        switch validation {
        case .accepted(let acceptedMovement):
            movement = acceptedMovement
        case .insufficientNewContent:
            // Keep the older reference frame so several tiny wheel movements
            // accumulate into one reliable overlap instead of appending 1–2 px
            // strips and gradually duplicating content.
            return nil
        case .ambiguousMatch:
            // Repeated rows can produce more than one plausible overlap. Do
            // not append until a later wheel movement makes the match unique.
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

        let projectedMinimum = min(minimumCapturedPosition, nextViewportPosition)
        let projectedMaximum = max(maximumCapturedPosition, nextViewportPosition)
        guard frameExtent + projectedMaximum - projectedMinimum <= maximumExtent else {
            throw HelloXError.captureFailed("长截图已达到最大尺寸")
        }

        let newContentExtent: Int
        let tilePosition: Int
        if nextViewportPosition > maximumCapturedPosition {
            newContentExtent = nextViewportPosition - maximumCapturedPosition
            tilePosition = maximumCapturedPosition + frameExtent
            maximumCapturedPosition = nextViewportPosition
        } else {
            newContentExtent = minimumCapturedPosition - nextViewportPosition
            tilePosition = nextViewportPosition
            minimumCapturedPosition = nextViewportPosition
        }
        let tile = try newContentStrip(
            from: nextFrame,
            direction: direction,
            extent: newContentExtent
        )
        capturedTiles.append(CapturedTile(position: tilePosition, image: tile))
        viewportPosition = nextViewportPosition
        self.previous = next
        if let nextFingerprint {
            knownViewports.append(KnownViewport(position: nextViewportPosition, fingerprint: nextFingerprint))
            if knownViewports.count > 160 {
                knownViewports.removeFirst(knownViewports.count - 160)
            }
        }
        frameCount += 1
        let preview = try renderComposite(maximumLongEdge: previewMaximumLongEdge)
        previewImage = preview
        return update(preview: preview, latest: nextFrame, direction: direction)
    }

    public func result() throws -> CaptureResult {
        guard !capturedTiles.isEmpty else { throw HelloXError.captureFailed("尚未捕获长截图内容") }
        let stitched = try renderComposite(maximumLongEdge: nil)
        return CaptureResult(
            image: stitched,
            displayScale: target.displayScale,
            capturedRect: target.captureRect,
            mode: .scrolling
        )
    }

    private func update(
        preview: CGImage,
        latest: CGImage,
        direction: ScrollDirection
    ) -> ManualScrollingCaptureUpdate {
        let pixelSize = compositePixelSize()
        return ManualScrollingCaptureUpdate(
            stitchedImage: preview,
            latestFrame: latest,
            frameCount: frameCount,
            pixelHeight: Int(pixelSize.height),
            pixelWidth: Int(pixelSize.width),
            direction: direction
        )
    }

    private func captureResponsiveFrame(
        reference: CGImage,
        waitsForMovement: Bool
    ) async throws -> CGImage {
        guard let frameCapturer else {
            throw HelloXError.captureFailed("长截图尚未开始")
        }
        let candidate = try await frameCapturer.capture().image
        guard waitsForMovement,
              stabilityTimeoutNanoseconds > 0,
              stabilityPollNanoseconds > 0 else { return candidate }

        // Active wheel capture must not wait for the viewport to settle. The
        // first moved frame has the largest overlap with the reference and is
        // therefore the safest one to stitch during a fast gesture.
        if stitcher.frameDifference(reference, candidate) >= Self.minimumAcceptedFrameDifference {
            return candidate
        }

        var best = candidate
        var bestReferenceDifference = stitcher.frameDifference(reference, candidate)
        var elapsed: UInt64 = 0
        while elapsed < stabilityTimeoutNanoseconds {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: stabilityPollNanoseconds)
            elapsed += stabilityPollNanoseconds
            let current = try await frameCapturer.capture().image
            let referenceDifference = stitcher.frameDifference(reference, current)
            if referenceDifference > bestReferenceDifference {
                bestReferenceDifference = referenceDifference
                best = current
            }
            if referenceDifference >= Self.minimumAcceptedFrameDifference {
                return current
            }
        }
        return best
    }

    private func compositePixelSize() -> CGSize {
        guard let first = capturedTiles.first else { return .zero }
        let horizontal = isHorizontalCapture ?? false
        let movementExtent = maximumCapturedPosition - minimumCapturedPosition
        return horizontal
            ? CGSize(
                width: CGFloat(first.image.width + movementExtent),
                height: CGFloat(first.image.height)
            )
            : CGSize(
                width: CGFloat(first.image.width),
                height: CGFloat(first.image.height + movementExtent)
            )
    }

    private func renderComposite(maximumLongEdge: Int?) throws -> CGImage {
        guard !capturedTiles.isEmpty else {
            throw HelloXError.captureFailed("尚未捕获长截图内容")
        }
        let fullSize = compositePixelSize()
        guard fullSize.width >= 1, fullSize.height >= 1 else {
            throw HelloXError.captureFailed("长截图尺寸无效")
        }
        let longest = max(fullSize.width, fullSize.height)
        let scale: CGFloat
        if let maximumLongEdge, longest > CGFloat(maximumLongEdge) {
            scale = CGFloat(maximumLongEdge) / longest
        } else {
            scale = 1
        }
        let outputWidth = max(1, Int((fullSize.width * scale).rounded()))
        let outputHeight = max(1, Int((fullSize.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HelloXError.captureFailed("无法创建长截图画布") }
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.interpolationQuality = scale < 1 ? .medium : .none

        let horizontal = isHorizontalCapture ?? false
        let minimum = minimumCapturedPosition
        let maximumContentPosition = maximumCapturedPosition
            + (horizontal ? capturedTiles[0].image.width : capturedTiles[0].image.height)
        for tile in capturedTiles {
            let origin: CGPoint
            if horizontal {
                origin = CGPoint(x: CGFloat(tile.position - minimum), y: 0)
            } else {
                origin = CGPoint(
                    x: 0,
                    y: CGFloat(maximumContentPosition - tile.position - tile.image.height)
                )
            }
            context.draw(tile.image, in: CGRect(
                x: origin.x * scale,
                y: origin.y * scale,
                width: CGFloat(tile.image.width) * scale,
                height: CGFloat(tile.image.height) * scale
            ))
        }
        guard let image = context.makeImage() else {
            throw HelloXError.captureFailed("无法生成长截图")
        }
        return image
    }

    private func newContentStrip(
        from image: CGImage,
        direction: ScrollDirection,
        extent: Int
    ) throws -> CGImage {
        let frameExtent = direction.isHorizontal ? image.width : image.height
        guard extent > 0, extent <= frameExtent else {
            throw HelloXError.captureFailed("长截图新增区域无效")
        }
        let outputWidth = direction.isHorizontal ? extent : image.width
        let outputHeight = direction.isHorizontal ? image.height : extent
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HelloXError.captureFailed("无法创建长截图分块") }
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.interpolationQuality = .none

        let origin: CGPoint
        switch direction {
        case .down:
            origin = .zero
        case .up:
            origin = CGPoint(x: 0, y: -(image.height - extent))
        case .right:
            origin = CGPoint(x: -(image.width - extent), y: 0)
        case .left:
            origin = .zero
        }
        context.draw(image, in: CGRect(
            x: origin.x,
            y: origin.y,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))
        guard let strip = context.makeImage() else {
            throw HelloXError.captureFailed("无法生成长截图分块")
        }
        return strip
    }

    private func cropViewport(
        _ image: CGImage,
        sideInsets: (leading: Int, trailing: Int),
        verticalInsets: (top: Int, bottom: Int)
    ) -> CGImage? {
        guard sideInsets.leading >= 0, sideInsets.trailing >= 0,
              verticalInsets.top >= 0, verticalInsets.bottom >= 0,
              sideInsets.leading + sideInsets.trailing < image.width,
              verticalInsets.top + verticalInsets.bottom < image.height else { return nil }
        return image.cropping(to: CGRect(
            x: sideInsets.leading,
            y: verticalInsets.top,
            width: image.width - sideInsets.leading - sideInsets.trailing,
            height: image.height - verticalInsets.top - verticalInsets.bottom
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
