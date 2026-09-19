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
    let dynamicIslandPreferences = DynamicIslandPreferencesStore()
    lazy var menuBarOverflowService = MenuBarOverflowService()

    @Published var lastError: String?
    @Published var isBusy = false
    @Published private(set) var isDynamicIslandSuppressed = false
    @Published var isShowingSettings = false
    @Published var selectedMode: CaptureMode = .region
    @Published var mainDestination: SettingsDestination = .shortcuts
    @Published var translationProfiles: [TranslationProfile] = []
    @Published var defaultTranslationProfileID: UUID?
    @Published var isOfflineTranslationEnabled = true
    @Published private(set) var screenshotTranslationTargetLanguage: SupportedLanguage = .simplifiedChinese
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
    private var selectionTranslationTask: Task<Void, Never>?
    private var selectionTranslationRequestID: UUID?
    private var captureSessionActive = false
    private var activeCaptureSuppressesDynamicIsland = false
    private var pendingCaptureSuppressesDynamicIsland = false
    private var lastExternalApplicationPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var permissionActivationObserver: NSObjectProtocol?
    private let pendingPermissionStore = PendingPermissionActionStore()
    private var pendingPermissionAction: PendingPermissionAction?
    private var permissionRequestInFlight = false
    private var awaitingPermissionReturn = false
    private var requestedPermission: PrivacyPermission?
    var shortcutApplyHandler: (([ShortcutAction: ShortcutBinding]) -> Result<Void, ShortcutRegistrationError>)?
    var shortcutAvailabilityHandler: ((ShortcutAction, ShortcutBinding) -> ShortcutRegistrationError?)?
    private let updateClient = GitHubReleaseClient()
    private static let screenshotTranslationTargetLanguageKey = "screenshot-translation-target-language"

    /// Supplying a state creates an isolated model for rendered previews and
    /// layout checks, without loading credentials or resuming permission work.
    init(translationProfileState: TranslationProfileState? = nil) {
        if let rawValue = UserDefaults.standard.string(forKey: Self.screenshotTranslationTargetLanguageKey),
           let language = SupportedLanguage(rawValue: rawValue),
           language != .auto {
            screenshotTranslationTargetLanguage = language
        }
        let profileState = translationProfileState
            ?? TranslationProfilePreferences.loadOrMigrate(legacyKeychain: KeychainStore())
        translationProfiles = profileState.profiles
        defaultTranslationProfileID = profileState.defaultProfileID
        isOfflineTranslationEnabled = profileState.isOfflineTranslationEnabled
        translationAPIKeys = profileState.apiKeys
        normalizeDefaultTranslationProfile()
        if translationProfileState != nil { return }
        pendingPermissionAction = pendingPermissionStore.load()
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
            Task { @MainActor in
                guard let self else { return }
                self.permissions.refresh(returnedFromSettings: true)
                self.resumePendingPermissionAction()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.resumePendingPermissionAction(afterLaunch: true)
        }
    }

    func startCapture(_ mode: CaptureMode) {
        startCapture(mode, hideDynamicIsland: false, initialDisplayCaptures: [])
    }

    func startCapture(
        _ mode: CaptureMode,
        hideDynamicIsland: Bool,
        initialDisplayCaptures: [CaptureResult] = []
    ) {
        authorizeAndPerform(
            .capture(mode: mode, targetProcessID: targetApplicationPID().map { Int32($0) }),
            hideDynamicIslandDuringCapture: hideDynamicIsland,
            initialDisplayCaptures: initialDisplayCaptures
        )
    }

    private func performCapture(
        _ mode: CaptureMode,
        targetProcessID: Int32?,
        hideDynamicIsland: Bool,
        initialDisplayCaptures: [CaptureResult]
    ) {
        guard beginCaptureSession(hideDynamicIsland: hideDynamicIsland) else { return }
        selectedMode = mode
        lastError = nil
        let scrollProcessID = targetProcessID.map { pid_t($0) }
        Task { @MainActor in
            defer { endCaptureSession() }
            do {
                let result: CaptureResult
                switch mode {
                case .region, .scrolling:
                    let selectedDisplay = try await selectRegionAcrossDisplays(
                        initialResults: initialDisplayCaptures
                    )
                    var refinedSelection = selectedDisplay.selection
                    var detectedRegions: [ScrollableRegion] = []
                    if mode == .scrolling, let targetPID = scrollProcessID {
                        detectedRegions = ScrollableRegionDetector.detect(processID: targetPID)
                        if let best = Self.bestScrollableRegion(
                            for: refinedSelection,
                            in: detectedRegions
                        ) {
                            refinedSelection = best.bounds
                        }
                    }
                    showCaptureOverlay(
                        for: selectedDisplay.result,
                        imageFrame: selectedDisplay.frame,
                        selection: refinedSelection,
                        startsScrolling: mode == .scrolling,
                        scrollProcessID: scrollProcessID,
                        detectedScrollableRegions: detectedRegions
                    )
                    return
                case .window:
                    result = try await capturer.captureWindow(excludingOwnApplication: false)
                case .fullScreen:
                    let triggerPoint = coreGraphicsPoint(fromAppKit: NSEvent.mouseLocation)
                    if let initialCapture = initialDisplayCaptures.first(where: {
                        $0.capturedRect.contains(triggerPoint)
                    }) {
                        result = initialCapture
                    } else {
                        result = try await capturer.captureDisplay(excludingOwnApplication: false)
                    }
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
        startScreenRecording(hideDynamicIsland: false)
    }

    func startScreenRecording(hideDynamicIsland: Bool) {
        authorizeAndPerform(
            .screenRecording,
            hideDynamicIslandDuringCapture: hideDynamicIsland
        )
    }

    private func performScreenRecording(hideDynamicIsland: Bool) {
        guard recordingController == nil else {
            NSSound.beep()
            return
        }
        guard beginCaptureSession(hideDynamicIsland: hideDynamicIsland) else { return }
        lastError = nil

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
                updateDynamicIslandSuppression()
                recorder.onUnexpectedStop = { [weak self] error in
                    Task { @MainActor in
                        self?.recordingController?.failBecauseStreamStopped(error)
                    }
                }
                controller.onFinish = { [weak self] url in
                    guard let self else { return }
                    recordingController = nil
                    activeCaptureSuppressesDynamicIsland = false
                    updateDynamicIslandSuppression()
                    lastError = nil
                    CopyFeedbackPresenter.shared.showSuccess("录屏已保存：\(url.lastPathComponent)")
                }
                controller.onFailure = { [weak self] error in
                    guard let self else { return }
                    recordingController = nil
                    activeCaptureSuppressesDynamicIsland = false
                    updateDynamicIslandSuppression()
                    let message = error.localizedDescription
                    lastError = message
                    CopyFeedbackPresenter.shared.showFailure(message)
                    NSSound.beep()
                }
                controller.onCancel = { [weak self] in
                    self?.recordingController = nil
                    self?.activeCaptureSuppressesDynamicIsland = false
                    self?.updateDynamicIslandSuppression()
                }
                controller.present()
                endCaptureSession()
            } catch {
                recordingController = nil
                updateDynamicIslandSuppression()
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
        captureAndOCR(hideDynamicIsland: false, initialDisplayCaptures: [])
    }

    func captureAndOCR(
        hideDynamicIsland: Bool,
        initialDisplayCaptures: [CaptureResult] = []
    ) {
        authorizeAndPerform(
            .captureAndOCR,
            hideDynamicIslandDuringCapture: hideDynamicIsland,
            initialDisplayCaptures: initialDisplayCaptures
        )
    }

    func captureAndTranslate() {
        captureAndTranslate(hideDynamicIsland: false, initialDisplayCaptures: [])
    }

    func captureAndTranslate(
        hideDynamicIsland: Bool,
        initialDisplayCaptures: [CaptureResult] = []
    ) {
        authorizeAndPerform(
            .captureAndTranslate,
            hideDynamicIslandDuringCapture: hideDynamicIsland,
            initialDisplayCaptures: initialDisplayCaptures
        )
    }

    private func captureTextFromScreen(
        runTranslation: Bool = false,
        hideDynamicIsland: Bool,
        initialDisplayCaptures: [CaptureResult]
    ) {
        guard beginCaptureSession(hideDynamicIsland: hideDynamicIsland) else { return }
        lastError = nil
        Task { @MainActor in
            defer { endCaptureSession() }
            do {
                let selectedDisplay = try await selectRegionAcrossDisplays(
                    initialResults: initialDisplayCaptures
                )
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

    private func beginCaptureSession(hideDynamicIsland: Bool) -> Bool {
        guard !captureSessionActive, selectionController == nil, captureOverlays.isEmpty else {
            NSSound.beep()
            return false
        }
        activeCaptureSuppressesDynamicIsland = hideDynamicIsland
        captureSessionActive = true
        isBusy = true
        updateDynamicIslandSuppression()
        return true
    }

    private func endCaptureSession() {
        captureSessionActive = false
        isBusy = false
        if recordingController == nil, captureOverlays.isEmpty {
            activeCaptureSuppressesDynamicIsland = false
        }
        updateDynamicIslandSuppression()
    }

    private func updateDynamicIslandSuppression() {
        isDynamicIslandSuppressed = activeCaptureSuppressesDynamicIsland
            && (captureSessionActive || recordingController != nil || !captureOverlays.isEmpty)
    }

    func translateSelectedText() {
        lastError = nil
        guard let processID = targetApplicationPID() else { return }
        authorizeAndPerform(.translateSelection(processID: Int32(processID)))
    }

    func showTextTranslation() {
        lastError = nil
        showTranslation(.manual)
    }

    func showTranslation(_ context: TranslationWindowContext) {
        lastError = nil
        showTranslationWindow(context)
    }

    private func translateSelectedText(from processID: pid_t) {
        selectionTranslationTask?.cancel()
        let requestID = UUID()
        selectionTranslationRequestID = requestID
        selectionTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.selectionTranslationRequestID == requestID {
                    self.selectionTranslationTask = nil
                }
            }
            do {
                let context: SelectedTextContext
                do {
                    context = try await selectionService.readSelection(
                        processID: processID,
                        allowClipboardFallback: UserDefaults.standard.bool(forKey: "did-allow-selection-clipboard-fallback")
                    )
                } catch SelectedTextError.clipboardFallbackRequired {
                    let alert = HelloXAlert()
                    alert.messageText = "允许临时使用剪贴板？"
                    alert.informativeText = "为准确保留选中文字的段落和换行，HelloX 需要临时模拟复制。读取完成后会恢复原剪贴板内容。"
                    alert.addButton(withTitle: "允许")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    UserDefaults.standard.set(true, forKey: "did-allow-selection-clipboard-fallback")
                    context = try await selectionService.readSelection(processID: processID, allowClipboardFallback: true)
                }
                try Task.checkCancellation()
                guard selectionTranslationRequestID == requestID,
                      !SystemTextSelectionService.isClipboardSentinel(context.text) else { return }
                showSelectionTranslation(context)
            } catch {
                if error is CancellationError { return }
                guard selectionTranslationRequestID == requestID else { return }
                guard !Self.shouldSilentlyIgnoreSelectionTranslationError(error) else { return }
                presentSelectionTranslationError(error, processID: processID)
            }
        }
    }

    static func shouldSilentlyIgnoreSelectionTranslationError(_ error: Error) -> Bool {
        if case SelectedTextError.noSelection = error {
            return true
        }
        if case SelectedTextError.targetUnavailable = error {
            return true
        }
        if case SelectedTextError.copyBlocked = error {
            return true
        }
        return false
    }

    private func presentSelectionTranslationError(_ error: Error, processID: pid_t?) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        let alert = HelloXAlert()
        alert.alertStyle = .warning
        alert.messageText = "划词翻译不可用"
        alert.informativeText = message
        if case SelectedTextError.accessibilityDenied = error {
            alert.addButton(withTitle: "授权辅助功能")
            alert.addButton(withTitle: "使用剪贴板保留排版")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let processID {
                    authorizeAndPerform(.translateSelection(processID: Int32(processID)))
                } else {
                    requestAccessibilityPermission()
                }
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

    private func authorizeAndPerform(
        _ action: PendingPermissionAction,
        hideDynamicIslandDuringCapture: Bool = false,
        initialDisplayCaptures: [CaptureResult] = []
    ) {
        if pendingPermissionAction != nil {
            clearPendingPermissionAction()
        }
        pendingCaptureSuppressesDynamicIsland = hideDynamicIslandDuringCapture
        permissions.refresh()
        let missingPermissions = action.requiredPermissions.filter { !permissions.isGranted($0) }
        guard !missingPermissions.isEmpty else {
            let shouldHideDynamicIsland = pendingCaptureSuppressesDynamicIsland
            pendingCaptureSuppressesDynamicIsland = false
            performPermissionAction(
                action,
                hideDynamicIsland: shouldHideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
            return
        }
        guard ensureInstalledForPermissions() else {
            pendingCaptureSuppressesDynamicIsland = false
            return
        }

        let alert = HelloXAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(action.featureName)需要授权"
        let permissionLines = missingPermissions.map {
            "• \($0.displayName)：\(permissionPurpose($0, for: action))"
        }.joined(separator: "\n")
        alert.informativeText = "HelloX 需要以下权限才能继续：\n\n\(permissionLines)\n\n确认后，macOS 会将 HelloX 登记到对应授权列表并打开系统授权页面。请开启开关并完成密码或 Touch ID 验证。"
        alert.addButton(withTitle: "前往开启")
        if case .translateSelection = action {
            alert.addButton(withTitle: "使用剪贴板保留排版")
        }
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            beginPermissionFlow(for: action)
        } else if response == .alertSecondButtonReturn,
                  case .translateSelection(let processID) = action {
            pendingCaptureSuppressesDynamicIsland = false
            UserDefaults.standard.set(true, forKey: "did-allow-selection-clipboard-fallback")
            translateSelectedText(from: pid_t(processID))
        } else {
            pendingCaptureSuppressesDynamicIsland = false
        }
    }

    private func permissionPurpose(
        _ permission: PrivacyPermission,
        for action: PendingPermissionAction
    ) -> String {
        switch permission {
        case .screenRecording:
            return action == .screenRecording ? "读取用户选择的屏幕区域并录制画面" : "读取用户选择的屏幕内容"
        case .accessibility:
            if case .translateSelection = action { return "读取用户主动选择的文字" }
            return "向目标应用发送滚动操作并识别滚动区域"
        }
    }

    private func beginPermissionFlow(for action: PendingPermissionAction) {
        pendingPermissionAction = action
        pendingPermissionStore.save(action)
        permissionRequestInFlight = false
        requestedPermission = nil
        awaitingPermissionReturn = false
        requestNextMissingPermission()
    }

    private func requestNextMissingPermission() {
        guard !permissionRequestInFlight, let action = pendingPermissionAction else { return }
        permissions.refresh()
        guard let permission = action.requiredPermissions.first(where: { !permissions.isGranted($0) }) else {
            consumePendingPermissionAction()
            return
        }

        permissionRequestInFlight = true
        requestedPermission = permission
        let granted = permissions.request(permission)
        permissions.refresh()
        permissionRequestInFlight = false

        if granted || permissions.isGranted(permission) {
            requestedPermission = nil
            requestNextMissingPermission()
            return
        }
        if permission == .screenRecording,
           permissions.screenRecordingState == .requiresRelaunch {
            presentPermissionRestartPrompt()
            return
        }

        awaitingPermissionReturn = true
        permissions.openSettings(for: permission)
    }

    private func resumePendingPermissionAction(afterLaunch: Bool = false) {
        guard !permissionRequestInFlight, let action = pendingPermissionAction else { return }
        permissions.refresh(returnedFromSettings: !afterLaunch)
        let missingPermissions = action.requiredPermissions.filter { !permissions.isGranted($0) }
        if missingPermissions.isEmpty {
            consumePendingPermissionAction()
            return
        }

        if afterLaunch {
            clearPendingPermissionAction()
            return
        }
        guard awaitingPermissionReturn else { return }
        awaitingPermissionReturn = false

        if let requestedPermission,
           !missingPermissions.contains(requestedPermission) {
            self.requestedPermission = nil
            requestNextMissingPermission()
            return
        }
        if requestedPermission == .screenRecording,
           permissions.screenRecordingState == .requiresRelaunch {
            presentPermissionRestartPrompt()
            return
        }

        let permissionName = requestedPermission?.displayName ?? missingPermissions[0].displayName
        lastError = "尚未开启\(permissionName)权限，已取消继续执行\(action.featureName)。"
        clearPendingPermissionAction()
    }

    private func consumePendingPermissionAction() {
        guard let action = pendingPermissionAction else { return }
        let shouldHideDynamicIsland = pendingCaptureSuppressesDynamicIsland
        clearPendingPermissionAction()
        performPermissionAction(action, hideDynamicIsland: shouldHideDynamicIsland)
    }

    private func clearPendingPermissionAction() {
        pendingPermissionAction = nil
        pendingPermissionStore.clear()
        requestedPermission = nil
        awaitingPermissionReturn = false
        permissionRequestInFlight = false
        pendingCaptureSuppressesDynamicIsland = false
    }

    private func performPermissionAction(
        _ action: PendingPermissionAction,
        hideDynamicIsland: Bool = false,
        initialDisplayCaptures: [CaptureResult] = []
    ) {
        switch action {
        case .capture(let mode, let targetProcessID):
            performCapture(
                mode,
                targetProcessID: targetProcessID,
                hideDynamicIsland: hideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
        case .screenRecording:
            performScreenRecording(hideDynamicIsland: hideDynamicIsland)
        case .captureAndOCR:
            captureTextFromScreen(
                hideDynamicIsland: hideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
        case .captureAndTranslate:
            captureTextFromScreen(
                runTranslation: true,
                hideDynamicIsland: hideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
        case .translateSelection(let processID):
            translateSelectedText(from: pid_t(processID))
        case .manage:
            permissions.refresh()
        }
    }

    private func presentPermissionRestartPrompt() {
        let alert = HelloXAlert()
        alert.alertStyle = .informational
        alert.messageText = "重启 HelloX 以完成授权"
        alert.informativeText = "macOS 已接受屏幕录制授权。重启 HelloX 后将自动继续刚才的操作。"
        alert.addButton(withTitle: "重启并继续")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            restartApplication()
        } else {
            clearPendingPermissionAction()
        }
    }

    func requestScreenPermission() {
        authorizeAndPerform(.manage(.screenRecording))
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

    func showSettingsWindow(destination: SettingsDestination = .shortcuts) {
        mainDestination = destination
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: self)
        }
        settingsWindowController?.present()
    }

    func showUtilityTool(_ tool: UtilityTool) {
        utilityToolController(for: tool).present()
    }

    func openDocuments(_ urls: [URL]) {
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
        let markdownURLs = urls.filter {
            markdownExtensions.contains($0.pathExtension.lowercased())
        }
        let diagramURLs = urls.filter { $0.pathExtension.lowercased() == "hxdiagram" }
        if !markdownURLs.isEmpty {
            utilityToolController(for: .markdown).openMarkdownDocuments(at: markdownURLs)
        }
        if let diagramURL = diagramURLs.first {
            utilityToolController(for: .mindMap).openDiagramDocument(at: diagramURL)
        }
        if markdownURLs.isEmpty, diagramURLs.isEmpty {
            CopyFeedbackPresenter.shared.showFailure("HelloX 当前可直接打开 Markdown 或 .hxdiagram 文档")
        }
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
        authorizeAndPerform(.manage(.accessibility))
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
        let alert = HelloXAlert()
        alert.alertStyle = .warning
        alert.messageText = "请先安装 HelloX"
        alert.informativeText = "当前正在从只读安装镜像运行。macOS 无法为这个临时副本稳定保存屏幕录制和辅助功能权限。请安装 HelloX，退出当前副本，再从“应用程序”中打开。"
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { revealRunningApplication() }
        return false
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

    private struct SelectedFrozenDisplay {
        let result: CaptureResult
        let frame: CGRect
        let selection: CGRect
    }

    private func selectRegionAcrossDisplays(
        initialResults: [CaptureResult] = []
    ) async throws -> SelectedFrozenDisplay {
        let results: [CaptureResult]
        if initialResults.isEmpty {
            let screenPoints = NSScreen.screens.map {
                coreGraphicsPoint(fromAppKit: CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            let captureService = capturer
            results = try await withThrowingTaskGroup(of: CaptureResult.self) { group in
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
        } else {
            results = initialResults
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
            rendersFrozenBackdrop: !initialResults.isEmpty,
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
        scrollProcessID: pid_t? = nil,
        detectedScrollableRegions: [ScrollableRegion] = []
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
            if captureOverlays.isEmpty, recordingController == nil, !captureSessionActive {
                activeCaptureSuppressesDynamicIsland = false
            }
            updateDynamicIslandSuppression()
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
        controller.onEdit = { [weak self, weak controller] in
            guard let self else { return }
            controller?.close()
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

    private func showTranslationWindow(_ context: TranslationWindowContext) {
        if let translationWindow {
            translationWindow.update(context: context)
            return
        }
        let controller = TranslationWindowController(
            context: context,
            appModel: self
        )
        translationWindow = controller
        controller.onClose = { [weak self] in self?.translationWindow = nil }
        controller.present()
    }

    /// Picks the best detected scrollable region for a user selection.
    /// Prefers regions fully contained in the selection; falls back to the
    /// largest region that overlaps significantly.
    private static func bestScrollableRegion(
        for selection: CGRect,
        in regions: [ScrollableRegion]
    ) -> ScrollableRegion? {
        guard !regions.isEmpty else { return nil }
        if let contained = regions.first(where: { selection.contains($0.bounds) }) {
            return contained
        }
        return regions
            .filter { $0.bounds.intersects(selection) }
            .max { a, b in
                a.bounds.intersection(selection).area < b.bounds.intersection(selection).area
            }
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
            $0.id == requestedID && $0.isEnabled && $0.vendor.supportsTextTranslation
        }) else {
            throw HelloXError.invalidConfiguration("请选择一个已启用的翻译配置")
        }
        return try TranslationProviderFactory.make(
            profile: profile,
            apiKey: apiKey(for: profile.id)
        )
    }

    var enabledTranslationProfiles: [TranslationProfile] {
        translationProfiles.filter { $0.isEnabled && $0.vendor.supportsTextTranslation }
    }

    var defaultTextTranslationProfile: TranslationProfile? {
        guard let defaultTranslationProfileID else { return nil }
        return translationProfiles.first {
            $0.id == defaultTranslationProfileID && $0.isEnabled && $0.vendor.supportsTextTranslation
        }
    }

    var enabledTranslationServiceCount: Int {
        (isOfflineTranslationEnabled ? 1 : 0) + enabledTranslationProfiles.count
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

    func deleteTranslationProfile(_ id: UUID) {
        guard let profile = translationProfiles.first(where: { $0.id == id }) else { return }
        if profile.isEnabled,
           profile.vendor.supportsTextTranslation,
           enabledTranslationServiceCount <= 1 {
            lastError = "至少保留一个启用的翻译服务。"
            return
        }
        translationProfiles.removeAll { $0.id == id }
        translationAPIKeys.removeValue(forKey: id.uuidString)
        normalizeDefaultTranslationProfile()
        persistTranslationProfiles()
    }

    func setTranslationProfileEnabled(_ id: UUID, enabled: Bool) {
        guard let index = translationProfiles.firstIndex(where: { $0.id == id }) else { return }
        if !enabled,
           translationProfiles[index].isEnabled,
           translationProfiles[index].vendor.supportsTextTranslation,
           enabledTranslationServiceCount <= 1 {
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

    func setScreenshotTranslationTargetLanguage(_ language: SupportedLanguage) {
        guard language != .auto, language != screenshotTranslationTargetLanguage else { return }
        screenshotTranslationTargetLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.screenshotTranslationTargetLanguageKey)
    }

    func setDefaultTranslationProfile(_ id: UUID) {
        guard enabledTranslationProfiles.contains(where: { $0.id == id }) else { return }
        defaultTranslationProfileID = id
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
        if enabledTranslationProfiles.isEmpty {
            isOfflineTranslationEnabled = true
        }
        guard let currentID = defaultTranslationProfileID,
              translationProfiles.contains(where: {
                  $0.id == currentID && $0.isEnabled && $0.vendor.supportsTextTranslation
              }) else {
            defaultTranslationProfileID = enabledTranslationProfiles.first?.id
            return
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

}
