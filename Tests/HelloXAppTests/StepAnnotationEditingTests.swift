import CoreGraphics
import Foundation
import Testing
@testable import HelloXApp
@testable import HelloXCore

@Suite("Step annotation editing")
struct StepAnnotationEditingTests {
    private let imageRect = CGRect(x: 20, y: 30, width: 800, height: 500)
    private let sourceSize = CGSize(width: 1_600, height: 1_000)

    @Test func clickFactoryCreatesDefaultWidthInsideTheImage() {
        let annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: 200, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        let layout = AnnotationEditingGeometry.stepLayout(
            for: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(annotation.tool == .step)
        #expect(abs(layout.cardRect.width - StepAnnotationLayout.defaultCardWidth) < 0.5)
        #expect(imageRect.contains(layout.bounds))
    }

    @Test func rightEdgeClickKeepsTheBadgeAtTheRightAndOpensTheCardLeftward() {
        let annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: imageRect.maxX - 2, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        let layout = AnnotationEditingGeometry.stepLayout(
            for: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(annotation.start.x > annotation.end.x)
        #expect(abs(layout.badgeRect.maxX - imageRect.maxX) < 0.5)
        #expect(layout.cardRect.maxX < layout.badgeRect.minX)
        #expect(imageRect.contains(layout.bounds))
    }

    @Test func resizingARightEdgeStepKeepsItsBadgeOnTheRight() {
        let annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: imageRect.maxX - 2, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        let resized = AnnotationEditingGeometry.resized(
            annotation,
            handle: .left,
            by: CGSize(width: 40, height: 0),
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )
        let layout = AnnotationEditingGeometry.stepLayout(
            for: resized,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(resized.start.x > resized.end.x)
        #expect(layout.cardRect.maxX < layout.badgeRect.minX)
        #expect(imageRect.contains(layout.bounds))
    }

    @Test func stepHitTestingIncludesTheFilledCardInterior() {
        var annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: 200, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        annotation.text = "步骤说明"
        let layout = AnnotationEditingGeometry.stepLayout(
            for: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        let hit = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: layout.cardRect.midX, y: layout.cardRect.midY),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(hit?.id == annotation.id)
    }

    @Test func onlyHorizontalResizeHandlesAreExposed() {
        let annotation = Annotation(
            tool: .step,
            start: CGPoint(x: 0.1, y: 0.1),
            end: CGPoint(x: 0.5, y: 0.3),
            text: "步骤"
        )

        #expect(AnnotationEditingGeometry.resizeHandles(for: annotation) == [.left, .right])
    }

    @Test func badgeCanMoveIndependentlyAcrossTheCard() {
        let annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: 200, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        let originalLayout = AnnotationEditingGeometry.stepLayout(
            for: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )
        let targetCenter = CGPoint(
            x: originalLayout.cardRect.maxX + 60,
            y: originalLayout.cardRect.maxY + 40
        )

        let moved = AnnotationEditingGeometry.movedStepBadge(
            annotation,
            by: CGSize(
                width: targetCenter.x - originalLayout.badgeRect.midX,
                height: targetCenter.y - originalLayout.badgeRect.midY
            ),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )
        let movedLayout = AnnotationEditingGeometry.stepLayout(
            for: moved,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(abs(movedLayout.badgeRect.midX - targetCenter.x) < 0.5)
        #expect(abs(movedLayout.badgeRect.midY - targetCenter.y) < 0.5)
        #expect(movedLayout.badgeRect.minX > movedLayout.cardRect.maxX)
        #expect(movedLayout.cardRect == originalLayout.cardRect)
        #expect(movedLayout.connectorStart == CGPoint(
            x: movedLayout.badgeRect.midX,
            y: movedLayout.badgeRect.midY
        ))
        #expect(abs(movedLayout.connectorEnd.y - movedLayout.cardRect.maxY) < 0.5)
        #expect(movedLayout.connectorEnd.x >= movedLayout.cardRect.minX)
        #expect(movedLayout.connectorEnd.x <= movedLayout.cardRect.maxX)
    }

    @Test func cardCanMoveIndependentlyFromTheBadge() {
        var annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: 200, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        annotation.stepBadgePosition = nil
        let originalLayout = AnnotationEditingGeometry.stepLayout(
            for: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        let moved = AnnotationEditingGeometry.movedStepCard(
            annotation,
            by: CGSize(width: 80, height: 100),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )
        let movedLayout = AnnotationEditingGeometry.stepLayout(
            for: moved,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(movedLayout.badgeRect == originalLayout.badgeRect)
        #expect(abs(movedLayout.cardRect.minX - originalLayout.cardRect.minX - 80) < 0.5)
        #expect(abs(movedLayout.cardRect.minY - originalLayout.cardRect.minY - 100) < 0.5)
        #expect(imageRect.contains(movedLayout.cardRect))
    }

    @Test func movingAWholeStepAlsoMovesItsCustomBadge() throws {
        var annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: 200, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        annotation.stepBadgePosition = CGPoint(x: 0.25, y: 0.25)

        let moved = AnnotationEditingGeometry.moved(
            annotation,
            by: CGSize(width: 40, height: 30),
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )

        let originalBadge = try #require(annotation.stepBadgePosition)
        let movedBadge = try #require(moved.stepBadgePosition)
        #expect(abs(movedBadge.x - originalBadge.x - 0.05) < 0.001)
        #expect(abs(movedBadge.y - originalBadge.y - 0.06) < 0.001)
    }

    @Test func horizontalResizeKeepsTheMinimumCardWidth() {
        let annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: 200, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        let resized = AnnotationEditingGeometry.resized(
            annotation,
            handle: .right,
            by: CGSize(width: -1_000, height: 0),
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )
        let layout = AnnotationEditingGeometry.stepLayout(
            for: resized,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(abs(layout.cardRect.width - StepAnnotationLayout.minimumCardWidth) < 0.5)
        #expect(imageRect.contains(layout.bounds))
    }

    @Test func onlyTheTextCardStartsInlineEditing() {
        var annotation = AnnotationEditingGeometry.makeStepAnnotation(
            at: CGPoint(x: 200, y: 160),
            number: 1,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize,
            color: .red,
            lineWidth: 4
        )
        annotation.text = "步骤说明"
        let layout = AnnotationEditingGeometry.stepLayout(
            for: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(!AnnotationEditingGeometry.isStepTextInput(
            at: CGPoint(x: layout.badgeRect.midX, y: layout.badgeRect.midY),
            annotation: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        ))
        #expect(AnnotationEditingGeometry.isStepBadge(
            at: CGPoint(x: layout.badgeRect.midX, y: layout.badgeRect.midY),
            annotation: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        ))
        #expect(AnnotationEditingGeometry.isStepTextInput(
            at: CGPoint(x: layout.cardRect.midX, y: layout.cardRect.midY),
            annotation: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        ))
        #expect(!AnnotationEditingGeometry.isStepBadge(
            at: CGPoint(x: layout.cardRect.midX, y: layout.cardRect.midY),
            annotation: annotation,
            number: 1,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        ))
    }

    @Test func newStepWaitsForTheTextCardBeforeEditing() {
        #expect(AnnotationInlineEditingPolicy.beginsImmediatelyAfterCreation(for: .text))
        #expect(!AnnotationInlineEditingPolicy.beginsImmediatelyAfterCreation(for: .step))
    }

    @Test func emptyStepSurvivesLeavingInlineEditing() {
        #expect(!AnnotationInlineEditingPolicy.removesEmptyAnnotation(
            tool: .step,
            whenStartingStepBadgeDrag: true
        ))
        #expect(!AnnotationInlineEditingPolicy.removesEmptyAnnotation(
            tool: .step,
            whenStartingStepBadgeDrag: false
        ))
        #expect(AnnotationInlineEditingPolicy.removesEmptyAnnotation(
            tool: .text,
            whenStartingStepBadgeDrag: false
        ))
    }

    @Test func stepResizeHandlesRemainAvailableWhileEditingSavedText() {
        #expect(AnnotationInlineEditingPolicy.showsResizeHandles(
            for: .step,
            isEditingText: true
        ))
        #expect(!AnnotationInlineEditingPolicy.showsResizeHandles(
            for: .text,
            isEditingText: true
        ))
        #expect(!AnnotationInlineEditingPolicy.showsResizeHandles(
            for: .watermark,
            isEditingText: false
        ))
    }
}

@Suite("Text annotation editing")
struct TextAnnotationEditingTests {
    @Test func textCanBeSelectedFromItsInteriorNotOnlyItsTrailingEdge() {
        let imageRect = CGRect(x: 20, y: 30, width: 800, height: 500)
        let sourceSize = CGSize(width: 1_600, height: 1_000)
        let annotation = Annotation(
            tool: .text,
            start: CGPoint(x: 0.20, y: 0.25),
            end: CGPoint(x: 0.20, y: 0.25),
            text: "点击任意文字位置都可以选中",
            color: .red,
            lineWidth: 4
        )
        let textRect = AnnotationEditingGeometry.textRect(
            for: annotation,
            imageRect: imageRect,
            sourceImageSize: sourceSize
        )

        let hit = AnnotationEditingGeometry.hitAnnotation(
            at: CGPoint(x: textRect.midX, y: textRect.midY),
            annotations: [annotation],
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceSize
        )

        #expect(hit?.id == annotation.id)
    }

    @Test func markedTextIsNotOverwrittenDuringPinyinComposition() {
        #expect(!InlineTextInputPolicy.shouldApplyBindingText(
            currentText: "拼",
            bindingText: "",
            hasMarkedText: true
        ))
        #expect(InlineTextInputPolicy.shouldApplyBindingText(
            currentText: "旧文字",
            bindingText: "新文字",
            hasMarkedText: false
        ))
        #expect(!InlineTextInputPolicy.handlesCancelCommand(hasMarkedText: true))
        #expect(InlineTextInputPolicy.handlesCancelCommand(hasMarkedText: false))
    }
}
