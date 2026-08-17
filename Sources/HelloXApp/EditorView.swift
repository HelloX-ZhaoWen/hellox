import HelloXCore
import SwiftUI
@preconcurrency import Translation

private struct EditorOfflineTranslationRequest {
    let id: UUID
    let text: String
    let sourceLanguageIdentifier: String?
    let targetLanguageIdentifier: String
}

enum EditorZoomGeometry {
    static let minimumScale: CGFloat = 0.25
    static let maximumScale: CGFloat = 8

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    static func aspectFitSize(imageSize: CGSize, container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

struct EditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var document: EditorDocument
    @State private var tool: AnnotationTool = .select
    @State private var color: Color = .red
    @State private var lineWidth: Double = 4
    @State private var mosaicMode: MosaicMode = .brush
    @State private var mosaicBlockSize: Double = 10
    @State private var watermarkSpacing: Double = 48
    @State private var textValue = "文字"
    @State private var draft: Annotation?
    @State private var sourceLanguage: SupportedLanguage = .simplifiedChinese
    @State private var targetLanguage: SupportedLanguage = .english
    @State private var selectedProfileID: UUID?
    @State private var offlineTranslationConfiguration: TranslationSession.Configuration?
    @State private var offlineTranslationRequest: EditorOfflineTranslationRequest?
    @State private var selectedAnnotationID: UUID?
    @State private var selectedAnnotationDraft: Annotation?
    @State private var propertyEditRegistered = false
    @State private var isEditingText = false
    @State private var inlineTextBuffer = InlineAnnotationTextBuffer()
    @State private var zoomScale: CGFloat = 1

    init(document: EditorDocument, startsWithWatermark: Bool = false) {
        self.document = document
        _selectedProfileID = State(initialValue: document.isOfflineTranslationEnabled ? nil : (document.defaultTranslationProfileID ?? document.translationProfiles.first?.id))
        if startsWithWatermark,
           let watermark = document.annotations.last(where: { $0.tool == .watermark }) {
            _tool = State(initialValue: .watermark)
            _color = State(initialValue: Color(
                red: watermark.color.red,
                green: watermark.color.green,
                blue: watermark.color.blue,
                opacity: watermark.color.alpha
            ))
            _lineWidth = State(initialValue: watermark.lineWidth)
            _watermarkSpacing = State(initialValue: watermark.watermarkSpacing)
            _textValue = State(initialValue: watermark.text)
            _selectedAnnotationID = State(initialValue: watermark.id)
            _selectedAnnotationDraft = State(initialValue: watermark)
            _propertyEditRegistered = State(initialValue: true)
        }
    }

    var body: some View {
        ZStack {
            HelloXGlowBackground()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                toolBar
                HStack(spacing: 12) {
                EditorCanvas(
                    image: document.image,
                    annotations: document.annotations,
                    ocrBlocks: document.ocrResult?.blocks ?? [],
                    draft: draft,
                    cropSelection: document.cropSelection,
                    tool: tool,
                    color: rgbaColor,
                    lineWidth: lineWidth,
                    mosaicMode: mosaicMode,
                    mosaicBlockSize: mosaicBlockSize,
                    textValue: textValue,
                    selectedAnnotationID: $selectedAnnotationID,
                    selectedAnnotationDraft: $selectedAnnotationDraft,
                    isEditingText: $isEditingText,
                    zoomScale: $zoomScale,
                    inlineTextBuffer: inlineTextBuffer,
                    onDraft: { draft = $0 },
                    onCommit: commit,
                    onUpdate: document.update,
                    onTextCommit: persistPropertyChange,
                    onDelete: document.removeAnnotation
                )
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius).stroke(HelloXTheme.border(for: colorScheme)))
                .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 12, y: 6)

                if document.ocrResult != nil || document.isPerformingOCR || document.translatedText != nil {
                    textPanel.frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                }
                }
                .padding(12)
                statusBar
            }
        }
        .tint(HelloXTheme.accent)
        .onChange(of: selectedAnnotationID) { _ in
            propertyEditRegistered = false
        }
        .onChange(of: document.isOfflineTranslationEnabled) { enabled in
            if !enabled, selectedProfileID == nil {
                selectedProfileID = document.defaultTranslationProfileID ?? document.translationProfiles.first?.id
            }
        }
        .translationTask(offlineTranslationConfiguration) { session in
            guard let request = offlineTranslationRequest else { return }
            do {
                let availability = LanguageAvailability()
                let target = Locale.Language(identifier: request.targetLanguageIdentifier)
                let status: LanguageAvailability.Status
                if let sourceIdentifier = request.sourceLanguageIdentifier {
                    status = await availability.status(
                        from: Locale.Language(identifier: sourceIdentifier),
                        to: target
                    )
                } else {
                    status = try await availability.status(for: request.text, to: target)
                }
                guard status != .unsupported else { throw HelloXError.languageNotSupported }
                if status == .supported {
                    try await session.prepareTranslation()
                }
                let response = try await session.translate(request.text)
                try Task.checkCancellation()
                finishOfflineTranslation(requestID: request.id, text: response.targetText, errorMessage: nil)
            } catch is CancellationError {
            } catch {
                finishOfflineTranslation(
                    requestID: request.id,
                    text: nil,
                    errorMessage: TranslationWindowModel.offlineMessage(for: error)
                )
            }
        }
    }

    private var toolBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(AnnotationTool.allCases) { item in
                    HelloXIconButton(
                        icon: item.helloXIcon,
                        help: item.localizedName,
                        isSelected: tool == item,
                        size: 30,
                        iconSize: 14,
                        action: { selectTool(item) }
                    )
                }
                Spacer()
                HelloXIconButton(icon: .line, help: "缩小（⌘-）", size: 30, iconSize: 14, action: zoomOut)
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(zoomScale <= EditorZoomGeometry.minimumScale)
                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    .frame(width: 46, height: 30)
                HelloXIconButton(icon: .screen, help: "适合窗口（⌘0）", size: 30, iconSize: 14, action: resetZoom)
                    .keyboardShortcut("0", modifiers: .command)
                HelloXIconButton(icon: .add, help: "放大（⌘+）", size: 30, iconSize: 14, action: zoomIn)
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(zoomScale >= EditorZoomGeometry.maximumScale)
                HelloXIconButton(icon: .undo, help: "撤销", size: 30, iconSize: 14, action: undo)
                HelloXIconButton(icon: .redo, help: "重做", size: 30, iconSize: 14, action: redo)
                if document.isPerformingOCR {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    HelloXIconButton(icon: .textRecognition, help: "文字识别", size: 30, iconSize: 14) {
                        document.runOCR()
                    }
                }
                HelloXIconButton(icon: .copy, help: "复制", size: 30, iconSize: 14, action: copyImage)
                HelloXIconButton(icon: .save, help: "保存", role: .accent, size: 30, iconSize: 14, action: save)
            }

            if showsPropertyBar {
                HStack(spacing: 8) {
                    AnnotationPropertyBar(
                        tool: selectedAnnotationDraft?.tool ?? tool,
                        color: propertyColorBinding,
                        lineWidth: propertyLineWidthBinding,
                        mosaicMode: propertyMosaicModeBinding,
                        mosaicBlockSize: propertyMosaicBlockSizeBinding,
                        text: propertyTextBinding,
                        watermarkSpacing: propertyWatermarkSpacingBinding
                    )
                    if tool == .crop, document.cropSelection != nil {
                        HelloXIconButton(icon: .confirm, help: "应用裁剪", role: .accent) {
                            document.applyCrop()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(HelloXTheme.surface(for: colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HelloXTheme.border(for: colorScheme))
                .frame(height: 1)
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 7) {
                    HelloXIcon(icon: .textRecognition, size: 16)
                    Text("识别文字")
                }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                Spacer()
                if document.ocrResult != nil {
                    HelloXIconButton(icon: .copy, help: "复制识别文字", action: document.copyOCRText)
                }
            }
            if document.isPerformingOCR {
                ProgressView("正在识别…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(document.ocrResult?.text ?? "")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .scrollContentBackground(.hidden)
                .visibleScrollChrome()
            }
            HStack {
                HelloXLanguagePicker(
                    title: "源语言",
                    selection: $sourceLanguage,
                    includesAuto: true
                )
                HelloXIcon(icon: .arrowRight, size: 14)
                HelloXLanguagePicker(
                    title: "目标语言",
                    selection: $targetLanguage,
                    includesAuto: false
                )
            }
            Picker("翻译配置", selection: $selectedProfileID) {
                if document.isOfflineTranslationEnabled {
                    Text("离线翻译").tag(UUID?.none)
                }
                ForEach(document.translationProfiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            HStack {
                Spacer()
                if document.isPerformingTranslation {
                    ProgressView().controlSize(.small)
                } else {
                    HelloXIconButton(icon: .translation, help: "翻译全文", role: .accent) {
                        if let selectedProfileID {
                            document.translate(source: sourceLanguage, target: targetLanguage, profileID: selectedProfileID)
                        } else if document.isOfflineTranslationEnabled {
                            requestOfflineTranslation()
                        }
                    }
                    .disabled(document.ocrResult == nil)
                }
            }
            if let translation = document.translatedText {
                HStack {
                    HStack(spacing: 7) {
                        HelloXIcon(icon: .translation, size: 16)
                        Text("译文")
                    }
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    HelloXIconButton(icon: .copy, help: "复制译文", action: document.copyTranslation)
                }
                ScrollView { Text(translation).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .scrollIndicators(.hidden)
                    .scrollContentBackground(.hidden)
                    .seamlessScrollChrome()
            }
        }
        .padding(18)
        .background(HelloXTheme.cardGradient(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius).stroke(HelloXTheme.border(for: colorScheme)))
        .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 12, y: 6)
    }

    private func requestOfflineTranslation() {
        guard let text = document.beginOfflineTranslation() else { return }
        let request = EditorOfflineTranslationRequest(
            id: UUID(),
            text: text,
            sourceLanguageIdentifier: sourceLanguage.systemLanguageIdentifier,
            targetLanguageIdentifier: targetLanguage.systemLanguageIdentifier ?? targetLanguage.rawValue
        )
        offlineTranslationRequest = request
        let source = request.sourceLanguageIdentifier.map(Locale.Language.init(identifier:))
        let target = Locale.Language(identifier: request.targetLanguageIdentifier)
        if var configuration = offlineTranslationConfiguration,
           configuration.source == source,
           configuration.target == target {
            configuration.invalidate()
            offlineTranslationConfiguration = configuration
        } else {
            offlineTranslationConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func finishOfflineTranslation(requestID: UUID, text: String?, errorMessage: String?) {
        guard offlineTranslationRequest?.id == requestID else { return }
        offlineTranslationRequest = nil
        document.completeOfflineTranslation(text: text, errorMessage: errorMessage)
    }

    private var statusBar: some View {
        HStack {
            Text("\(document.image.width) × \(document.image.height) px")
            if let result = document.ocrResult {
                Text("OCR 置信度 \(Int(result.averageConfidence * 100))%")
            }
            Spacer()
            if document.dirty { Text("已修改").foregroundStyle(.secondary) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(HelloXTheme.surface(for: colorScheme))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HelloXTheme.border(for: colorScheme))
                .frame(height: 1)
        }
    }

    private var showsPropertyBar: Bool {
        tool != .select || selectedAnnotationDraft != nil
    }

    private var propertyColorBinding: Binding<Color> {
        Binding(
            get: {
                guard let selectedAnnotationDraft else { return color }
                return Color(
                    red: selectedAnnotationDraft.color.red,
                    green: selectedAnnotationDraft.color.green,
                    blue: selectedAnnotationDraft.color.blue,
                    opacity: selectedAnnotationDraft.color.alpha
                )
            },
            set: { value in
                color = value
                guard var selected = selectedAnnotationDraft else { return }
                selected.color = rgbaColor(from: value)
                selectedAnnotationDraft = selected
                persistPropertyChange(selected)
            }
        )
    }

    private var propertyLineWidthBinding: Binding<Double> {
        Binding(
            get: { selectedAnnotationDraft.map { Double($0.lineWidth) } ?? lineWidth },
            set: { value in
                lineWidth = value
                guard var selected = selectedAnnotationDraft else { return }
                selected.lineWidth = value
                selectedAnnotationDraft = selected
                persistPropertyChange(selected)
            }
        )
    }

    private var propertyMosaicModeBinding: Binding<MosaicMode> {
        Binding(
            get: { selectedAnnotationDraft?.mosaicMode ?? mosaicMode },
            set: { value in
                mosaicMode = value
                guard var selected = selectedAnnotationDraft, selected.tool == .pixelate else { return }
                selected.mosaicMode = value
                selectedAnnotationDraft = selected
                persistPropertyChange(selected)
            }
        )
    }

    private var propertyMosaicBlockSizeBinding: Binding<Double> {
        Binding(
            get: { selectedAnnotationDraft.map { Double($0.mosaicBlockSize) } ?? mosaicBlockSize },
            set: { value in
                mosaicBlockSize = value
                guard var selected = selectedAnnotationDraft, selected.tool == .pixelate else { return }
                selected.mosaicBlockSize = value
                selectedAnnotationDraft = selected
                persistPropertyChange(selected)
            }
        )
    }

    private var propertyTextBinding: Binding<String> {
        Binding(
            get: { selectedAnnotationDraft?.text ?? textValue },
            set: { value in
                textValue = value
                guard var selected = selectedAnnotationDraft, selected.tool == .watermark else { return }
                selected.text = value
                selectedAnnotationDraft = selected
                persistPropertyChange(selected)
            }
        )
    }

    private var propertyWatermarkSpacingBinding: Binding<Double> {
        Binding(
            get: { selectedAnnotationDraft.map { Double($0.watermarkSpacing) } ?? watermarkSpacing },
            set: { value in
                watermarkSpacing = value
                guard var selected = selectedAnnotationDraft, selected.tool == .watermark else { return }
                selected.watermarkSpacing = value
                selectedAnnotationDraft = selected
                persistPropertyChange(selected)
            }
        )
    }

    private func selectTool(_ newTool: AnnotationTool) {
        finishTextEditing()
        commitSelectedAnnotation()
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
        if newTool == .watermark {
            activateWatermarkTool()
        } else {
            tool = newTool
        }
    }

    private func activateWatermarkTool() {
        let annotation: Annotation
        if let existing = document.annotations.last(where: { $0.tool == .watermark }) {
            annotation = existing
            propertyEditRegistered = false
        } else {
            annotation = WatermarkAnnotationFactory.makeDefault()
            document.add(annotation)
            propertyEditRegistered = true
        }
        tool = .watermark
        selectedAnnotationID = annotation.id
        selectedAnnotationDraft = annotation
        textValue = annotation.text
        color = Color(
            red: annotation.color.red,
            green: annotation.color.green,
            blue: annotation.color.blue,
            opacity: annotation.color.alpha
        )
        lineWidth = annotation.lineWidth
        watermarkSpacing = annotation.watermarkSpacing
    }

    private func commitSelectedAnnotation() {
        guard let selectedAnnotationDraft else { return }
        document.update(selectedAnnotationDraft)
    }

    private func persistPropertyChange(_ annotation: Annotation) {
        if propertyEditRegistered {
            document.replaceDuringEditing(annotation)
        } else {
            document.update(annotation)
            propertyEditRegistered = true
        }
    }

    private func undo() {
        finishTextEditing()
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
        document.undo()
    }

    private func redo() {
        finishTextEditing()
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
        document.redo()
    }

    private func copyImage() {
        finishTextEditing()
        commitSelectedAnnotation()
        Task { @MainActor in await document.copyImageAsync() }
    }

    private func save() {
        finishTextEditing()
        commitSelectedAnnotation()
        Task { @MainActor in _ = await document.saveAsync() }
    }

    private func zoomIn() {
        zoomScale = EditorZoomGeometry.clamped(zoomScale * 1.25)
    }

    private func zoomOut() {
        zoomScale = EditorZoomGeometry.clamped(zoomScale / 1.25)
    }

    private func resetZoom() {
        zoomScale = 1
    }

    private var rgbaColor: RGBAColor {
        rgbaColor(from: color)
    }

    private func rgbaColor(from color: Color) -> RGBAColor {
        let value = NSColor(color).usingColorSpace(.deviceRGB) ?? .systemRed
        return RGBAColor(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent, alpha: value.alphaComponent)
    }

    private func commit(_ input: Annotation) {
        var annotation = input
        draft = nil
        if annotation.tool == .crop {
            document.cropSelection = annotation.normalizedRect
        } else {
            document.add(annotation)
            if annotation.tool == .text {
                annotation.text = ""
                document.updateLast(annotation)
                selectedAnnotationID = annotation.id
                selectedAnnotationDraft = annotation
                propertyEditRegistered = true
                color = Color(
                    red: annotation.color.red,
                    green: annotation.color.green,
                    blue: annotation.color.blue,
                    opacity: annotation.color.alpha
                )
                lineWidth = annotation.lineWidth
                textValue = annotation.text
                tool = .select
                inlineTextBuffer.text = ""
                isEditingText = true
            }
        }
    }

    private func finishTextEditing() {
        guard isEditingText else { return }
        if var annotation = selectedAnnotationDraft {
            let value = inlineTextBuffer.text
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document.removeAnnotation(id: annotation.id)
                selectedAnnotationID = nil
                selectedAnnotationDraft = nil
                isEditingText = false
                return
            }
            annotation.text = value
            textValue = annotation.text
            selectedAnnotationDraft = annotation
            persistPropertyChange(annotation)
        }
        isEditingText = false
    }
}

private struct EditorCanvas: View {
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
    let textValue: String
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
    @State private var didMoveSelectedText = false
    @State private var mosaicCache = MosaicPreviewCache()
    @State private var interactionThrottle = AnnotationInteractionThrottle()
    @State private var magnificationStartScale: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let fittedSize = EditorZoomGeometry.aspectFitSize(
                imageSize: sourceImageSize,
                container: proxy.size
            )
            let scaledSize = CGSize(
                width: fittedSize.width * zoomScale,
                height: fittedSize.height * zoomScale
            )
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                canvasSurface
                    .frame(width: scaledSize.width, height: scaledSize.height)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .scrollContentBackground(.hidden)
            .seamlessScrollChrome()
            .background(HelloXTheme.pageBackground(for: colorScheme))
            .simultaneousGesture(magnificationGesture)
        }
        .onChange(of: tool) { newTool in
            guard newTool == .pixelate else { return }
            _ = mosaicCache.image(for: image, blockSize: mosaicBlockSize)
        }
        .onChange(of: mosaicBlockSize) { value in
            guard tool == .pixelate else { return }
            _ = mosaicCache.image(for: image, blockSize: value)
        }
    }

    private var canvasSurface: some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(imageSize: CGSize(width: image.width, height: image.height), container: proxy.size)
            ZStack {
                HelloXTheme.pageBackground(for: colorScheme)
                Image(decorative: image, scale: 1)
                    .resizable()
                    // Keep screenshot pixels crisp while fitting the canvas.
                    // SwiftUI's default interpolation can soften text and 1px UI lines.
                    .interpolation(.none)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                Canvas { context, _ in
                    context.clip(to: Path(imageRect))
                    for annotation in annotations where annotation.id != selectedAnnotationID {
                        draw(annotation, in: imageRect, context: &context)
                    }
                    if let cropSelection {
                        let rect = denormalize(cropSelection, in: imageRect)
                        context.stroke(Path(rect), with: .color(.blue), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
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
                    if let draft { draw(draft, in: imageRect, context: &context) }
                    if let selectedAnnotationDraft,
                       !(isEditingText && selectedAnnotationDraft.tool == .text) {
                        draw(selectedAnnotationDraft, in: imageRect, context: &context)
                    }
                }
                .allowsHitTesting(false)
                if let selectedAnnotationDraft,
                   !(isEditingText && selectedAnnotationDraft.tool == .text) {
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
                Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: tool == .text || tool == .select || (tool == .pixelate && mosaicMode == .brush) ? 0 : 2)
                    .onChanged { value in
                        guard imageRect.contains(value.startLocation) else { return }
                        guard tool != .watermark else { return }
                        if isEditingText {
                            finishInlineTextEditing(in: imageRect)
                            return
                        }
                        guard interactionThrottle.shouldProcess(value.location) else { return }
                        if tool == .select {
                            updateSelectionDrag(value, imageRect: imageRect)
                            return
                        }
                        let start = normalize(value.startLocation, in: imageRect)
                        let end = normalize(value.location, in: imageRect)
                        if dragStart == nil { dragStart = start; penPoints = [start] }
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
                            mosaicBlockSize: mosaicBlockSize
                        )
                        onDraft(annotation)
                    }
                    .onEnded { value in
                        interactionThrottle.reset()
                        guard tool != .watermark else { return }
                        if tool == .select {
                            finishSelectionDrag()
                            return
                        }
                        defer { dragStart = nil; penPoints.removeAll(); onDraft(nil) }
                        guard let start = dragStart else { return }
                        let end = normalize(value.location, in: imageRect)
                        let isFreehand = tool == .pen || (tool == .pixelate && mosaicMode == .brush)
                        let annotation = Annotation(
                            tool: tool,
                            start: start,
                            end: end,
                            points: isFreehand ? penPoints + [end] : [],
                            text: textValue,
                            color: color,
                            lineWidth: lineWidth,
                            mosaicMode: mosaicMode,
                            mosaicBlockSize: mosaicBlockSize
                        )
                        if annotation.normalizedRect.width > 0.002 || annotation.normalizedRect.height > 0.002 || tool == .text || (tool == .pixelate && mosaicMode == .brush) {
                            onCommit(annotation)
                        }
                    })
                inlineTextEditor(in: imageRect)
            }
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
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
        }

        guard let originalSelectedAnnotation else { return }
        didMoveSelectedText = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
        selectedAnnotationDraft = AnnotationEditingGeometry.moved(
            originalSelectedAnnotation,
            by: value.translation,
            imageRect: imageRect,
            editingBounds: imageRect,
            sourceImageSize: sourceImageSize
        )
    }

    private func finishSelectionDrag() {
        let shouldEditInline = originalSelectedAnnotation != nil && !didMoveSelectedText
        if let selectedAnnotationDraft, originalSelectedAnnotation != nil {
            onUpdate(selectedAnnotationDraft)
        }
        originalSelectedAnnotation = nil
        didMoveSelectedText = false
        if shouldEditInline, selectedAnnotationDraft?.tool == .text { isEditingText = true }
    }

    @ViewBuilder
    private func inlineTextEditor(in imageRect: CGRect) -> some View {
        if isEditingText,
           let annotation = selectedAnnotationDraft,
           annotation.tool == .text {
            InlineAnnotationTextEditor(
                annotation: annotation,
                imageRect: imageRect,
                editingBounds: imageRect,
                sourceImageSize: sourceImageSize,
                buffer: inlineTextBuffer,
                onCommit: { finishInlineTextEditing(in: imageRect) },
                onCancel: cancelInlineTextEditing
            )
            .id(annotation.id)
        }
    }

    private func finishInlineTextEditing(in imageRect: CGRect) {
        guard isEditingText else { return }
        if var annotation = selectedAnnotationDraft {
            let value = inlineTextBuffer.text
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onDelete(annotation.id)
                selectedAnnotationID = nil
                selectedAnnotationDraft = nil
                isEditingText = false
                return
            }
            annotation.text = value
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
    }

    private func cancelInlineTextEditing() {
        if inlineTextBuffer.originalText.isEmpty, let id = selectedAnnotationDraft?.id {
            onDelete(id)
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
        }
        isEditingText = false
    }

    private func draw(_ annotation: Annotation, in imageRect: CGRect, context: inout GraphicsContext) {
        AnnotationCanvasDrawing.draw(
            annotation,
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
