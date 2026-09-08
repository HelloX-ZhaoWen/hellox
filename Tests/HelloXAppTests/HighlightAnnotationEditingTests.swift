import CoreGraphics
import Testing
@testable import HelloXApp
@testable import HelloXCore

@Suite("Highlight annotation editing")
struct HighlightAnnotationEditingTests {
    @Test func highlightCanBeSelectedFromItsFilledInterior() {
        let annotation = Annotation(
            tool: .highlight,
            start: CGPoint(x: 0.20, y: 0.20),
            end: CGPoint(x: 0.60, y: 0.60),
            color: AnnotationHighlightStyle.defaultColor
        )
        let imageRect = CGRect(x: 0, y: 0, width: 400, height: 200)

        let hit = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: 160, y: 80),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: CGSize(width: 800, height: 400)
        )
        let miss = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: 320, y: 160),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: CGSize(width: 800, height: 400)
        )

        #expect(hit?.id == annotation.id)
        #expect(miss == nil)
        #expect(!annotation.highlightShowsBorder)
        #expect(AnnotationEditingGeometry.resizeHandles(for: annotation).count == 8)
    }

    @Test func ellipseHitTestingFollowsTheVisibleShape() {
        let annotation = Annotation(
            tool: .highlight,
            start: CGPoint(x: 0.20, y: 0.20),
            end: CGPoint(x: 0.80, y: 0.80),
            highlightShape: .ellipse
        )
        let imageRect = CGRect(x: 0, y: 0, width: 400, height: 200)

        let center = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: 200, y: 100),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: CGSize(width: 800, height: 400)
        )
        let corner = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: 85, y: 45),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: CGSize(width: 800, height: 400)
        )

        #expect(center?.id == annotation.id)
        #expect(corner == nil)
    }
}
