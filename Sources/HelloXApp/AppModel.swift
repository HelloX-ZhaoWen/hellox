import AppKit
import HelloXCore
import SwiftUI
import UniformTypeIdentifiers

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdate)
    case downloading
    case installing
    case failed(String)

    var message: String? {
        switch self {
        case .idle: nil
        case .checking: "正在检查更新…"
        case .upToDate: "当前已是最新版本"
        case .available(let update): "发现 HelloX \(update.version)"
        case .downloading: "正在下载更新…"
        case .installing: "正在验证并安装更新…"
        case .failed(let message): message
        }
    }
}

enum ScreenRecordingOutputNaming {
    static let filenamePrefix = "HELLOX录屏"

    static func destinationURL(
        in directory: URL,
        date: Date = Date(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = "\(filenamePrefix) \(formatter.string(from: date))"
        var destination = directory.appendingPathComponent("\(baseName).mp4")
        var suffix = 2
        while fileExists(destination.path) {
            destination = directory.appendingPathComponent("\(baseName) \(suffix).mp4")
            suffix += 1
        }
        return destination
    }
}

@MainActor
final class AppModel: ObservableObject {
    let permissions = PermissionService()
    let capturer = ScreenCaptureService()
    let ocrService = VisionOCRService()
    let selectionService = SystemTextSelectionService()

    @Published var lastError: String?
    @Published var isBusy = false
    @Published var isShowingSettings = false
    @Published var selectedMode: CaptureMode = .region
    @Published var mainDestination: SettingsDestination = .workbench
    @Published var translationProfiles: [TranslationProfile] = []
    @Published var defaultTranslationProfileID: UUID?
    @Published var isOfflineTranslationEnabled = true
    private var translationAPIKeys: [String: String] = [:]
    @Published var shortcutBindings = ShortcutPreferences.load()
    @Published var shortcutValidationMessage: String?
    @Published private(set) var shortcutConflictMessages: [ShortcutAction: String] = [:]
    @Published private(set) var updateState: UpdateState = .idle

    private var captureWindows: [NSWindowController] = []
    private var captureOverlays: [CaptureOverlayEditorController] = []
    private var pinnedWindows: [PinnedImageWindowController] = []
    private var selectionController: SelectionOverlayController?
    private var recordingController: ScreenRecordingControlWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var watermarkImportWindowController: WatermarkImportWindowController?
    private var utilityToolWindows: [UtilityTool: UtilityToolWindowController] = [:]
    private var ocrResultWindow: OCRResultWindowController?
    private var qrCodeResultWindow: QRCodeResultWindowController?
    private var translationWindow: TranslationWindowController?
    private var captureSessionActive = false
    private var lastExternalApplicationPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var permissionActivationObserver: NSObjectProtocol?
    private var promptedSemanticSelectionAccessibility = false
    var shortcutApplyHandler: (([ShortcutAction: ShortcutBinding]) -> Result<Void, ShortcutRegistrationError>)?
    var shortcutAvailabilityHandler: ((ShortcutAction, ShortcutBinding) -> ShortcutRegistrationError?)?
    private let updateClient = GitHubReleaseClient()

    init() {
        let profileState = TranslationProfilePreferences.loadOrMigrate(legacyKeychain: KeychainStore())
        translationProfiles = profileState.profiles
        defaultTranslationProfileID = profileState.defaultProfileID
        isOfflineTranslationEnabled = profileState.isOfflineTranslationEnabled
        translationAPIKeys = profileState.apiKeys
        normalizeDefaultTranslationProfile()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != ownPID {
            lastExternalApplicationPID = pid
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            Task { @MainActor in self?.lastExternalApplicationPID = app.processIdentifier }
        }
        permissionActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.permissions.refresh(returnedFromSettings: true) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.presentOnboardingIfNeeded()
        }
    }

    func startCapture(_ mode: CaptureMode) {
        guard beginCaptureSession() else { return }
        selectedMode = mode
        lastError = nil
        permissions.refresh()
        guard permissions.canRecordScreen else {
            endCaptureSession()
            presentScreenPermissionRecovery()
            return
        }
        let scrollProcessID = targetApplicationPID()
        Task { @MainActor in
            defer { endCaptureSession() }
            do {
                let result: CaptureResult
                switch mode {
                case .region, .scrolling:
                    let selectedDisplay = try await selectRegionAcrossDisplays()
                    showCaptureOverlay(
                        for: selectedDisplay.result,
                        imageFrame: selectedDisplay.frame,
                        selection: selectedDisplay.selection,
                        startsScrolling: mode == .scrolling,
                        scrollProcessID: scrollProcessID
                    )
                    return
                case .window:
                    result = try await capturer.captureWindow(excludingOwnApplication: false)
                case .fullScreen:
                    result = try await capturer.captureDisplay(excludingOwnApplication: false)
                }
                let frame = appKitRect(fromCoreGraphics: result.capturedRect)
                showCaptureOverlay(
                    for: result,
                    imageFrame: frame,
                    selection: frame,
                    scrollProcessID: scrollProcessID
                )
            } catch {
                dismissSelectionOverlay()
                if !(error is CancellationError), (error as? HelloXError) != .cancelled {
                    handleCaptureError(error)
                }
            }
        }
    }

    func startScreenRecording() {
        guard recordingController == nil else {
            NSSound.beep()
            return
        }
        guard beginCaptureSession() else { return }
        lastError = nil
        permissions.refresh()
        guard permissions.canRecordScreen else {
            endCaptureSession()
            presentScreenPermissionRecovery()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let selectedDisplay = try await selectRegionAcrossDisplays()
                dismissSelectionOverlay()
                let selection = selectedDisplay.selection
                let outputURL = try makeScreenRecordingOutputURL()
                let recorder = ScreenRecordingService()
                let controller = ScreenRecordingControlWindowController(
                    recorder: recorder,
                    selectionFrame: selection,
                    recordingRegion: coreGraphicsRect(fromAppKit: selection),
                    outputURL: outputURL
                )
                recordingController = controller
                recorder.onUnexpectedStop = { [weak self] error in
                    Task { @MainActor in
                        self?.recordingController?.failBecauseStreamStopped(error)
                    }
                }
                controller.onFinish = { [weak self] url in
                    guard let self else { return }
                    recordingController = nil
                    lastError = nil
                    CopyFeedbackPresenter.shared.showSuccess("录屏已保存：\(url.lastPathComponent)")
                }
                controller.onFailure = { [weak self] error in
                    guard let self else { return }
                    recordingController = nil
                    let message = error.localizedDescription
                    lastError = message
                    CopyFeedbackPresenter.shared.showFailure(message)
                    NSSound.beep()
                }
                controller.onCancel = { [weak self] in
                    self?.recordingController = nil
                }
                controller.present()
                endCaptureSession()
            } catch {
                recordingController = nil
                endCaptureSession()
                if !(error is CancellationError), (error as? HelloXError) != .cancelled {
                    handleCaptureError(error)
                    CopyFeedbackPresenter.shared.showFailure(error.localizedDescription)
                }
            }
        }
    }

    private func makeScreenRecordingOutputURL() throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ScreenRecordingOutputNaming.destinationURL(in: baseDirectory)
    }

    private func targetApplicationPID() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let current = NSWorkspace.shared.frontmostApplication?.processIdentifier, current != ownPID { return current }
        return lastExternalApplicationPID
    }

    private func screenScale(forAppKitRect rect: CGRect) -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.backingScaleFactor ?? 1
    }

    private func windowID(at point: CGPoint, processID: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows.first { item in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return false }
            return bounds.contains(point)
        }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    private func scrollWindowTarget(
        at point: CGPoint,
        fallbackProcessID: pid_t?
    ) -> (processID: pid_t, windowID: CGWindowID?)? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]],
           let match = windows.first(where: { item in
               guard let ownerPID = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                     ownerPID != ownPID,
                     (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                     let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any],
                     let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                   return false
               }
               return bounds.contains(point)
           }),
           let ownerPID = (match[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value {
            return (
                processID: ownerPID,
                windowID: (match[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            )
        }

        guard let fallbackProcessID, fallbackProcessID != ownPID else { return nil }
        return (
            processID: fallbackProcessID,
            windowID: windowID(at: point, processID: fallbackProcessID)
        )
    }

    func captureAndOCR() {
        captureTextFromScreen(runTranslation: false)
    }

    func captureAndTranslate() {
        captureTextFromScreen(runTranslation: true)
    }

    private func captureTextFromScreen(runTranslation: Bool) {
        guard beginCaptureSession() else { return }
        lastError = nil
        permissions.refresh()
        guard permissions.canRecordScreen else {
            endCaptureSession()
            presentScreenPermissionRecovery()
            return
        }
        Task { @MainActor in
            defer { endCaptureSession() }
            do {
                let selectedDisplay = try await selectRegionAcrossDisplays()
                showCaptureOverlay(
                    for: selectedDisplay.result,
                    imageFrame: selectedDisplay.frame,
                    selection: selectedDisplay.selection,
                    runOCR: !runTranslation,
                    runTranslation: runTranslation
                )
            } catch {
                if !(error is CancellationError), (error as? HelloXError) != .cancelled {
                    handleCaptureError(error)
                }
            }
        }
    }

    private func beginCaptureSession() -> Bool {
        guard !captureSessionActive, selectionController == nil, captureOverlays.isEmpty else {
            NSSound.beep()
            return false
        }
        captureSessionActive = true
        isBusy = true
        return true
    }

    private func endCaptureSession() {
        captureSessionActive = false
        isBusy = false
    }

    func translateSelectedText() {
        lastError = nil
        guard let processID = targetApplicationPID() else {
            presentSelectionTranslationError(
                SelectedTextError.targetUnavailable,
                processID: nil
            )
            return
        }
        translateSelectedText(from: processID)
    }

    func showTextTranslation() {
        lastError = nil
        showTranslation(.manual)
    }

    private func translateSelectedText(from processID: pid_t) {
        Task { @MainActor in
            do {
                let context: SelectedTextContext
                do {
                    context = try await selectionService.readSelection(
                        processID: processID,
                        allowClipboardFallback: UserDefaults.standard.bool(forKey: "did-allow-selection-clipboard-fallback")
                    )
                } catch SelectedTextError.clipboardFallbackRequired {
                    let alert = NSAlert()
                    alert.messageText = "允许临时使用剪贴板？"
                alert.informativeText = "当前应用无法直接提供选中文字。HelloX 可以临时模拟复制，读取文字后恢复原剪贴板内容。"
                    alert.addButton(withTitle: "允许")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    UserDefaults.standard.set(true, forKey: "did-allow-selection-clipboard-fallback")
                    context = try await selectionService.readSelection(processID: processID, allowClipboardFallback: true)
                }
                showSelectionTranslation(context)
            } catch {
                guard !Self.shouldSilentlyIgnoreSelectionTranslationError(error) else { return }
                presentSelectionTranslationError(error, processID: processID)
            }
        }
    }

    static func shouldSilentlyIgnoreSelectionTranslationError(_ error: Error) -> Bool {
        if case SelectedTextError.noSelection = error {
            return true
        }
        return false
    }

    private func presentSelectionTranslationError(_ error: Error, processID: pid_t?) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "划词翻译不可用"
        alert.informativeText = message
        if case SelectedTextError.accessibilityDenied = error {
            alert.addButton(withTitle: "授权辅助功能")
            alert.addButton(withTitle: "使用剪贴板兜底")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                requestAccessibilityPermission()
            case .alertSecondButtonReturn:
                UserDefaults.standard.set(true, forKey: "did-allow-selection-clipboard-fallback")
                if let processID { translateSelectedText(from: processID) }
            default: break
            }
            return
        }
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let processID { translateSelectedText(from: processID) }
        case .alertSecondButtonReturn:
            permissions.openAccessibilitySettings()
        default: break
        }
    }

    private func showSelectionTranslation(_ context: SelectedTextContext) {
        showTranslation(.selectedText(context))
    }

    func requestScreenPermission() {
        guard ensureInstalledForPermissions() else { return }
        if !permissions.requestScreenRecording() { permissions.openScreenRecordingSettings() }
    }

    func repairScreenPermission() {
        guard ensureInstalledForPermissions() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "修复 HelloX 屏幕录制授权？"
        alert.informativeText = "这只会清除 HelloX 自己的旧屏幕录制授权。随后请在系统提示或系统设置中重新允许，并重启 HelloX。"
        alert.addButton(withTitle: "重置并重新授权")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performScreenPermissionReset()
    }

    private func performScreenPermissionReset() {
        do {
            try resetTCC(service: "ScreenCapture")
            permissions.resetScreenPermissionFlow()
            if permissions.requestScreenRecording() {
                restartApplication()
            } else {
                permissions.openScreenRecordingSettings()
            }
        } catch {
            lastError = "无法重置屏幕录制授权：\(error.localizedDescription)"
        }
    }

    private func presentScreenPermissionRecovery() {
        guard ensureInstalledForPermissions() else { return }
        lastError = "当前运行版本没有可用的屏幕录制权限。请点击“修复授权”，重新允许后重启 HelloX。"
        showSettings()
    }

    func repairAccessibilityPermission() {
        guard ensureInstalledForPermissions() else { return }
        do {
            try resetTCC(service: "Accessibility")
            requestAccessibilityPermission()
        } catch {
            lastError = "无法重置辅助功能授权：\(error.localizedDescription)"
        }
    }

    func restartApplication() {
        guard !isRunningFromDiskImage else {
            _ = ensureInstalledForPermissions()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            lastError = "无法重新启动 HelloX：\(error.localizedDescription)"
        }
    }

    func showMainWindow() {
        mainDestination = .workbench
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: self)
        }
        settingsWindowController?.present()
    }

    func showSettings() {
        showMainWindow()
    }

    func showUtilityTool(_ tool: UtilityTool) {
        utilityToolController(for: tool).present()
    }

    func openDocuments(_ urls: [URL]) {
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
        let markdownURLs = urls.filter {
            markdownExtensions.contains($0.pathExtension.lowercased())
        }
        guard !markdownURLs.isEmpty else {
            CopyFeedbackPresenter.shared.showFailure("HelloX 当前可直接打开 Markdown 文档")
            return
        }
        utilityToolController(for: .markdown).openMarkdownDocuments(at: markdownURLs)
    }

    private func utilityToolController(for tool: UtilityTool) -> UtilityToolWindowController {
        let controller: UtilityToolWindowController
        if let existing = utilityToolWindows[tool] {
            controller = existing
        } else {
            controller = UtilityToolWindowController(tool: tool)
            utilityToolWindows[tool] = controller
        }
        return controller
    }

    func requestAccessibilityPermission() {
        guard ensureInstalledForPermissions() else { return }
        if !permissions.requestAccessibility() { permissions.openAccessibilitySettings() }
    }

    var isRunningFromDiskImage: Bool {
        let url = Bundle.main.bundleURL
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return url.path.hasPrefix("/Volumes/") && values?.volumeIsReadOnly == true
    }

    func revealRunningApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func ensureInstalledForPermissions() -> Bool {
        guard isRunningFromDiskImage else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "请先安装 HelloX"
        alert.informativeText = "当前正在从只读安装镜像运行。macOS 无法为这个临时副本稳定保存屏幕录制和辅助功能权限。请安装 HelloX，退出当前副本，再从“应用程序”中打开。"
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { revealRunningApplication() }
        return false
    }

    private func resetTCC(service: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.hellox.app"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "tccutil 返回错误"
            throw HelloXError.captureFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func handleCaptureError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        if (error as? HelloXError) == .screenRecordingPermissionDenied {
            permissions.markScreenCaptureFailure(message)
        } else if let shotError = error as? HelloXError, case .captureFailed = shotError {
            permissions.markScreenCaptureFailure(message)
        }
    }

    func selectRegion(
        allowedRect: CGRect? = nil,
        frozenImage: CGImage? = nil,
        frozenDisplays: [SelectionFrozenDisplay] = [],
        rendersFrozenBackdrop: Bool = true,
        preservesOverlayUntilHandoff: Bool = false,
        prefersDisplayTargetForClick: Bool = false
    ) async throws -> CGRect {
        promptForSemanticSelectionAccessibilityIfNeeded()
        return try await withCheckedThrowingContinuation { continuation in
            let controller = SelectionOverlayController(
                allowedRect: allowedRect,
                frozenImage: frozenImage,
                frozenDisplays: frozenDisplays,
                rendersFrozenBackdrop: rendersFrozenBackdrop,
                preservesSuccessfulSelectionForHandoff: preservesOverlayUntilHandoff,
                prefersDisplayTargetForClick: prefersDisplayTargetForClick
            ) { result in
                if !preservesOverlayUntilHandoff {
                    self.selectionController = nil
                } else if case .failure = result {
                    self.selectionController = nil
                }
                continuation.resume(with: result)
            }
            selectionController = controller
            controller.show()
        }
    }

    private func promptForSemanticSelectionAccessibilityIfNeeded() {
        permissions.refresh()
        guard !permissions.canUseAccessibility,
              !promptedSemanticSelectionAccessibility,
              ensureInstalledForPermissions() else {
            return
        }
        promptedSemanticSelectionAccessibility = true
        _ = permissions.requestAccessibility(prompt: true)
    }

    private struct SelectedFrozenDisplay {
        let result: CaptureResult
        let frame: CGRect
        let selection: CGRect
    }

    private func selectRegionAcrossDisplays() async throws -> SelectedFrozenDisplay {
        let screenPoints = NSScreen.screens.map {
            coreGraphicsPoint(fromAppKit: CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        let captureService = capturer
        let results = try await withThrowingTaskGroup(of: CaptureResult.self) { group in
            for point in screenPoints {
                group.addTask {
                    try await captureService.captureDisplay(
                        containing: point,
                        excludingOwnApplication: false
                    )
                }
            }
            var values: [CaptureResult] = []
            for try await result in group { values.append(result) }
            return values
        }
        let uniqueResults = results.reduce(into: [CaptureResult]()) { values, result in
            guard !values.contains(where: { $0.capturedRect == result.capturedRect }) else { return }
            values.append(result)
        }
        guard !uniqueResults.isEmpty else { throw HelloXError.captureFailed("找不到可截图的显示器") }
        let frames = uniqueResults.map { appKitRect(fromCoreGraphics: $0.capturedRect) }
        let frozenDisplays = zip(frames, uniqueResults).map {
            SelectionFrozenDisplay(frame: $0.0, image: $0.1.image)
        }
        let selection = try await selectRegion(
            frozenDisplays: frozenDisplays,
            rendersFrozenBackdrop: false,
            preservesOverlayUntilHandoff: true
        )
        guard let index = SelectionScreenPolicy.bestDisplayIndex(for: selection, displayFrames: frames) else {
            dismissSelectionOverlay()
            throw HelloXError.captureFailed("找不到选区所在的显示器")
        }
        return SelectedFrozenDisplay(
            result: uniqueResults[index],
            frame: frames[index],
            selection: selection.intersection(frames[index])
        )
    }

    func showEditor(
        for result: CaptureResult,
        runOCR: Bool = false,
        startsWithWatermark: Bool = false
    ) {
        let document = EditorDocument(result: result, appModel: self)
        if startsWithWatermark {
            document.add(WatermarkAnnotationFactory.makeDefault())
        }
        let controller = EditorWindowController(
            document: document,
            startsWithWatermark: startsWithWatermark
        )
        captureWindows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.captureWindows.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if runOCR { document.runOCR() }
    }

    func importImageForWatermark() {
        if watermarkImportWindowController == nil {
            watermarkImportWindowController = WatermarkImportWindowController(model: self)
        }
        watermarkImportWindowController?.present()
    }

    func chooseImageForWatermark() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择需要添加水印的图片"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        isBusy = true
        NSApp.activate(ignoringOtherApps: true)
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isBusy = false }
                guard response == .OK, let url = panel.url else { return }
                self.openWatermarkEditor(for: url)
            }
        }
        if let window = watermarkImportWindowController?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @discardableResult
    func openWatermarkEditor(for url: URL) -> Bool {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let nsImage = NSImage(contentsOf: url) else {
            lastError = "无法读取所选图片。"
            return false
        }
        var proposedRect = CGRect(origin: .zero, size: nsImage.size)
        guard let image = nsImage.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            lastError = "无法解码所选图片。"
            return false
        }
        let result = CaptureResult(
            image: image,
            displayScale: 1,
            capturedRect: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            mode: .region
        )
        lastError = nil
        watermarkImportWindowController?.close()
        showEditor(for: result, startsWithWatermark: true)
        return true
    }

    private func showCaptureOverlay(
        for result: CaptureResult,
        imageFrame: CGRect,
        selection: CGRect,
        runOCR: Bool = false,
        runTranslation: Bool = false,
        startsScrolling: Bool = false,
        rendersCapturedImagePreview: Bool = false,
        scrollProcessID: pid_t? = nil
    ) {
        guard let screen = screen(withLargestIntersection: selection) else {
            dismissSelectionOverlay()
            lastError = "找不到截图所在的显示器。"
            return
        }
        let visibleSelection = selection.intersection(screen.frame)
        guard !visibleSelection.isNull, visibleSelection.width >= 2, visibleSelection.height >= 2 else {
            dismissSelectionOverlay()
            lastError = "截图选区不在可用显示器内。"
            return
        }
        let panelHandoff = selectionController?.takePanels(for: screen)
        if panelHandoff != nil {
            selectionController = nil
        } else {
            dismissSelectionOverlay()
        }
        let document = EditorDocument(result: result, appModel: self)
        let controller = CaptureOverlayEditorController(
            document: document,
            screen: screen,
            imageFrame: imageFrame,
            selection: visibleSelection,
            automaticallyRunsOCR: runOCR,
            automaticallyRunsTranslation: runTranslation,
            startsScrolling: startsScrolling,
            rendersCapturedImagePreview: rendersCapturedImagePreview,
            panelHandoff: panelHandoff
        )
        captureOverlays.append(controller)
        controller.onPin = { [weak self] image, frame in self?.showPinnedImage(image, frame: frame) }
        controller.onEdit = { [weak self] result in self?.showEditor(for: result) }
        controller.onOCR = { [weak self] image in self?.showOCR(image: image) }
        controller.onQRCodeResults = { [weak self] values in self?.showQRCodeResults(values) }
        controller.makeScrollingContext = { [weak self] appKitRect in
            guard let self else { return nil }
            let rect = self.coreGraphicsRect(fromAppKit: appKitRect)
            let eventLocation = CGPoint(x: rect.midX, y: rect.midY)
            guard let targetWindow = self.scrollWindowTarget(
                at: eventLocation,
                fallbackProcessID: scrollProcessID ?? self.targetApplicationPID()
            ) else { return nil }
            let target = HelloXCore.ScrollTarget(
                processID: targetWindow.processID,
                windowID: targetWindow.windowID,
                captureRect: rect,
                eventLocation: eventLocation,
                displayScale: self.screenScale(forAppKitRect: appKitRect)
            )
            return ManualScrollingCaptureContext(
                service: ScrollingCaptureService(capturer: self.capturer),
                target: target
            )
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.captureOverlays.removeAll { $0 === controller }
        }
        controller.show()
    }

    private func dismissSelectionOverlay() {
        selectionController?.dismiss()
        selectionController = nil
    }

    private func showPinnedImage(_ image: CGImage, frame: CGRect) {
        let controller = PinnedImageWindowController(image: image, frame: frame)
        pinnedWindows.append(controller)
        controller.onEdit = { [weak self] in
            guard let self else { return }
            let result = CaptureResult(
                image: image,
                displayScale: 1,
                capturedRect: CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height)),
                mode: .region
            )
            self.showEditor(for: result)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.pinnedWindows.removeAll { $0 === controller }
        }
        controller.present()
    }

    private func showOCR(image: CGImage, payload: OCRResultPayload? = nil) {
        if let ocrResultWindow {
            ocrResultWindow.update(image: image, payload: payload)
            return
        }
        let controller = OCRResultWindowController(image: image, payload: payload, appModel: self)
        ocrResultWindow = controller
        controller.onClose = { [weak self] in self?.ocrResultWindow = nil }
        controller.present()
    }

    private func showQRCodeResults(_ values: [String]) {
        if let qrCodeResultWindow {
            qrCodeResultWindow.update(values: values)
            return
        }
        let controller = QRCodeResultWindowController(values: values)
        qrCodeResultWindow = controller
        controller.onClose = { [weak self] in self?.qrCodeResultWindow = nil }
        controller.present()
    }

    private func showTranslation(_ context: TranslationWindowContext) {
        if let translationWindow {
            translationWindow.update(context: context)
            return
        }
        let controller = TranslationWindowController(
            context: context,
            appModel: self,
            onOpenOCR: { [weak self] payload in
                self?.showOCR(image: payload.image, payload: payload)
            }
        )
        translationWindow = controller
        controller.onClose = { [weak self] in self?.translationWindow = nil }
        controller.present()
    }

    private func screen(withLargestIntersection rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(rect)
            let right = rhs.frame.intersection(rect)
            return left.width * left.height < right.width * right.height
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }


    private func coreGraphicsRect(fromAppKit rect: CGRect) -> CGRect {
        let appKitBounds = CoordinateMapper.union(NSScreen.screens.map(\.frame))
        let coreGraphicsBounds = coreGraphicsDesktopBounds()
        return CoordinateMapper.appKitToCoreGraphics(
            rect,
            appKitDesktopBounds: appKitBounds,
            coreGraphicsDesktopBounds: coreGraphicsBounds
        )
    }

    private func appKitRect(fromCoreGraphics rect: CGRect) -> CGRect {
        CoordinateMapper.coreGraphicsToAppKit(
            rect,
            appKitDesktopBounds: CoordinateMapper.union(NSScreen.screens.map(\.frame)),
            coreGraphicsDesktopBounds: coreGraphicsDesktopBounds()
        )
    }

    private func coreGraphicsPoint(fromAppKit point: CGPoint) -> CGPoint {
        let rect = coreGraphicsRect(fromAppKit: CGRect(origin: point, size: .zero))
        return rect.origin
    }

    private func coreGraphicsDesktopBounds() -> CGRect {
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

    func provider(for request: TranslationRequest, profileID: UUID? = nil) throws -> any TranslationProvider {
        let requestedID = profileID ?? defaultTranslationProfileID
        guard let profile = translationProfiles.first(where: {
            $0.id == requestedID && $0.isEnabled && $0.vendor != .local
        }) else {
            throw HelloXError.invalidConfiguration("请选择一个已启用的翻译配置")
        }
        return try TranslationProviderFactory.make(
            profile: profile,
            apiKey: apiKey(for: profile.id)
        )
    }

    var enabledTranslationProfiles: [TranslationProfile] {
        translationProfiles.filter { $0.isEnabled && $0.vendor != .local }
    }

    var enabledTranslationServiceCount: Int {
        (isOfflineTranslationEnabled ? 1 : 0) + enabledTranslationProfiles.count
    }

    @discardableResult
    func addTranslationProfile(_ vendor: TranslationVendor) -> TranslationProfile {
        let profile = TranslationProfile.preset(vendor)
        translationProfiles.append(profile)
        persistTranslationProfiles()
        return profile
    }

    func saveTranslationProfile(_ profile: TranslationProfile, apiKey: String) {
        guard profile.vendor != .local else {
            lastError = "本地语言包功能已移除"
            return
        }
        if profile.isEnabled {
            do { try profile.validate(hasAPIKey: !apiKey.isEmpty) }
            catch { lastError = error.localizedDescription; return }
        }
        if let index = translationProfiles.firstIndex(where: { $0.id == profile.id }) { translationProfiles[index] = profile }
        else { translationProfiles.append(profile) }
        if apiKey.isEmpty { translationAPIKeys.removeValue(forKey: profile.id.uuidString) }
        else { translationAPIKeys[profile.id.uuidString] = apiKey }
        normalizeDefaultTranslationProfile()
        persistTranslationProfiles()
    }

    func duplicateTranslationProfile(_ id: UUID) -> TranslationProfile? {
        guard var profile = translationProfiles.first(where: { $0.id == id }) else { return nil }
        let oldID = profile.id
        profile.id = UUID()
        profile.name += " 副本"
        translationProfiles.append(profile)
        if let key = apiKey(for: oldID), !key.isEmpty {
            translationAPIKeys[profile.id.uuidString] = key
        }
        persistTranslationProfiles()
        return profile
    }

    func deleteTranslationProfile(_ id: UUID) {
        guard let profile = translationProfiles.first(where: { $0.id == id }) else { return }
        if profile.isEnabled && enabledTranslationServiceCount <= 1 {
            lastError = "至少保留一个启用的翻译服务。"
            return
        }
        translationProfiles.removeAll { $0.id == id }
        translationAPIKeys.removeValue(forKey: id.uuidString)
        normalizeDefaultTranslationProfile()
        persistTranslationProfiles()
    }

    func setDefaultTranslationProfile(_ id: UUID) {
        guard translationProfiles.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        defaultTranslationProfileID = id
        persistTranslationProfiles()
    }

    func setTranslationProfileEnabled(_ id: UUID, enabled: Bool) {
        guard let index = translationProfiles.firstIndex(where: { $0.id == id }) else { return }
        if !enabled && translationProfiles[index].isEnabled && enabledTranslationServiceCount <= 1 {
            lastError = "至少保留一个启用的翻译服务。"
            return
        }
        if enabled {
            do { try translationProfiles[index].validate(hasAPIKey: hasAPIKey(for: id)) }
            catch { lastError = error.localizedDescription; return }
        }
        translationProfiles[index].isEnabled = enabled
        normalizeDefaultTranslationProfile()
        persistTranslationProfiles()
    }

    func setOfflineTranslationEnabled(_ enabled: Bool) {
        if !enabled && isOfflineTranslationEnabled && enabledTranslationServiceCount <= 1 {
            lastError = "至少保留一个启用的翻译服务。"
            return
        }
        isOfflineTranslationEnabled = enabled
        persistTranslationProfiles()
    }

    func apiKey(for profileID: UUID) -> String? {
        translationAPIKeys[profileID.uuidString]
    }

    func hasAPIKey(for profileID: UUID) -> Bool { !(apiKey(for: profileID) ?? "").isEmpty }

    private func persistTranslationProfiles() {
        TranslationProfilePreferences.save(.init(
            profiles: translationProfiles,
            defaultProfileID: defaultTranslationProfileID,
            apiKeys: translationAPIKeys,
            isOfflineTranslationEnabled: isOfflineTranslationEnabled
        ))
    }

    private func normalizeDefaultTranslationProfile() {
        guard let currentID = defaultTranslationProfileID,
              translationProfiles.contains(where: { $0.id == currentID && $0.isEnabled && $0.vendor != .local }) else {
            defaultTranslationProfileID = enabledTranslationProfiles.first?.id
            return
        }
    }

    func saveShortcuts() {
        guard let shortcutApplyHandler else { return }
        if let error = ShortcutConflictDetector.validationError(in: shortcutBindings) {
            shortcutValidationMessage = error.localizedDescription
            shortcutConflictMessages[error.action] = error.reason
            lastError = error.localizedDescription
            return
        }
        switch shortcutApplyHandler(shortcutBindings) {
        case .success:
            ShortcutPreferences.save(shortcutBindings)
            shortcutValidationMessage = nil
            shortcutConflictMessages.removeAll()
            lastError = nil
        case .failure(let error):
            lastError = error.localizedDescription
            shortcutValidationMessage = error.localizedDescription
            shortcutConflictMessages[error.action] = error.reason
            shortcutBindings = ShortcutPreferences.load()
        }
    }

    func setShortcut(_ action: ShortcutAction, binding: ShortcutBinding) {
        var candidate = shortcutBindings
        candidate[action] = binding
        if let error = ShortcutConflictDetector.validationError(in: candidate, changedAction: action) {
            NSSound.beep()
            shortcutValidationMessage = error.localizedDescription
            shortcutConflictMessages[action] = error.reason
            lastError = error.localizedDescription
            return
        }
        if let error = shortcutAvailabilityHandler?(action, binding) {
            NSSound.beep()
            shortcutValidationMessage = error.localizedDescription
            shortcutConflictMessages[action] = error.reason
            lastError = error.localizedDescription
            return
        }
        applyShortcutCandidate(candidate, changedAction: action)
    }

    func clearShortcut(_ action: ShortcutAction) {
        var candidate = shortcutBindings
        candidate[action] = nil
        applyShortcutCandidate(candidate, changedAction: action)
    }

    func resetShortcut(_ action: ShortcutAction) {
        if let binding = action.defaultBinding { setShortcut(action, binding: binding) }
        else { clearShortcut(action) }
    }

    func resetAllShortcuts() {
        applyShortcutCandidate(ShortcutPreferences.defaults, changedAction: nil)
    }

    private func applyShortcutCandidate(
        _ candidate: [ShortcutAction: ShortcutBinding],
        changedAction: ShortcutAction?
    ) {
        guard let shortcutApplyHandler else {
            shortcutBindings = candidate
            ShortcutPreferences.save(candidate)
            return
        }
        switch shortcutApplyHandler(candidate) {
        case .success:
            shortcutBindings = candidate
            ShortcutPreferences.save(candidate)
            shortcutValidationMessage = nil
            shortcutConflictMessages.removeAll()
            lastError = nil
        case .failure(let error):
            NSSound.beep()
            shortcutValidationMessage = error.localizedDescription
            shortcutConflictMessages[changedAction ?? error.action] = error.reason
            lastError = error.localizedDescription
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkForUpdates() {
        guard updateState != .checking, updateState != .downloading, updateState != .installing else { return }
        updateState = .checking
        Task { @MainActor in
            do {
                if let update = try await updateClient.check(currentVersion: currentVersion) {
                    updateState = .available(update)
                } else {
                    updateState = .upToDate
                }
            } catch {
                updateState = .failed("无法检查更新：\(error.localizedDescription)")
            }
        }
    }

    func installAvailableUpdate() {
        guard case .available(let update) = updateState else { return }
        updateState = .downloading
        Task { @MainActor in
            do {
                let updatesDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("HelloX/Updates", isDirectory: true)
                let dmgURL = try await updateClient.download(update, to: updatesDirectory)
                updateState = .installing
                try UpdateInstaller().install(update: update, dmgURL: dmgURL)
            } catch {
                updateState = .failed("更新失败：\(error.localizedDescription)")
            }
        }
    }

    private func presentOnboardingIfNeeded() {
        guard ensureInstalledForPermissions() else { return }
        guard !UserDefaults.standard.bool(forKey: "did-show-onboarding") else { return }
        UserDefaults.standard.set(true, forKey: "did-show-onboarding")
        let alert = NSAlert()
        alert.messageText = "欢迎使用 HelloX"
        alert.informativeText = "截图需要屏幕录制权限；滚动长截图和划词翻译会在首次使用时另外申请辅助功能权限。截图与 OCR 默认在本机处理。"
        alert.addButton(withTitle: "授权屏幕录制")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { requestScreenPermission() }
    }
}
