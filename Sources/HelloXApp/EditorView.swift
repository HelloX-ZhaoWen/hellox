import AppKit
import HelloXCore
import SwiftUI

enum EditorZoomGeometry {
    static let minimumScale: CGFloat = 0.25
    static let maximumScale: CGFloat = 8

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    /// `displayScale` is the capture's pixel density (`document.displayScale`),
    /// not the editor window's backing scale, so previews stay aligned with the
    /// exported pixel mapping on mixed-scale multi-display setups.
    static func logicalImageSize(pixelSize: CGSize, displayScale: CGFloat) -> CGSize {
        let scale = max(1, displayScale)
        return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    static func fitScale(pixelSize: CGSize, container: CGSize, displayScale: CGFloat) -> CGFloat {
        let logicalSize = logicalImageSize(pixelSize: pixelSize, displayScale: displayScale)
        guard logicalSize.width > 0, logicalSize.height > 0,
              container.width > 0, container.height > 0 else { return 1 }
        return clamped(min(container.width / logicalSize.width, container.height / logicalSize.height))
    }

    static func displaySize(pixelSize: CGSize, zoomScale: CGFloat, displayScale: CGFloat) -> CGSize {
        let logicalSize = logicalImageSize(pixelSize: pixelSize, displayScale: displayScale)
        return CGSize(width: logicalSize.width * zoomScale, height: logicalSize.height * zoomScale)
    }

}

struct EditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var document: EditorDocument
    let onClose: () -> Void
    @State private var tool: AnnotationTool = .select
    @State private var color: Color = .red
    @State private var lineWidth: Double = 4
    @State private var mosaicMode: MosaicMode = .brush
    @State private var mosaicBlockSize: Double = 10
    @State private var watermarkSpacing: Double = 48
    @State private var highlightShowsBorder = false
    @State private var highlightShape: AnnotationHighlightShape = .rectangle
    @State private var textValue = "文字"
    @State private var draft: Annotation?
    @State private var selectedAnnotationID: UUID?
    @State private var selectedAnnotationDraft: Annotation?
    @State private var propertyEditRegistered = false
    @State private var isEditingText = false
    @State private var inlineTextBuffer = InlineAnnotationTextBuffer()
    @State private var zoomScale: CGFloat = 1
    @State private var fitScale: CGFloat = 1
    @State private var isFitMode = true
    @State private var zoomPercentInput = "100"
    @State private var isEditingZoomPercent = false
    @FocusState private var isZoomPercentFocused: Bool

    init(document: EditorDocument, startsWithWatermark: Bool = false, initialTool: AnnotationTool = .select, onClose: @escaping () -> Void = {}) {
        self.document = document
        self.onClose = onClose
        _tool = State(initialValue: initialTool)
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
        HXDialogSurface {
            VStack(spacing: 0) {
                documentBar
                if showsPropertyBar { propertyToolbar }
                HStack(spacing: 0) {
                    toolRail

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
                        highlightShowsBorder: highlightShowsBorder,
                        highlightShape: highlightShape,
                        textValue: textValue,
                        displayScale: document.displayScale,
                        fitScale: $fitScale,
                        isFitMode: $isFitMode,
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
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                    .simultaneousGesture(TapGesture().onEnded {
                        if isEditingZoomPercent {
                            finishZoomPercentEditing()
                        }
                    })

                    if document.ocrResult != nil || document.isPerformingOCR {
                        textPanel
                            .frame(width: 260)
                            .background(HelloXTheme.surface(for: colorScheme))
                            .overlay(alignment: .leading) {
                                Rectangle().fill(HelloXTheme.border(for: colorScheme)).frame(width: 1)
                            }
                    }
                }
                .background(HelloXTheme.controlBackground(for: colorScheme))
                statusBar
            }
        }
        .ignoresSafeArea()
        .tint(HelloXTheme.accent)
        .onChange(of: selectedAnnotationID) {
            propertyEditRegistered = false
        }
        .onChange(of: isZoomPercentFocused) { _, focused in
            if !focused, isEditingZoomPercent {
                finishZoomPercentEditing()
            }
        }
    }

    private var documentBar: some View {
        HStack(spacing: HXSpacing.xs) {
            HStack(spacing: HXSpacing.xs) {
                Text("截图编辑器")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                if document.dirty {
                    Circle()
                        .fill(HelloXTheme.accentBlue)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("已修改")
                }
            }
            .frame(minWidth: 140, alignment: .leading)

            HelloXIconButton(icon: .undo, help: "撤销", size: 34, iconSize: 16, isBorderless: true, action: undo)
                .disabled(!document.canUndo)
            HelloXIconButton(icon: .redo, help: "重做", size: 34, iconSize: 16, isBorderless: true, action: redo)
                .disabled(!document.canRedo)

            Spacer()

            HelloXIconButton(icon: .line, help: "缩小（⌘-）", size: 34, iconSize: 16, isBorderless: true, action: zoomOut)
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoomScale <= EditorZoomGeometry.minimumScale)
            zoomPercentControl
            HelloXIconButton(icon: .screen, help: "还原为 100%（⌘0）", size: 34, iconSize: 16, isBorderless: true, action: resetZoom)
                .keyboardShortcut("0", modifiers: .command)
            HelloXIconButton(icon: .add, help: "放大（⌘+）", size: 34, iconSize: 16, isBorderless: true, action: zoomIn)
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoomScale >= EditorZoomGeometry.maximumScale)

            Spacer()

            if document.isPerformingOCR {
                ProgressView().controlSize(.small).frame(width: 34, height: 34)
            } else {
                HelloXIconButton(icon: .textRecognition, help: "文字识别", size: 34, iconSize: 16, isBorderless: true) {
                    document.runOCR()
                }
            }
            HelloXIconButton(icon: .copy, help: "复制", size: 34, iconSize: 16, isBorderless: true, action: copyImage)
            HelloXIconButton(icon: .save, help: "保存", role: .accent, size: 34, iconSize: 16, action: save)
            HelloXIconButton(icon: .close, help: "关闭", size: 32, iconSize: 16, isBorderless: true, action: onClose)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(HelloXTheme.surface(for: colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HelloXTheme.border(for: colorScheme))
                .frame(height: 1)
        }
    }

    private var toolRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: HXSpacing.xxs) {
                ForEach(AnnotationTool.allCases) { item in
                    HelloXIconButton(
                        icon: item.helloXIcon,
                        help: item.localizedName,
                        isSelected: tool == item,
                        size: 38,
                        iconSize: 16,
                        isBorderless: true,
                        action: { selectTool(item) }
                    )
                }
            }
            .padding(.vertical, HXSpacing.sm)
        }
        .frame(width: 52)
        .background(HelloXTheme.surface(for: colorScheme))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(HelloXTheme.border(for: colorScheme))
                .frame(width: 1)
        }
        .accessibilityLabel("标注工具")
    }

    private var propertyToolbar: some View {
        HStack(spacing: 12) {
            Text((selectedAnnotationDraft?.tool ?? tool).localizedName)
                .font(HXTypography.section)
                .frame(minWidth: 42, alignment: .leading)
            if tool == .crop {
                Text("拖拽选择范围，拖动控制点调整")
                    .font(HXTypography.caption)
                    .foregroundStyle(HXTextStyle.secondary)
                Spacer(minLength: 8)
                if let selection = (draft?.tool == .crop ? draft?.normalizedRect : document.cropSelection) {
                    Text("\(Int((selection.width * CGFloat(document.image.width)).rounded())) × \(Int((selection.height * CGFloat(document.image.height)).rounded())) px")
                        .font(HXTypography.caption).monospacedDigit()
                        .foregroundStyle(HXTextStyle.secondary)
                }
                Button("取消裁剪") { document.cropSelection = nil; draft = nil }
                    .buttonStyle(HelloXButtonStyle())
                    .disabled(document.cropSelection == nil)
                Button("应用裁剪", action: document.applyCrop)
                    .buttonStyle(HelloXButtonStyle(role: .accent))
                    .disabled(document.cropSelection == nil)
            } else {
                AnnotationPropertyBar(
                    tool: selectedAnnotationDraft?.tool ?? tool,
                    color: propertyColorBinding,
                    lineWidth: propertyLineWidthBinding,
                    mosaicMode: propertyMosaicModeBinding,
                    mosaicBlockSize: propertyMosaicBlockSizeBinding,
                    text: propertyTextBinding,
                    watermarkSpacing: propertyWatermarkSpacingBinding,
                    highlightShowsBorder: propertyHighlightShowsBorderBinding,
                    highlightShape: propertyHighlightShapeBinding
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(HelloXTheme.surface(for: colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(HelloXTheme.border(for: colorScheme)).frame(height: 1)
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 7) {
                    HelloXIcon(icon: .textRecognition, size: 16)
                        .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
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
        }
        .padding(HXSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusBar: some View {
        HStack {
            Text("\(document.image.width) × \(document.image.height) px")
            if let result = document.ocrResult {
                Text("OCR 置信度 \(Int(result.averageConfidence * 100))%")
            }
            Spacer()
            if document.dirty { Text("已修改").foregroundStyle(HXTextStyle.secondary) }
        }
        .font(.caption)
        .foregroundStyle(HXTextStyle.secondary)
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
                if selected.tool == .step {
                    let displaySize = EditorZoomGeometry.displaySize(
                        pixelSize: CGSize(width: document.image.width, height: document.image.height),
                        zoomScale: zoomScale,
                        displayScale: document.displayScale
                    )
                    selected = AnnotationEditingGeometry.fittedStepAnnotation(
                        selected,
                        number: StepAnnotationNumbering.number(
                            for: selected.id,
                            in: document.annotations
                        ) ?? 1,
                        imageRect: CGRect(origin: .zero, size: displaySize),
                        editingBounds: CGRect(origin: .zero, size: displaySize),
                        sourceImageSize: CGSize(width: document.image.width, height: document.image.height)
                    )
                }
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

    private var propertyHighlightShowsBorderBinding: Binding<Bool> {
        Binding(
            get: { selectedAnnotationDraft?.highlightShowsBorder ?? highlightShowsBorder },
            set: { value in
                highlightShowsBorder = value
                guard var selected = selectedAnnotationDraft, selected.tool == .highlight else { return }
                selected.highlightShowsBorder = value
                selectedAnnotationDraft = selected
                persistPropertyChange(selected)
            }
        )
    }

    private var propertyHighlightShapeBinding: Binding<AnnotationHighlightShape> {
        Binding(
            get: { selectedAnnotationDraft?.highlightShape ?? highlightShape },
            set: { value in
                highlightShape = value
                guard var selected = selectedAnnotationDraft, selected.tool == .highlight else { return }
                selected.highlightShape = value
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
            if newTool == .highlight, tool != .highlight {
                color = Color(
                    red: AnnotationHighlightStyle.defaultColor.red,
                    green: AnnotationHighlightStyle.defaultColor.green,
                    blue: AnnotationHighlightStyle.defaultColor.blue
                )
            }
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
        isFitMode = false
        zoomScale = EditorZoomGeometry.clamped(zoomScale * 1.25)
    }

    private func zoomOut() {
        isFitMode = false
        zoomScale = EditorZoomGeometry.clamped(zoomScale / 1.25)
    }

    private func resetZoom() {
        isFitMode = false
        zoomScale = 1
        zoomPercentInput = formattedZoomPercent(zoomScale)
    }

    private func applyZoomPercentInput() {
        let normalized = zoomPercentInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        guard let percent = Double(normalized), percent.isFinite else {
            zoomPercentInput = formattedZoomPercent(zoomScale)
            return
        }
        let scale = CGFloat(percent / 100)
        guard scale >= EditorZoomGeometry.minimumScale,
              scale <= EditorZoomGeometry.maximumScale else {
            zoomPercentInput = formattedZoomPercent(zoomScale)
            return
        }
        isFitMode = false
        zoomScale = scale
        zoomPercentInput = formattedZoomPercent(scale)
    }

    private func finishZoomPercentEditing() {
        applyZoomPercentInput()
        isEditingZoomPercent = false
        isZoomPercentFocused = false
    }

    private var zoomPercentControl: some View {
        Group {
            if isEditingZoomPercent {
                TextField("100%", text: $zoomPercentInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 58, height: 26)
                    .focused($isZoomPercentFocused)
                    .onSubmit {
                        finishZoomPercentEditing()
                    }
            } else {
                Button {
                    zoomPercentInput = formattedZoomPercent(zoomScale)
                    isEditingZoomPercent = true
                    DispatchQueue.main.async {
                        isZoomPercentFocused = true
                    }
                } label: {
                    Text("\(formattedZoomPercent(zoomScale))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 58, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击编辑缩放比例")
            }
        }
        .onChange(of: zoomScale) { _, value in
            if !isEditingZoomPercent {
                zoomPercentInput = formattedZoomPercent(value)
            }
        }
    }

    private func formattedZoomPercent(_ scale: CGFloat) -> String {
        "\(Int((scale * 100).rounded()))"
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
        } else if annotation.tool == .text || annotation.tool == .step {
            annotation.text = ""
            document.add(annotation)
            selectedAnnotationID = annotation.id
            selectedAnnotationDraft = annotation
            propertyEditRegistered = true
            textValue = annotation.text
            inlineTextBuffer.text = ""
            isEditingText = AnnotationInlineEditingPolicy.beginsImmediatelyAfterCreation(
                for: annotation.tool
            )
        } else {
            document.add(annotation)
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
            propertyEditRegistered = false
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
            if annotation.tool == .step,
               let number = StepAnnotationNumbering.number(for: annotation.id, in: document.annotations) {
                annotation = AnnotationEditingGeometry.fittedStepAnnotation(
                    annotation,
                    number: number,
                    imageRect: CGRect(
                        origin: .zero,
                        size: EditorZoomGeometry.displaySize(
                            pixelSize: CGSize(width: document.image.width, height: document.image.height),
                            zoomScale: zoomScale,
                            displayScale: document.displayScale
                        )
                    ),
                    editingBounds: CGRect(
                        origin: .zero,
                        size: EditorZoomGeometry.displaySize(
                            pixelSize: CGSize(width: document.image.width, height: document.image.height),
                            zoomScale: zoomScale,
                            displayScale: document.displayScale
                        )
                    ),
                    sourceImageSize: CGSize(width: document.image.width, height: document.image.height)
                )
            }
            textValue = annotation.text
            selectedAnnotationDraft = annotation
            persistPropertyChange(annotation)
        }
        isEditingText = false
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
    }
}
