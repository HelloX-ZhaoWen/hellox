import CoreGraphics
import Foundation

public struct StitchMatch: Equatable, Sendable {
    public let overlap: Int
    public let meanError: Double
    public let secondBestError: Double?
    public let confidenceGap: Double?

    public init(overlap: Int, meanError: Double, secondBestError: Double? = nil) {
        self.overlap = overlap
        self.meanError = meanError
        self.secondBestError = secondBestError
        self.confidenceGap = secondBestError.map { $0 - meanError }
    }
}

public enum MatchValidationResult: Equatable, Sendable {
    case accepted(movement: Int)
    case insufficientNewContent(movement: Int, minimum: Int)
    case ambiguousMatch(gap: Double)
}

public struct VerticalStitcher: Sendable {
    public let minimumOverlapRatio: Double
    public let maximumOverlapRatio: Double
    public let sampleStride: Int
    public let maximumMeanError: Double

    public init(
        minimumOverlapRatio: Double = 0.12,
        maximumOverlapRatio: Double = 0.90,
        sampleStride: Int = 8,
        maximumMeanError: Double = 22
    ) {
        self.minimumOverlapRatio = minimumOverlapRatio
        self.maximumOverlapRatio = maximumOverlapRatio
        self.sampleStride = sampleStride
        self.maximumMeanError = maximumMeanError
    }

    public func bestOverlap(previous: CGImage, next: CGImage) -> StitchMatch? {
        guard previous.width == next.width else { return nil }
        guard let previousPixels = GrayPixels(image: previous), let nextPixels = GrayPixels(image: next) else { return nil }
        let height = min(previous.height, next.height)
        let minimum = max(24, Int(Double(height) * minimumOverlapRatio))
        let maximum = max(minimum, Int(Double(height) * maximumOverlapRatio))
        var bestOverlap = minimum
        var bestError = Double.infinity
        var secondBestError = Double.infinity
        let coarseStep = max(2, sampleStride / 2)
        for overlap in stride(from: minimum, through: maximum, by: coarseStep) {
            let error = overlapError(previous: previousPixels, next: nextPixels, overlap: overlap)
            if error < bestError {
                secondBestError = bestError
                bestError = error
                bestOverlap = overlap
            } else if error < secondBestError {
                secondBestError = error
            }
        }
        guard bestError < .infinity else { return nil }
        let lower = max(minimum, bestOverlap - coarseStep)
        let upper = min(maximum, bestOverlap + coarseStep)
        for overlap in lower...upper {
            let error = overlapError(previous: previousPixels, next: nextPixels, overlap: overlap)
            if error < bestError {
                secondBestError = bestError
                bestError = error
                bestOverlap = overlap
            } else if error < secondBestError {
                secondBestError = error
            }
        }
        guard bestError <= maximumMeanError else { return nil }
        let second = secondBestError < .infinity ? secondBestError : nil
        return StitchMatch(overlap: bestOverlap, meanError: bestError, secondBestError: second)
    }

    /// Finds the overlap for any scroll direction. The original vertical-down
    /// overload remains as a compatibility wrapper for existing callers.
    public func bestOverlap(
        previous: CGImage,
        next: CGImage,
        direction: ScrollDirection
    ) -> StitchMatch? {
        let samePerpendicularAxis = direction.isHorizontal
            ? previous.height == next.height
            : previous.width == next.width
        guard samePerpendicularAxis else { return nil }
        guard let previousPixels = GrayPixels(image: previous), let nextPixels = GrayPixels(image: next) else {
            return nil
        }
        let fixedEdges = fixedEdgeInsets(previous: previous, next: next)
        let extent = direction.isHorizontal
            ? min(previous.width, next.width)
            : min(previous.height, next.height)
        let minimum = max(24, Int(Double(extent) * minimumOverlapRatio))
        let maximum = max(minimum, Int(Double(extent) * maximumOverlapRatio))
        var evaluatedErrors: [Int: Double] = [:]
        let coarseStep = max(2, sampleStride / 2)
        for overlap in stride(from: minimum, through: maximum, by: coarseStep) {
            let error = directionalOverlapError(
                previous: previousPixels,
                next: nextPixels,
                overlap: overlap,
                direction: direction,
                fixedEdges: fixedEdges
            )
            guard error.isFinite else { continue }
            evaluatedErrors[overlap] = error
        }
        guard !evaluatedErrors.isEmpty else { return nil }

        // Refine several spatially independent valleys. Refining only the
        // coarse winner can make a repeated chat row look more confident than
        // the true shift when the latter falls between coarse samples.
        let distinctSeparation = max(12, Int(Double(extent) * 0.04))
        var basinCenters: [Int] = []
        for candidate in evaluatedErrors.sorted(by: { $0.value < $1.value }) {
            guard basinCenters.allSatisfy({ abs($0 - candidate.key) >= distinctSeparation }) else { continue }
            basinCenters.append(candidate.key)
            if basinCenters.count == 3 { break }
        }
        for center in basinCenters {
            let lower = max(minimum, center - coarseStep)
            let upper = min(maximum, center + coarseStep)
            for overlap in lower...upper {
                let error = directionalOverlapError(
                    previous: previousPixels,
                    next: nextPixels,
                    overlap: overlap,
                    direction: direction,
                    fixedEdges: fixedEdges
                )
                guard error.isFinite else { continue }
                evaluatedErrors[overlap] = error
            }
        }

        guard let globalMinimum = evaluatedErrors.min(by: { $0.value < $1.value }),
              globalMinimum.value <= maximumMeanError else { return nil }
        // Within one error valley prefer the larger overlap, which avoids a
        // small duplicate strip without drifting to a separate repeated row.
        let localBest = evaluatedErrors
            .filter {
                abs($0.key - globalMinimum.key) < distinctSeparation
                    && $0.value <= globalMinimum.value + ambiguityTolerance
            }
            .max(by: { $0.key < $1.key }) ?? globalMinimum
        let bestOverlap = localBest.key
        let bestError = localBest.value
        guard bestError <= maximumMeanError else { return nil }
        // Adjacent overlap values belong to the same error valley. Only a
        // spatially distinct alternative is evidence that the match is
        // genuinely ambiguous (for example, repeated search-result rows).
        let second = evaluatedErrors
            .filter { abs($0.key - bestOverlap) >= distinctSeparation }
            .map(\.value)
            .min()
        return StitchMatch(overlap: bestOverlap, meanError: bestError, secondBestError: second)
    }

    public func append(previous: CGImage, next: CGImage, overlap: Int) throws -> CGImage {
        guard previous.width == next.width, overlap >= 0,
              overlap < previous.height, overlap < next.height else {
            throw HelloXError.captureFailed("长截图帧尺寸不匹配")
        }
        let outputHeight = previous.height + next.height - overlap
        guard let context = CGContext(
            data: nil,
            width: previous.width,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HelloXError.captureFailed("无法创建长截图画布") }
        context.interpolationQuality = .none
        context.draw(next, in: CGRect(x: 0, y: 0, width: next.width, height: next.height))
        context.draw(previous, in: CGRect(x: 0, y: next.height - overlap, width: previous.width, height: previous.height))
        guard let image = context.makeImage() else { throw HelloXError.captureFailed("无法生成长截图") }
        return image
    }

    public func append(
        previous: CGImage,
        next: CGImage,
        overlap: Int,
        direction: ScrollDirection
    ) throws -> CGImage {
        let samePerpendicularAxis = direction.isHorizontal
            ? previous.height == next.height
            : previous.width == next.width
        guard samePerpendicularAxis, overlap >= 0 else {
            throw HelloXError.captureFailed("长截图帧尺寸不匹配")
        }
        let outputWidth = direction.isHorizontal
            ? previous.width + next.width - overlap
            : previous.width
        let outputHeight = direction.isHorizontal
            ? previous.height
            : previous.height + next.height - overlap
        guard overlap < (direction.isHorizontal ? min(previous.width, next.width) : min(previous.height, next.height)) else {
            throw HelloXError.captureFailed("长截图重叠区域无效")
        }
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HelloXError.captureFailed("无法创建长截图画布") }
        context.interpolationQuality = .none

        switch direction {
        case .down:
            context.draw(next, in: CGRect(x: 0, y: 0, width: next.width, height: next.height))
            context.draw(previous, in: CGRect(x: 0, y: next.height - overlap, width: previous.width, height: previous.height))
        case .up:
            context.draw(next, in: CGRect(x: 0, y: previous.height - overlap, width: next.width, height: next.height))
            context.draw(previous, in: CGRect(x: 0, y: 0, width: previous.width, height: previous.height))
        case .right:
            context.draw(next, in: CGRect(x: previous.width - overlap, y: 0, width: next.width, height: next.height))
            context.draw(previous, in: CGRect(x: 0, y: 0, width: previous.width, height: previous.height))
        case .left:
            context.draw(next, in: CGRect(x: 0, y: 0, width: next.width, height: next.height))
            context.draw(previous, in: CGRect(x: next.width - overlap, y: 0, width: previous.width, height: previous.height))
        }
        guard let image = context.makeImage() else { throw HelloXError.captureFailed("无法生成长截图") }
        return image
    }

    public func validateMatch(
        _ match: StitchMatch,
        frameExtent: Int,
        minimumNewContentRatio: Double = 0.03,
        minimumNewContentAbsolute: Int = 24,
        minimumConfidenceGap: Double = 0.5
    ) -> MatchValidationResult {
        let movement = max(1, frameExtent - match.overlap)
        let minimumNewContent = max(minimumNewContentAbsolute, Int(Double(frameExtent) * minimumNewContentRatio))
        guard movement >= minimumNewContent else {
            return .insufficientNewContent(movement: movement, minimum: minimumNewContent)
        }
        guard let gap = match.confidenceGap else {
            return .ambiguousMatch(gap: 0)
        }
        let requiredConfidenceGap = max(minimumConfidenceGap, match.meanError * 0.08)
        if gap < requiredConfidenceGap {
            return .ambiguousMatch(gap: gap)
        }
        return .accepted(movement: movement)
    }

    public func frameDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return .infinity }
        var sum = 0.0
        var count = 0
        for y in stride(from: 0, to: lhs.height, by: sampleStride) {
            for x in stride(from: 0, to: lhs.width, by: sampleStride) {
                sum += abs(Double(a[x, y]) - Double(b[x, y]))
                count += 1
            }
        }
        return count == 0 ? .infinity : sum / Double(count)
    }

    /// Percentage of sampled pixels that changed materially at the same
    /// screen coordinate. A real scroll moves text and cell edges across a
    /// meaningful part of the viewport; a blinking caret, thumbnail load or
    /// hover animation usually changes only a tiny island.
    public func frameChangeCoverage(_ lhs: CGImage, _ rhs: CGImage, threshold: Int = 8) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return 1 }
        var changed = 0
        var count = 0
        let stride = max(3, sampleStride / 2)
        for y in Swift.stride(from: 0, to: lhs.height, by: stride) {
            for x in Swift.stride(from: 0, to: lhs.width, by: stride) {
                if abs(Int(a[x, y]) - Int(b[x, y])) >= threshold { changed += 1 }
                count += 1
            }
        }
        return count == 0 ? 1 : Double(changed) / Double(count)
    }

    /// Counts vertical viewport bands with material changes. A scroll moves
    /// content through several bands; animated stickers and video thumbnails
    /// usually alter only one local area.
    public func activeChangeVerticalBands(
        _ lhs: CGImage,
        _ rhs: CGImage,
        threshold: Int = 8,
        bands: Int = 6,
        minimumBandCoverage: Double = 0.025
    ) -> Int {
        guard bands > 0,
              lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return bands }
        var changed = [Int](repeating: 0, count: bands)
        var sampled = [Int](repeating: 0, count: bands)
        let stride = max(3, sampleStride / 2)
        for y in Swift.stride(from: 0, to: lhs.height, by: stride) {
            let band = min(bands - 1, y * bands / lhs.height)
            for x in Swift.stride(from: 0, to: lhs.width, by: stride) {
                sampled[band] += 1
                if abs(Int(a[x, y]) - Int(b[x, y])) >= threshold {
                    changed[band] += 1
                }
            }
        }
        return zip(changed, sampled).filter { changed, sampled in
            sampled > 0 && Double(changed) / Double(sampled) >= minimumBandCoverage
        }.count
    }

    /// Detects a fixed header repeated at the top of consecutive frames.
    /// A small minimum prevents ordinary similar content from being removed.
    public func repeatedHeaderHeight(_ lhs: CGImage, _ rhs: CGImage, maximumRatio: Double = 0.25) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return 0 }
        let maximum = Int(Double(lhs.height) * maximumRatio)
        let thinBoundary = repeatedThinBoundaryExtent(
            a,
            b,
            fromLeadingEdge: true,
            maximum: min(64, maximum)
        )
        let broadHeader = repeatedTexturedBoundaryExtent(
            a,
            b,
            fromLeadingEdge: true,
            maximum: maximum
        )
        return max(thinBoundary, broadHeader)
    }

    public func repeatedFooterHeight(_ lhs: CGImage, _ rhs: CGImage, maximumRatio: Double = 0.20) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return 0 }
        let maximum = Int(Double(lhs.height) * maximumRatio)
        let thinBoundary = repeatedThinBoundaryExtent(
            a,
            b,
            fromLeadingEdge: false,
            maximum: min(64, maximum)
        )
        let broadFooter = repeatedTexturedBoundaryExtent(
            a,
            b,
            fromLeadingEdge: false,
            maximum: maximum
        )
        return max(thinBoundary, broadFooter)
    }

    /// Detects screen-fixed columns such as frozen table actions or row
    /// selectors. They must not participate in horizontal motion matching,
    /// otherwise a large stationary block can look like a nearly full-frame
    /// overlap and cause the same viewport to be appended repeatedly.
    public func repeatedLeadingWidth(_ lhs: CGImage, _ rhs: CGImage, maximumRatio: Double = 0.40) -> Int {
        repeatedColumnExtent(lhs, rhs, fromLeadingEdge: true, maximumRatio: maximumRatio)
    }

    public func repeatedTrailingWidth(_ lhs: CGImage, _ rhs: CGImage, maximumRatio: Double = 0.30) -> Int {
        repeatedColumnExtent(lhs, rhs, fromLeadingEdge: false, maximumRatio: maximumRatio)
    }

    /// Finds textured overlays that remain at the same screen coordinate near
    /// the left or right edge while the page content moves. Cropping these
    /// side rails prevents floating web toolbars from being repeated at every
    /// vertical stitch seam.
    public func stationarySideInsets(
        _ lhs: CGImage,
        _ rhs: CGImage,
        maximumRatio: Double = 0.22
    ) -> (leading: Int, trailing: Int) {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return (0, 0) }
        return (
            stationaryOverlayWidth(a, b, fromLeadingEdge: true, maximumRatio: maximumRatio),
            stationaryOverlayWidth(a, b, fromLeadingEdge: false, maximumRatio: maximumRatio)
        )
    }

    private func overlapError(previous: GrayPixels, next: GrayPixels, overlap: Int) -> Double {
        var bandErrors: [Double] = []
        let startY = previous.height - overlap
        let bands = [(0.08, 0.32), (0.36, 0.64), (0.68, 0.92)]
        for band in bands {
            var total = 0.0
            var count = 0
            let lower = Int(Double(previous.width) * band.0)
            let upper = Int(Double(previous.width) * band.1)
            for offsetY in stride(from: 0, to: overlap, by: sampleStride) {
                for x in stride(from: lower, to: upper, by: sampleStride) {
                    total += abs(Double(previous[x, startY + offsetY]) - Double(next[x, offsetY]))
                    count += 1
                }
            }
            if count > 0 { bandErrors.append(total / Double(count)) }
        }
        guard !bandErrors.isEmpty else { return .infinity }
        return bandErrors.sorted()[bandErrors.count / 2]
    }

    private func directionalOverlapError(
        previous: GrayPixels,
        next: GrayPixels,
        overlap: Int,
        direction: ScrollDirection,
        fixedEdges: FixedEdgeInsets
    ) -> Double {
        let horizontal = direction.isHorizontal
        let span = horizontal ? previous.height : previous.width
        let bands = [(0.08, 0.32), (0.36, 0.64), (0.68, 0.92)]
        var bandErrors: [Double] = []
        for band in bands {
            var total = 0.0
            var count = 0
            var edgeTotal = 0.0
            var edgeCount = 0
            var edgeMotionBins = [Int](repeating: 0, count: 4)
            let lower = Int(Double(span) * band.0)
            let upper = Int(Double(span) * band.1)
            if horizontal {
                for offset in stride(from: 0, to: overlap, by: sampleStride) {
                    for perpendicular in stride(from: lower, to: upper, by: sampleStride) {
                        let previousX = direction == .right ? previous.width - overlap + offset : offset
                        let nextX = direction == .right ? offset : next.width - overlap + offset
                        guard !fixedEdges.containsColumn(previousX, width: previous.width),
                              !fixedEdges.containsColumn(nextX, width: next.width),
                              !fixedEdges.containsRow(perpendicular, height: previous.height) else { continue }
                        let delta = abs(Double(previous[previousX, perpendicular]) - Double(next[nextX, perpendicular]))
                        total += delta
                        let previousEdge = previous.edgeMagnitude(x: previousX, y: perpendicular)
                        let nextEdge = next.edgeMagnitude(x: nextX, y: perpendicular)
                        if max(previousEdge, nextEdge) >= 10 {
                            edgeTotal += delta + 0.6 * abs(previousEdge - nextEdge)
                            edgeCount += 1
                            edgeMotionBins[min(3, offset * 4 / max(1, overlap))] += 1
                        }
                        count += 1
                    }
                }
            } else {
                for offset in stride(from: 0, to: overlap, by: sampleStride) {
                    for perpendicular in stride(from: lower, to: upper, by: sampleStride) {
                        let previousY = direction == .down ? previous.height - overlap + offset : offset
                        let nextY = direction == .down ? offset : next.height - overlap + offset
                        guard !fixedEdges.containsRow(previousY, height: previous.height),
                              !fixedEdges.containsRow(nextY, height: next.height),
                              !fixedEdges.containsColumn(perpendicular, width: previous.width) else { continue }
                        let delta = abs(Double(previous[perpendicular, previousY]) - Double(next[perpendicular, nextY]))
                        total += delta
                        let previousEdge = previous.edgeMagnitude(x: perpendicular, y: previousY)
                        let nextEdge = next.edgeMagnitude(x: perpendicular, y: nextY)
                        if max(previousEdge, nextEdge) >= 10 {
                            edgeTotal += delta + 0.6 * abs(previousEdge - nextEdge)
                            edgeCount += 1
                            edgeMotionBins[min(3, offset * 4 / max(1, overlap))] += 1
                        }
                        count += 1
                    }
                }
            }
            // A blank band has zero luma error for every candidate and used to
            // outvote the single band that actually contained page content.
            // Require a small amount of edge evidence before a band can vote.
            let minimumEdgeSamples = max(6, count / 120)
            let informativeMotionBins = edgeMotionBins.filter { $0 >= 2 }.count
            let requiredMotionBins = overlap >= sampleStride * 4 ? 2 : 1
            if count > 0,
               edgeCount >= minimumEdgeSamples,
               informativeMotionBins >= requiredMotionBins {
                let lumaMean = total / Double(count)
                let edgeMean = edgeTotal / Double(edgeCount)
                bandErrors.append(lumaMean * 0.25 + edgeMean * 0.75)
            }
        }
        guard !bandErrors.isEmpty else { return .infinity }
        return bandErrors.sorted()[bandErrors.count / 2]
    }

    private func fixedEdgeInsets(previous: CGImage, next: CGImage) -> FixedEdgeInsets {
        guard previous.width == next.width, previous.height == next.height else { return .zero }
        return FixedEdgeInsets(
            top: repeatedHeaderHeight(previous, next),
            bottom: repeatedFooterHeight(previous, next),
            left: repeatedLeadingWidth(previous, next),
            right: repeatedTrailingWidth(previous, next)
        )
    }

    private func repeatedColumnExtent(
        _ lhs: CGImage,
        _ rhs: CGImage,
        fromLeadingEdge: Bool,
        maximumRatio: Double
    ) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return 0 }
        let maximum = Int(Double(lhs.width) * maximumRatio)
        var lastMatchingOffset = 0
        var misses = 0
        for offset in stride(from: 0, to: maximum, by: 2) {
            let x = fromLeadingEdge ? offset : lhs.width - 1 - offset
            var total = 0.0
            var count = 0
            for y in stride(from: 0, to: lhs.height, by: sampleStride) {
                total += abs(Double(a[x, y]) - Double(b[x, y]))
                count += 1
            }
            let error = count == 0 ? .infinity : total / Double(count)
            if error <= 6 {
                lastMatchingOffset = offset
                misses = 0
            } else {
                misses += 1
                if misses >= 3 { break }
            }
        }
        return lastMatchingOffset >= 12 ? min(maximum, lastMatchingOffset + 2) : 0
    }

    private func stationaryOverlayWidth(
        _ lhs: GrayPixels,
        _ rhs: GrayPixels,
        fromLeadingEdge: Bool,
        maximumRatio: Double
    ) -> Int {
        let maximum = max(1, Int(Double(lhs.width) * maximumRatio))
        var stationaryOffsets: [Int] = []
        for offset in stride(from: 0, to: maximum, by: 2) {
            let x = fromLeadingEdge ? offset : lhs.width - 1 - offset
            var informative = 0
            var matching = 0
            for y in stride(from: 1, to: lhs.height, by: max(3, sampleStride / 2)) {
                let lhsEdge = lhs.edgeMagnitude(x: x, y: y)
                let rhsEdge = rhs.edgeMagnitude(x: x, y: y)
                guard max(lhsEdge, rhsEdge) >= 10 else { continue }
                informative += 1
                if abs(Int(lhs[x, y]) - Int(rhs[x, y])) <= 7,
                   abs(lhsEdge - rhsEdge) <= 10 {
                    matching += 1
                }
            }
            guard informative >= 6 else { continue }
            if Double(matching) / Double(informative) >= 0.58 {
                stationaryOffsets.append(offset)
            }
        }
        guard stationaryOffsets.count >= 3,
              let furthest = stationaryOffsets.max(), furthest >= 6 else { return 0 }
        return min(maximum, furthest + 3)
    }

    /// Recognizes thin, full-width window separators at a viewport boundary.
    /// Chat applications often use a 1–8 px fixed divider; the broad fixed-band
    /// detector intentionally ignores anything below 12 px, so an upward
    /// capture would otherwise append that divider and nearby content once per
    /// wheel step. Blank margins alone are not cropped: an interior contrast
    /// edge must be present in both frames.
    private func repeatedThinBoundaryExtent(
        _ lhs: GrayPixels,
        _ rhs: GrayPixels,
        fromLeadingEdge: Bool,
        maximum: Int
    ) -> Int {
        guard maximum > 0, lhs.width == rhs.width, lhs.height == rhs.height else { return 0 }
        var detectedExtent = 0
        for offset in 0..<min(maximum, lhs.height - 1) {
            let row = fromLeadingEdge ? offset : lhs.height - 1 - offset
            let interiorRow = fromLeadingEdge ? row + 1 : row - 1
            var sameCoordinateDifference = 0.0
            var contrastByBand = [Double](repeating: 0, count: 4)
            var samplesByBand = [Int](repeating: 0, count: 4)
            var count = 0
            for x in stride(from: 0, to: lhs.width, by: max(2, sampleStride / 2)) {
                sameCoordinateDifference += abs(Double(lhs[x, row]) - Double(rhs[x, row]))
                let contrast = max(
                    abs(Double(lhs[x, row]) - Double(lhs[x, interiorRow])),
                    abs(Double(rhs[x, row]) - Double(rhs[x, interiorRow]))
                )
                let band = min(3, x * 4 / max(1, lhs.width))
                contrastByBand[band] += contrast
                samplesByBand[band] += 1
                count += 1
            }
            guard count > 0,
                  sameCoordinateDifference / Double(count) <= 2.5 else { break }
            let contrastingBands = zip(contrastByBand, samplesByBand).filter { total, samples in
                samples > 0 && total / Double(samples) >= 3.0
            }.count
            if contrastingBands >= 3 {
                detectedExtent = offset + 1
            }
        }
        return detectedExtent
    }

    /// Finds a larger fixed toolbar/header using only informative edges. Mean
    /// luma over a mostly white chat viewport is not evidence of stationarity:
    /// it previously classified ordinary blank margins as a 20+ px header.
    private func repeatedTexturedBoundaryExtent(
        _ lhs: GrayPixels,
        _ rhs: GrayPixels,
        fromLeadingEdge: Bool,
        maximum: Int
    ) -> Int {
        guard maximum > 0, lhs.width == rhs.width, lhs.height == rhs.height else { return 0 }
        var evidenceRows = 0
        var mismatchingEvidenceRows = 0
        var furthestMatchingOffset = 0
        for offset in stride(from: 0, to: min(maximum, lhs.height), by: 2) {
            let row = fromLeadingEdge ? offset : lhs.height - 1 - offset
            var informative = 0
            var matching = 0
            for x in stride(from: 1, to: lhs.width, by: max(2, sampleStride / 2)) {
                let lhsEdge = lhs.edgeMagnitude(x: x, y: row)
                let rhsEdge = rhs.edgeMagnitude(x: x, y: row)
                guard max(lhsEdge, rhsEdge) >= 10 else { continue }
                informative += 1
                if abs(Int(lhs[x, row]) - Int(rhs[x, row])) <= 7,
                   abs(lhsEdge - rhsEdge) <= 10 {
                    matching += 1
                }
            }
            guard informative >= 4 else { continue }
            if Double(matching) / Double(informative) >= 0.72 {
                evidenceRows += 1
                mismatchingEvidenceRows = 0
                furthestMatchingOffset = offset
            } else if evidenceRows > 0 {
                mismatchingEvidenceRows += 1
                if mismatchingEvidenceRows >= 3 { break }
            }
        }
        guard evidenceRows >= 3, furthestMatchingOffset >= 12 else { return 0 }
        return min(maximum, furthestMatchingOffset + 2)
    }

    private let ambiguityTolerance = 0.25
}

private struct FixedEdgeInsets {
    let top: Int
    let bottom: Int
    let left: Int
    let right: Int

    static let zero = FixedEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)

    func containsRow(_ row: Int, height: Int) -> Bool {
        row < top || row >= height - bottom
    }

    func containsColumn(_ column: Int, width: Int) -> Bool {
        column < left || column >= width - right
    }
}

private struct GrayPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    subscript(_ x: Int, _ y: Int) -> UInt8 { bytes[y * width + x] }

    func edgeMagnitude(x: Int, y: Int) -> Double {
        let center = Int(self[x, y])
        let left = Int(self[max(0, x - 1), y])
        let top = Int(self[x, max(0, y - 1)])
        return Double(abs(center - left) + abs(center - top))
    }
}
