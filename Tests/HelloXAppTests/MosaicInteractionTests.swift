import CoreGraphics
import Testing
@testable import HelloXApp
@testable import HelloXCore

@Suite("Mosaic interaction")
struct MosaicInteractionTests {
    private let imageRect = CGRect(x: 0, y: 0, width: 800, height: 500)
    private let sourceSize = CGSize(width: 1_600, height: 1_000)

    @Test func brushMosaicCannotBeSelected() {
        let annotation = Annotation(
            tool: .pixelate,
            start: CGPoint(x: 0.2, y: 0.2),
            end: CGPoint(x: 0.4, y: 0.4),
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.4, y: 0.4)],
            lineWidth: 40,
            mosaicMode: .brush
        )

        let hit = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: 240, y: 150),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(hit == nil)
    }

    @Test func rectangularMosaicCannotBeSelected() {
        let annotation = Annotation(
            tool: .pixelate,
            start: CGPoint(x: 0.2, y: 0.2),
            end: CGPoint(x: 0.4, y: 0.4),
            mosaicMode: .rectangle
        )

        let hit = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: 160, y: 150),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(hit == nil)
    }

    @Test func mosaicCannotBeMovedDefensively() {
        let annotation = Annotation(
            tool: .pixelate,
            start: CGPoint(x: 0.2, y: 0.2),
            end: CGPoint(x: 0.4, y: 0.4),
            mosaicMode: .rectangle
        )

        let moved = AnnotationEditingGeometry.moved(
            annotation,
            by: CGSize(width: 100, height: 80),
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(moved == annotation)
    }
}
