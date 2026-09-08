import AppKit
import HelloXCore
import SwiftUI

private struct EditorScrollWheelZoomView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollWheelView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaX
                guard delta != 0 else { return event }
                self.onScroll?(CGFloat(delta) * (event.hasPreciseScrollingDeltas ? 1 : 8))
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removeMonitor() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

struct EditorCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    let image: CGImage
    let annotations: [Annotation]
    let ocrBlocks: [RecognizedTextBlock]
    let draft: Annotation?
    let cropSelection: CGRect?
    let tool: AnnotationTool
    let color: RGBAColor
    let lineWidth: Double
    let mosaicMode: MosaicMode
    let mosaicBlockSize: Double
    let highlightShowsBorder: Bool
    let highlightShape: AnnotationHighlightShape
    let textValue: String
    let displayScale: CGFloat
    @Binding var fitScale: CGFloat
    @Binding var isFitMode: Bool
    @Binding var selectedAnnotationID: UUID?
    @Binding var selectedAnnotationDraft: Annotation?
    @Binding var isEditingText: Bool
    @Binding var zoomScale: CGFloat
    let inlineTextBuffer: InlineAnnotationTextBuffer
    let onDraft: (Annotation?) -> Void
    let onCommit: (Annotation) -> Void
    let onUpdate: (Annotation) -> Void
    let onTextCommit: (Annotation) -> Void
    let onDelete: (UUID) -> Void

    @State private var dragStart: CGPoint?
    @State private var penPoints: [CGPoint] = []
    @State private var originalSelectedAnnotation: Annotation?
    @State private var resizeOriginalAnnotation: Annotation?
    @State private var didMoveSelectedText = false
    @State private var editsSelectedStepTextOnRelease = false
    @State private var isDraggingStepBadge = false
    @State private var isDraggingStepCard = false
    @State private var hoveredAnnotationID: UUID?
    @State private var isSelectionInteraction = false
    @State private var mosaicCache = MosaicPreviewCache()
    @State private var interactionThrottle = AnnotationInteractionThrottle()
    @State private var magnificationStartScale: CGFloat?
    @State private var didInitializeFit = false
    @State private var cropInteraction: EditorCropGeometry.Interaction?

    var body: some View {
        GeometryReader { proxy in
            let fit = EditorZoomGeometry.fitScale(
                pixelSize: sourceImageSize,
                container: proxy.size,
                displayScale: displayScale
            )
            let scaledSize = EditorZoomGeometry.displaySize(
                pixelSize: sourceImageSize,
                zoomScale: zoomScale,
                displayScale: displayScale
            )
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                canvasSurface
                    .frame(width: scaledSize.width, height: scaledSize.height)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollContentBackground(.hidden)
            .seamlessScrollChrome()
            .background(HelloXTheme.controlBackground(for: colorScheme))
            .simultaneousGesture(magnificationGesture)
            .onAppear {
                fitScale = fit
                if !didInitializeFit {
                    zoomScale = fit
                    isFitMode = true
                    didInitializeFit = true
                }
            }
            .onChange(of: fit) { _, value in
                fitScale = value
                if isFitMode { zoomScale = value }
            }
        }
        .onChange(of: tool) { _, newTool in
            if cropInteraction != nil {
                cropInteraction = nil
                onDraft(nil)
            }
            guard newTool == .pixelate else { return }
            _ = mosaicCache.image(for: image, blockSize: mosaicBlockSize)
        }
        .onChange(of: mosaicBlockSize) { _, value in
            guard tool == .pixelate else { return }
            _ = mosaicCache.image(for: image, blockSize: value)
        }
    }

    private var canvasSurface: some View {
        GeometryReader { proxy in
            let logicalSize = EditorZoomGeometry.logicalImageSize(
                pixelSize: sourceImageSize,
                displayScale: displayScale
            )
            let imageRect = aspectFitRect(imageSize: logicalSize, container: proxy.size)
            let physicalScale = imageRect.width * displayScale / max(1, CGFloat(image.width))
            ZStack {
                HelloXTheme.controlBackground(for: colorScheme)
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(abs(physicalScale - 1) < 0.02 ? .none : .high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .overlay(Rectangle().strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 6, y: 2)
                    .position(x: imageRect.midX, y: imageRect.midY)
                Canvas { context, _ in
                    context.clip(to: Path(imageRect))
                    var stepNumber = 0
                    for annotation in annotations {
                        if annotation.tool == .step { stepNumber += 1 }
                        guard annotation.id != selectedAnnotationID else { continue }
                        draw(
                            annotation,
                            stepNumber: annotation.tool == .step ? stepNumber : nil,
                            in: imageRect,
                            context: &context
                        )
                    }
                    for block in ocrBlocks {
                        let visionRect = CGRect(
                            x: block.boundingBox.minX,
                            y: 1 - block.boundingBox.maxY,
                            width: block.boundingBox.width,
                            height: block.boundingBox.height
                        )
                        let rect = denormalize(visionRect, in: imageRect)
                        context.fill(Path(rect), with: .color(.yellow.opacity(0.12)))
                        context.stroke(Path(rect), with: .color(.yellow.opacity(0.85)), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
                .drawingGroup(opaque: false, colorMode: .linear)
                Canvas { context, _ in
                    context.clip(to: Path(imageRect))
                    if let draft { draw(draft, stepNumber: nil, in: imageRect, context: &context) }
                    if let selectedAnnotationDraft,
                       !(isEditingText && selectedAnnotationDraft.tool.isTextual) {
                        draw(
                            selectedAnnotationDraft,
                            stepNumber: StepAnnotationNumbering.number(
                                for: selectedAnnotationDraft.id,
                                in: annotations
                            ),
                            in: imageRect,
                            context: &context
                        )
                    }
                }
                .allowsHitTesting(false)
                cropOverlay(in: imageRect)
                if tool != .crop, let selectedAnnotationDraft,
                   !(isEditingText && selectedAnnotationDraft.tool.isTextual) {
                    let rect = AnnotationEditingGeometry.displayBounds(
                        for: selectedAnnotationDraft,
                        imageRect: imageRect,
                        sourceImageSize: sourceImageSize
                    ).insetBy(dx: -5, dy: -4)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            HelloXTheme.accent,
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                EditorScrollWheelZoomView { delta in
                    isFitMode = false
                    zoomScale = EditorZoomGeometry.clamped(
                        zoomScale * CGFloat(pow(1.08, Double(delta)))
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                AnnotationInteractionEventView(
                    hitTarget: { point in
                        guard tool != .watermark, tool != .pixelate, tool != .crop, !isEditingText else { return nil }
                        return hitAnnotation(at: point, imageRect: imageRect)?.id
                    },
                    onHoverTargetChange: { hoveredAnnotationID = $0 },
                    onDelete: deleteSelectedAnnotation
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if tool == .crop {
                            updateCropDrag(value, imageRect: imageRect)
                            return
                        }
                        guard imageRect.contains(value.startLocation) else { return }
                        guard tool != .watermark else { return }
                        if isEditingText {
                            let startsStepBadgeDrag = selectedAnnotationDraft.map {
                                AnnotationEditingGeometry.isStepBadge(
                                    at: value.startLocation,
                                    annotation: $0,
                                    number: StepAnnotationNumbering.number(
                                        for: $0.id,
                                        in: annotations
                                    ) ?? 1,
                                    imageRect: imageRect,
                                    sourceImageSize: sourceImageSize
                                )
                            } ?? false
                            finishInlineTextEditing(
                                in: imageRect,
                                keepsSelection: startsStepBadgeDrag,
                                whenStartingStepBadgeDrag: startsStepBadgeDrag
                            )
                            if startsStepBadgeDrag, let selectedAnnotationDraft {
                                originalSelectedAnnotation = selectedAnnotationDraft
                                isDraggingStepBadge = true
                                isDraggingStepCard = false
                                didMoveSelectedText = false
                                editsSelectedStepTextOnRelease = false
                                isSelectionInteraction = true
                                updateSelectionDrag(value, imageRect: imageRect)
                            }
                            return
                        }
                        guard interactionThrottle.shouldProcess(value.location) else { return }
                        if dragStart == nil, originalSelectedAnnotation == nil, !isSelectionInteraction {
                            let hit = hitAnnotation(at: value.startLocation, imageRect: imageRect)
                            if hoveredAnnotationID != hit?.id { hoveredAnnotationID = hit?.id }
                            if tool == .select || (tool != .pixelate && hit != nil) {
                                isSelectionInteraction = true
                            } else {
                                selectedAnnotationID = nil
                                selectedAnnotationDraft = nil
                            }
                        }
                        if isSelectionInteraction {
                            updateSelectionDrag(value, imageRect: imageRect)
                            return
                        }
                        let start = normalize(value.startLocation, in: imageRect)
                        let end = normalize(value.location, in: imageRect)
                        if dragStart == nil { dragStart = start; penPoints = [start] }
                        if tool == .step {
                            onDraft(nil)
                            return
                        }
                        let isFreehand = tool == .pen || (tool == .pixelate && mosaicMode == .brush)
                        if isFreehand, shouldAppendPenPoint(end, to: penPoints, imageRect: imageRect) { penPoints.append(end) }
                        let annotation = Annotation(
                            tool: tool,
                            start: start,
                            end: end,
                            points: isFreehand ? penPoints : [],
                            text: textValue,
                            color: color,
                            lineWidth: lineWidth,
                            mosaicMode: mosaicMode,
                            mosaicBlockSize: mosaicBlockSize,
                            highlightShowsBorder: highlightShowsBorder,
                            highlightShape: highlightShape
                        )
                        onDraft(annotation)
                    }
                    .onEnded { value in
                        if tool == .crop {
                            finishCropDrag(value, imageRect: imageRect)
                            return
                        }
                        interactionThrottle.reset()
                        guard tool != .watermark else { return }
                        if isSelectionInteraction {
                            finishSelectionDrag()
                            isSelectionInteraction = false
                            return
                        }
                        defer { dragStart = nil; penPoints.removeAll(); onDraft(nil) }
                        guard let start = dragStart else { return }
                        let end = normalize(value.location, in: imageRect)
                        let isFreehand = tool == .pen || (tool == .pixelate && mosaicMode == .brush)
                        let annotation: Annotation
                        if tool == .step {
                            annotation = AnnotationEditingGeometry.makeStepAnnotation(
                                at: value.startLocation,
                                number: annotations.filter { $0.tool == .step }.count + 1,
                                imageRect: imageRect,
                                editingBounds: imageRect,
                                sourceImageSize: sourceImageSize,
                                color: color,
                                lineWidth: lineWidth
                            )
                        } else {
                            annotation = Annotation(
                                tool: tool,
                                start: start,
                                end: end,
                                points: isFreehand ? penPoints + [end] : [],
                                text: textValue,
                                color: color,
                                lineWidth: lineWidth,
                                mosaicMode: mosaicMode,
                                mosaicBlockSize: mosaicBlockSize,
                                highlightShowsBorder: highlightShowsBorder,
                                highlightShape: highlightShape
                            )
                        }
                        if annotation.normalizedRect.width > 0.002 || annotation.normalizedRect.height > 0.002 || tool == .text || tool == .step || (tool == .pixelate && mosaicMode == .brush) {
                            onCommit(annotation)
                        }
                    })
                inlineTextEditor(in: imageRect)
                annotationResizeHandles(in: imageRect)
            }
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                isFitMode = false
                if magnificationStartScale == nil {
                    magnificationStartScale = zoomScale
                }
                zoomScale = EditorZoomGeometry.clamped(
                    (magnificationStartScale ?? zoomScale) * magnification
                )
            }
            .onEnded { _ in
                magnificationStartScale = nil
            }
    }

    private var sourceImageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    private func cropOverlay(in imageRect: CGRect) -> some View {
        Canvas { context, _ in
            guard let selection = EditorCropGeometry.visibleSelection(draft: draft, selection: cropSelection) else { return }
            let rect = EditorCropGeometry.displayRect(selection, in: imageRect)
            let inset = min(0.75, min(rect.width, rect.height) / 2)
            let outline = Path(rect.insetBy(dx: inset, dy: inset))
            context.stroke(outline, with: .color(.white), lineWidth: 1.5)
            context.stroke(outline, with: .color(.black), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            guard tool == .crop else { return }
            for handle in SelectionHandle.allCases {
                let point = EditorCropGeometry.handlePosition(handle, selection: selection, imageRect: imageRect)
                let size = EditorCropGeometry.handleSize
                let handleRect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                let path = Path(roundedRect: handleRect, cornerRadius: 1)
                context.fill(path, with: .color(HelloXTheme.accentBlue))
                context.stroke(path, with: .color(.white), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func updateCropDrag(_ value: DragGesture.Value, imageRect: CGRect) {
        if cropInteraction == nil {
            guard let interaction = EditorCropGeometry.interaction(
                at: value.startLocation, selection: cropSelection, imageRect: imageRect
            ) else { return }
            if isEditingText {
                finishInlineTextEditing(in: imageRect)
            } else if let selectedAnnotationDraft {
                onUpdate(selectedAnnotationDraft)
            }
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
            hoveredAnnotationID = nil
            originalSelectedAnnotation = nil
            resizeOriginalAnnotation = nil
            isSelectionInteraction = false
            cropInteraction = interaction
        }
        guard let cropInteraction else { return }
        let rect = EditorCropGeometry.updatedSelection(
            for: cropInteraction,
            start: value.startLocation,
            end: value.location,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        onDraft(cropAnnotation(for: rect))
    }

    private func finishCropDrag(_ value: DragGesture.Value, imageRect: CGRect) {
        defer {
            cropInteraction = nil
            dragStart = nil
            penPoints.removeAll()
            interactionThrottle.reset()
            onDraft(nil)
        }
        guard let cropInteraction else { return }
        let rect = EditorCropGeometry.updatedSelection(
            for: cropInteraction,
            start: value.startLocation,
            end: value.location,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        )
        if EditorCropGeometry.isUsable(rect, sourceImageSize: sourceImageSize) {
            onCommit(cropAnnotation(for: rect))
        }
    }

    private func cropAnnotation(for rect: CGRect) -> Annotation {
        Annotation(tool: .crop, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY))
    }

    private func updateSelectionDrag(_ value: DragGesture.Value, imageRect: CGRect) {
        if originalSelectedAnnotation == nil {
            if let existingDraft = selectedAnnotationDraft {
                onUpdate(existingDraft)
            }
            guard let hit = AnnotationEditingGeometry.hitAnnotation(
                at: value.startLocation,
                annotations: annotations,
                imageRect: imageRect,
                editingBounds: imageRect,
                sourceImageSize: sourceImageSize
            ) else {
                selectedAnnotationID = nil
                selectedAnnotationDraft = nil
                return
            }
            selectedAnnotationID = hit.id
            selectedAnnotationDraft = hit
            originalSelectedAnnotation = hit
            didMoveSelectedText = false
            inlineTextBuffer.text = hit.text
            let stepNumber = StepAnnotationNumbering.number(for: hit.id, in: annotations) ?? 1
            isDraggingStepBadge = hit.tool == .step
                && AnnotationEditingGeometry.isStepBadge(
                    at: value.startLocation,
                    annotation: hit,
                    number: stepNumber,
                    imageRect: imageRect,
                    sourceImageSize: sourceImageSize
                )
            isDraggingStepCard = hit.tool == .step
                && !isDraggingStepBadge
                && AnnotationEditingGeometry.isStepTextInput(
                    at: value.startLocation,
                    annotation: hit,
                    number: stepNumber,
                    imageRect: imageRect,
                    sourceImageSize: sourceImageSize
                )
            editsSelectedStepTextOnRelease = isDraggingStepCard
        }

        guard let originalSelectedAnnotation else { return }
        didMoveSelectedText = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
        if isDraggingStepBadge {
            selectedAnnotationDraft = AnnotationEditingGeometry.movedStepBadge(
                originalSelectedAnnotation,
                by: value.translation,
                number: StepAnnotationNumbering.number(for: originalSelectedAnnotation.id, in: annotations) ?? 1,
                imageRect: imageRect,
                editingBounds: imageRect,
                sourceImageSize: sourceImageSize
            )
        } else if isDraggingStepCard {
            selectedAnnotationDraft = AnnotationEditingGeometry.movedStepCard(
                originalSelectedAnnotation,
                by: value.translation,
                number: StepAnnotationNumbering.number(for: originalSelectedAnnotation.id, in: annotations) ?? 1,
                imageRect: imageRect,
                editingBounds: imageRect,
                sourceImageSize: sourceImageSize
            )
        } else {
            selectedAnnotationDraft = AnnotationEditingGeometry.moved(
                originalSelectedAnnotation,
                by: value.translation,
                imageRect: imageRect,
                editingBounds: imageRect,
                sourceImageSize: sourceImageSize
            )
        }
    }

    private func finishSelectionDrag() {
        let shouldEditInline = originalSelectedAnnotation != nil && !didMoveSelectedText
        let shouldEditStepText = shouldEditInline && editsSelectedStepTextOnRelease
        if let selectedAnnotationDraft, originalSelectedAnnotation != nil {
            onUpdate(selectedAnnotationDraft)
        }
        originalSelectedAnnotation = nil
        didMoveSelectedText = false
        editsSelectedStepTextOnRelease = false
        isDraggingStepBadge = false
        isDraggingStepCard = false
        if shouldEditInline, selectedAnnotationDraft?.tool == .text {
            isEditingText = true
        } else if shouldEditStepText, selectedAnnotationDraft?.tool == .step {
            isEditingText = true
        }
    }

    @ViewBuilder
    private func annotationResizeHandles(in imageRect: CGRect) -> some View {
        if tool != .crop, let annotation = selectedAnnotationDraft,
           AnnotationInlineEditingPolicy.showsResizeHandles(
               for: annotation.tool,
               isEditingText: isEditingText
           ) {
            ForEach(AnnotationEditingGeometry.resizeHandles(for: annotation)) { handle in
                AnnotationResizeHandleView(
                    handle: handle,
                    position: AnnotationEditingGeometry.resizeHandlePosition(
                        handle,
                        for: annotation,
                        imageRect: imageRect,
                        sourceImageSize: sourceImageSize
                    ),
                    onChanged: { translation in
                        if resizeOriginalAnnotation == nil { resizeOriginalAnnotation = annotation }
                        guard let original = resizeOriginalAnnotation else { return }
                        selectedAnnotationDraft = AnnotationEditingGeometry.resized(
                            original,
                            handle: handle,
                            by: translation,
                            imageRect: imageRect,
                            editingBounds: imageRect,
                            sourceImageSize: sourceImageSize
                        )
                    },
                    onEnded: {
                        if let selectedAnnotationDraft, resizeOriginalAnnotation != nil {
                            onUpdate(selectedAnnotationDraft)
                        }
                        resizeOriginalAnnotation = nil
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func inlineTextEditor(in imageRect: CGRect) -> some View {
        if isEditingText,
           let annotation = selectedAnnotationDraft,
           annotation.tool == .text || annotation.tool == .step {
            InlineAnnotationTextEditor(
                annotation: annotation,
                imageRect: imageRect,
                editingBounds: imageRect,
                sourceImageSize: sourceImageSize,
                stepNumber: StepAnnotationNumbering.number(for: annotation.id, in: annotations),
                buffer: inlineTextBuffer,
                onCommit: { finishInlineTextEditing(in: imageRect) },
                onCancel: cancelInlineTextEditing
            )
            .id(annotation.id)
        }
    }

    private func finishInlineTextEditing(
        in imageRect: CGRect,
        keepsSelection: Bool = false,
        whenStartingStepBadgeDrag: Bool = false
    ) {
        guard isEditingText else { return }
        if var annotation = selectedAnnotationDraft {
            let value = inlineTextBuffer.text
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if AnnotationInlineEditingPolicy.removesEmptyAnnotation(
                    tool: annotation.tool,
                    whenStartingStepBadgeDrag: whenStartingStepBadgeDrag
                ) {
                    onDelete(annotation.id)
                    selectedAnnotationID = nil
                    selectedAnnotationDraft = nil
                } else {
                    annotation.text = ""
                    selectedAnnotationDraft = annotation
                    onTextCommit(annotation)
                }
                isEditingText = false
                return
            }
            annotation.text = value
            if annotation.tool == .step {
                annotation = AnnotationEditingGeometry.fittedStepAnnotation(
                    annotation,
                    number: StepAnnotationNumbering.number(for: annotation.id, in: annotations) ?? 1,
                    imageRect: imageRect,
                    editingBounds: imageRect,
                    sourceImageSize: sourceImageSize
                )
            }
            annotation = AnnotationEditingGeometry.moved(
                annotation,
                by: .zero,
                imageRect: imageRect,
                editingBounds: imageRect,
                sourceImageSize: sourceImageSize
            )
            selectedAnnotationDraft = annotation
            onTextCommit(annotation)
        }
        isEditingText = false
        if !keepsSelection {
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
        }
    }

    private func cancelInlineTextEditing() {
        if inlineTextBuffer.originalText.isEmpty, let id = selectedAnnotationDraft?.id {
            onDelete(id)
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
        }
        isEditingText = false
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
    }

    private func hitAnnotation(at point: CGPoint, imageRect: CGRect) -> Annotation? {
        AnnotationEditingGeometry.hitAnnotation(
            at: point,
            annotations: annotations,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceImageSize
        )
    }

    private func deleteSelectedAnnotation() -> Bool {
        guard !isEditingText, let id = selectedAnnotationID else { return false }
        onDelete(id)
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        originalSelectedAnnotation = nil
        resizeOriginalAnnotation = nil
        isSelectionInteraction = false
        editsSelectedStepTextOnRelease = false
        isDraggingStepBadge = false
        isDraggingStepCard = false
        return true
    }

    private func draw(
        _ annotation: Annotation,
        stepNumber: Int?,
        in imageRect: CGRect,
        context: inout GraphicsContext
    ) {
        AnnotationCanvasDrawing.draw(
            annotation,
            stepNumber: stepNumber,
            image: image,
            imageRect: imageRect,
            mosaicCache: mosaicCache,
            context: &context
        )
    }

    private func aspectFitRect(imageSize: CGSize, container: CGSize) -> CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        AnnotationEditingGeometry.normalizedPoint(point, imageRect: rect, editingBounds: rect)
    }

    private func shouldAppendPenPoint(_ point: CGPoint, to points: [CGPoint], imageRect: CGRect) -> Bool {
        guard let previous = points.last else { return true }
        return hypot(
            (point.x - previous.x) * imageRect.width,
            (point.y - previous.y) * imageRect.height
        ) >= 1.5
    }

    private func denormalize(_ normalized: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + normalized.minX * rect.width, y: rect.minY + normalized.minY * rect.height, width: normalized.width * rect.width, height: normalized.height * rect.height)
    }
}
