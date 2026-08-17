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
            14,
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

    static func hitText(
        at point: CGPoint,
        annotations: [Annotation],
        imageRect: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation? {
        annotations.reversed().first { annotation in
            guard annotation.tool.isTextual else { return false }
            return textRect(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            )
            .insetBy(dx: -7, dy: -7)
            .contains(point)
        }
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

    static func hitAnnotation(
        at point: CGPoint,
        annotations: [Annotation],
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation? {
        guard editingBounds.contains(point) else { return nil }
        // Text has a compact visible target and must remain independently movable even when a
        // shape overlaps it. Prefer the topmost text hit before considering larger shape bounds.
        if let text = hitText(
            at: point,
            annotations: annotations,
            imageRect: imageRect,
            sourceImageSize: sourceImageSize
        ), text.tool == .text {
            return text
        }
        return annotations.reversed().first { annotation in
            guard !annotation.tool.isTextual else { return false }
            return displayBounds(for: annotation, imageRect: imageRect, sourceImageSize: sourceImageSize)
                .insetBy(dx: -5, dy: -5)
                .contains(point)
        }
    }

    static func moved(
        _ annotation: Annotation,
        by translation: CGSize,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize
    ) -> Annotation {
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
            14,
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
        defer {
            lastTime = now
            lastPoint = point
        }
        guard let lastPoint else { return true }
        let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
        return now - lastTime >= 1.0 / 120.0 || distance >= 3
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
    let buffer: InlineAnnotationTextBuffer
    let onCommit: () -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(
        annotation: Annotation,
        imageRect: CGRect,
        editingBounds: CGRect,
        sourceImageSize: CGSize,
        buffer: InlineAnnotationTextBuffer,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.annotation = annotation
        self.imageRect = imageRect
        self.editingBounds = editingBounds
        self.sourceImageSize = sourceImageSize
        self.buffer = buffer
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: buffer.text)
    }

    var body: some View {
        let layout = InlineTextEditorGeometry.layout(
            for: annotation,
            text: text,
            imageRect: imageRect,
            editingBounds: editingBounds,
            sourceImageSize: sourceImageSize
        )
        let fontSize = max(
            14,
            AnnotationEditingGeometry.displayLineWidth(
                for: annotation,
                imageRect: imageRect,
                sourceImageSize: sourceImageSize
            ) * 5
        )
        ZStack {
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
        .onAppear {
            buffer.text = text
            buffer.originalText = text
        }
        .accessibilityLabel("截图多行文字标注")
    }

    private func annotationFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard annotation.tool == .watermark else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    private var annotationNSColor: NSColor {
        let color = annotation.color.nsColor
        return annotation.tool == .watermark
            ? color.withAlphaComponent(annotation.color.alpha * 0.38)
            : color
    }
}

/// A borderless NSTextView whose text container never wraps automatically. SwiftUI owns the
/// measured frame, while AppKit provides reliable multiline input, focus and command handling.
private struct InlineGrowingTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let color: NSColor
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
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 100_000, height: 100_000)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
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
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineGrowingTextView
        private var suppressEndCommit = false

        init(parent: InlineGrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
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
        switch annotation.tool {
        case .rectangle: path.addRect(rect)
        case .ellipse: path.addEllipse(in: rect)
        case .line, .arrow:
            path.move(to: start); path.addLine(to: end)
            if annotation.tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = max(10, width * 4)
                path.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
            }
        case .pen:
            guard let first = annotation.points.first else { return }
            path.move(to: denormalize(first))
            for point in annotation.points.dropFirst() { path.addLine(to: denormalize(point)) }
        case .text, .watermark:
            guard !annotation.text.isEmpty else { return }
            var label = Text(annotation.text).font(.system(size: max(14, width * 5)))
            if annotation.tool == .watermark {
                label = label.italic().foregroundColor(swiftColor.opacity(0.38))
                drawTiledWatermark(
                    label,
                    text: annotation.text,
                    fontSize: max(14, width * 5),
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if tool == .pixelate {
                    propertyLabel("模式")
                    Picker("马赛克模式", selection: $mosaicMode) {
                        Text("画笔").tag(MosaicMode.brush)
                        Text("矩形").tag(MosaicMode.rectangle)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.borderless)
                    .frame(width: 104)
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

                propertyLabel(tool.isTextual ? "字号" : tool == .pixelate && mosaicMode == .brush ? "笔刷" : tool == .pixelate ? "颗粒" : "粗细")

                Slider(
                    value: sliderBinding,
                    in: tool.isTextual ? 14...96 : 1...32,
                    step: 1
                )
                    .frame(width: 96)
                    .fixedSize(horizontal: true, vertical: false)

                Text("\(Int(sliderBinding.wrappedValue.rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                    .frame(width: 20, alignment: .trailing)

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
                } else if tool != .pixelate {
                    HStack(spacing: 2) {
                        ForEach(AnnotationPalette.colors) { item in
                            paletteButton(item)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 10)
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollContentBackground(.hidden)
        .seamlessScrollChrome()
        .frame(height: 40)
        .background(
            HelloXTheme.cardGradient(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 12, y: 5)
    }

    private var sliderBinding: Binding<Double> {
        if tool == .pixelate && mosaicMode == .rectangle { return $mosaicBlockSize }
        if tool.isTextual {
            return Binding(
                get: { max(14, lineWidth * 5) },
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
    static let toolbarHorizontalPadding: CGFloat = 14

    static func buttonRowWidth(count: Int) -> CGFloat {
        guard count > 0 else { return toolbarHorizontalPadding }
        return CGFloat(count) * toolbarButtonSize
            + CGFloat(count - 1) * toolbarButtonSpacing
            + toolbarHorizontalPadding
    }

    static func propertyContentWidth(for tool: AnnotationTool) -> CGFloat {
        tool == .watermark ? 710 : 626
    }

    static func preferredToolbarWidth(for tool: AnnotationTool, buttonCount: Int = 19) -> CGFloat {
        max(buttonRowWidth(count: buttonCount), propertyContentWidth(for: tool))
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
