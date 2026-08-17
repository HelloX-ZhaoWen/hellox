import AppKit
import HelloXCore
import SwiftUI

enum EditorSaveResult {
    case saved
    case cancelled
    case failed
}

enum EditorImageSnapshotMode {
    case originalSelection
    case annotatedOutput
}

struct ImageTranslationOfflineRequest: Identifiable {
    let id = UUID()
    let paragraphs: [RecognizedTextParagraph]
    let sourceLanguageIdentifier: String?
    let targetLanguageIdentifier: String
}

@MainActor
final class EditorDocument: ObservableObject {
    @Published var image: CGImage
    @Published var annotations: [Annotation] = []
    @Published var ocrResult: OCRResult?
    @Published var translatedText: String?
    @Published var imageTranslationBlocks: [ImageTranslationBlock] = []
    @Published private(set) var pendingImageTranslationRequest: ImageTranslationOfflineRequest?
    @Published var isPerformingOCR = false
    @Published var isPerformingTranslation = false
    @Published var dirty = false
    @Published var cropSelection: CGRect?
    @Published var outputCrop: CGRect?
    @Published var isExporting = false
    @Published var exportMessage: String?
    @Published var exportError: String?

    let displayScale: CGFloat
    private let appModel: AppModel
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    init(result: CaptureResult, appModel: AppModel, outputCrop: CGRect? = nil) {
        self.image = result.image
        self.displayScale = result.displayScale
        self.appModel = appModel
        self.outputCrop = outputCrop
    }

    var translationProfiles: [TranslationProfile] { appModel.enabledTranslationProfiles }
    var defaultTranslationProfileID: UUID? { appModel.defaultTranslationProfileID }
    var isOfflineTranslationEnabled: Bool { appModel.isOfflineTranslationEnabled }

    func add(_ annotation: Annotation) {
        pushUndo()
        annotations.append(annotation)
        dirty = true
    }

    func updateLast(_ annotation: Annotation) {
        guard !annotations.isEmpty else { return }
        annotations[annotations.count - 1] = annotation
        dirty = true
    }

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }),
              annotations[index] != annotation else { return }
        pushUndo()
        annotations[index] = annotation
        dirty = true
    }

    func removeAnnotation(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        dirty = true
    }

    /// Replaces an annotation within an already registered editing transaction.
    /// Interactive controls use this after their first change so a slider drag or
    /// text entry remains a single undo step.
    func replaceDuringEditing(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }),
              annotations[index] != annotation else { return }
        annotations[index] = annotation
        dirty = true
    }

    func annotation(id: UUID?) -> Annotation? {
        guard let id else { return nil }
        return annotations.first { $0.id == id }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        dirty = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        dirty = true
    }

    func applyCrop() {
        guard let cropSelection, let result = try? AnnotationRenderer.crop(baseImage: image, normalizedRect: cropSelection) else { return }
        pushUndo()
        image = result
        annotations.removeAll()
        imageTranslationBlocks.removeAll()
        translatedText = nil
        self.cropSelection = nil
        dirty = true
    }

    func runOCR() {
        guard !isPerformingOCR else { return }
        isPerformingOCR = true
        Task { @MainActor in
            defer { isPerformingOCR = false }
            do { ocrResult = try await appModel.ocrService.recognizeText(in: try imageForOutput()) }
            catch { appModel.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    func translate(source: SupportedLanguage, target: SupportedLanguage, profileID: UUID? = nil) {
        guard !isPerformingTranslation else { return }
        guard let text = ocrResult?.text, !text.isEmpty else {
            appModel.lastError = HelloXError.noTextFound.localizedDescription
            return
        }
        isPerformingTranslation = true
        Task { @MainActor in
            defer { isPerformingTranslation = false }
            do {
                let request = TranslationRequest(text: text, sourceLanguage: source, targetLanguage: target)
                translatedText = try await appModel.provider(for: request, profileID: profileID).translate(request).text
            } catch { appModel.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    /// Translates complete OCR paragraphs and anchors each translated paragraph
    /// to the union of its source lines. Line breaks are restored only after the
    /// paragraph has been translated with its full context.
    func translateImageInPlace() {
        guard !isPerformingOCR, !isPerformingTranslation else { return }
        isPerformingOCR = true
        isPerformingTranslation = true
        imageTranslationBlocks.removeAll()
        translatedText = nil
        Task { @MainActor in
            do {
                let sourceImage = try imageForOutput()
                let recognized = try await appModel.ocrService.recognizeText(in: sourceImage)
                guard !recognized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HelloXError.noTextFound
                }
                ocrResult = recognized
                isPerformingOCR = false
                let source = recognized.language.flatMap(SupportedLanguage.init(rawValue:)) ?? .auto
                let target: SupportedLanguage = source == .simplifiedChinese || source == .traditionalChinese
                    ? .english
                    : .simplifiedChinese
                let paragraphs = OCRParagraphLayout.paragraphs(from: recognized.blocks)
                guard !paragraphs.isEmpty else { throw HelloXError.noTextFound }

                // Prefer a configured cloud profile for image translation so
                // the OCR text is translated through the user's API and can
                // be rendered back into its original image locations.
                if appModel.enabledTranslationProfiles.isEmpty,
                   appModel.isOfflineTranslationEnabled {
                    pendingImageTranslationRequest = ImageTranslationOfflineRequest(
                        paragraphs: paragraphs,
                        sourceLanguageIdentifier: source.systemLanguageIdentifier,
                        targetLanguageIdentifier: target.systemLanguageIdentifier ?? target.rawValue
                    )
                    return
                }

                let provider = try appModel.provider(for: TranslationRequest(
                    text: paragraphs[0].text,
                    sourceLanguage: source,
                    targetLanguage: target
                ))
                var translations: [UUID: String] = [:]
                var firstError: String?
                await withTaskGroup(of: (UUID, String?, String?).self) { group in
                    for paragraph in paragraphs {
                        group.addTask {
                            do {
                                let request = TranslationRequest(
                                    text: paragraph.text,
                                    sourceLanguage: source,
                                    targetLanguage: target
                                )
                                return (paragraph.id, try await provider.translate(request).text, nil)
                            } catch {
                                return (paragraph.id, nil, error.localizedDescription)
                            }
                        }
                    }
                    for await (id, text, errorMessage) in group {
                        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            translations[id] = text
                        } else if firstError == nil {
                            firstError = errorMessage
                        }
                    }
                }

                let appearances = ImageTranslationAppearanceExtractor.appearances(for: recognized.blocks, in: sourceImage)
                let renderedBlocks = makeImageTranslationBlocks(
                    paragraphs: paragraphs,
                    translations: translations,
                    appearances: appearances,
                    imageSize: CGSize(width: sourceImage.width, height: sourceImage.height)
                )
                guard !renderedBlocks.isEmpty else {
                    throw HelloXError.captureFailed(firstError ?? "图片翻译失败")
                }
                applyImageTranslations(renderedBlocks)
            } catch {
                isPerformingOCR = false
                isPerformingTranslation = false
                pendingImageTranslationRequest = nil
                appModel.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func completeOfflineImageTranslation(requestID: UUID, texts: [String]?, errorMessage: String?) {
        guard let request = pendingImageTranslationRequest, request.id == requestID else { return }
        pendingImageTranslationRequest = nil
        isPerformingTranslation = false
        guard let texts, texts.count == request.paragraphs.count else {
            if let errorMessage { appModel.lastError = errorMessage }
            return
        }
        guard let sourceImage = try? imageForOutput() else { return }
        let appearances = ImageTranslationAppearanceExtractor.appearances(
            for: request.paragraphs.flatMap(\.blocks),
            in: sourceImage
        )
        let translations = Dictionary(uniqueKeysWithValues: zip(request.paragraphs, texts).map { ($0.id, $1) })
        let translatedBlocks = makeImageTranslationBlocks(
            paragraphs: request.paragraphs,
            translations: translations,
            appearances: appearances,
            imageSize: CGSize(width: sourceImage.width, height: sourceImage.height)
        )
        applyImageTranslations(translatedBlocks)
    }

    func beginOfflineTranslation() -> String? {
        guard !isPerformingTranslation else { return nil }
        guard appModel.isOfflineTranslationEnabled else {
            appModel.lastError = "离线翻译已停用，请选择其他已启用的翻译服务。"
            return nil
        }
        guard let text = ocrResult?.text, !text.isEmpty else {
            appModel.lastError = HelloXError.noTextFound.localizedDescription
            return nil
        }
        isPerformingTranslation = true
        return text
    }

    func completeOfflineTranslation(text: String?, errorMessage: String?) {
        isPerformingTranslation = false
        if let text {
            translatedText = text
        } else if let errorMessage {
            appModel.lastError = errorMessage
        }
    }

    func renderedImage() throws -> CGImage {
        try imageSnapshot(.annotatedOutput)
    }

    /// Crops the frozen capture without compositing annotations.
    func originalSelectionImage() throws -> CGImage {
        try imageSnapshot(.originalSelection)
    }

    func imageSnapshot(_ mode: EditorImageSnapshotMode) throws -> CGImage {
        switch mode {
        case .originalSelection:
            guard let outputCrop else { return image }
            return try AnnotationRenderer.crop(baseImage: image, normalizedRect: outputCrop)
        case .annotatedOutput:
            return try AnnotationRenderer.renderOutput(
                baseImage: image,
                annotations: annotations,
                normalizedCrop: outputCrop,
                translatedBlocks: imageTranslationBlocks
            )
        }
    }

    func imageSnapshotAsync(_ mode: EditorImageSnapshotMode) async throws -> CGImage {
        await Task.yield()
        return try imageSnapshot(mode)
    }

    @discardableResult
    func copyImage() -> PasteboardWriteResult {
        do {
            let result = ImageExporter.copyToPasteboard(try renderedImage())
            switch result {
            case .success:
                exportError = nil
                exportMessage = "已复制到剪贴板"
                CopyFeedbackPresenter.shared.showSuccess()
            case .failure(let message):
                exportMessage = nil
                exportError = message
                appModel.lastError = message
                CopyFeedbackPresenter.shared.showFailure(message)
            }
            return result
        } catch {
            exportMessage = nil
            exportError = error.localizedDescription
            appModel.lastError = error.localizedDescription
            return .failure(error.localizedDescription)
        }
    }

    @discardableResult
    func copyImageAsync() async -> PasteboardWriteResult {
        do {
            let result = await ImageExporter.copyToPasteboardAsync(try await imageSnapshotAsync(.annotatedOutput))
            applyCopyResult(result)
            return result
        } catch {
            let result = PasteboardWriteResult.failure(error.localizedDescription)
            applyCopyResult(result)
            return result
        }
    }

    func copyOCRText() {
        guard let text = ocrResult?.text else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            CopyFeedbackPresenter.shared.showSuccess("识别文字已复制")
        } else {
            CopyFeedbackPresenter.shared.showFailure()
        }
    }

    func copyTranslation() {
        guard let translatedText else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(translatedText, forType: .string) {
            CopyFeedbackPresenter.shared.showSuccess("译文已复制")
        } else {
            CopyFeedbackPresenter.shared.showFailure()
        }
    }

    @discardableResult
    func save() -> EditorSaveResult {
        let rendered: CGImage
        do { rendered = try renderedImage() }
        catch {
            appModel.lastError = error.localizedDescription
            return .failed
        }
        return save(image: rendered)
    }

    @discardableResult
    func save(image rendered: CGImage) -> EditorSaveResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "HelloX-\(Self.dateFormatter.string(from: Date())).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        let format: ImageExportFormat = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? .jpeg : .png
        do {
            try ImageExporter.write(rendered, to: url, format: format)
            dirty = false
            return .saved
        } catch {
            appModel.lastError = error.localizedDescription
            return .failed
        }
    }

    func saveAsync() async -> EditorSaveResult {
        let rendered: CGImage
        do { rendered = try await imageSnapshotAsync(.annotatedOutput) }
        catch {
            appModel.lastError = error.localizedDescription
            return .failed
        }
        return await saveAsync(image: rendered)
    }

    func saveAsync(image rendered: CGImage) async -> EditorSaveResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "HelloX-\(Self.dateFormatter.string(from: Date())).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        let format: ImageExportFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        do {
            try await ImageExporter.writeAsync(rendered, to: url, format: format)
            dirty = false
            return .saved
        } catch {
            appModel.lastError = error.localizedDescription
            return .failed
        }
    }

    private func imageForOutput() throws -> CGImage { try originalSelectionImage() }

    /// Keeps each OCR line in its original geometry while using the largest
    /// single font size that every translated line in a paragraph can contain.
    /// This preserves the screenshot's layout and prevents adjacent lines from
    /// looking arbitrarily larger or smaller after translation.
    private func makeImageTranslationBlocks(
        paragraphs: [RecognizedTextParagraph],
        translations: [UUID: String],
        appearances: [UUID: ImageTranslationAppearance],
        imageSize: CGSize
    ) -> [ImageTranslationBlock] {
        paragraphs.flatMap { paragraph in
            guard let translation = translations[paragraph.id] else { return [ImageTranslationBlock]() }
            let sourceBlocks = paragraph.blocks.sorted(by: VisionOCRService.readingOrder)
            let fragments = OCRParagraphLayout.distribute(translation, across: sourceBlocks)
            guard fragments.count == sourceBlocks.count else { return [ImageTranslationBlock]() }

            let sourceAppearances = sourceBlocks.map { appearances[$0.id] ?? .fallback }
            let preferredSize = sourceAppearances.map(\.fontSize).sorted()[sourceAppearances.count / 2]
            let sharedSize = zip(sourceBlocks, fragments).map { sourceBlock, fragment in
                ImageTranslationTextLayout.fittedFontSize(
                    for: fragment,
                    in: pixelRect(for: sourceBlock.boundingBox, imageSize: imageSize),
                    preferredSize: preferredSize
                )
            }.min() ?? preferredSize

            return zip(zip(sourceBlocks, fragments), sourceAppearances).map { pair, sourceAppearance in
                let (sourceBlock, fragment) = pair
                return ImageTranslationBlock(
                    id: sourceBlock.id,
                    text: fragment,
                    boundingBox: sourceBlock.boundingBox,
                    appearance: ImageTranslationAppearance(
                        fontSize: sharedSize,
                        foregroundColor: sourceAppearance.foregroundColor,
                        backgroundColor: sourceAppearance.backgroundColor,
                        lineCount: sourceAppearance.lineCount
                    )
                )
            }
        }
    }

    private func pixelRect(for boundingBox: CGRect, imageSize: CGSize) -> CGRect {
        let box = boundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGRect(
            x: box.minX * imageSize.width,
            y: (1 - box.maxY) * imageSize.height,
            width: box.width * imageSize.width,
            height: box.height * imageSize.height
        ).integral
    }

    private func applyImageTranslations(_ blocks: [ImageTranslationBlock]) {
        imageTranslationBlocks = blocks
        translatedText = blocks.map(\.text).joined(separator: "\n")
        isPerformingTranslation = false
        pendingImageTranslationRequest = nil
        dirty = true
    }

    private func applyCopyResult(_ result: PasteboardWriteResult) {
        switch result {
        case .success:
            exportError = nil
            exportMessage = "已复制到剪贴板"
            CopyFeedbackPresenter.shared.showSuccess()
        case .failure(let message):
            exportMessage = nil
            exportError = message
            appModel.lastError = message
            CopyFeedbackPresenter.shared.showFailure(message)
        }
    }

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
