import AppKit
import HelloXCore
import SwiftUI
@preconcurrency import Translation

struct OCRResultPayload: @unchecked Sendable {
    let image: CGImage
    let result: OCRResult
}

@MainActor
final class OCRResultWindowModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage = ""

    private let appModel: AppModel
    private var image: CGImage
    private var task: Task<Void, Never>?
    private var recognitionID = UUID()

    init(image: CGImage, payload: OCRResultPayload? = nil, appModel: AppModel) {
        self.image = image
        self.appModel = appModel
        if let payload {
            text = payload.result.text
        } else {
            recognize()
        }
    }

    func update(image: CGImage, payload: OCRResultPayload? = nil) {
        task?.cancel()
        recognitionID = UUID()
        self.image = image
        text = payload?.result.text ?? ""
        errorMessage = ""
        isLoading = false
        if payload == nil { recognize() }
    }

    func recognize() {
        task?.cancel()
        let recognitionID = UUID()
        self.recognitionID = recognitionID
        text = ""
        errorMessage = ""
        isLoading = true
        let image = image
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.recognitionID == recognitionID { self.isLoading = false }
            }
            do {
                let result = try await appModel.ocrService.recognizeText(in: image)
                try Task.checkCancellation()
                guard self.recognitionID == recognitionID else { return }
                text = result.text
            } catch is CancellationError {
            } catch {
                guard self.recognitionID == recognitionID else { return }
                errorMessage = Self.message(for: error)
            }
        }
    }

    func copyAll() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            errorMessage = "无法写入系统剪贴板。"
            CopyFeedbackPresenter.shared.showFailure()
            return
        }
        CopyFeedbackPresenter.shared.showSuccess("识别文字已复制")
    }

    func saveTXT() {
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "HelloX-OCR.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

@MainActor
final class OCRResultWindowController: NSWindowController, NSWindowDelegate {
    let model: OCRResultWindowModel
    var onClose: (() -> Void)?

    init(image: CGImage, payload: OCRResultPayload? = nil, appModel: AppModel) {
        model = OCRResultWindowModel(image: image, payload: payload, appModel: appModel)
        let window = HelloXWindowFactory.make(title: "HelloX 文字识别", size: NSSize(width: 560, height: 620))
        window.contentViewController = NSHostingController(rootView: OCRResultWindowView(model: model))
        window.setContentSize(NSSize(width: 560, height: 620))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: CGImage, payload: OCRResultPayload? = nil) {
        model.update(image: image, payload: payload)
        present()
    }

    func present() { HelloXWindowFactory.present(self) }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor
enum TranslationWindowContext {
    case manual
    case screenshot(CGImage)
    case selectedText(SelectedTextContext)

    var title: String {
        switch self {
        case .manual: "HelloX 文本翻译"
        case .screenshot: "HelloX 截图翻译"
        case .selectedText: "HelloX 划词翻译"
        }
    }

}

struct TranslationModelOutput: Identifiable, Equatable, Sendable {
    static let offlineID = UUID(uuidString: "0FF11E00-0000-4000-8000-000000000001")!

    let id: UUID
    let profileName: String
    let isOffline: Bool
    var translatedText = ""
    var errorMessage = ""
    var isLoading = false

    init(
        id: UUID,
        profileName: String,
        isOffline: Bool = false,
        translatedText: String = "",
        errorMessage: String = "",
        isLoading: Bool = false
    ) {
        self.id = id
        self.profileName = profileName
        self.isOffline = isOffline
        self.translatedText = translatedText
        self.errorMessage = errorMessage
        self.isLoading = isLoading
    }
}

private struct TranslationJob: Sendable {
    let profileID: UUID
    let provider: any TranslationProvider
}

private struct TranslationCompletion: Sendable {
    let profileID: UUID
    let translatedText: String?
    let errorMessage: String?
}

private struct OfflineTranslationRequest: Sendable {
    let id: UUID
    let operationID: UUID
    let text: String
    let sourceLanguageIdentifier: String?
    let targetLanguageIdentifier: String
}

@MainActor
final class TranslationWindowModel: ObservableObject {
    @Published private(set) var errorMessage = ""
    @Published private(set) var isLoadingOCR = false
    @Published private(set) var ocrPayload: OCRResultPayload?
    @Published private(set) var outputs: [TranslationModelOutput] = []
    @Published var sourceText = ""
    @Published var sourceLanguage: SupportedLanguage = .auto
    @Published var targetLanguage: SupportedLanguage = .simplifiedChinese
    @Published private(set) var offlineTranslationConfiguration: TranslationSession.Configuration?

    private(set) var context: TranslationWindowContext
    private let appModel: AppModel
    private let providerBuilder: (TranslationRequest, UUID) throws -> any TranslationProvider
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private(set) var offlineRequestID = UUID()
    private var offlineRequest: OfflineTranslationRequest?
    var onOpenOCR: ((OCRResultPayload) -> Void)?

    init(
        context: TranslationWindowContext,
        appModel: AppModel,
        providerBuilder: ((TranslationRequest, UUID) throws -> any TranslationProvider)? = nil
    ) {
        self.context = context
        self.appModel = appModel
        self.providerBuilder = providerBuilder ?? { request, profileID in
            try appModel.provider(for: request, profileID: profileID)
        }
        resetOutputs()
        apply(context)
    }

    var title: String { context.title }
    var profiles: [TranslationProfile] { appModel.enabledTranslationProfiles }
    var isOfflineTranslationEnabled: Bool { appModel.isOfflineTranslationEnabled }
    var modeTitle: String {
        switch context {
        case .manual: "文本翻译"
        case .screenshot: "截图翻译"
        case .selectedText: "划词翻译"
        }
    }
    var isScreenshot: Bool {
        if case .screenshot = context { return true }
        return false
    }
    var isLoadingTranslation: Bool { outputs.contains(where: \.isLoading) }
    var enabledModelCount: Int { profiles.count + (isOfflineTranslationEnabled ? 1 : 0) }

    func update(context: TranslationWindowContext) {
        task?.cancel()
        operationID = UUID()
        self.context = context
        sourceText = ""
        errorMessage = ""
        ocrPayload = nil
        isLoadingOCR = false
        resetOutputs()
        apply(context)
    }

    func retry() {
        switch context {
        case .screenshot where sourceText.isEmpty: runScreenshotPipeline()
        case .manual, .screenshot, .selectedText: translate()
        }
    }

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = HelloXError.noTextFound.localizedDescription
            return
        }
        let operationID = beginOperation()
        startTranslations(text: text, operationID: operationID)
    }

    func openOCR() {
        guard let ocrPayload else { return }
        onOpenOCR?(ocrPayload)
    }

    func copySource() {
        copyToPasteboard(sourceText, successMessage: "原文已复制")
    }

    func clearSource() {
        task?.cancel()
        operationID = UUID()
        offlineRequest = nil
        offlineTranslationConfiguration = nil
        sourceText = ""
        errorMessage = ""
        isLoadingOCR = false
        resetOutputs()
    }

    func copyTranslation(outputID: UUID) {
        guard let text = outputs.first(where: { $0.id == outputID })?.translatedText else { return }
        copyToPasteboard(text, successMessage: "译文已复制")
    }

    fileprivate func offlineTranslationRequest(for requestID: UUID) -> OfflineTranslationRequest? {
        guard offlineRequest?.id == requestID,
              offlineRequest?.operationID == operationID else { return nil }
        return offlineRequest
    }

    func completeOfflineTranslation(
        requestID: UUID,
        operationID: UUID,
        translatedText: String?,
        errorMessage: String?
    ) {
        guard offlineRequest?.id == requestID,
              offlineRequest?.operationID == operationID,
              self.operationID == operationID else { return }
        updateOutput(
            profileID: TranslationModelOutput.offlineID,
            translatedText: translatedText,
            errorMessage: errorMessage
        )
    }

    private func copyToPasteboard(_ text: String, successMessage: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            errorMessage = "无法写入系统剪贴板。"
            CopyFeedbackPresenter.shared.showFailure()
            return
        }
        CopyFeedbackPresenter.shared.showSuccess(successMessage)
    }

    private func apply(_ context: TranslationWindowContext) {
        switch context {
        case .manual:
            sourceLanguage = .auto
            targetLanguage = .simplifiedChinese
        case .screenshot:
            sourceLanguage = .auto
            targetLanguage = .simplifiedChinese
            runScreenshotPipeline()
        case .selectedText(let selected):
            sourceText = selected.text
            sourceLanguage = selected.detectedLanguage ?? .auto
            targetLanguage = selected.detectedLanguage == .simplifiedChinese || selected.detectedLanguage == .traditionalChinese
                ? .english
                : .simplifiedChinese
            translate()
        }
    }

    private func runScreenshotPipeline() {
        guard case .screenshot(let image) = context else { return }
        let operationID = beginOperation()
        sourceText = ""
        errorMessage = ""
        ocrPayload = nil
        isLoadingOCR = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await appModel.ocrService.recognizeText(in: image)
                try Task.checkCancellation()
                guard self.operationID == operationID else { return }
                sourceText = result.text
                ocrPayload = OCRResultPayload(image: image, result: result)
                if sourceLanguage == .auto,
                   let detected = result.language.flatMap(SupportedLanguage.init(rawValue:)) {
                    sourceLanguage = detected
                    if targetLanguage == detected {
                        targetLanguage = detected == .simplifiedChinese || detected == .traditionalChinese
                            ? .english
                            : .simplifiedChinese
                    }
                }
                isLoadingOCR = false
                startTranslations(text: result.text, operationID: operationID)
            } catch is CancellationError {
            } catch {
                guard self.operationID == operationID else { return }
                isLoadingOCR = false
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func startTranslations(text: String, operationID: UUID) {
        guard self.operationID == operationID else { return }
        let profiles = profiles
        guard isOfflineTranslationEnabled || !profiles.isEmpty else {
            errorMessage = "请启用至少一个翻译服务。"
            outputs = []
            return
        }
        let allowsCloudTranslation = profiles.isEmpty || confirmCloudTranslationIfNeeded(profiles: profiles)
        errorMessage = ""
        let offlineOutputs = isOfflineTranslationEnabled ? [Self.offlineOutput(isLoading: true)] : []
        outputs = offlineOutputs + profiles.map {
            TranslationModelOutput(
                id: $0.id,
                profileName: $0.name,
                errorMessage: allowsCloudTranslation ? "" : "已取消发送到云端。",
                isLoading: allowsCloudTranslation
            )
        }
        let request = TranslationRequest(text: text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        if isOfflineTranslationEnabled {
            requestOfflineTranslation(text: text, operationID: operationID)
        } else {
            offlineRequest = nil
            offlineTranslationConfiguration = nil
        }
        var jobs: [TranslationJob] = []
        for profile in profiles where allowsCloudTranslation {
            do {
                jobs.append(TranslationJob(
                    profileID: profile.id,
                    provider: try providerBuilder(request, profile.id)
                ))
            } catch {
                updateOutput(profileID: profile.id, translatedText: nil, errorMessage: Self.message(for: error))
            }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: TranslationCompletion.self) { group in
                for job in jobs {
                    group.addTask {
                        do {
                            let result = try await job.provider.translate(request)
                            return TranslationCompletion(
                                profileID: job.profileID,
                                translatedText: result.text,
                                errorMessage: nil
                            )
                        } catch {
                            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            return TranslationCompletion(
                                profileID: job.profileID,
                                translatedText: nil,
                                errorMessage: message
                            )
                        }
                    }
                }
                for await completion in group {
                    guard !Task.isCancelled, self.operationID == operationID else { return }
                    self.updateOutput(
                        profileID: completion.profileID,
                        translatedText: completion.translatedText,
                        errorMessage: completion.errorMessage
                    )
                }
            }
        }
    }

    private func beginOperation() -> UUID {
        task?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        isLoadingOCR = false
        errorMessage = ""
        resetOutputs()
        return operationID
    }

    private func resetOutputs() {
        let offlineOutputs = isOfflineTranslationEnabled ? [Self.offlineOutput()] : []
        outputs = offlineOutputs + profiles.map {
            TranslationModelOutput(id: $0.id, profileName: $0.name)
        }
    }

    private static func offlineOutput(isLoading: Bool = false) -> TranslationModelOutput {
        TranslationModelOutput(
            id: TranslationModelOutput.offlineID,
            profileName: "离线翻译",
            isOffline: true,
            isLoading: isLoading
        )
    }

    private func requestOfflineTranslation(text: String, operationID: UUID) {
        let requestID = UUID()
        offlineRequestID = requestID
        offlineRequest = OfflineTranslationRequest(
            id: requestID,
            operationID: operationID,
            text: text,
            sourceLanguageIdentifier: sourceLanguage.systemLanguageIdentifier,
            targetLanguageIdentifier: targetLanguage.systemLanguageIdentifier ?? targetLanguage.rawValue
        )
        let source = sourceLanguage.systemLanguageIdentifier.map(Locale.Language.init(identifier:))
        let target = Locale.Language(identifier: targetLanguage.systemLanguageIdentifier ?? targetLanguage.rawValue)
        if var configuration = offlineTranslationConfiguration,
           configuration.source == source,
           configuration.target == target {
            configuration.invalidate()
            offlineTranslationConfiguration = configuration
        } else {
            offlineTranslationConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func updateOutput(profileID: UUID, translatedText: String?, errorMessage: String?) {
        guard let index = outputs.firstIndex(where: { $0.id == profileID }) else { return }
        outputs[index].isLoading = false
        outputs[index].translatedText = translatedText ?? ""
        outputs[index].errorMessage = errorMessage ?? ""
    }

    private func confirmCloudTranslationIfNeeded(profiles: [TranslationProfile]) -> Bool {
        let key = "did-confirm-cloud-text-translation"
        guard !UserDefaults.standard.bool(forKey: key) else { return true }
        let alert = NSAlert()
        alert.messageText = "允许发送文字？"
        let modelNames = profiles.map(\.name).joined(separator: "、")
        alert.informativeText = "HelloX 会将原文同时发送给已启用的模型（\(modelNames)）并展示各自译文。截图翻译只发送 OCR 文字，不上传截图。"
        alert.addButton(withTitle: "允许并继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    nonisolated private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    nonisolated static func offlineMessage(for error: Error) -> String {
        if error as? HelloXError == .languageNotSupported {
            return "系统离线翻译暂不支持所选语言组合。"
        }
        let detail = message(for: error)
        return detail.isEmpty ? "离线翻译失败，请重试。" : detail
    }
}

@MainActor
final class TranslationWindowController: NSWindowController, NSWindowDelegate {
    let model: TranslationWindowModel
    var onClose: (() -> Void)?

    init(context: TranslationWindowContext, appModel: AppModel, onOpenOCR: @escaping (OCRResultPayload) -> Void) {
        model = TranslationWindowModel(context: context, appModel: appModel)
        model.onOpenOCR = onOpenOCR
        let window = HelloXWindowFactory.make(title: context.title, size: NSSize(width: 760, height: 780), level: .normal)
        window.contentViewController = NSHostingController(rootView: TranslationWindowView(model: model))
        window.setContentSize(NSSize(width: 760, height: 780))
        window.minSize = NSSize(width: 640, height: 600)
        super.init(window: window)
        window.delegate = self
        position(window, context: context)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(context: TranslationWindowContext) {
        model.update(context: context)
        window?.title = context.title
        if let window { position(window, context: context) }
        present()
    }

    func present() { HelloXWindowFactory.present(self, alwaysOnTop: false) }
    func windowWillClose(_ notification: Notification) { onClose?() }

    private func position(_ window: NSWindow, context: TranslationWindowContext) {
        guard case .selectedText(let selected) = context, let rect = selected.anchorRect else {
            window.center()
            return
        }
        let appKitBounds = CoordinateMapper.union(NSScreen.screens.map(\.frame))
        let converted = CoordinateMapper.coreGraphicsToAppKit(
            rect,
            appKitDesktopBounds: appKitBounds,
            coreGraphicsDesktopBounds: Self.coreGraphicsDesktopBounds()
        )
        let visible = (NSScreen.screens.first { $0.frame.intersects(converted) } ?? NSScreen.main)?.visibleFrame ?? appKitBounds
        let proposed = CGPoint(x: converted.minX, y: converted.minY - window.frame.height - 12)
        window.setFrameOrigin(CGPoint(
            x: min(max(visible.minX, proposed.x), visible.maxX - window.frame.width),
            y: min(max(visible.minY, proposed.y), visible.maxY - window.frame.height)
        ))
    }

    private static func coreGraphicsDesktopBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CoordinateMapper.union(NSScreen.screens.map(\.frame))
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return CoordinateMapper.union(NSScreen.screens.map(\.frame))
        }
        return CoordinateMapper.union(displays.map(CGDisplayBounds))
    }
}

@MainActor
private enum HelloXWindowFactory {
    static func make(title: String, size: NSSize, level: NSWindow.Level = .floating) -> NSWindow {
        let window = HelloXWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 380)
        HelloXWindowStyle.apply(to: window, movableByBackground: false)
        return window
    }

    static func present(_ controller: NSWindowController, alwaysOnTop: Bool = true) {
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.level = alwaysOnTop ? .floating : .normal
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
    }
}

private struct OCRResultWindowView: View {
    @ObservedObject var model: OCRResultWindowModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("识别结果").font(.system(size: 15, weight: .bold))
                    Text("当前截图选区")
                        .font(.system(size: 10.5))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                Spacer()
                HelloXIconButton(icon: .copy, help: "复制全部", action: model.copyAll)
                    .disabled(model.text.isEmpty)
                HelloXIconButton(icon: .save, help: "保存 TXT", action: model.saveTXT)
                    .disabled(model.text.isEmpty)
                HelloXIconButton(icon: .textRecognition, help: "重新识别", action: model.recognize)
                    .disabled(model.isLoading)
            }
            if model.isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在识别…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.errorMessage.isEmpty {
                VStack(spacing: 12) {
                    HelloXStatusBanner(message: model.errorMessage, kind: .error)
                    HelloXIconButton(icon: .update, help: "重试", role: .accent, action: model.recognize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Text("识别到 \(model.text.count) 个字符")
                        Spacer()
                        Text("可选择并复制")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 9))

                    ScrollView {
                        Text(model.text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                    .scrollIndicators(.visible)
                    .scrollContentBackground(.hidden)
                    .visibleScrollChrome()
                    .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius).stroke(HelloXTheme.border(for: colorScheme)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .background(HelloXGlowBackground().ignoresSafeArea())
        .tint(HelloXTheme.accent)
    }
}

private struct TranslationWindowView: View {
    @ObservedObject var model: TranslationWindowModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSourceEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    sourceCard
                    if !model.errorMessage.isEmpty {
                        HelloXStatusBanner(message: model.errorMessage, kind: .error)
                    }
                    resultsSection
                }
                .padding(22)
            }
            .scrollIndicators(.visible)
            .scrollContentBackground(.hidden)
            .visibleScrollChrome()
        }
        .background(HelloXGlowBackground().ignoresSafeArea())
        .tint(HelloXTheme.accent)
        .translationTask(model.offlineTranslationConfiguration) { session in
            let requestID = model.offlineRequestID
            guard let request = model.offlineTranslationRequest(for: requestID) else { return }
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
                guard status != .unsupported else {
                    throw HelloXError.languageNotSupported
                }
                if status == .supported {
                    try await session.prepareTranslation()
                }
                let response = try await session.translate(request.text)
                try Task.checkCancellation()
                model.completeOfflineTranslation(
                    requestID: request.id,
                    operationID: request.operationID,
                    translatedText: response.targetText,
                    errorMessage: nil
                )
            } catch is CancellationError {
            } catch {
                let message = TranslationWindowModel.offlineMessage(for: error)
                model.completeOfflineTranslation(
                    requestID: request.id,
                    operationID: request.operationID,
                    translatedText: nil,
                    errorMessage: message
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            HelloXRowIcon(icon: .translation, size: 42)
            Text(model.modeTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.enabledModelCount > 0 ? HelloXTheme.success : HelloXTheme.warning)
                    .frame(width: 7, height: 7)
                Text("\(model.enabledModelCount) 个模型")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(HelloXTheme.controlBackground(for: colorScheme), in: Capsule())
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .background(HelloXTheme.surface(for: colorScheme).opacity(0.92))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            languagePicker(title: "源语言", selection: $model.sourceLanguage, includesAuto: true)
            HelloXIcon(icon: .arrowRight, size: 15)
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            languagePicker(title: "目标语言", selection: $model.targetLanguage, includesAuto: false)
            Spacer(minLength: 12)
            Button(action: model.translate) {
                HStack(spacing: 8) {
                    if model.isLoadingTranslation {
                        ProgressView().controlSize(.small)
                    } else {
                        HelloXIcon(icon: .translation, size: 16)
                    }
                    Text(model.isLoadingTranslation ? "翻译中" : "全部翻译")
                }
            }
            .buttonStyle(HelloXButtonStyle(role: .accent))
            .disabled(
                model.isLoadingOCR ||
                model.isLoadingTranslation ||
                model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(14)
        .background(HelloXTheme.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius).stroke(HelloXTheme.border(for: colorScheme)))
    }

    private func languagePicker(
        title: String,
        selection: Binding<SupportedLanguage>,
        includesAuto: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            HelloXLanguagePicker(
                title: title,
                selection: selection,
                includesAuto: includesAuto
            )
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("原文")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.sourceText.count) 字")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                if model.isScreenshot {
                    HelloXIconButton(icon: .textRecognition, help: "查看 OCR 识别结果", size: 34, iconSize: 15, action: model.openOCR)
                        .disabled(model.ocrPayload == nil)
                }
                HelloXIconButton(icon: .copy, help: "复制原文", size: 34, iconSize: 15, action: model.copySource)
                    .disabled(model.sourceText.isEmpty)
                HelloXIconButton(icon: .close, help: "清空原文", role: .destructive, size: 34, iconSize: 15, action: model.clearSource)
                    .disabled(model.sourceText.isEmpty)
            }

            ZStack(alignment: .topLeading) {
                if model.sourceText.isEmpty && !model.isLoadingOCR && !isSourceEditorFocused {
                    Text("输入或粘贴需要翻译的文字…")
                        .font(.system(size: 13))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme).opacity(0.72))
                        .padding(7)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.sourceText)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .padding(7)
                    .scrollContentBackground(.hidden)
                    .visibleScrollChrome()
                    .background(Color.clear)
                    .focused($isSourceEditorFocused)
                    .disabled(model.isLoadingOCR)
            }
            .frame(minHeight: 150, maxHeight: 210)
            .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HelloXTheme.controlRadius).stroke(HelloXTheme.border(for: colorScheme)))
        }
        .padding(16)
        .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius).stroke(HelloXTheme.border(for: colorScheme)))
        .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 9, y: 4)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("翻译结果")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }

            ForEach(model.outputs) { output in
                outputCard(output)
            }
        }
    }

    private func outputCard(_ output: TranslationModelOutput) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                HelloXRowIcon(icon: output.isOffline ? .translation : .cloud, size: 32)
                Text(output.profileName)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                outputStatus(output)
                HelloXIconButton(
                    icon: .copy,
                    help: "复制 \(output.profileName) 的译文",
                    size: 34,
                    iconSize: 15,
                    action: { model.copyTranslation(outputID: output.id) }
                )
                .disabled(output.translatedText.isEmpty)
            }

            if output.isLoading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在生成译文…")
                        .font(.system(size: 11))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                .frame(minHeight: 58)
            } else if !output.errorMessage.isEmpty {
                HelloXStatusBanner(message: output.errorMessage, kind: .error)
            } else {
                Text(output.translatedText.isEmpty ? "等待翻译" : output.translatedText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(
                        output.translatedText.isEmpty
                            ? HelloXTheme.secondaryText(for: colorScheme)
                            : HelloXTheme.primaryText(for: colorScheme)
                    )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            }
        }
        .padding(15)
        .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius).stroke(HelloXTheme.border(for: colorScheme)))
    }

    @ViewBuilder
    private func outputStatus(_ output: TranslationModelOutput) -> some View {
        let color: Color = output.isLoading
            ? HelloXTheme.accent
            : (!output.errorMessage.isEmpty ? HelloXTheme.error : (!output.translatedText.isEmpty ? HelloXTheme.success : HelloXTheme.secondaryText(for: colorScheme)))
        let title = output.isLoading
            ? "翻译中"
            : (!output.errorMessage.isEmpty ? "失败" : (!output.translatedText.isEmpty ? "已完成" : "等待中"))
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(color.opacity(0.10), in: Capsule())
    }
}
