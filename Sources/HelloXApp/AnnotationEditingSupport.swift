import AppKit
import HelloXCore
import SwiftUI

enum WatermarkAnnotationFactory {
    static func makeDefault() -> Annotation {
        Annotation(
            tool: .watermark,
            start: .zero,
            end: CGPoint(x: 1, y: 1),
            text: "水印",
            color: .black,
            lineWidth: 6,
            watermarkSpacing: 48
        )
    }
}

enum AnnotationEditingGeometry {
    /// Extra screen-space tolerance around visible annotation edges.
    static let hitTolerance: CGFloat = 6

    /// Handles shown around a selected annotation. The order matches the visual
    /// clockwise order used by the selection rectangle.
    static let resizeHandles: [AnnotationResizeHandle] = [
        .topLeft, .top, .topRight, .right,
        .bottomRight, .bottom, .bottomLeft, .left
    ]

    static func resizeHandles(for annotation: Annotation) -> [AnnotationResizeHandle] {
        if annotation.tool == .arrow { return [.start, .end] }
        if annotation.tool == .step { return [.left, .right] }
        return resizeHandles
    }

    static func displayLineWidth(
        for annotation: Annotation,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> CGFloat {
        max(1, annotation.lineWidth * imageRect.width / max(1, sourceImageSize.width))
    }

    static func textRect(
        for annotation: Annotation,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> CGRect {
        let origin = CGPoint(
            x: imageRect.minX + annotation.start.x * imageRect.width,
            y: imageRect.minY + annotation.start.y * imageRect.height
        )
        let fontSize = max(
            AnnotationTypography.minimumFontSize,
            displayLineWidth(for: annotation, imageRect: imageRect, sourceImageSize: sourceImageSize) * 5
        )
        let text = annotation.text.isEmpty
            ? (annotation.tool == .watermark ? "水印" : "文字")
            : annotation.text
        let baseFont = NSFont.systemFont(ofSize: fontSize)
        let font = annotation.tool == .watermark
            ? NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            : baseFont
        let measured = unwrappedTextSize(text, font: font)
        return CGRect(
            origin: origin,
            size: CGSize(width: max(12, measured.width), height: max(fontSize, measured.height))
        )
    }

    static func stepLayout(
        for annotation: Annotation,
        text: String? = nil,
        number: Int,
        imageRect: CGRect,
        sourceImageSize: CGSize,
        usesCustomBadgePosition: Bool = true
    ) -> StepAnnotationLayoutMetrics {
        let start = CGPoint(
            x: imageRect.minX + annotation.start.x * imageRect.width,
            y: imageRect.minY + annotation.start.y * imageRect.height
        )
        let end = CGPoint(
            x: imageRect.minX + annotation.end.x * imageRect.width,
            y: imageRect.minY + annotation.end.y * imageRect.height
        )
        let badgeOnTrailingEdge = end.x < start.x
        let totalWidth = max(
            StepAnnotationLayout.minimumCardWidth,
            abs(end.x - start.x)
        )
        let fontSize = max(
            AnnotationTypography.minimumFontSize,
            displayLineWidth(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ) * 5
        )
        return StepAnnotationLayout.layout(
            text: text ?? annotation.text,
            number: number,
            origin: CGPoint(x: min(start.x, end.x), y: start.y),
            totalWidth: totalWidth,
            fontSize: fontSize,
            badgeOnTrailingEdge: badgeOnTrailingEdge,
            badgeCenter: usesCustomBadgePosition ? annotation.stepBadgePosition.map {
                CGPoint(
                    x: imageRect.minX + $0.x * imageRect.width,
                    y: imageRect.minY + $0.y * imageRect.height
                )
            } : nil
        )
    }

    static func makeStepAnnotation(
        at point: CGPoint,
        number: Int,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize,
        color: RGBAColor,
        lineWidth: CGFloat
    ) -> Annotation {
        var seed = Annotation(
            tool: .step,
            start: .zero,
            end: .zero,
            text: "",
            color: color,
            lineWidth: lineWidth
        )
        let fontSize = max(
            AnnotationTypography.minimumFontSize,
            displayLineWidth(
                for: seed,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ) * 5
        )
        let provisional = StepAnnotationLayout.layout(
            text: "",
            number: number,
            origin: .zero,
            totalWidth: StepAnnotationLayout.defaultCardWidth + 100,
            fontSize: fontSize
        )
        let desiredWidth = provisional.badgeRect.width
            + StepAnnotationLayout.badgeGap
            + StepAnnotationLayout.defaultCardWidth
        let leadingOriginX = point.x - provisional.badgeRect.width / 2
        let trailingMaxX = point.x + provisional.badgeRect.width / 2
        let availableOnRight = max(1, editingBounds.maxX - leadingOriginX)
        let availableOnLeft = max(1, trailingMaxX - editingBounds.minX)
        let badgeOnTrailingEdge = availableOnRight < desiredWidth
            && availableOnLeft > availableOnRight
        let availableWidth = badgeOnTrailingEdge ? availableOnLeft : availableOnRight
        let minimumTotalWidth = provisional.badgeRect.width
            + StepAnnotationLayout.badgeGap
            + StepAnnotationLayout.minimumCardWidth
        let resolvedWidth = min(
            desiredWidth,
            max(minimumTotalWidth, availableWidth)
        )
        let measured = StepAnnotationLayout.layout(
            text: "",
            number: number,
            origin: .zero,
            totalWidth: resolvedWidth,
            fontSize: fontSize,
            badgeOnTrailingEdge: badgeOnTrailingEdge
        )
        let desiredOriginX = badgeOnTrailingEdge
            ? trailingMaxX - measured.bounds.width
            : leadingOriginX
        let desiredOrigin = CGPoint(
            x: desiredOriginX,
            y: point.y - provisional.badgeRect.height / 2
        )
        let origin = CGPoint(
            x: min(
                max(editingBounds.minX, desiredOrigin.x),
                max(editingBounds.minX, editingBounds.maxX - measured.bounds.width)
            ),
            y: min(
                max(editingBounds.minY, desiredOrigin.y),
                max(editingBounds.minY, editingBounds.maxY - measured.bounds.height)
            )
        )
        let oppositeCorner = CGPoint(
            x: badgeOnTrailingEdge ? origin.x : origin.x + measured.bounds.width,
            y: origin.y + measured.bounds.height
        )
        let badgeEdge = CGPoint(
            x: badgeOnTrailingEdge ? origin.x + measured.bounds.width : origin.x,
            y: origin.y
        )
        seed.start = normalizedPoint(
            badgeEdge,
            imageRect: imageRect,
            editingBounds: editingBounds
        )
        seed.end = normalizedPoint(
            oppositeCorner,
            imageRect: imageRect,
            editingBounds: editingBounds
        )
        seed.stepBadgePosition = normalizedPoint(
            CGPoint(
                x: origin.x + measured.badgeRect.midX,
                y: origin.y + measured.badgeRect.midY
            ),
            imageRect: imageRect,
            editingBounds: editingBounds
        )
        return seed
    }

    static func fittedStepAnnotation(
        _ annotation: Annotation,
        number: Int,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
        guard annotation.tool == .step else { return annotation }
        let layout = stepLayout(
            for: annotation,
            number: number,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        var result = annotation
        result.end.y = normalizedPoint(
            CGPoint(x: layout.cardRect.maxX, y: layout.cardRect.maxY),
            imageRect: imageRect,
            editingBounds: editingBounds
        ).y
        return moved(
            result,
            by: .zero,
            imageRect: imageRect,
            editingBounds: editingBounds,
            sourceImageSize: sourceImageSize
        )
    }

    static func isStepTextInput(
        at point: CGPoint,
        annotation: Annotation,
        number: Int,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> Bool {
        guard annotation.tool == .step else { return false }
        return stepLayout(
            for: annotation,
            number: number,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        ).cardRect.contains(point)
    }

    static func isStepBadge(
        at point: CGPoint,
        annotation: Annotation,
        number: Int,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> Bool {
        guard annotation.tool == .step else { return false }
        return stepLayout(
            for: annotation,
            number: number,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        ).badgeRect.contains(point)
    }

    /// Measures explicit lines without introducing automatic wrapping. The inline editor and
    /// rendered annotation use this same geometry, so typing grows width and Return grows height.
    static func unwrappedTextSize(_ text: String, font: NSFont) -> CGSize {
        let lines = text.components(separatedBy: "\n")
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let width = lines.reduce(CGFloat.zero) { result, line in
            max(result, ceil((line as NSString).size(withAttributes: attributes).width))
        }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGSize(width: width, height: lineHeight * CGFloat(max(1, lines.count)))
    }

    static func displayBounds(
        for annotation: Annotation,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> CGRect {
        if annotation.tool == .watermark {
            return imageRect
        }
        if annotation.tool == .text {
            return textRect(for: annotation, imageRect: imageRect, sourceImageSize: sourceImageSize)
        }
        if annotation.tool == .step {
            return stepLayout(
                for: annotation,
                number: 1,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ).bounds
        }
        let width = displayLineWidth(for: annotation, imageRect: imageRect, sourceImageSize: sourceImageSize)
        let points: [CGPoint]
        if annotation.tool == .pen || (annotation.tool == .pixelate && annotation.mosaicMode == .brush) {
            points = annotation.points.isEmpty ? [annotation.start, annotation.end] : annotation.points
        } else {
            points = [annotation.start, annotation.end]
        }
        guard let first = points.first else { return .zero }
        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        let rect = CGRect(
            x: imageRect.minX + minimumX * imageRect.width,
            y: imageRect.minY + minimumY * imageRect.height,
            width: (maximumX - minimumX) * imageRect.width,
            height: (maximumY - minimumY) * imageRect.height
        )
        let expansion = annotation.tool == .arrow ? max(8, width * 4) : max(3, width / 2)
        return rect.insetBy(dx: -expansion, dy: -expansion)
    }

    /// Returns the annotation's unexpanded geometry bounds. `displayBounds` includes
    /// stroke padding for hit testing, while resizing must operate on the actual
    /// coordinates so a thicker stroke does not unexpectedly move the handles.
    static func resizeBounds(
        for annotation: Annotation,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> CGRect {
        if annotation.tool == .text {
            return textRect(for: annotation, imageRect: imageRect, sourceImageSize: sourceImageSize)
        }
        if annotation.tool == .step {
            return displayBounds(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            )
        }
        if annotation.tool == .watermark {
            return imageRect
        }
        let points: [CGPoint]
        if annotation.tool == .pen || (annotation.tool == .pixelate && annotation.mosaicMode == .brush) {
            points = annotation.points.isEmpty ? [annotation.start, annotation.end] : annotation.points
        } else {
            points = [annotation.start, annotation.end]
        }
        guard let first = points.first else { return .zero }
        var minimumX = first.x
        var maximumX = first.x
        var minimumY = first.y
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(
            x: imageRect.minX + minimumX * imageRect.width,
            y: imageRect.minY + minimumY * imageRect.height,
            width: max(1, (maximumX - minimumX) * imageRect.width),
            height: max(1, (maximumY - minimumY) * imageRect.height)
        )
    }

    static func resized(
        _ annotation: Annotation,
        handle: AnnotationResizeHandle,
        by translation: CGSize,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
        if annotation.tool == .arrow, (handle == .start || handle == .end) {
            var result = annotation
            let endpoint = handle == .start ? annotation.start : annotation.end
            let point = CGPoint(
                x: imageRect.minX + endpoint.x * imageRect.width + translation.width,
                y: imageRect.minY + endpoint.y * imageRect.height + translation.height
            )
            let normalized = normalizedPoint(point, imageRect: imageRect, editingBounds: editingBounds)
            if handle == .start {
                result.start = normalized
            } else {
                result.end = normalized
            }
            return result
        }
        if annotation.tool == .step {
            return resizedStep(
                annotation,
                handle: handle,
                by: translation,
                imageRect: imageRect,
                editingBounds: editingBounds,
                sourceImageSize: sourceImageSize
            )
        }
        let originalRect = resizeBounds(
            for: annotation,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        guard originalRect.width > 0, originalRect.height > 0 else { return annotation }
        let minimum = CGSize(width: max(18, imageRect.width * 0.01), height: max(18, imageRect.height * 0.01))
        let targetRect = resizedRect(
            originalRect,
            handle: handle,
            by: translation,
            within: editingBounds,
            minimumSize: minimum
        )
        let scaleX = targetRect.width / originalRect.width
        let scaleY = targetRect.height / originalRect.height
        let uniformScale = max(0.05, sqrt(max(0.0025, scaleX * scaleY)))

        func mapped(_ point: CGPoint) -> CGPoint {
            let x = targetRect.minX + (point.x * imageRect.width + imageRect.minX - originalRect.minX) * scaleX
            let y = targetRect.minY + (point.y * imageRect.height + imageRect.minY - originalRect.minY) * scaleY
            return normalizedPoint(CGPoint(x: x, y: y), imageRect: imageRect, editingBounds: editingBounds)
        }

        var result = annotation
        result.start = mapped(annotation.start)
        result.end = mapped(annotation.end)
        result.points = annotation.points.map(mapped)
        if annotation.tool == .text {
            result.lineWidth = max(1, annotation.lineWidth * uniformScale)
        } else if annotation.tool == .watermark {
            result.lineWidth = max(1, annotation.lineWidth * uniformScale)
        }
        return result
    }

    private static func resizedStep(
        _ annotation: Annotation,
        handle: AnnotationResizeHandle,
        by translation: CGSize,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
        let layout = stepLayout(
            for: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize,
            usesCustomBadgePosition: false
        )
        let rect = layout.bounds
        let minimumWidth = layout.badgeRect.width
            + StepAnnotationLayout.badgeGap
            + StepAnnotationLayout.minimumCardWidth
        var minX = rect.minX
        var maxX = rect.maxX
        if handle == .left {
            minX = min(
                max(editingBounds.minX, rect.minX + translation.width),
                rect.maxX - minimumWidth
            )
        } else if handle == .right {
            maxX = max(
                min(editingBounds.maxX, rect.maxX + translation.width),
                rect.minX + minimumWidth
            )
        }
        var result = annotation
        let badgeOnTrailingEdge = annotation.end.x < annotation.start.x
        let normalizedMinX = normalizedPoint(
            CGPoint(x: minX, y: rect.minY),
            imageRect: imageRect,
            editingBounds: editingBounds
        ).x
        let normalizedMaxX = normalizedPoint(
            CGPoint(x: maxX, y: rect.maxY),
            imageRect: imageRect,
            editingBounds: editingBounds
        ).x
        result.start.x = badgeOnTrailingEdge ? normalizedMaxX : normalizedMinX
        result.end.x = badgeOnTrailingEdge ? normalizedMinX : normalizedMaxX
        return fittedStepAnnotation(
            result,
            number: 1,
            imageRect: imageRect,
            editingBounds: editingBounds,
            sourceImageSize: sourceImageSize
        )
    }

    static func resizeHandlePosition(
        _ handle: AnnotationResizeHandle,
        for annotation: Annotation,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> CGPoint {
        if annotation.tool == .arrow {
            let point = handle == .start ? annotation.start : annotation.end
            return CGPoint(
                x: imageRect.minX + point.x * imageRect.width,
                y: imageRect.minY + point.y * imageRect.height
            )
        }
        if annotation.tool == .step {
            let rect = stepLayout(
                for: annotation,
                number: 1,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ).cardRect.insetBy(dx: -5, dy: -4)
            return handle.position(in: rect)
        }
        let rect = displayBounds(
            for: annotation,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        ).insetBy(dx: -5, dy: -4)
        return handle.position(in: rect)
    }

    private static func resizedRect(
        _ rect: CGRect,
        handle: AnnotationResizeHandle,
        by translation: CGSize,
        within bounds: CGRect,
        minimumSize: CGSize
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        if handle.movesMinX { minX = min(max(bounds.minX, rect.minX + translation.width), rect.maxX - minimumSize.width) }
        if handle.movesMaxX { maxX = max(min(bounds.maxX, rect.maxX + translation.width), rect.minX + minimumSize.width) }
        if handle.movesMinY { minY = min(max(bounds.minY, rect.minY + translation.height), rect.maxY - minimumSize.height) }
        if handle.movesMaxY { maxY = max(min(bounds.maxY, rect.maxY + translation.height), rect.minY + minimumSize.height) }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    static func hitAnnotation(
        at point: CGPoint,
        annotations: [Annotation],
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation? {
        guard editingBounds.contains(point) else { return nil }
        return annotations.reversed().first { annotation in
            hitsVisibleBoundary(
                annotation,
                at: point,
                stepNumber: StepAnnotationNumbering.number(for: annotation.id, in: annotations),
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            )
        }
    }

    private static func hitsVisibleBoundary(
        _ annotation: Annotation,
        at point: CGPoint,
        stepNumber: Int?,
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> Bool {
        guard annotation.tool != .watermark else { return false }
        let lineWidth = displayLineWidth(
            for: annotation,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        let strokeTolerance = hitTolerance + lineWidth / 2

        switch annotation.tool {
        case .rectangle:
            return distanceToRectangleBoundary(point, rect: geometryRect(annotation, imageRect: imageRect)) <= strokeTolerance
        case .highlight:
            let rect = geometryRect(annotation, imageRect: imageRect)
                .insetBy(dx: -hitTolerance, dy: -hitTolerance)
            switch annotation.highlightShape {
            case .rectangle: return rect.contains(point)
            case .ellipse: return ellipseContains(point, rect: rect)
            }
        case .ellipse:
            return distanceToEllipseBoundary(point, rect: geometryRect(annotation, imageRect: imageRect)) <= strokeTolerance
        case .text:
            return textRect(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ).insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point)
        case .step:
            let layout = stepLayout(
                for: annotation,
                number: stepNumber ?? 1,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            )
            return layout.cardRect.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point)
                || layout.badgeRect.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point)
                || distance(
                    point,
                    toPolyline: [layout.connectorStart, layout.connectorEnd]
                ) <= strokeTolerance
        case .line:
            return distance(point, toPolyline: screenPoints(for: annotation, imageRect: imageRect)) <= strokeTolerance
        case .arrow:
            let endpoints = screenPoints(for: annotation, imageRect: imageRect)
            guard endpoints.count >= 2 else { return false }
            let start = endpoints[0]
            let end = endpoints[1]
            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLength = max(10, lineWidth * 4)
            let left = CGPoint(
                x: end.x - headLength * cos(angle - .pi / 6),
                y: end.y - headLength * sin(angle - .pi / 6)
            )
            let right = CGPoint(
                x: end.x - headLength * cos(angle + .pi / 6),
                y: end.y - headLength * sin(angle + .pi / 6)
            )
            return min(
                distance(point, toPolyline: [start, end]),
                distance(point, toPolyline: [left, end, right])
            ) <= strokeTolerance
        case .pen:
            return distance(point, toPolyline: screenPoints(for: annotation, imageRect: imageRect)) <= strokeTolerance
        case .pixelate:
            // Mosaic is paint-like and intentionally cannot be selected or moved.
            return false
        case .crop, .select, .watermark:
            return false
        }
    }

    private static func geometryRect(_ annotation: Annotation, imageRect: CGRect) -> CGRect {
        let start = screenPoint(annotation.start, imageRect: imageRect)
        let end = screenPoint(annotation.end, imageRect: imageRect)
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private static func screenPoints(for annotation: Annotation, imageRect: CGRect) -> [CGPoint] {
        let normalizedPoints = annotation.points.isEmpty
            ? [annotation.start, annotation.end]
            : annotation.points
        return normalizedPoints.map { screenPoint($0, imageRect: imageRect) }
    }

    private static func screenPoint(_ point: CGPoint, imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
        )
    }

    private static func distanceToRectangleBoundary(_ point: CGPoint, rect: CGRect) -> CGFloat {
        let rect = rect.standardized
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY)
        ]
        return distance(point, toPolyline: corners)
    }

    private static func distanceToEllipseBoundary(_ point: CGPoint, rect: CGRect) -> CGFloat {
        let rect = rect.standardized
        guard rect.width > 0, rect.height > 0 else {
            return hypot(point.x - rect.midX, point.y - rect.midY)
        }
        let pointCount = 96
        let points = (0...pointCount).map { index in
            let angle = CGFloat(index) / CGFloat(pointCount) * 2 * .pi
            return CGPoint(
                x: rect.midX + cos(angle) * rect.width / 2,
                y: rect.midY + sin(angle) * rect.height / 2
            )
        }
        return distance(point, toPolyline: points)
    }

    private static func ellipseContains(_ point: CGPoint, rect: CGRect) -> Bool {
        let rect = rect.standardized
        guard rect.width > 0, rect.height > 0 else { return false }
        let normalizedX = (point.x - rect.midX) / (rect.width / 2)
        let normalizedY = (point.y - rect.midY) / (rect.height / 2)
        return normalizedX * normalizedX + normalizedY * normalizedY <= 1
    }

    private static func distance(_ point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var minimum = CGFloat.greatestFiniteMagnitude
        for (start, end) in zip(points, points.dropFirst()) {
            minimum = min(minimum, distance(point, toSegmentFrom: start, to: end))
        }
        return minimum
    }

    private static func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let nearest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    static func moved(
        _ annotation: Annotation,
        by translation: CGSize,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
        // Keep this invariant even if a caller already holds a mosaic selection.
        guard annotation.tool != .pixelate else { return annotation }
        if annotation.tool == .text {
            return movedText(
                annotation,
                by: translation,
                imageRect: imageRect,
                editingBounds: editingBounds,
                sourceImageSize: sourceImageSize
            )
        }
        let bounds = displayBounds(for: annotation, imageRect: imageRect, sourceImageSize: sourceImageSize)
        let lowerX = editingBounds.minX - bounds.minX
        let upperX = editingBounds.maxX - bounds.maxX
        let lowerY = editingBounds.minY - bounds.minY
        let upperY = editingBounds.maxY - bounds.maxY
        let dx = lowerX <= upperX ? min(upperX, max(lowerX, translation.width)) : 0
        let dy = lowerY <= upperY ? min(upperY, max(lowerY, translation.height)) : 0
        let delta = CGPoint(
            x: dx / max(1, imageRect.width),
            y: dy / max(1, imageRect.height)
        )
        var result = annotation
        result.start = shifted(annotation.start, by: delta)
        result.end = shifted(annotation.end, by: delta)
        result.points = annotation.points.map { shifted($0, by: delta) }
        result.stepBadgePosition = annotation.stepBadgePosition.map { shifted($0, by: delta) }
        return result
    }

    static func movedStepBadge(
        _ annotation: Annotation,
        by translation: CGSize,
        number: Int,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
        guard annotation.tool == .step else { return annotation }
        let layout = stepLayout(
            for: annotation,
            number: number,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        let halfWidth = layout.badgeRect.width / 2
        let halfHeight = layout.badgeRect.height / 2
        let minimumX = editingBounds.minX + halfWidth
        let maximumX = editingBounds.maxX - halfWidth
        let minimumY = editingBounds.minY + halfHeight
        let maximumY = editingBounds.maxY - halfHeight
        let center = CGPoint(
            x: minimumX <= maximumX
                ? min(maximumX, max(minimumX, layout.badgeRect.midX + translation.width))
                : editingBounds.midX,
            y: minimumY <= maximumY
                ? min(maximumY, max(minimumY, layout.badgeRect.midY + translation.height))
                : editingBounds.midY
        )
        var result = annotation
        result.stepBadgePosition = normalizedPoint(
            center,
            imageRect: imageRect,
            editingBounds: editingBounds
        )
        return result
    }

    static func movedStepCard(
        _ annotation: Annotation,
        by translation: CGSize,
        number: Int,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
        guard annotation.tool == .step else { return annotation }
        let layout = stepLayout(
            for: annotation,
            number: number,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        let lowerX = editingBounds.minX - layout.cardRect.minX
        let upperX = editingBounds.maxX - layout.cardRect.maxX
        let lowerY = editingBounds.minY - layout.cardRect.minY
        let upperY = editingBounds.maxY - layout.cardRect.maxY
        let dx = lowerX <= upperX ? min(upperX, max(lowerX, translation.width)) : 0
        let dy = lowerY <= upperY ? min(upperY, max(lowerY, translation.height)) : 0
        let delta = CGPoint(
            x: dx / max(1, imageRect.width),
            y: dy / max(1, imageRect.height)
        )

        var result = annotation
        if result.stepBadgePosition == nil {
            result.stepBadgePosition = normalizedPoint(
                CGPoint(x: layout.badgeRect.midX, y: layout.badgeRect.midY),
                imageRect: imageRect,
                editingBounds: editingBounds
            )
        }
        result.start = shifted(annotation.start, by: delta)
        result.end = shifted(annotation.end, by: delta)
        // Keep the badge fixed so the card moves independently and the
        // connector can choose the new facing edge.
        return result
    }

    static func normalizedPoint(_ point: CGPoint, imageRect: CGRect, editingBounds: CGRect) -> CGPoint {
        let bounded = CGPoint(
            x: min(editingBounds.maxX, max(editingBounds.minX, point.x)),
            y: min(editingBounds.maxY, max(editingBounds.minY, point.y))
        )
        return CGPoint(
            x: min(1, max(0, (bounded.x - imageRect.minX) / max(1, imageRect.width))),
            y: min(1, max(0, (bounded.y - imageRect.minY) / max(1, imageRect.height)))
        )
    }

    static func movedText(
        _ annotation: Annotation,
        by translation: CGSize,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
        let originalRect = textRect(
            for: annotation,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        let maximumX = max(editingBounds.minX, editingBounds.maxX - originalRect.width)
        let maximumY = max(editingBounds.minY, editingBounds.maxY - originalRect.height)
        let movedOrigin = CGPoint(
            x: min(maximumX, max(editingBounds.minX, originalRect.minX + translation.width)),
            y: min(maximumY, max(editingBounds.minY, originalRect.minY + translation.height))
        )
        let delta = CGPoint(
            x: (movedOrigin.x - originalRect.minX) / max(1, imageRect.width),
            y: (movedOrigin.y - originalRect.minY) / max(1, imageRect.height)
        )
        var result = annotation
        result.start = shifted(annotation.start, by: delta)
        result.end = shifted(annotation.end, by: delta)
        result.points = annotation.points.map { shifted($0, by: delta) }
        return result
    }

    private static func shifted(_ point: CGPoint, by delta: CGPoint) -> CGPoint {
        CGPoint(
            x: min(1, max(0, point.x + delta.x)),
            y: min(1, max(0, point.y + delta.y))
        )
    }
}

enum AnnotationResizeHandle: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end

    var id: String { rawValue }
    var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesMinY: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesMaxY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .start, .end: CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}

struct AnnotationResizeHandleView: View {
    let handle: AnnotationResizeHandle
    let position: CGPoint
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    var body: some View {
        Group {
            if handle == .start || handle == .end {
                Circle()
                    .fill(HelloXTheme.accent)
                    .overlay(Circle().stroke(HelloXTheme.prominentForeground, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(HelloXTheme.accent)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(HelloXTheme.prominentForeground, lineWidth: 1))
            }
        }
            .frame(width: 10, height: 10)
            .contentShape(Rectangle().inset(by: -5))
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChanged($0.translation) }
                    .onEnded { _ in onEnded() }
            )
            .accessibilityLabel("调整标记大小")
    }
}

/// Shared AppKit bridge for pointer-location hit feedback and window-scoped
/// annotation deletion. The view is transparent to mouse hit testing, so the
/// SwiftUI canvas gestures and controls continue to receive their events.
struct AnnotationInteractionEventView: NSViewRepresentable {
    let hitTarget: (CGPoint) -> UUID?
    let onHoverTargetChange: (UUID?) -> Void
    let onDelete: () -> Bool

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) {
        update(nsView)
    }

    private func update(_ view: EventView) {
        view.hitTarget = hitTarget
        view.onHoverTargetChange = onHoverTargetChange
        view.onDelete = onDelete
    }

    final class EventView: NSView {
        var hitTarget: ((CGPoint) -> UUID?)?
        var onHoverTargetChange: ((UUID?) -> Void)?
        var onDelete: (() -> Bool)?

        private var keyMonitor: Any?
        private var showsMoveCursor = false

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeKeyMonitor()
            guard window != nil else { return }
            window?.acceptsMouseMovedEvents = true
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.window === self.window,
                      event.keyCode == 51 || event.keyCode == 117,
                      !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                      !(self.window?.firstResponder is NSTextView),
                      self.onDelete?() == true else { return event }
                return nil
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                owner: self
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(for: event)
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(for: event)
        }

        override func mouseDragged(with event: NSEvent) {
            updateHover(for: event)
        }

        private func updateHover(for event: NSEvent) {
            let target = hitTarget?(convert(event.locationInWindow, from: nil))
            setMoveCursor(target != nil)
            onHoverTargetChange?(target)
        }

        override func mouseExited(with event: NSEvent) {
            setMoveCursor(false)
            onHoverTargetChange?(nil)
        }

        override func cursorUpdate(with event: NSEvent) {
            (showsMoveCursor ? NSCursor.openHand : NSCursor.arrow).set()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeKeyMonitor()
                if showsMoveCursor { NSCursor.arrow.set() }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func setMoveCursor(_ value: Bool) {
            guard showsMoveCursor != value else { return }
            showsMoveCursor = value
            window?.invalidateCursorRects(for: self)
            (value ? NSCursor.openHand : NSCursor.arrow).set()
        }

        private func removeKeyMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

    }
}

final class InlineAnnotationTextBuffer {
    var text = ""
    var originalText = ""
}

struct InlineTextEditorLayout: Equatable {
    let frame: CGRect
    let contentSize: CGSize
}

enum InlineTextEditorGeometry {
    static let horizontalPadding: CGFloat = 5
    static let verticalPadding: CGFloat = 4

    static func layout(
        for annotation: Annotation,
        text: String,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> InlineTextEditorLayout {
        var liveAnnotation = annotation
        liveAnnotation.text = text
        let textRect = AnnotationEditingGeometry.textRect(
            for: liveAnnotation,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        let fontSize = max(
            AnnotationTypography.minimumFontSize,
            AnnotationEditingGeometry.displayLineWidth(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ) * 5
        )
        let desiredContentSize = CGSize(
            width: max(28, textRect.width + 2),
            height: max(fontSize + 2, textRect.height + 2)
        )
        let width = min(
            editingBounds.width,
            desiredContentSize.width + horizontalPadding * 2
        )
        let height = min(
            editingBounds.height,
            desiredContentSize.height + verticalPadding * 2
        )
        let desiredOrigin = CGPoint(
            x: textRect.minX - horizontalPadding,
            y: textRect.minY - verticalPadding
        )
        let origin = CGPoint(
            x: min(
                max(editingBounds.minX, desiredOrigin.x),
                max(editingBounds.minX, editingBounds.maxX - width)
            ),
            y: min(
                max(editingBounds.minY, desiredOrigin.y),
                max(editingBounds.minY, editingBounds.maxY - height)
            )
        )
        return InlineTextEditorLayout(
            frame: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            contentSize: CGSize(
                width: max(1, width - horizontalPadding * 2),
                height: max(1, height - verticalPadding * 2)
            )
        )
    }
}

final class AnnotationInteractionThrottle {
    private var lastTime: TimeInterval = 0
    private var lastPoint: CGPoint?

    func shouldProcess(_ point: CGPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastPoint {
            let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
            guard now - lastTime >= 1.0 / 120.0 || distance >= 3 else {
                return false
            }
        }
        // Only accepted samples advance the baseline. Updating it for rejected
        // high-frequency mouse events prevents time and distance from ever
        // accumulating, which makes slow or reversing drags appear to freeze.
        lastTime = now
        lastPoint = point
        return true
    }

    func reset() {
        lastTime = 0
        lastPoint = nil
    }
}

struct InlineAnnotationTextEditor: View {
    let annotation: Annotation
    let imageRect: CGRect
    let editingBounds: CGRect
    let sourceImageSize: CGSize
    let stepNumber: Int?
    let buffer: InlineAnnotationTextBuffer
    let onCommit: () -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(
        annotation: Annotation,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize,
        stepNumber: Int? = nil,
        buffer: InlineAnnotationTextBuffer,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.annotation = annotation
        self.imageRect = imageRect
        self.editingBounds = editingBounds
        self.sourceImageSize = sourceImageSize
        self.stepNumber = stepNumber
        self.buffer = buffer
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: buffer.text)
    }

    var body: some View {
        editorBody
            .onAppear {
                buffer.text = text
                buffer.originalText = text
            }
            .accessibilityLabel(annotation.tool == .step ? "截图步骤说明标注" : "截图多行文字标注")
    }

    @ViewBuilder
    private var editorBody: some View {
        if annotation.tool == .step {
            stepEditor
        } else {
            growingTextEditor
        }
    }

    private var growingTextEditor: some View {
        let layout = InlineTextEditorGeometry.layout(
            for: annotation,
            text: text,
            imageRect: imageRect,
            editingBounds: editingBounds,
            sourceImageSize: sourceImageSize
        )
        let fontSize = max(
            AnnotationTypography.minimumFontSize,
            AnnotationEditingGeometry.displayLineWidth(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ) * 5
        )
        return ZStack {
            InlineGrowingTextView(
                text: Binding(
                    get: { text },
                    set: { value in
                        text = value
                        buffer.text = value
                    }
                ),
                font: annotationFont(size: fontSize),
                color: annotationNSColor,
                wraps: false,
                contentInset: .zero,
                onCommit: onCommit,
                onCancel: {
                    buffer.text = buffer.originalText
                    onCancel()
                }
            )
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
            .clipped()

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    HelloXTheme.accent,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                )
                .allowsHitTesting(false)
        }
        .frame(width: layout.frame.width, height: layout.frame.height)
        .background(Color.clear)
        .position(x: layout.frame.midX, y: layout.frame.midY)
    }

    private var stepEditor: some View {
        let number = stepNumber ?? 1
        let layout = AnnotationEditingGeometry.stepLayout(
            for: annotation,
            text: text,
            number: number,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        let fontSize = max(
            AnnotationTypography.minimumFontSize,
            AnnotationEditingGeometry.displayLineWidth(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ) * 5
        )
        let localBadge = layout.badgeRect.offsetBy(dx: -layout.bounds.minX, dy: -layout.bounds.minY)
        let localCard = layout.cardRect.offsetBy(dx: -layout.bounds.minX, dy: -layout.bounds.minY)
        let localConnectorStart = CGPoint(
            x: layout.connectorStart.x - layout.bounds.minX,
            y: layout.connectorStart.y - layout.bounds.minY
        )
        let localConnectorEnd = CGPoint(
            x: layout.connectorEnd.x - layout.bounds.minX,
            y: layout.connectorEnd.y - layout.bounds.minY
        )
        let stepColor = Color(
            red: annotation.color.red,
            green: annotation.color.green,
            blue: annotation.color.blue,
            opacity: annotation.color.alpha
        )
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: localConnectorStart)
                path.addLine(to: localConnectorEnd)
            }
            .stroke(stepColor, style: StrokeStyle(lineWidth: max(1.5, fontSize / 5), lineCap: .round))
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: localBadge.height / 2, style: .continuous)
                .fill(stepColor)
                .frame(width: localBadge.width, height: localBadge.height)
                .position(x: localBadge.midX, y: localBadge.midY)
                .allowsHitTesting(false)
            Text(String(number))
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(.white)
                .position(x: localBadge.midX, y: localBadge.midY)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: StepAnnotationLayout.cornerRadius, style: .continuous)
                .fill(Color(red: 0.38, green: 0.38, blue: 0.38).opacity(0.92))
                .frame(width: localCard.width, height: localCard.height)
                .position(x: localCard.midX, y: localCard.midY)
                .allowsHitTesting(false)
            InlineGrowingTextView(
                text: Binding(
                    get: { text },
                    set: { value in
                        text = value
                        buffer.text = value
                    }
                ),
                font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                color: .white,
                wraps: true,
                contentInset: NSSize(
                    width: StepAnnotationLayout.horizontalPadding,
                    height: StepAnnotationLayout.verticalPadding
                ),
                onCommit: onCommit,
                onCancel: {
                    buffer.text = buffer.originalText
                    onCancel()
                }
            )
            .frame(width: localCard.width, height: localCard.height)
            .position(x: localCard.midX, y: localCard.midY)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    HelloXTheme.accent,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                )
                .allowsHitTesting(false)
        }
        .frame(width: layout.bounds.width, height: layout.bounds.height)
        .position(x: layout.bounds.midX, y: layout.bounds.midY)
    }

    private func annotationFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard annotation.tool == .watermark else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private var annotationNSColor: NSColor {
        if annotation.tool == .step { return .white }
        let color = annotation.color.nsColor
        return annotation.tool == .watermark
            ? color.withAlphaComponent(annotation.color.alpha * 0.38)
            : color
    }
}

/// A borderless NSTextView whose text container never wraps automatically. SwiftUI owns the
/// measured frame, while AppKit provides reliable multiline input, focus and command handling.
enum InlineTextInputPolicy {
    static func shouldApplyBindingText(
        currentText: String,
        bindingText: String,
        hasMarkedText: Bool
    ) -> Bool {
        !hasMarkedText && currentText != bindingText
    }

    static func handlesCancelCommand(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }
}

enum AnnotationInlineEditingPolicy {
    static func beginsImmediatelyAfterCreation(for tool: AnnotationTool) -> Bool {
        tool == .text
    }

    static func removesEmptyAnnotation(
        tool: AnnotationTool,
        whenStartingStepBadgeDrag _: Bool
    ) -> Bool {
        // A step's numbered badge remains useful even when its optional
        // description is empty. Leaving the inline editor must therefore not
        // turn a normal blur into an implicit delete.
        tool != .step
    }

    static func showsResizeHandles(for tool: AnnotationTool, isEditingText: Bool) -> Bool {
        tool != .watermark && (!isEditingText || tool == .step)
    }
}

private struct InlineGrowingTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let color: NSColor
    let wraps: Bool
    let contentInset: NSSize
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = !wraps
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 100_000, height: 100_000)
        textView.textContainerInset = contentInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: wraps ? max(1, textView.bounds.width) : 100_000,
            height: 100_000
        )
        textView.textStorage?.delegate = context.coordinator
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.textContainerInset = contentInset
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        if wraps {
            textView.textContainer?.containerSize = NSSize(
                width: max(1, textView.bounds.width),
                height: 100_000
            )
        }
        if InlineTextInputPolicy.shouldApplyBindingText(
            currentText: textView.string,
            bindingText: text,
            hasMarkedText: textView.hasMarkedText()
        ) {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: InlineGrowingTextView
        private var suppressEndCommit = false

        init(parent: InlineGrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        @MainActor
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            parent.text = textStorage.string
        }

        func textDidEndEditing(_ notification: Notification) {
            if suppressEndCommit {
                suppressEndCommit = false
            } else {
                parent.onCommit()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard InlineTextInputPolicy.handlesCancelCommand(
                    hasMarkedText: textView.hasMarkedText()
                ) else { return false }
                suppressEndCommit = true
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                suppressEndCommit = true
                parent.onCommit()
                return true
            }
            return false
        }
    }
}

@MainActor
final class MosaicPreviewCache {
    private var images: [Int: CGImage] = [:]
    private var recency: [Int] = []

    func image(for baseImage: CGImage, blockSize: CGFloat) -> CGImage? {
        let key = max(2, Int(blockSize.rounded()))
        if let cached = images[key] {
            touch(key)
            return cached
        }
        let generated = AnnotationRenderer.pixelatedImage(baseImage: baseImage, blockSize: CGFloat(key))
        if let generated {
            images[key] = generated
            touch(key)
            while recency.count > 3, let oldest = recency.first {
                recency.removeFirst()
                images.removeValue(forKey: oldest)
            }
        }
        return generated
    }

    private func touch(_ key: Int) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

enum AnnotationCanvasDrawing {
    @MainActor
    static func draw(
        _ annotation: Annotation,
        stepNumber: Int? = nil,
        image: CGImage,
        imageRect: CGRect,
        mosaicCache: MosaicPreviewCache,
        context: inout GraphicsContext
    ) {
        let denormalize: (CGPoint) -> CGPoint = { point in
            CGPoint(x: imageRect.minX + point.x * imageRect.width, y: imageRect.minY + point.y * imageRect.height)
        }
        let start = denormalize(annotation.start)
        let end = denormalize(annotation.end)
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        let swiftColor = Color(red: annotation.color.red, green: annotation.color.green, blue: annotation.color.blue, opacity: annotation.color.alpha)
        let width = max(1, annotation.lineWidth * imageRect.width / CGFloat(max(1, image.width)))
        var path = Path()
        var arrowHead: Path?
        switch annotation.tool {
        case .rectangle: path.addRect(rect)
        case .highlight:
            path.addRect(imageRect)
            switch annotation.highlightShape {
            case .rectangle: path.addRect(rect)
            case .ellipse: path.addEllipse(in: rect)
            }
            context.fill(
                path,
                with: .color(.black.opacity(AnnotationHighlightStyle.dimOpacity)),
                style: FillStyle(eoFill: true)
            )
            if annotation.highlightShowsBorder {
                var border = Path()
                switch annotation.highlightShape {
                case .rectangle: border.addRect(rect)
                case .ellipse: border.addEllipse(in: rect)
                }
                context.stroke(
                    border,
                    with: .color(swiftColor),
                    style: StrokeStyle(lineWidth: width, lineCap: .square, lineJoin: .miter)
                )
            }
            return
        case .ellipse: path.addEllipse(in: rect)
        case .line:
            path.move(to: start); path.addLine(to: end)
        case .arrow:
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(14, width * 4.5)
            let halfWidth = max(6, width * 2)
            let distance = hypot(end.x - start.x, end.y - start.y)
            let shaftInset = min(length * 0.72, distance * 0.9)
            let shaftEnd = distance > 0
                ? CGPoint(
                    x: end.x - shaftInset * (end.x - start.x) / distance,
                    y: end.y - shaftInset * (end.y - start.y) / distance
                )
                : end
            path.move(to: start)
            path.addLine(to: shaftEnd)
            let base = CGPoint(
                x: end.x - length * cos(angle),
                y: end.y - length * sin(angle)
            )
            let left = CGPoint(
                x: base.x - halfWidth * sin(angle),
                y: base.y + halfWidth * cos(angle)
            )
            let right = CGPoint(
                x: base.x + halfWidth * sin(angle),
                y: base.y - halfWidth * cos(angle)
            )
            var head = Path()
            head.move(to: end)
            head.addLine(to: left)
            head.addLine(to: right)
            head.closeSubpath()
            arrowHead = head
        case .pen:
            guard let first = annotation.points.first else { return }
            path.move(to: denormalize(first))
            for point in annotation.points.dropFirst() { path.addLine(to: denormalize(point)) }
        case .step:
            let layout = AnnotationEditingGeometry.stepLayout(
                for: annotation,
                number: stepNumber ?? 1,
                imageRect: imageRect,
                sourceImageSize: CGSize(width: image.width, height: image.height)
            )
            var connector = Path()
            connector.move(to: layout.connectorStart)
            connector.addLine(to: layout.connectorEnd)
            context.stroke(
                connector,
                with: .color(swiftColor),
                style: StrokeStyle(lineWidth: max(1.5, width), lineCap: .round)
            )
            let badge = Path(
                roundedRect: layout.badgeRect,
                cornerRadius: layout.badgeRect.height / 2
            )
            context.fill(badge, with: .color(swiftColor))
            context.fill(
                Path(
                    roundedRect: layout.cardRect,
                    cornerRadius: StepAnnotationLayout.cornerRadius
                ),
                with: .color(Color(red: 0.38, green: 0.38, blue: 0.38).opacity(0.92))
            )
            let fontSize = max(AnnotationTypography.minimumFontSize, width * 5)
            context.draw(
                Text(String(stepNumber ?? 1))
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.white),
                at: CGPoint(x: layout.badgeRect.midX, y: layout.badgeRect.midY),
                anchor: .center
            )
            if !annotation.text.isEmpty {
                context.draw(
                    Text(annotation.text)
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(.white),
                    in: layout.textRect
                )
            }
            return
        case .text, .watermark:
            guard !annotation.text.isEmpty else { return }
            var label = Text(annotation.text).font(.system(size: max(AnnotationTypography.minimumFontSize, width * 5)))
            if annotation.tool == .watermark {
                label = label.italic().foregroundColor(swiftColor.opacity(0.38))
                drawTiledWatermark(
                    label,
                    text: annotation.text,
                    fontSize: max(AnnotationTypography.minimumFontSize, width * 5),
                    watermarkSpacing: max(
                        4,
                        annotation.watermarkSpacing * imageRect.width / CGFloat(max(1, image.width))
                    ),
                    in: imageRect,
                    context: &context
                )
                return
            } else {
                label = label.foregroundColor(swiftColor)
            }
            context.draw(label, at: start, anchor: .topLeading)
            return
        case .pixelate:
            guard let pixelated = mosaicCache.image(for: image, blockSize: annotation.mosaicBlockSize) else { return }
            let mask: Path
            if annotation.mosaicMode == .brush {
                let points = annotation.points.isEmpty ? [annotation.start, annotation.end] : annotation.points
                guard let first = points.first else { return }
                if points.count == 1 || annotation.start == annotation.end {
                    let center = denormalize(first)
                    mask = Path(ellipseIn: CGRect(x: center.x - width / 2, y: center.y - width / 2, width: width, height: width))
                } else {
                    var centerline = Path()
                    centerline.move(to: denormalize(first))
                    for point in points.dropFirst() { centerline.addLine(to: denormalize(point)) }
                    mask = centerline.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            } else {
                mask = Path(rect)
            }
            context.drawLayer { layer in
                layer.clip(to: mask)
                layer.draw(Image(decorative: pixelated, scale: 1), in: imageRect)
            }
            return
        case .crop, .select: return
        }
        context.stroke(path, with: .color(swiftColor), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        if let arrowHead {
            context.fill(arrowHead, with: .color(swiftColor))
        }
    }

    private static func drawTiledWatermark(
        _ label: Text,
        text: String,
        fontSize: CGFloat,
        watermarkSpacing: CGFloat,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        let measured = (text as NSString).size(
            withAttributes: [.font: NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: fontSize, weight: .medium),
                toHaveTrait: .italicFontMask
            )]
        )
        let spacing = WatermarkLayout.tileSpacing(
            textSize: measured,
            fontSize: fontSize,
            spacing: watermarkSpacing
        )
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            var row = 0
            var y = rect.minY - spacing.height / 2
            while y < rect.maxY + spacing.height / 2 {
                var x = row.isMultiple(of: 2)
                    ? rect.minX
                    : rect.minX - spacing.width / 2
                while x < rect.maxX + spacing.width / 2 {
                    layer.drawLayer { tile in
                        tile.translateBy(x: x, y: y)
                        tile.rotate(by: .degrees(WatermarkLayout.rotationDegrees))
                        tile.draw(label, at: .zero, anchor: .center)
                    }
                    x += spacing.width
                }
                row += 1
                y += spacing.height
            }
        }
    }
}

struct AnnotationPropertyBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isWatermarkTextFocused: Bool
    let tool: AnnotationTool
    @Binding var color: Color
    @Binding var lineWidth: Double
    @Binding var mosaicMode: MosaicMode
    @Binding var mosaicBlockSize: Double
    @Binding var text: String
    @Binding var watermarkSpacing: Double
    @Binding var highlightShowsBorder: Bool
    @Binding var highlightShape: AnnotationHighlightShape

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if tool == .pixelate {
                    propertyLabel("模式")
                    HXSegmentedControl("马赛克模式", selection: $mosaicMode, options: [
                        HXSegment(.brush, "画笔"),
                        HXSegment(.rectangle, "矩形")
                    ])
                    .help("选择马赛克模式")
                }

                if tool == .watermark {
                    propertyLabel("内容")
                    TextField("输入水印文字", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius))
                        .frame(width: 138)
                        .fixedSize(horizontal: true, vertical: false)
                        .focused($isWatermarkTextFocused)
                        .onAppear {
                            DispatchQueue.main.async { isWatermarkTextFocused = true }
                        }
                }

                if tool == .highlight {
                    propertyLabel("形状")
                    HXSegmentedControl("高亮形状", selection: $highlightShape, options:
                        AnnotationHighlightShape.allCases.map { HXSegment($0, $0.localizedName) }
                    )
                    .help("选择聚光灯高亮区域的形状")

                    Toggle("边框", isOn: $highlightShowsBorder)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("为聚光灯高亮区域添加边框")
                }

                if tool != .highlight || highlightShowsBorder {
                    propertyLabel(tool.isTextual ? "字号" : tool == .pixelate && mosaicMode == .brush ? "笔刷" : tool == .pixelate ? "颗粒" : "粗细")

                    Slider(
                        value: sliderBinding,
                        in: tool.isTextual ? 10...96 : 1...32,
                        step: 1
                    )
                        .frame(width: 96)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("\(Int(sliderBinding.wrappedValue.rounded()))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                        .frame(width: 20, alignment: .trailing)
                }

                if tool == .watermark {
                    propertyLabel("间距")
                    Slider(value: $watermarkSpacing, in: 12...160, step: 2)
                        .frame(width: 78)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("\(Int(watermarkSpacing.rounded()))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                        .frame(width: 26, alignment: .trailing)
                }

                if tool == .pixelate && mosaicMode == .brush {
                    propertyLabel("颗粒")
                    Slider(value: $mosaicBlockSize, in: 2...32, step: 1)
                        .frame(width: 72)
                        .fixedSize(horizontal: true, vertical: false)
                } else if tool == .watermark {
                    HStack(spacing: 2) {
                        ForEach(AnnotationPalette.watermarkColors) { item in
                            paletteButton(item)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                } else if tool == .highlight {
                    if highlightShowsBorder {
                        HStack(spacing: 2) {
                            ForEach(AnnotationPalette.colors) { item in
                                paletteButton(item)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                } else if tool != .pixelate {
                    HStack(spacing: 2) {
                        ForEach(AnnotationPalette.colors) { item in
                            paletteButton(item)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 8)
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollContentBackground(.hidden)
        .seamlessScrollChrome()
        .frame(height: 36)
        .background(
            HelloXTheme.cardGradient(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(HelloXTheme.border(for: colorScheme), lineWidth: 1)
        }
    }

    private var sliderBinding: Binding<Double> {
        if tool == .pixelate && mosaicMode == .rectangle { return $mosaicBlockSize }
        if tool.isTextual {
            return Binding(
                get: { max(Double(AnnotationTypography.minimumFontSize), lineWidth * 5) },
                set: { lineWidth = $0 / 5 }
            )
        }
        return $lineWidth
    }

    private func propertyLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
    }

    private func isSelected(_ candidate: Color) -> Bool {
        guard let current = NSColor(color).usingColorSpace(.deviceRGB),
              let comparison = NSColor(candidate).usingColorSpace(.deviceRGB) else { return false }
        return abs(current.redComponent - comparison.redComponent) < 0.015
            && abs(current.greenComponent - comparison.greenComponent) < 0.015
            && abs(current.blueComponent - comparison.blueComponent) < 0.015
    }

    private func paletteButton(_ item: AnnotationPalette.Item) -> some View {
        Button {
            color = item.color
        } label: {
            Circle()
                .fill(item.color)
                .frame(width: 14, height: 14)
                .shadow(color: Color.black.opacity(item.id == "white" ? 0.12 : 0), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
                .frame(width: 24, height: 24)
                .background(
                    isSelected(item.color)
                        ? HelloXTheme.selectedBackground(for: colorScheme)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(item.name)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected(item.color) ? .isSelected : [])
    }
}

enum AnnotationPropertyBarLayout {
    static let toolbarButtonSize: CGFloat = 30
    static let toolbarButtonSpacing: CGFloat = 4

    static func propertyContentWidth(for tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .watermark: 710
        case .highlight: 680
        default: 626
        }
    }
}

enum AnnotationPalette {
    struct Item: Identifiable {
        let id: String
        let name: String
        let color: Color
    }

    static let colors: [Item] = [
        Item(id: "red", name: "红色", color: Color(red: 0.94, green: 0.27, blue: 0.27)),
        Item(id: "orange", name: "橙色", color: Color(red: 0.98, green: 0.45, blue: 0.09)),
        Item(id: "yellow", name: "黄色", color: Color(red: 0.92, green: 0.70, blue: 0.03)),
        Item(id: "green", name: "绿色", color: Color(red: 0.13, green: 0.77, blue: 0.37)),
        Item(id: "cyan", name: "青色", color: Color(red: 0.02, green: 0.71, blue: 0.83)),
        Item(id: "blue", name: "蓝色", color: Color(red: 0.23, green: 0.51, blue: 0.96)),
        Item(id: "purple", name: "紫色", color: Color(red: 0.55, green: 0.36, blue: 0.96)),
        Item(id: "black", name: "黑色", color: Color(red: 0.07, green: 0.09, blue: 0.15)),
        Item(id: "white", name: "白色", color: .white)
    ]

    static let watermarkColors: [Item] = [
        Item(id: "black", name: "黑色", color: Color(red: 0.07, green: 0.09, blue: 0.15)),
        Item(id: "white", name: "白色", color: .white),
        Item(id: "red", name: "红色", color: Color(red: 0.94, green: 0.27, blue: 0.27)),
        Item(id: "blue", name: "蓝色", color: Color(red: 0.23, green: 0.51, blue: 0.96)),
        Item(id: "gray", name: "灰色", color: Color(red: 0.42, green: 0.47, blue: 0.55))
    ]
}
