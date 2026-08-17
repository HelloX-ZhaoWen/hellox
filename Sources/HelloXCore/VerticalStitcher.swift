import CoreGraphics
import Foundation

public struct StitchMatch: Equatable, Sendable {
    public let overlap: Int
    public let meanError: Double

    public init(overlap: Int, meanError: Double) {
        self.overlap = overlap
        self.meanError = meanError
    }
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
        var best: StitchMatch?
        let coarseStep = max(2, sampleStride / 2)
        for overlap in stride(from: minimum, through: maximum, by: coarseStep) {
            let error = overlapError(previous: previousPixels, next: nextPixels, overlap: overlap)
            if best == nil || error < best!.meanError { best = StitchMatch(overlap: overlap, meanError: error) }
        }
        guard let coarse = best else { return nil }
        let lower = max(minimum, coarse.overlap - coarseStep)
        let upper = min(maximum, coarse.overlap + coarseStep)
        for overlap in lower...upper {
            let error = overlapError(previous: previousPixels, next: nextPixels, overlap: overlap)
            if error < best!.meanError { best = StitchMatch(overlap: overlap, meanError: error) }
        }
        guard let best, best.meanError <= maximumMeanError else { return nil }
        return best
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
        var best: StitchMatch?
        let coarseStep = max(2, sampleStride / 2)
        for overlap in stride(from: minimum, through: maximum, by: coarseStep) {
            let error = directionalOverlapError(
                previous: previousPixels,
                next: nextPixels,
                overlap: overlap,
                direction: direction,
                fixedEdges: fixedEdges
            )
            if shouldPrefer(error: error, overlap: overlap, over: best) {
                best = StitchMatch(overlap: overlap, meanError: error)
            }
        }
        guard let coarse = best else { return nil }
        let lower = max(minimum, coarse.overlap - coarseStep)
        let upper = min(maximum, coarse.overlap + coarseStep)
        for overlap in lower...upper {
            let error = directionalOverlapError(
                previous: previousPixels,
                next: nextPixels,
                overlap: overlap,
                direction: direction,
                fixedEdges: fixedEdges
            )
            if shouldPrefer(error: error, overlap: overlap, over: best) {
                best = StitchMatch(overlap: overlap, meanError: error)
            }
        }
        guard let best, best.meanError <= maximumMeanError else { return nil }
        return best
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
        var lastMatchingRow = 0
        var misses = 0
        for y in stride(from: 0, to: maximum, by: 2) {
            var total = 0.0
            var count = 0
            for x in stride(from: 0, to: lhs.width, by: sampleStride) {
                total += abs(Double(a[x, y]) - Double(b[x, y]))
                count += 1
            }
            let error = count == 0 ? .infinity : total / Double(count)
            if error <= 6 {
                lastMatchingRow = y
                misses = 0
            } else {
                misses += 1
                if misses >= 3 { break }
            }
        }
        return lastMatchingRow >= 12 ? min(maximum, lastMatchingRow + 2) : 0
    }

    public func repeatedFooterHeight(_ lhs: CGImage, _ rhs: CGImage, maximumRatio: Double = 0.20) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = GrayPixels(image: lhs), let b = GrayPixels(image: rhs) else { return 0 }
        let maximum = Int(Double(lhs.height) * maximumRatio)
        var lastMatchingOffset = 0
        var misses = 0
        for offset in stride(from: 0, to: maximum, by: 2) {
            let y = lhs.height - 1 - offset
            var total = 0.0
            var count = 0
            for x in stride(from: 0, to: lhs.width, by: sampleStride) {
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
                        }
                        count += 1
                    }
                }
            }
            if count > 0 {
                let lumaMean = total / Double(count)
                let edgeMean = edgeCount >= 4 ? edgeTotal / Double(edgeCount) : lumaMean
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

    private func shouldPrefer(error: Double, overlap: Int, over best: StitchMatch?) -> Bool {
        guard let best else { return true }
        // When a sparse table produces several almost-identical matches, a
        // conservative larger overlap avoids duplicating an entire viewport.
        let ambiguityTolerance = 0.25
        if error < best.meanError - ambiguityTolerance { return true }
        return abs(error - best.meanError) <= ambiguityTolerance && overlap > best.overlap
    }
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
