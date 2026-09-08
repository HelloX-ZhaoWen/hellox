import CoreGraphics
import Testing
@testable import HelloXCore

struct ScrollingCaptureTests {
    @Test func wheelIntentDoesNotLockToTheFirstSmallDiagonalSample() {
        var intent = ScrollingWheelIntentAccumulator()

        #expect(intent.resolve(
            deltaX: -0.4,
            deltaY: -0.05,
            explicitHorizontalIntent: false,
            timestamp: 1
        ) == nil)
        #expect(intent.resolve(
            deltaX: -0.05,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1.01
        ) == .down)
        #expect(intent.resolve(
            deltaX: 0.05,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1.02
        ) == .down)

        // The accumulated vertical gesture remains vertical despite a later
        // horizontal-only sample in the same burst.
        #expect(intent.resolve(
            deltaX: -3,
            deltaY: 0,
            explicitHorizontalIntent: false,
            timestamp: 1.03
        ) == nil)
    }

    @Test func explicitHorizontalWheelIntentResolvesImmediately() {
        var intent = ScrollingWheelIntentAccumulator()

        #expect(intent.resolve(
            deltaX: 0.25,
            deltaY: -2,
            explicitHorizontalIntent: true,
            timestamp: 1
        ) == .right)
    }

    @Test func wheelIntentResetsItsAxisAfterIdle() {
        var intent = ScrollingWheelIntentAccumulator(idleResetInterval: 0.1)

        #expect(intent.resolve(
            deltaX: 0,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1
        ) == .down)
        #expect(intent.resolve(
            deltaX: 0,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1.01
        ) == .down)
        #expect(intent.resolve(
            deltaX: -1,
            deltaY: 0,
            explicitHorizontalIntent: false,
            timestamp: 1.2
        ) == .right)
    }

    @Test func wheelIntentRecoversFromVerticalLockDuringContinuousHorizontalInput() {
        var intent = ScrollingWheelIntentAccumulator()

        #expect(intent.resolve(
            deltaX: 0,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1
        ) == .down)
        #expect(intent.resolve(
            deltaX: 0,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1.01
        ) == .down)
        #expect(intent.resolve(
            deltaX: -1,
            deltaY: 0,
            explicitHorizontalIntent: false,
            timestamp: 1.02
        ) == nil)
        #expect(intent.resolve(
            deltaX: -1,
            deltaY: 0,
            explicitHorizontalIntent: false,
            timestamp: 1.03
        ) == .right)
    }

    @Test func wheelIntentRecoversVerticalInputAfterShiftHorizontalIntent() {
        var intent = ScrollingWheelIntentAccumulator()

        #expect(intent.resolve(
            deltaX: 0,
            deltaY: -2,
            explicitHorizontalIntent: true,
            timestamp: 1
        ) == .right)
        #expect(intent.resolve(
            deltaX: 0,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1.01
        ) == nil)
        #expect(intent.resolve(
            deltaX: 0,
            deltaY: -1,
            explicitHorizontalIntent: false,
            timestamp: 1.02
        ) == .down)
    }

    @Test func singleFrameExportPreservesSourcePixelsExactly() async throws {
        let first = try makePatternImage(width: 96, height: 140)
        let session = ManualScrollingCaptureSession(
            capturer: QueueCapturer(images: [first]),
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        let result = try await session.result()

        #expect(result.image.width == first.width)
        #expect(result.image.height == first.height)
        #expect(rgbaBytes(result.image) == rgbaBytes(first))
    }

    @Test func findsVerticalOverlapAndAppendsOnlyNewContent() throws {
        let content = try makePatternImage(width: 96, height: 260)
        let first = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let second = try crop(content, x: 0, y: 52, width: 96, height: 140)
        let stitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 3,
            maximumMeanError: 3
        )

        let match = stitcher.bestOverlap(previous: first, next: second, direction: .down)

        #expect(match?.overlap == 88)
        let stitched = try stitcher.append(previous: first, next: second, overlap: match?.overlap ?? 0, direction: .down)
        #expect(stitched.width == 96)
        #expect(stitched.height == 192)
    }

    @Test func ignoresBlankSamplingBandsOnNarrowWebContent() throws {
        let content = try makeNarrowContentImage(width: 360, height: 360, contentWidth: 110)
        let first = try crop(content, x: 0, y: 0, width: 360, height: 180)
        let second = try crop(content, x: 0, y: 64, width: 360, height: 180)
        let stitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 3,
            maximumMeanError: 3
        )

        let match = stitcher.bestOverlap(previous: first, next: second, direction: .down)

        #expect(match?.overlap == 116)
    }

    @Test func rejectsASecondDistinctOverlapWithNearlyEqualScore() {
        let stitcher = VerticalStitcher()
        let match = StitchMatch(overlap: 100, meanError: 0.125, secondBestError: 0.25)

        #expect(stitcher.validateMatch(match, frameExtent: 160) == .ambiguousMatch(gap: 0.125))
    }

    @Test func rejectsMatchWithoutAnIndependentConfidenceBasin() {
        let stitcher = VerticalStitcher()
        let match = StitchMatch(overlap: 100, meanError: 0.125)

        #expect(stitcher.validateMatch(match, frameExtent: 160) == .ambiguousMatch(gap: 0))
    }

    @Test func manualSessionMatchesDirectVerticalComposite() async throws {
        let content = try makePatternImage(width: 96, height: 260)
        let first = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let second = try crop(content, x: 0, y: 52, width: 96, height: 140)
        let capturer = QueueCapturer(images: [first, second])
        let stitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 3,
            maximumMeanError: 3
        )
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(
                processID: 1,
                captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)
            ),
            stitcher: stitcher,
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        let update = try #require(try await session.captureCurrentFrame(directionHint: .down))
        let result = try await session.result()
        let direct = try stitcher.append(previous: first, next: second, overlap: 88, direction: .down)

        #expect(update.pixelWidth == 96)
        #expect(update.pixelHeight == 192)
        #expect(result.image.width == direct.width)
        #expect(result.image.height == direct.height)
        #expect(rgbaBytes(result.image) == rgbaBytes(direct))
    }

    @Test func manualSessionMatchesDirectUpwardComposite() async throws {
        let content = try makePatternImage(width: 96, height: 260)
        let first = try crop(content, x: 0, y: 52, width: 96, height: 140)
        let second = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let capturer = QueueCapturer(images: [first, second])
        let stitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 3,
            maximumMeanError: 3
        )
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: stitcher,
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        let update = try #require(try await session.captureCurrentFrame(directionHint: .up))
        let result = try await session.result()
        let direct = try stitcher.append(previous: first, next: second, overlap: 88, direction: .up)

        #expect(update.pixelHeight == 192)
        #expect(rgbaBytes(result.image) == rgbaBytes(direct))
    }

    @Test func manualSessionMatchesDirectHorizontalComposite() async throws {
        let content = try makePatternImage(width: 260, height: 96)
        let first = try crop(content, x: 0, y: 0, width: 140, height: 96)
        let second = try crop(content, x: 52, y: 0, width: 140, height: 96)
        let capturer = QueueCapturer(images: [first, second])
        let stitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 3,
            maximumMeanError: 3
        )
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 140, height: 96)),
            stitcher: stitcher,
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        let update = try #require(try await session.captureCurrentFrame(directionHint: .right))
        let result = try await session.result()
        let direct = try stitcher.append(previous: first, next: second, overlap: 88, direction: .right)

        #expect(update.pixelWidth == 192)
        #expect(update.pixelHeight == 96)
        #expect(rgbaBytes(result.image) == rgbaBytes(direct))
    }

    @Test func manualSessionDoesNotAppendWhenReturningInsideCapturedRange() async throws {
        let content = try makePatternImage(width: 96, height: 300)
        let first = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let second = try crop(content, x: 0, y: 52, width: 96, height: 140)
        let capturer = QueueCapturer(images: [first, second, first])
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.05,
                maximumOverlapRatio: 0.995,
                sampleStride: 3,
                maximumMeanError: 3
            ),
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        let appended = try await session.captureCurrentFrame(directionHint: .down)
        let returned = try await session.captureCurrentFrame(directionHint: .up)
        let result = try await session.result()

        #expect(appended?.pixelHeight == 192)
        #expect(returned == nil)
        #expect(result.image.height == 192)
    }

    @Test func livePreviewIsBoundedButExportKeepsFullResolution() async throws {
        let content = try makePatternImage(width: 128, height: 900)
        let first = try crop(content, x: 0, y: 0, width: 128, height: 400)
        let second = try crop(content, x: 0, y: 220, width: 128, height: 400)
        let capturer = QueueCapturer(images: [first, second])
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 128, height: 400)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.05,
                maximumOverlapRatio: 0.995,
                sampleStride: 4,
                maximumMeanError: 3
            ),
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0,
            previewMaximumLongEdge: 512
        )

        _ = try await session.begin()
        let update = try #require(try await session.captureCurrentFrame(directionHint: .down))
        let result = try await session.result()

        #expect(update.pixelHeight == 620)
        #expect(update.stitchedImage.height == 512)
        #expect(result.image.height == 620)
        #expect(result.image.width == 128)
    }

    @Test func manualSessionWaitsOnlyUntilWheelMovementBecomesVisible() async throws {
        let content = try makePatternImage(width: 96, height: 280)
        let first = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let transient = try crop(content, x: 0, y: 30, width: 96, height: 140)
        let capturer = QueueCapturer(images: [first, first, transient])
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.05,
                maximumOverlapRatio: 0.995,
                sampleStride: 3,
                maximumMeanError: 3
            ),
            stabilityPollNanoseconds: 1,
            stabilityTimeoutNanoseconds: 3
        )

        _ = try await session.begin()
        let update = try #require(try await session.captureCurrentFrame(directionHint: .down))

        #expect(update.pixelHeight == 170)
        #expect(await capturer.captureCount == 3)
    }

    @Test func manualSessionDoesNotStopAtSubthresholdIntermediateFrame() async throws {
        let content = try makePatternImage(width: 96, height: 280)
        let first = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let intermediate = try offsettingRGB(first, by: 2)
        let moved = try crop(content, x: 0, y: 30, width: 96, height: 140)
        let stitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 3,
            maximumMeanError: 3
        )
        let intermediateDifference = stitcher.frameDifference(first, intermediate)
        let capturer = QueueCapturer(images: [first, intermediate, moved])
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: stitcher,
            stabilityPollNanoseconds: 1,
            stabilityTimeoutNanoseconds: 3
        )

        #expect(intermediateDifference >= 1.5)
        #expect(intermediateDifference < 3)
        _ = try await session.begin()
        let update = try #require(try await session.captureCurrentFrame(directionHint: .down))

        #expect(update.pixelHeight == 170)
        #expect(await capturer.captureCount == 3)
    }

    @Test func continuousMotionKeepsEarliestOverlappingFrame() async throws {
        let content = try makePatternImage(width: 96, height: 360)
        let first = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let earliest = try crop(content, x: 0, y: 30, width: 96, height: 140)
        let later = try crop(content, x: 0, y: 70, width: 96, height: 140)
        let latest = try crop(content, x: 0, y: 110, width: 96, height: 140)
        let capturer = QueueCapturer(images: [first, earliest, later, latest])
        let session = ManualScrollingCaptureSession(
            capturer: capturer,
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.05,
                maximumOverlapRatio: 0.995,
                sampleStride: 3,
                maximumMeanError: 3
            ),
            stabilityPollNanoseconds: 1,
            stabilityTimeoutNanoseconds: 10
        )

        _ = try await session.begin()
        let update = try #require(try await session.captureCurrentFrame(directionHint: .down))

        #expect(update.pixelHeight == 170)
        #expect(await capturer.captureCount == 2)
    }

    @Test func upwardWheelHintNeverFallsBackToDownwardMatch() async throws {
        let content = try makePatternImage(width: 96, height: 260)
        let first = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let downwardFrame = try crop(content, x: 0, y: 52, width: 96, height: 140)
        let session = ManualScrollingCaptureSession(
            capturer: QueueCapturer(images: [first, downwardFrame]),
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.05,
                maximumOverlapRatio: 0.995,
                sampleStride: 3,
                maximumMeanError: 3
            ),
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        let update = try await session.captureCurrentFrame(directionHint: .up)

        #expect(update == nil)
        #expect((try await session.result()).image.height == 140)
    }

    @Test func fastMultiFrameUpwardCaptureRemovesThinFixedBoundaries() async throws {
        let content = try makePatternImage(width: 96, height: 320)
        let first = try addingFixedBands(
            to: crop(content, x: 0, y: 160, width: 96, height: 140),
            extent: 2
        )
        let second = try addingFixedBands(
            to: crop(content, x: 0, y: 80, width: 96, height: 140),
            extent: 2
        )
        let third = try addingFixedBands(
            to: crop(content, x: 0, y: 0, width: 96, height: 140),
            extent: 2
        )
        let session = ManualScrollingCaptureSession(
            capturer: QueueCapturer(images: [first, second, third]),
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.12,
                maximumOverlapRatio: 0.995,
                sampleStride: 3,
                maximumMeanError: 3
            ),
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        _ = try #require(try await session.captureCurrentFrame(directionHint: .up))
        _ = try #require(try await session.captureCurrentFrame(directionHint: .up))
        let result = try await session.result()
        let expected = try crop(content, x: 0, y: 2, width: 96, height: 296)

        #expect(result.image.width == expected.width)
        #expect(result.image.height == expected.height)
        #expect(rgbaBytes(result.image) == rgbaBytes(expected))
    }

    @Test func fastSparseChatUpwardCaptureDoesNotDuplicateRepeatedRows() async throws {
        let content = try makeSparseChatImage(width: 240, height: 600)
        let first = try addingFixedBands(
            to: crop(content, x: 0, y: 300, width: 240, height: 260),
            extent: 2
        )
        let second = try addingFixedBands(
            to: crop(content, x: 0, y: 190, width: 240, height: 260),
            extent: 2
        )
        let third = try addingFixedBands(
            to: crop(content, x: 0, y: 80, width: 240, height: 260),
            extent: 2
        )
        let session = ManualScrollingCaptureSession(
            capturer: QueueCapturer(images: [first, second, third]),
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 240, height: 260)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.12,
                maximumOverlapRatio: 0.995,
                sampleStride: 3,
                maximumMeanError: 3
            ),
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        _ = try #require(try await session.captureCurrentFrame(directionHint: .up))
        _ = try #require(try await session.captureCurrentFrame(directionHint: .up))
        let result = try await session.result()
        let expected = try crop(content, x: 0, y: 82, width: 240, height: 476)

        #expect(result.image.width == expected.width)
        #expect(result.image.height == expected.height)
        #expect(rgbaBytes(result.image) == rgbaBytes(expected))
    }

    @Test func unmatchedWheelFrameIsRecoverable() async throws {
        let first = try makePatternImage(width: 96, height: 140)
        let unrelated = try makePatternImage(width: 96, height: 140, seedOffset: 17_123)
        let session = ManualScrollingCaptureSession(
            capturer: QueueCapturer(images: [first, unrelated]),
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: VerticalStitcher(
                minimumOverlapRatio: 0.05,
                maximumOverlapRatio: 0.995,
                sampleStride: 3,
                maximumMeanError: 1
            ),
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        let update = try await session.captureCurrentFrame(directionHint: .down)

        #expect(update == nil)
    }

    @Test func fixedTopAndBottomBandsAreNotRepeatedIntoLongCapture() async throws {
        let content = try makePatternImage(width: 96, height: 280)
        let rawFirst = try crop(content, x: 0, y: 0, width: 96, height: 140)
        let rawSecond = try crop(content, x: 0, y: 52, width: 96, height: 140)
        let first = try addingFixedBands(to: rawFirst, extent: 18)
        let second = try addingFixedBands(to: rawSecond, extent: 18)
        let stitcher = VerticalStitcher(
            minimumOverlapRatio: 0.05,
            maximumOverlapRatio: 0.995,
            sampleStride: 3,
            maximumMeanError: 3
        )
        let top = stitcher.repeatedHeaderHeight(first, second)
        let bottom = stitcher.repeatedFooterHeight(first, second)
        let croppedFirst = try crop(
            first,
            x: 0,
            y: top,
            width: first.width,
            height: first.height - top - bottom
        )
        let croppedSecond = try crop(
            second,
            x: 0,
            y: top,
            width: second.width,
            height: second.height - top - bottom
        )
        let match = try #require(stitcher.bestOverlap(
            previous: croppedFirst,
            next: croppedSecond,
            direction: .down
        ))
        let expected = try stitcher.append(
            previous: croppedFirst,
            next: croppedSecond,
            overlap: match.overlap,
            direction: .down
        )
        let session = ManualScrollingCaptureSession(
            capturer: QueueCapturer(images: [first, second]),
            target: ScrollTarget(processID: 1, captureRect: CGRect(x: 0, y: 0, width: 96, height: 140)),
            stitcher: stitcher,
            stabilityPollNanoseconds: 0,
            stabilityTimeoutNanoseconds: 0
        )

        _ = try await session.begin()
        _ = try #require(try await session.captureCurrentFrame(directionHint: .down))
        let result = try await session.result()

        #expect(top >= 16)
        #expect(bottom >= 16)
        #expect(result.image.width == expected.width)
        #expect(result.image.height == expected.height)
        #expect(rgbaBytes(result.image) == rgbaBytes(expected))
    }
}

private actor QueueCapturer: ScreenCapturing {
    private var images: [CGImage]
    private var index = 0

    init(images: [CGImage]) {
        self.images = images
    }

    var captureCount: Int { index }

    func captureRegion(_ rect: CGRect) async throws -> CaptureResult {
        try next(rect: rect)
    }

    func captureRegion(_ rect: CGRect, excludingOwnWindows: Bool) async throws -> CaptureResult {
        try next(rect: rect)
    }

    func captureDisplay(containing point: CGPoint?) async throws -> CaptureResult {
        try next(rect: .zero)
    }

    func captureWindow(at point: CGPoint?) async throws -> CaptureResult {
        try next(rect: .zero)
    }

    private func next(rect: CGRect) throws -> CaptureResult {
        guard index < images.count else {
            throw HelloXError.captureFailed("测试帧不足")
        }
        let image = images[index]
        index += 1
        return CaptureResult(image: image, displayScale: 1, capturedRect: rect, mode: .region)
    }
}

private enum ScrollingCaptureTestError: Error {
    case imageCreationFailed
    case cropFailed
}

private func makePatternImage(width: Int, height: Int, seedOffset: UInt32 = 0) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let seed = UInt32(x &* 1_103 &+ y &* 7_919 &+ (x ^ y) &* 97) &+ seedOffset
            bytes[index] = UInt8(truncatingIfNeeded: seed)
            bytes[index + 1] = UInt8(truncatingIfNeeded: seed >> 7)
            bytes[index + 2] = UInt8(truncatingIfNeeded: seed >> 15)
            bytes[index + 3] = 255
        }
    }
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        throw ScrollingCaptureTestError.imageCreationFailed
    }
    return image
}

private func makeNarrowContentImage(width: Int, height: Int, contentWidth: Int) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<min(width, contentWidth) {
            let index = (y * width + x) * 4
            let seed = UInt32(x &* 1_103 &+ y &* 7_919 &+ (x ^ y) &* 97)
            bytes[index] = UInt8(truncatingIfNeeded: seed)
            bytes[index + 1] = UInt8(truncatingIfNeeded: seed >> 7)
            bytes[index + 2] = UInt8(truncatingIfNeeded: seed >> 15)
            bytes[index + 3] = 255
        }
    }
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        throw ScrollingCaptureTestError.imageCreationFailed
    }
    return image
}

private func makeSparseChatImage(width: Int, height: Int) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 3, to: bytes.count, by: 4) {
        bytes[index] = 255
    }
    for row in 0..<(height / 68 + 1) {
        let top = row * 68 + 8
        let outgoing = row.isMultiple(of: 4)
        let avatarX = outgoing ? width - 24 : 8
        let bubbleWidth = 44 + (row * 17) % 58
        let bubbleX = outgoing ? max(28, avatarX - bubbleWidth - 8) : 32
        for y in top..<min(height, top + 20) {
            for x in avatarX..<min(width, avatarX + 16) {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(70 + row * 13 % 90)
                bytes[index + 1] = UInt8(110 + row * 19 % 90)
                bytes[index + 2] = UInt8(150 + row * 11 % 80)
            }
        }
        for y in (top + 3)..<min(height, top + 25) {
            for x in bubbleX..<min(width, bubbleX + bubbleWidth) {
                let index = (y * width + x) * 4
                let shade = outgoing ? UInt8(168) : UInt8(235)
                bytes[index] = shade
                bytes[index + 1] = outgoing ? 238 : shade
                bytes[index + 2] = shade
            }
        }
        let markerX = bubbleX + 8 + row * 7 % max(9, bubbleWidth - 14)
        for y in (top + 10)..<min(height, top + 13) {
            for x in markerX..<min(width, markerX + 6) {
                let index = (y * width + x) * 4
                bytes[index] = 52
                bytes[index + 1] = 58
                bytes[index + 2] = 66
            }
        }
    }
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        throw ScrollingCaptureTestError.imageCreationFailed
    }
    return image
}

private func crop(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) throws -> CGImage {
    guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
        throw ScrollingCaptureTestError.cropFailed
    }
    return cropped
}

private func rgbaBytes(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
        data: &bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

private func offsettingRGB(_ image: CGImage, by offset: UInt8) throws -> CGImage {
    var bytes = rgbaBytes(image)
    for pixelStart in stride(from: 0, to: bytes.count, by: 4) {
        bytes[pixelStart] = UInt8(clamping: Int(bytes[pixelStart]) + Int(offset))
        bytes[pixelStart + 1] = UInt8(clamping: Int(bytes[pixelStart + 1]) + Int(offset))
        bytes[pixelStart + 2] = UInt8(clamping: Int(bytes[pixelStart + 2]) + Int(offset))
    }
    guard let context = CGContext(
        data: &bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let result = context.makeImage() else {
        throw ScrollingCaptureTestError.imageCreationFailed
    }
    return result
}

private func addingFixedBands(to image: CGImage, extent: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw ScrollingCaptureTestError.imageCreationFailed }
    context.setShouldAntialias(false)
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setFillColor(CGColor(red: 0.18, green: 0.32, blue: 0.72, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: image.width, height: extent))
    context.setFillColor(CGColor(red: 0.72, green: 0.24, blue: 0.16, alpha: 1))
    context.fill(CGRect(x: 0, y: image.height - extent, width: image.width, height: extent))
    guard let result = context.makeImage() else {
        throw ScrollingCaptureTestError.imageCreationFailed
    }
    return result
}
