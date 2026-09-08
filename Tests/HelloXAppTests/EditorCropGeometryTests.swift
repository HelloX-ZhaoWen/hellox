import CoreGraphics
import Testing
@testable import HelloXApp
@testable import HelloXCore

@Suite("Editor crop geometry")
struct EditorCropGeometryTests {
    private let imageRect = CGRect(x: 40, y: 30, width: 400, height: 200)
    private let sourceImageSize = CGSize(width: 1600, height: 800)

    @Test func liveDraftTakesPrecedenceOverCommittedCrop() {
        let previous = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let draft = Annotation(tool: .crop, start: CGPoint(x: 0.8, y: 0.7), end: CGPoint(x: 0.2, y: 0.3))
        #expect(EditorCropGeometry.visibleSelection(draft: draft, selection: previous) == draft.normalizedRect)
        #expect(EditorCropGeometry.visibleSelection(draft: nil, selection: previous) == previous)
        let pen = Annotation(tool: .pen, start: .zero, end: CGPoint(x: 1, y: 1))
        #expect(EditorCropGeometry.visibleSelection(draft: pen, selection: previous) == previous)
    }

    @Test func reverseDragNormalizesAndClampsAtImageBoundary() {
        let rect = EditorCropGeometry.normalizedRect(
            from: CGPoint(x: 360, y: 190), to: CGPoint(x: -100, y: -50), imageRect: imageRect
        )
        expectRect(rect, CGRect(x: 0, y: 0, width: 0.8, height: 0.8))
        expectRect(
            EditorCropGeometry.displayRect(rect, in: imageRect),
            CGRect(x: 40, y: 30, width: 320, height: 160)
        )
    }

    @Test func dragMappingFollowsDisplayedImageSizeAndOffset() {
        let original = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4)
        let moved = EditorCropGeometry.updatedSelection(
            for: .move(original), start: CGPoint(x: 140, y: 90), end: CGPoint(x: 180, y: 70),
            imageRect: imageRect, sourceImageSize: sourceImageSize
        )
        expectRect(moved, CGRect(x: 0.3, y: 0.1, width: 0.3, height: 0.4))
        let zoomedImageRect = CGRect(x: 15, y: 20, width: 800, height: 400)
        let zoomed = EditorCropGeometry.updatedSelection(
            for: .move(original), start: CGPoint(x: 215, y: 140), end: CGPoint(x: 295, y: 100),
            imageRect: zoomedImageRect, sourceImageSize: sourceImageSize
        )
        expectRect(zoomed, moved)
    }

    @Test func movingKeepsWholeCropWithinImage() {
        let moved = EditorCropGeometry.updatedSelection(
            for: .move(CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)),
            start: .zero, end: CGPoint(x: 1000, y: -1000),
            imageRect: imageRect, sourceImageSize: sourceImageSize
        )
        expectRect(moved, CGRect(x: 0.6, y: 0, width: 0.4, height: 0.5))
    }

    @Test func resizingClampsOuterEdgesAndKeepsOppositeCorner() {
        let original = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let expanded = EditorCropGeometry.updatedSelection(
            for: .resize(original, .topLeft), start: .zero, end: CGPoint(x: -1000, y: -1000),
            imageRect: imageRect, sourceImageSize: sourceImageSize
        )
        expectRect(expanded, CGRect(x: 0, y: 0, width: 0.6, height: 0.8))
        let collapsed = EditorCropGeometry.updatedSelection(
            for: .resize(original, .bottomRight), start: .zero, end: CGPoint(x: -1000, y: -1000),
            imageRect: imageRect, sourceImageSize: sourceImageSize
        )
        expectRect(collapsed, CGRect(x: 0.2, y: 0.3, width: 1 / 1600, height: 1 / 800))
        #expect(EditorCropGeometry.isUsable(collapsed, sourceImageSize: sourceImageSize))
    }

    @Test func hitTestingDistinguishesHandlesMoveAndNewSelection() {
        let selection = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        for handle in SelectionHandle.allCases {
            let position = EditorCropGeometry.handlePosition(handle, selection: selection, imageRect: imageRect)
            guard case .resize(let original, let actual)? = EditorCropGeometry.interaction(
                at: position, selection: selection, imageRect: imageRect
            ) else {
                Issue.record("Expected resize at \(handle)")
                continue
            }
            #expect(actual == handle)
            #expect(original == selection)
        }
        guard case .move? = EditorCropGeometry.interaction(
            at: CGPoint(x: 240, y: 130), selection: selection, imageRect: imageRect
        ) else {
            Issue.record("Expected move inside crop")
            return
        }
        guard case .create? = EditorCropGeometry.interaction(
            at: CGPoint(x: 50, y: 40), selection: selection, imageRect: imageRect
        ) else {
            Issue.record("Expected new crop outside selection")
            return
        }
        #expect(EditorCropGeometry.interaction(at: .zero, selection: selection, imageRect: imageRect) == nil)
    }

    @Test func edgeHandlesStayVisibleAndZeroAreaCropCannotCommit() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        for handle in SelectionHandle.allCases {
            let position = EditorCropGeometry.handlePosition(handle, selection: full, imageRect: imageRect)
            let halfSize = EditorCropGeometry.handleSize / 2
            #expect(position.x - halfSize >= imageRect.minX)
            #expect(position.x + halfSize <= imageRect.maxX)
            #expect(position.y - halfSize >= imageRect.minY)
            #expect(position.y + halfSize <= imageRect.maxY)
        }
        #expect(!EditorCropGeometry.isUsable(CGRect(x: 0, y: 0, width: 0, height: 1), sourceImageSize: sourceImageSize))
        #expect(!EditorCropGeometry.isUsable(CGRect(x: 0, y: 0, width: 1, height: 0), sourceImageSize: sourceImageSize))
    }

    private func expectRect(_ actual: CGRect, _ expected: CGRect) {
        #expect(abs(actual.minX - expected.minX) < 0.000_001)
        #expect(abs(actual.minY - expected.minY) < 0.000_001)
        #expect(abs(actual.width - expected.width) < 0.000_001)
        #expect(abs(actual.height - expected.height) < 0.000_001)
    }
}
