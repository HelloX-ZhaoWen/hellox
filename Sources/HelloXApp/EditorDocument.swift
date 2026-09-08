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

struct ScreenshotTranslationRequest: Identifiable {
    let id: UUID
    let paragraphs: [RecognizedTextParagraph]
    let sourceLanguageIdentifier: String?
    let targetLanguageIdentifier: String
}

@MainActor
final class EditorDocument: ObservableObject {
    @Published var image: CGImage
    @Published var annotations: [Annotation] = []
    @Published var ocrResult: OCRResult?
    @Published private(set) var screenshotTranslationBlocks: [ScreenshotTranslationBlock] = []
    @Published private(set) var screenshotTranslationBackgroundImage: CGImage?
    @Published private(set) var pendingScreenshotTranslationRequest: ScreenshotTranslationRequest?
    @Published var showsScreenshotTranslation = true
    @Published private(set) var screenshotTranslationError: String?
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
    private var screenshotTranslationTask: Task<Void, Never>?
    private var screenshotTranslationOperationID: UUID?

    init(result: CaptureResult, appModel: AppModel, outputCrop: CGRect? = nil) {
        self.image = result.image
        self.displayScale = result.displayScale
        self.appModel = appModel
        self.outputCrop = outputCrop
    }

    var isOfflineTranslationEnabled: Bool { appModel.isOfflineTranslationEnabled }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var hasScreenshotTranslation: Bool {
        screenshotTranslationBackgroundImage != nil || !screenshotTranslationBlocks.isEmpty
    }

    var isScreenshotTranslationSelectionLocked: Bool {
        ScreenshotTranslationInteractionPolicy.locksSelection(
            hasTranslationBlocks: hasScreenshotTranslation,
            hasReconstructedBackground: screenshotTranslationBackgroundImage != nil
        )
    }

    func add(_ annotation: Annotation) {
        pushUndo()
        annotations.append(annotation)
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
        clearScreenshotTranslation()
        self.cropSelection = nil
        dirty = true
    }

    func runOCR() {
        guard !isPerformingOCR else { return }
        isPerformingOCR = true
        Task { @MainActor in
            defer { isPerformingOCR = false }
            do { ocrResult = try await appModel.ocrService.recognizeText(in: try originalSelectionImage()) }
            catch { appModel.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    /// Runs local OCR, then translates recognized paragraphs with the selected text
    /// provider or Apple's on-device Translation framework before redrawing them locally.
    func translateScreenshot() {
        guard !isPerformingOCR, !isPerformingTranslation else { return }
        clearScreenshotTranslation()
        let operationID = UUID()
        screenshotTranslationOperationID = operationID
        isPerformingOCR = true
        isPerformingTranslation = true
        showsScreenshotTranslation = true
        screenshotTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sourceImage = try originalSelectionImage()
                let target = appModel.screenshotTranslationTargetLanguage
                let recognized = try await appModel.ocrService.recognizeText(in: sourceImage)
                try Task.checkCancellation()
                guard screenshotTranslationOperationID == operationID else { return }
                guard !recognized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HelloXError.noTextFound
                }
                ocrResult = recognized
                isPerformingOCR = false
                let imageSize = CGSize(width: sourceImage.width, height: sourceImage.height)
                let translatableBlocks = ScreenshotTranslationContentPolicy.translatableContents(
                    from: recognized.blocks,
                    imageSize: imageSize
                )
                let paragraphs = OCRParagraphLayout.paragraphs(from: translatableBlocks)
                guard !paragraphs.isEmpty else { throw HelloXError.noTextFound }
                let source = recognized.language.flatMap(SupportedLanguage.init(rawValue:)) ?? .auto
                let request = ScreenshotTranslationRequest(
                    id: operationID,
                    paragraphs: paragraphs,
                    sourceLanguageIdentifier: source.systemLanguageIdentifier,
                    targetLanguageIdentifier: target.systemLanguageIdentifier ?? target.rawValue
                )
                if source.isSameLanguage(as: target) {
                    finishScreenshotTranslation(
                        request: request,
                        translations: Dictionary(uniqueKeysWithValues: paragraphs.map {
                            ($0.id, ScreenshotTranslationContentPolicy.textForTranslation($0.text))
                        })
                    )
                    return
                }
                if !appModel.enabledTranslationProfiles.isEmpty {
                    do {
                        try await translateScreenshotUsingCloud(
                            request: request,
                            source: source,
                            target: target
                        )
                    } catch HelloXError.rateLimited where appModel.isOfflineTranslationEnabled {
                        guard screenshotTranslationOperationID == operationID else { return }
                        pendingScreenshotTranslationRequest = request
                        screenshotTranslationTask = nil
                    }
                } else if appModel.isOfflineTranslationEnabled {
                    guard screenshotTranslationOperationID == operationID else { return }
                    pendingScreenshotTranslationRequest = request
                    screenshotTranslationTask = nil
                } else {
                    throw HelloXError.invalidConfiguration("请配置一个云端翻译服务，或启用离线翻译")
                }
            } catch is CancellationError {
                guard screenshotTranslationOperationID == operationID else { return }
                screenshotTranslationTask = nil
                screenshotTranslationOperationID = nil
                isPerformingOCR = false
                isPerformingTranslation = false
            } catch {
                failScreenshotTranslation(error, operationID: operationID)
            }
        }
    }

    func completeOfflineScreenshotTranslation(
        requestID: UUID,
        translations: [UUID: String]?,
        errorMessage: String?
    ) {
        guard let request = pendingScreenshotTranslationRequest,
              request.id == requestID,
              screenshotTranslationOperationID == requestID else { return }
        pendingScreenshotTranslationRequest = nil
        guard let translations else {
            failScreenshotTranslation(
                HelloXError.captureFailed(errorMessage ?? "离线翻译失败"),
                operationID: requestID
            )
            return
        }
        finishScreenshotTranslation(request: request, translations: translations)
    }

    func clearScreenshotTranslation() {
        screenshotTranslationOperationID = nil
        screenshotTranslationTask?.cancel()
        screenshotTranslationTask = nil
        pendingScreenshotTranslationRequest = nil
        screenshotTranslationBlocks.removeAll()
        screenshotTranslationBackgroundImage = nil
        screenshotTranslationError = nil
        showsScreenshotTranslation = true
        isPerformingOCR = false
        isPerformingTranslation = false
    }

    func toggleScreenshotTranslation() {
        guard hasScreenshotTranslation else {
            translateScreenshot()
            return
        }
        showsScreenshotTranslation.toggle()
    }

    private func translateScreenshotUsingCloud(
        request: ScreenshotTranslationRequest,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws {
        guard appModel.defaultTextTranslationProfile != nil else {
            throw HelloXError.invalidConfiguration("请启用离线翻译，或配置一个云端翻译服务")
        }
        guard confirmCloudScreenshotTranslationIfNeeded() else {
            throw HelloXError.cancelled
        }
        let paragraphTexts = request.paragraphs.map {
            (
                id: $0.id,
                text: ScreenshotTranslationContentPolicy.textForTranslation($0.text)
            )
        }
        let batches = try ScreenshotTranslationBatchCodec.batches(for: paragraphTexts)
        guard let firstBatch = batches.first else { throw HelloXError.noTextFound }
        let seedRequest = TranslationRequest(
            text: firstBatch.text,
            sourceLanguage: source,
            targetLanguage: target,
            purpose: .screenshotBatch
        )
        let provider = try appModel.provider(for: seedRequest)
        var translations: [UUID: String] = [:]
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            if index > 0 {
                // Keep long screenshots below the common one-request-per-second
                // threshold used by entry-level machine translation plans.
                try await Task.sleep(nanoseconds: 1_100_000_000)
            }
            do {
                let result = try await provider.translate(TranslationRequest(
                    text: batch.text,
                    sourceLanguage: source,
                    targetLanguage: target,
                    purpose: .screenshotBatch
                ))
                translations.merge(
                    try ScreenshotTranslationBatchCodec.translations(
                        from: result.text,
                        for: batch
                    ),
                    uniquingKeysWith: { _, latest in latest }
                )
            } catch {
                let isUnparseableResponse = (error as? HelloXError) == .invalidResponse
                    || error is DecodingError
                guard batch.paragraphs.count > 1, isUnparseableResponse else { throw error }
                translations.merge(
                    try await translateScreenshotParagraphsIndividually(
                        batch.paragraphs,
                        provider: provider,
                        source: source,
                        target: target
                    ),
                    uniquingKeysWith: { _, latest in latest }
                )
            }
        }
        finishScreenshotTranslation(request: request, translations: translations)
    }

    /// Some traditional machine translation services rewrite or remove custom
    /// paragraph separators. Retry that batch one paragraph at a time, paced to
    /// stay under common entry-level QPS limits, instead of surfacing a parsing
    /// error to the user.
    private func translateScreenshotParagraphsIndividually(
        _ paragraphs: [ScreenshotTranslationBatch.Paragraph],
        provider: any TranslationProvider,
        source: SupportedLanguage,
        target: SupportedLanguage
    ) async throws -> [UUID: String] {
        var translations: [UUID: String] = [:]
        for paragraph in paragraphs {
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try Task.checkCancellation()
            let result = try await provider.translate(TranslationRequest(
                text: paragraph.protectedText.text,
                sourceLanguage: source,
                targetLanguage: target,
                purpose: .screenshotParagraph
            ))
            let text = paragraph.protectedText.restoring(in: result.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw HelloXError.invalidResponse }
            translations[paragraph.id] = text
        }
        return translations
    }

    private func finishScreenshotTranslation(
        request: ScreenshotTranslationRequest,
        translations: [UUID: String]
    ) {
        guard screenshotTranslationOperationID == request.id else { return }
        do {
            let sourceByID = Dictionary(uniqueKeysWithValues: request.paragraphs.map {
                ($0.id, $0.text)
            })
            let normalizedTranslations = Dictionary(uniqueKeysWithValues: translations.map { entry in
                (
                    entry.key,
                    ScreenshotTranslationOutputNormalizer.normalize(
                        entry.value,
                        sourceText: sourceByID[entry.key] ?? "",
                        targetLanguageIdentifier: request.targetLanguageIdentifier
                    )
                )
            })
            let sourceImage = try originalSelectionImage()
            let appearances = ScreenshotTranslationAppearanceExtractor.appearances(
                for: request.paragraphs.flatMap(\.blocks),
                in: sourceImage
            )
            let imageSize = CGSize(
                width: CGFloat(sourceImage.width),
                height: CGFloat(sourceImage.height)
            )
            let blocks = ScreenshotTranslationComposer.blocks(
                paragraphs: request.paragraphs,
                translations: normalizedTranslations,
                appearances: appearances,
                imageSize: imageSize
            )
            guard !blocks.isEmpty else { throw HelloXError.invalidResponse }
            let reconstructedBackground = try ScreenshotTranslationBackgroundReconstructor.eraseText(
                in: sourceImage,
                normalizedRegions: blocks.flatMap(\.backgroundRegions)
            )
            screenshotTranslationBackgroundImage = reconstructedBackground
            screenshotTranslationBlocks = blocks
            screenshotTranslationError = nil
            showsScreenshotTranslation = true
            isPerformingOCR = false
            isPerformingTranslation = false
            pendingScreenshotTranslationRequest = nil
            screenshotTranslationTask = nil
            screenshotTranslationOperationID = nil
            dirty = true
        } catch {
            failScreenshotTranslation(error, operationID: request.id)
        }
    }

    private func failScreenshotTranslation(_ error: Error, operationID: UUID) {
        guard screenshotTranslationOperationID == operationID else { return }
        screenshotTranslationTask = nil
        screenshotTranslationOperationID = nil
        isPerformingOCR = false
        isPerformingTranslation = false
        pendingScreenshotTranslationRequest = nil
        screenshotTranslationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func confirmCloudScreenshotTranslationIfNeeded() -> Bool {
        let key = "did-confirm-cloud-screenshot-translation"
        guard !UserDefaults.standard.bool(forKey: key) else { return true }
        guard let profile = appModel.defaultTextTranslationProfile else { return false }
        let alert = HelloXAlert()
        alert.messageText = "允许发送识别文字？"
        alert.informativeText = "HelloX 只会把本地 OCR 识别出的文字发送给“\(profile.name)”翻译，不会上传截图。"
        alert.addButton(withTitle: "允许并继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
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
            let translatedBackground = showsScreenshotTranslation
                ? screenshotTranslationBackgroundImage
                : nil
            return try AnnotationRenderer.renderOutput(
                baseImage: image,
                annotations: annotations,
                normalizedCrop: outputCrop,
                replacementBaseImage: translatedBackground,
                screenshotTranslationBlocks: showsScreenshotTranslation ? screenshotTranslationBlocks : []
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
