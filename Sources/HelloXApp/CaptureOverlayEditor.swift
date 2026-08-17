import AppKit
import HelloXCore
import SwiftUI
@preconcurrency import Translation

struct ManualScrollingCaptureContext {
    let service: ScrollingCaptureService
    let target: HelloXCore.ScrollTarget
}

enum ScrollingOverlayGeometry {
    static let toolbarSize = CGSize(width: 186, height: 44)

    static func toolbarFrame(selection: CGRect, in bounds: CGRect) -> CGRect {
        let size = CGSize(
            width: min(toolbarSize.width, max(132, bounds.width - 24)),
            height: toolbarSize.height
        )
        return CGRect(
            origin: SelectionGeometry.toolbarOrigin(selection: selection, toolbarSize: size, within: bounds),
            size: size
        )
    }

    static func previewFrame(
        selection: CGRect,
        in bounds: CGRect,
        direction: ScrollDirection = .down
    ) -> CGRect {
        if direction.isHorizontal {
            let width = min(max(320, selection.width * 0.72), min(620, bounds.width - 24))
            let height = min(180, max(132, bounds.height * 0.18))
            let centerX = min(
                bounds.maxX - 12 - width / 2,
                max(bounds.minX + 12 + width / 2, selection.midX)
            )
            let aboveY = selection.minY - 10 - height / 2
            let belowY = selection.maxY + 10 + height / 2
            let centerY: CGFloat
            if aboveY - height / 2 >= bounds.minY + 12 {
                centerY = aboveY
            } else if belowY + height / 2 <= bounds.maxY - 12 {
                centerY = belowY
            } else {
                centerY = min(bounds.maxY - 12 - height / 2, selection.minY + 12 + height / 2)
            }
            return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        }
        let width = min(184, max(144, bounds.width * 0.14))
        let height = min(max(240, selection.height * 0.72), min(520, bounds.height - 24))
        let canPlaceRight = bounds.maxX - selection.maxX >= width + 18
        let canPlaceLeft = selection.minX - bounds.minX >= width + 18
        let centerX: CGFloat
        if canPlaceRight {
            centerX = selection.maxX + 10 + width / 2
        } else if canPlaceLeft {
            centerX = selection.minX - 10 - width / 2
        } else {
            centerX = min(bounds.maxX - 12 - width / 2, selection.maxX - 12 - width / 2)
        }
        let centerY = min(
            bounds.maxY - 12 - height / 2,
            max(bounds.minY + 12 + height / 2, selection.midY)
        )
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    static func shouldPassMouseEvents(
        at point: CGPoint,
        selection: CGRect,
        in bounds: CGRect,
        direction: ScrollDirection = .down
    ) -> Bool {
        let toolbar = toolbarFrame(selection: selection, in: bounds).insetBy(dx: -8, dy: -8)
        let preview = previewFrame(selection: selection, in: bounds, direction: direction).insetBy(dx: -8, dy: -8)
        return selection.contains(point) && !toolbar.contains(point) && !preview.contains(point)
    }
}

enum MovableToolbarGeometry {
    static func clampedOrigin(_ origin: CGPoint, toolbarSize: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(bounds.minX + 8, origin.x), max(bounds.minX + 8, bounds.maxX - toolbarSize.width - 8)),
            y: min(max(bounds.minY + 8, origin.y), max(bounds.minY + 8, bounds.maxY - toolbarSize.height - 8))
        )
    }

    static func draggedOrigin(
        from origin: CGPoint,
        startLocation: CGPoint,
        currentLocation: CGPoint,
        toolbarSize: CGSize,
        in bounds: CGRect
    ) -> CGPoint {
        clampedOrigin(
            CGPoint(
                x: origin.x + currentLocation.x - startLocation.x,
                y: origin.y + currentLocation.y - startLocation.y
            ),
            toolbarSize: toolbarSize,
            in: bounds
        )
    }
}

enum CaptureToolbarLayout {
    static let scale: CGFloat = 1.25
    static let buttonSize = AnnotationPropertyBarLayout.toolbarButtonSize * scale
    static let iconSize: CGFloat = 14 * scale * 1.25 * 0.75
    static let buttonSpacing = AnnotationPropertyBarLayout.toolbarButtonSpacing * scale
    static let horizontalPadding = AnnotationPropertyBarLayout.toolbarHorizontalPadding * scale

    static func buttonRowWidth(count: Int) -> CGFloat {
        guard count > 0 else { return horizontalPadding }
        return CGFloat(count) * buttonSize
            + CGFloat(count - 1) * buttonSpacing
            + horizontalPadding
    }
}

enum CaptureOverlayDimPanelPolicy {
    static func createsNewPanels(hasSelectionOverlayHandoff: Bool) -> Bool {
        !hasSelectionOverlayHandoff
    }
}

private enum CaptureOverlayCoordinateSpace {
    static let name = "capture-overlay-fixed-coordinate-space"
}

private struct MovableToolbarContainer<Content: View>: View {
    let defaultOrigin: CGPoint
    let toolbarSize: CGSize
    let bounds: CGRect
    let enabled: Bool
    let onDragBegan: () -> Void
    @ViewBuilder let content: (CGPoint) -> Content

    @State private var originOverride: CGPoint?
    @State private var dragStartOrigin: CGPoint?
    @State private var isDragging = false

    private var origin: CGPoint {
        MovableToolbarGeometry.clampedOrigin(
            originOverride ?? defaultOrigin,
            toolbarSize: toolbarSize,
            in: bounds
        )
    }

    var body: some View {
        let resolvedOrigin = origin
        content(resolvedOrigin)
            .overlay(alignment: .top) {
                if enabled {
                    ZStack {
                        Color.clear
                        Capsule()
                            .fill(Color.secondary.opacity(0.42))
                            .frame(width: 26, height: 3)
                    }
                    .frame(width: 64, height: 12)
                    .contentShape(Rectangle())
                    .accessibilityLabel("拖动工具栏")
                    .gesture(dragGesture(origin: resolvedOrigin))
                }
            }
            .position(
                x: resolvedOrigin.x + toolbarSize.width / 2,
                y: resolvedOrigin.y + toolbarSize.height / 2
            )
            .transaction { transaction in
                if isDragging { transaction.animation = nil }
            }
            .onChange(of: enabled) { isEnabled in
                guard !isEnabled else { return }
                originOverride = nil
                dragStartOrigin = nil
                isDragging = false
            }
    }

    private func dragGesture(origin: CGPoint) -> some Gesture {
        DragGesture(
            minimumDistance: 1,
            coordinateSpace: .named(CaptureOverlayCoordinateSpace.name)
        )
        .onChanged { value in
            guard enabled else { return }
            if dragStartOrigin == nil {
                dragStartOrigin = origin
                isDragging = true
                onDragBegan()
            }
            guard let dragStartOrigin else { return }
            originOverride = MovableToolbarGeometry.draggedOrigin(
                from: dragStartOrigin,
                startLocation: value.startLocation,
                currentLocation: value.location,
                toolbarSize: toolbarSize,
                in: bounds
            )
        }
        .onEnded { _ in
            dragStartOrigin = nil
            isDragging = false
        }
    }
}

enum ScrollingWheelDirection {
    static func resolve(deltaX: CGFloat, deltaY: CGFloat, usesHorizontalWheel: Bool) -> ScrollDirection? {
        if usesHorizontalWheel {
            // Mouse drivers may report Shift + wheel through either axis.
            // Shift remains the explicit switch for horizontal capture.
            let horizontalDelta = abs(deltaX) > abs(deltaY) ? deltaX : deltaY
            guard abs(horizontalDelta) > 0.01 else { return nil }
            return horizontalDelta < 0 ? .right : .left
        }
        guard abs(deltaY) > 0.01 else { return nil }
        return deltaY < 0 ? .down : .up
    }
}

@MainActor
final class ManualScrollingCaptureModel: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var stitchedImage: CGImage?
    @Published private(set) var pixelHeight = 0
    @Published private(set) var pixelWidth = 0
    @Published private(set) var direction: ScrollDirection = .down

    private var session: ManualScrollingCaptureSession?
    private var startTask: Task<Void, Never>?
    private var scheduledCaptureTask: Task<Void, Never>?
    private var scrollDirectionHint: ScrollDirection?
    private var lastScrollEventDate: Date?
    private var firstPendingScrollEventDate: Date?
    private var eventGeneration: UInt64 = 0
    private var processedEventGeneration: UInt64 = 0
    private var captureInFlight = false

    // Keep consecutive source frames close enough to retain a real overlap
    // during fast trackpad scrolling. A 280 ms batch could cross an entire
    // chat viewport, after which the stitcher had no frame from which to
    // recover and stopped appending.
    private let idleCaptureDelay: TimeInterval = 0.07
    private let maximumContinuousCaptureDelay: TimeInterval = 0.14

    func noteScroll(deltaX: CGFloat, deltaY: CGFloat, usesHorizontalWheel: Bool) {
        guard let direction = ScrollingWheelDirection.resolve(
            deltaX: deltaX,
            deltaY: deltaY,
            usesHorizontalWheel: usesHorizontalWheel
        ) else { return }
        scrollDirectionHint = direction
        let now = Date()
        lastScrollEventDate = now
        if firstPendingScrollEventDate == nil {
            firstPendingScrollEventDate = now
        }
        eventGeneration &+= 1
        scheduleCaptureIfNeeded()
    }

    func begin(_ context: ManualScrollingCaptureContext) {
        guard !isActive else { return }
        isActive = true
        let session = context.service.makeManualSession(target: context.target)
        self.session = session
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Let SwiftUI remove the selection chrome before the initial
                // scrolling frame is requested.
                await Task.yield()
                self.apply(try await session.begin())
                self.scheduleCaptureIfNeeded()
            } catch is CancellationError {
            } catch {
                return
            }
        }
    }

    func snapshot() async throws -> CaptureResult {
        guard isActive, let session else {
            throw HelloXError.captureFailed("长截图尚未开始")
        }
        await startTask?.value
        return try await session.result()
    }

    func cancel() {
        startTask?.cancel()
        scheduledCaptureTask?.cancel()
        startTask = nil
        scheduledCaptureTask = nil
        session = nil
        isActive = false
        captureInFlight = false
        firstPendingScrollEventDate = nil
    }

    private func scheduleCaptureIfNeeded() {
        guard isActive, session != nil, !captureInFlight,
              eventGeneration > processedEventGeneration,
              let firstPendingScrollEventDate,
              let lastScrollEventDate else { return }

        let deadline = min(
            lastScrollEventDate.addingTimeInterval(idleCaptureDelay),
            firstPendingScrollEventDate.addingTimeInterval(maximumContinuousCaptureDelay)
        )
        let delay = max(0, deadline.timeIntervalSinceNow)
        scheduledCaptureTask?.cancel()
        scheduledCaptureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.capturePendingScrollEvent()
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func capturePendingScrollEvent() async {
        guard isActive, !captureInFlight, let session,
              eventGeneration > processedEventGeneration else { return }
        scheduledCaptureTask = nil
        captureInFlight = true
        let attemptedGeneration = eventGeneration
        let direction = scrollDirectionHint
        // Events arriving while the screenshot is being captured form the next batch.
        firstPendingScrollEventDate = nil
        defer {
            processedEventGeneration = max(processedEventGeneration, attemptedGeneration)
            captureInFlight = false
            scheduleCaptureIfNeeded()
        }
        do {
            if let update = try await session.captureCurrentFrame(directionHint: direction) {
                apply(update)
            }
        } catch is CancellationError {
        } catch {
            // A later wheel event gets a fresh attempt. Avoid retrying the same
            // event forever, which previously produced duplicate settling frames.
        }
    }

    private func apply(_ update: ManualScrollingCaptureUpdate) {
        stitchedImage = update.stitchedImage
        pixelHeight = update.pixelHeight
        pixelWidth = update.pixelWidth
        direction = update.direction
    }

}

@MainActor
final class CaptureOverlayEditorController: NSWindowController {
    let editorDocument: EditorDocument
    var onClose: (() -> Void)?
    var onPin: ((CGImage, CGRect) -> Void)?
    var onEdit: ((CaptureResult) -> Void)?
    var onOCR: ((CGImage) -> Void)?
    var onQRCodeResults: (([String]) -> Void)?
    var makeScrollingContext: ((CGRect) -> ManualScrollingCaptureContext?)?

    private let targetScreen: NSScreen
    private let targetPanel: SelectionPanel
    private let reusesSelectionPanels: Bool
    private let persistentCanvas: CaptureOverlayCanvasView?
    private var dimPanels: [NSPanel] = []
    private var editorContentView: NSView!
    private var currentSelection: CGRect
    private var escapeMonitor: Any?
    private var passthroughTimer: Timer?
    private var scrollingWheelMonitor: Any?
    private var localScrollingWheelMonitor: Any?
    private var finished = false
    private let startsScrolling: Bool
    private let scrollingModel = ManualScrollingCaptureModel()

    init(
        document: EditorDocument,
        screen: NSScreen,
        imageFrame: CGRect,
        selection: CGRect,
        automaticallyRunsOCR: Bool = false,
        automaticallyRunsTranslation: Bool = false,
        startsScrolling: Bool = false,
        rendersCapturedImagePreview: Bool = true,
        panelHandoff: CaptureOverlayPanelHandoff? = nil
    ) {
        editorDocument = document
        targetScreen = screen
        let localImageFrame = Self.localTopLeftRect(imageFrame, on: screen)
        let localSelection = Self.localTopLeftRect(selection, on: screen)
            .intersection(CGRect(origin: .zero, size: screen.frame.size))
        currentSelection = localSelection
        self.startsScrolling = startsScrolling
        reusesSelectionPanels = panelHandoff != nil
        persistentCanvas = panelHandoff?.targetCanvas
        targetPanel = panelHandoff?.targetPanel ?? SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
        super.init(window: targetPanel)
        if let panelHandoff {
            dimPanels = panelHandoff.dimPanels
        }

        document.outputCrop = Self.normalized(localSelection, in: localImageFrame)
        // A reused panel keeps its persistent transparent root canvas. The
        // selection and editor layers switch inside that canvas atomically.
        let opaqueTarget = panelHandoff == nil && imageFrame.insetBy(dx: -1, dy: -1).contains(screen.frame)
        configure(targetPanel, for: screen, interactive: true, opaque: opaqueTarget)
        targetPanel.onCancel = { [weak self] in self?.finish() }
        targetPanel.onComplete = { [weak self] in self?.complete() }
        targetPanel.onCopy = { [weak self] in self?.complete() }
        targetPanel.onSave = { [weak self] in self?.save() }
        targetPanel.onUndo = { [weak document] in document?.undo() }
        targetPanel.onRedo = { [weak document] in document?.redo() }
        let rootView = CaptureOverlayEditorView(
            document: document,
            scrollingModel: scrollingModel,
            imageFrame: localImageFrame,
            initialSelection: localSelection,
            automaticallyRunsOCR: automaticallyRunsOCR,
            automaticallyRunsTranslation: automaticallyRunsTranslation,
            rendersCapturedImagePreview: rendersCapturedImagePreview,
            onSelectionChange: { [weak self] rect in self?.selectionChanged(rect, imageFrame: localImageFrame) },
            onCancel: { [weak self] in self?.finish() },
            onComplete: { [weak self] in self?.complete() },
            onEdit: { [weak self] in self?.editScrollingCapture() },
            onSave: { [weak self] in self?.save() },
            onPin: { [weak self] in self?.pin() },
            onOCR: { [weak self] in self?.recognizeText() },
            onQRCode: { [weak self] in self?.recognizeQRCode() },
            onTranslate: { [weak self] in self?.translate() },
            onBeginScrolling: { [weak self] in self?.beginScrolling() }
        )
        let hostingView = NSHostingView(rootView: rootView)
        editorContentView = hostingView
        if let persistentCanvas {
            persistentCanvas.stageEditor(hostingView)
        } else {
            targetPanel.contentView = hostingView
        }
        if CaptureOverlayDimPanelPolicy.createsNewPanels(
            hasSelectionOverlayHandoff: reusesSelectionPanels
        ) {
            createDimPanels(excluding: screen)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        if reusesSelectionPanels {
            if !targetPanel.isVisible {
                for panel in dimPanels { panel.orderFrontRegardless() }
                targetPanel.orderFrontRegardless()
            }
            editorContentView.layoutSubtreeIfNeeded()
            editorContentView.displayIfNeeded()
            targetPanel.makeFirstResponder(editorContentView)
            persistentCanvas?.activateEditor()
            installInteractionHandlers()
            return
        }

        targetPanel.contentView?.layoutSubtreeIfNeeded()
        targetPanel.contentView?.displayIfNeeded()
        for panel in dimPanels {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
        }
        for panel in dimPanels { panel.orderFrontRegardless() }
        targetPanel.orderFrontRegardless()
        targetPanel.makeKeyAndOrderFront(nil)
        targetPanel.makeFirstResponder(targetPanel.contentView)
        installInteractionHandlers()
    }

    private func installInteractionHandlers() {
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.finish()
                return nil
            }
        }
        if startsScrolling && !scrollingModel.isActive {
            DispatchQueue.main.async { [weak self] in self?.beginScrolling() }
        }
    }

    private func configure(
        _ panel: NSPanel,
        for screen: NSScreen,
        interactive: Bool,
        opaque: Bool = false
    ) {
        panel.setFrame(screen.frame, display: true)
        panel.animationBehavior = .none
        panel.alphaValue = 1
        panel.isOpaque = opaque
        panel.backgroundColor = opaque ? .black : .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = !interactive
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }

    private func createDimPanels(excluding target: NSScreen) {
        for screen in NSScreen.screens where screen !== target {
            let panel = SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            configure(panel, for: screen, interactive: false)
            panel.contentView = NSHostingView(
                rootView: Color.black
                    .opacity(CaptureOverlayAppearance.editorDimOpacity)
                    .ignoresSafeArea()
            )
            dimPanels.append(panel)
        }
    }

    private func selectionChanged(_ rect: CGRect, imageFrame: CGRect) {
        currentSelection = rect
        let crop = Self.normalized(rect, in: imageFrame)
        if editorDocument.outputCrop != crop {
            editorDocument.outputCrop = crop
            editorDocument.ocrResult = nil
            editorDocument.translatedText = nil
            editorDocument.imageTranslationBlocks = []
        }
    }

    private func complete() {
        if scrollingModel.isActive {
            guard !editorDocument.isExporting else { return }
            editorDocument.isExporting = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { editorDocument.isExporting = false }
                do {
                    let result = try await scrollingModel.snapshot()
                    switch await ImageExporter.copyToPasteboardAsync(result.image) {
                    case .success:
                        editorDocument.exportError = nil
                        editorDocument.exportMessage = "长截图已复制到剪贴板"
                        CopyFeedbackPresenter.shared.showSuccess("长截图已复制")
                        finish()
                    case .failure(let message):
                        editorDocument.exportMessage = nil
                        editorDocument.exportError = message
                        CopyFeedbackPresenter.shared.showFailure(message)
                        NSSound.beep()
                    }
                } catch {
                    editorDocument.exportError = error.localizedDescription
                    NSSound.beep()
                }
            }
            return
        }
        guard !editorDocument.isExporting else { return }
        editorDocument.isExporting = true
        editorDocument.exportError = nil
        editorDocument.exportMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let result = await editorDocument.copyImageAsync()
            editorDocument.isExporting = false
            guard result.isSuccess else { NSSound.beep(); return }
            finish()
        }
    }

    private func save() {
        if scrollingModel.isActive {
            saveScrollingCapture()
            return
        }
        guard !editorDocument.isExporting else { return }
        editorDocument.isExporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            hideOverlayPanels()
            let result = await editorDocument.saveAsync()
            editorDocument.isExporting = false
            if result == .saved { finish() } else { show() }
        }
    }

    private func pin() {
        if scrollingModel.isActive {
            pinScrollingCapture()
            return
        }
        let image: CGImage
        do { image = try editorDocument.renderedImage() }
        catch {
            editorDocument.exportError = error.localizedDescription
            return
        }
        let globalFrame = Self.globalAppKitRect(currentSelection, on: targetScreen)
        onPin?(image, globalFrame)
        finish()
    }

    private func saveScrollingCapture() {
        guard !editorDocument.isExporting else { return }
        editorDocument.isExporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { editorDocument.isExporting = false }
            do {
                let result = try await scrollingModel.snapshot()
                hideOverlayPanels()
                if await editorDocument.saveAsync(image: result.image) == .saved {
                    finish()
                } else {
                    show()
                }
            } catch {
                editorDocument.exportError = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    private func pinScrollingCapture() {
        guard !editorDocument.isExporting else { return }
        editorDocument.isExporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { editorDocument.isExporting = false }
            do {
                let result = try await scrollingModel.snapshot()
                let globalFrame = Self.globalAppKitRect(currentSelection, on: targetScreen)
                onPin?(result.image, globalFrame)
                finish()
            } catch {
                editorDocument.exportError = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    private func editScrollingCapture() {
        guard scrollingModel.isActive, !editorDocument.isExporting else { return }
        editorDocument.isExporting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { editorDocument.isExporting = false }
            do {
                let result = try await scrollingModel.snapshot()
                finish()
                onEdit?(result)
            } catch {
                editorDocument.exportError = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    private func recognizeText() {
        do {
            let image = try editorDocument.originalSelectionImage()
            finish()
            onOCR?(image)
        } catch {
            editorDocument.exportError = error.localizedDescription
        }
    }

    private func recognizeQRCode() {
        guard !editorDocument.isExporting else { return }
        let image: CGImage
        do {
            image = try editorDocument.originalSelectionImage()
        } catch {
            editorDocument.exportError = error.localizedDescription
            return
        }
        editorDocument.isExporting = true
        editorDocument.exportError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let values = try await Task.detached {
                    try QRCodeRecognitionService.recognize(in: image)
                }.value
                editorDocument.isExporting = false
                let urls = values.compactMap(QRCodePayload.webURL(from:))
                finish()

                if urls.count == values.count {
                    let openedCount = urls.reduce(into: 0) { count, url in
                        if NSWorkspace.shared.open(url) { count += 1 }
                    }
                    if openedCount == values.count {
                        CopyFeedbackPresenter.shared.showSuccess(openedCount == 1 ? "已打开二维码网址" : "已打开 \(openedCount) 个二维码网址")
                    } else {
                        onQRCodeResults?(values)
                    }
                } else {
                    onQRCodeResults?(values)
                }
            } catch UtilityToolError.qrCodeNotFound {
                editorDocument.isExporting = false
                finish()
                CopyFeedbackPresenter.shared.showFailure(UtilityToolError.qrCodeNotFound.localizedDescription)
            } catch {
                editorDocument.isExporting = false
                editorDocument.exportError = error.localizedDescription
                CopyFeedbackPresenter.shared.showFailure(error.localizedDescription)
                NSSound.beep()
            }
        }
    }

    private func translate() {
        editorDocument.translateImageInPlace()
    }

    private func beginScrolling() {
        guard !scrollingModel.isActive else { return }
        let globalFrame = Self.globalAppKitRect(currentSelection, on: targetScreen)
        guard let context = makeScrollingContext?(globalFrame) else {
            editorDocument.exportError = "找不到需要滚动的目标应用"
            NSSound.beep()
            return
        }
        scrollingModel.begin(context)
        startScrollingPassthrough()
    }

    private func startScrollingPassthrough() {
        stopScrollingPassthrough()
        let handleWheel: (NSEvent) -> Void = { [weak self] event in
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let usesHorizontalWheel = event.modifierFlags.contains(.shift)
            Task { @MainActor [weak self] in
                self?.scrollingModel.noteScroll(
                    deltaX: deltaX,
                    deltaY: deltaY,
                    usesHorizontalWheel: usesHorizontalWheel
                )
            }
        }
        localScrollingWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleWheel(event)
            return event
        }
        scrollingWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
            handleWheel(event)
        }
        updateScrollingPassthrough()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateScrollingPassthrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        passthroughTimer = timer
    }

    private func updateScrollingPassthrough() {
        guard scrollingModel.isActive else {
            targetPanel.ignoresMouseEvents = false
            return
        }
        let pointer = NSEvent.mouseLocation
        let localPoint = CGPoint(
            x: pointer.x - targetScreen.frame.minX,
            y: targetScreen.frame.maxY - pointer.y
        )
        let bounds = CGRect(origin: .zero, size: targetScreen.frame.size)
        targetPanel.ignoresMouseEvents = ScrollingOverlayGeometry.shouldPassMouseEvents(
            at: localPoint,
            selection: currentSelection,
            in: bounds,
            direction: scrollingModel.direction
        )
    }

    private func stopScrollingPassthrough() {
        passthroughTimer?.invalidate()
        passthroughTimer = nil
        if let scrollingWheelMonitor {
            NSEvent.removeMonitor(scrollingWheelMonitor)
            self.scrollingWheelMonitor = nil
        }
        if let localScrollingWheelMonitor {
            NSEvent.removeMonitor(localScrollingWheelMonitor)
            self.localScrollingWheelMonitor = nil
        }
        targetPanel.ignoresMouseEvents = false
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        stopScrollingPassthrough()
        scrollingModel.cancel()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        hideOverlayPanels()
        onClose?()
    }

    private func hideOverlayPanels() {
        for panel in dimPanels { panel.orderOut(nil) }
        targetPanel.orderOut(nil)
    }

    private static func localTopLeftRect(_ global: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: global.minX - screen.frame.minX,
            y: screen.frame.maxY - global.maxY,
            width: global.width,
            height: global.height
        )
    }

    private static func globalAppKitRect(_ local: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX + local.minX,
            y: screen.frame.maxY - local.maxY,
            width: local.width,
            height: local.height
        )
    }

    private static func normalized(_ selection: CGRect, in imageFrame: CGRect) -> CGRect? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let intersection = selection.intersection(imageFrame)
        guard !intersection.isNull, intersection.width >= 2, intersection.height >= 2 else { return nil }
        return CGRect(
            x: (intersection.minX - imageFrame.minX) / imageFrame.width,
            y: (intersection.minY - imageFrame.minY) / imageFrame.height,
            width: intersection.width / imageFrame.width,
            height: intersection.height / imageFrame.height
        )
    }
}

private struct CaptureOverlayEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var document: EditorDocument
    @ObservedObject var scrollingModel: ManualScrollingCaptureModel
    let imageFrame: CGRect
    let automaticallyRunsOCR: Bool
    let automaticallyRunsTranslation: Bool
    let rendersCapturedImagePreview: Bool
    let onSelectionChange: (CGRect) -> Void
    let onCancel: () -> Void
    let onComplete: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let onOCR: () -> Void
    let onQRCode: () -> Void
    let onTranslate: () -> Void
    let onBeginScrolling: () -> Void

    @State private var selection: CGRect
    @State private var tool: AnnotationTool = .select
    @State private var color: Color = .red
    @State private var lineWidth: Double = 4
    @State private var mosaicMode: MosaicMode = .brush
    @State private var mosaicBlockSize: Double = 10
    @State private var watermarkSpacing: Double = 48
    @State private var textValue = "文字"
    @State private var draft: Annotation?
    @State private var dragStart: CGPoint?
    @State private var penPoints: [CGPoint] = []
    @State private var didStartAutomaticTextAction = false
    @State private var selectedAnnotationID: UUID?
    @State private var selectedAnnotationDraft: Annotation?
    @State private var originalSelectedAnnotation: Annotation?
    @State private var originalSelection: CGRect?
    @State private var propertyEditRegistered = false
    @State private var hoveredToolbarHelp: String?
    @State private var isEditingText = false
    @State private var didMoveSelectedText = false
    @State private var inlineTextBuffer = InlineAnnotationTextBuffer()
    @State private var mosaicCache = MosaicPreviewCache()
    @State private var interactionThrottle = AnnotationInteractionThrottle()
    @State private var imageTranslationConfiguration: TranslationSession.Configuration?

    init(
        document: EditorDocument,
        scrollingModel: ManualScrollingCaptureModel,
        imageFrame: CGRect,
        initialSelection: CGRect,
        automaticallyRunsOCR: Bool,
        automaticallyRunsTranslation: Bool,
        rendersCapturedImagePreview: Bool = true,
        onSelectionChange: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onOCR: @escaping () -> Void,
        onQRCode: @escaping () -> Void,
        onTranslate: @escaping () -> Void,
        onBeginScrolling: @escaping () -> Void
    ) {
        self.document = document
        self.scrollingModel = scrollingModel
        self.imageFrame = imageFrame
        self.automaticallyRunsOCR = automaticallyRunsOCR
        self.automaticallyRunsTranslation = automaticallyRunsTranslation
        self.rendersCapturedImagePreview = rendersCapturedImagePreview
        self.onSelectionChange = onSelectionChange
        self.onCancel = onCancel
        self.onComplete = onComplete
        self.onEdit = onEdit
        self.onSave = onSave
        self.onPin = onPin
        self.onOCR = onOCR
        self.onQRCode = onQRCode
        self.onTranslate = onTranslate
        self.onBeginScrolling = onBeginScrolling
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        GeometryReader { proxy in
            let screenBounds = CGRect(origin: .zero, size: proxy.size)
            let selectionBounds = imageFrame.intersection(screenBounds)
            ZStack(alignment: .topLeading) {
                Color.clear
                if !scrollingModel.isActive {
                    previewCanvas
                        .contentShape(Rectangle())
                        .gesture(annotationGesture)
                }
                dimMask(screenBounds)
                    .allowsHitTesting(false)

                if !scrollingModel.isActive {
                    selectionBorder
                }
                selectedTextBorder
                inlineTextEditor
                if !scrollingModel.isActive {
                    sizeLabel
                    selectionHandles(bounds: selectionBounds)
                }
                toolbar(in: screenBounds)
                scrollingThumbnailRail(in: screenBounds)
                exportStatus(in: screenBounds)
            }
            .coordinateSpace(name: CaptureOverlayCoordinateSpace.name)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .onAppear {
            guard !didStartAutomaticTextAction else { return }
            if automaticallyRunsOCR {
                didStartAutomaticTextAction = true
                DispatchQueue.main.async { recognizeText() }
            } else if automaticallyRunsTranslation {
                didStartAutomaticTextAction = true
                DispatchQueue.main.async { translate() }
            }
        }
        .onChange(of: tool) { newTool in
            guard newTool == .pixelate else { return }
            _ = mosaicCache.image(for: document.image, blockSize: mosaicBlockSize)
        }
        .onChange(of: mosaicBlockSize) { value in
            guard tool == .pixelate else { return }
            _ = mosaicCache.image(for: document.image, blockSize: value)
        }
        .onChange(of: scrollingModel.isActive) { active in
            if active { hoveredToolbarHelp = nil }
        }
        .onChange(of: document.pendingImageTranslationRequest?.id) { _ in
            requestOfflineImageTranslation()
        }
        .translationTask(imageTranslationConfiguration) { session in
            guard let request = document.pendingImageTranslationRequest else { return }
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
                    status = try await availability.status(
                        for: request.paragraphs.map(\.text).joined(separator: "\n\n"),
                        to: target
                    )
                }
                guard status != .unsupported else { throw HelloXError.languageNotSupported }
                if status == .supported {
                    try await session.prepareTranslation()
                }
                var translations: [String] = []
                for paragraph in request.paragraphs {
                    let response = try await session.translate(paragraph.text)
                    translations.append(response.targetText)
                }
                document.completeOfflineImageTranslation(
                    requestID: request.id,
                    texts: translations,
                    errorMessage: nil
                )
            } catch is CancellationError {
            } catch {
                document.completeOfflineImageTranslation(
                    requestID: request.id,
                    texts: nil,
                    errorMessage: TranslationWindowModel.offlineMessage(for: error)
                )
            }
        }
    }

    private var previewCanvas: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: document.image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .allowsHitTesting(false)
            Canvas { context, _ in
                context.clip(to: Path(selection))
                for annotation in document.annotations where annotation.id != selectedAnnotationID {
                    draw(annotation, context: &context)
                }
                if document.imageTranslationBlocks.isEmpty {
                    for block in document.ocrResult?.blocks ?? [] {
                        let rect = CGRect(
                            x: selection.minX + block.boundingBox.minX * selection.width,
                            y: selection.minY + (1 - block.boundingBox.maxY) * selection.height,
                            width: block.boundingBox.width * selection.width,
                            height: block.boundingBox.height * selection.height
                        )
                        context.fill(Path(rect), with: .color(.yellow.opacity(0.12)))
                        context.stroke(Path(rect), with: .color(.yellow.opacity(0.8)), lineWidth: 1)
                    }
                }
            }
            .allowsHitTesting(false)
            .drawingGroup(opaque: false, colorMode: .linear)
            ImageTranslationCanvasOverlay(
                blocks: document.imageTranslationBlocks,
                selection: selection,
                sourceImageSize: CGSize(
                    width: CGFloat(document.image.width) * selection.width / max(1, imageFrame.width),
                    height: CGFloat(document.image.height) * selection.height / max(1, imageFrame.height)
                )
            )
            .allowsHitTesting(false)
            Canvas { context, _ in
                context.clip(to: Path(selection))
                if let draft { draw(draft, context: &context) }
                if let selectedAnnotationDraft,
                   !(isEditingText && selectedAnnotationDraft.tool == .text) {
                    draw(selectedAnnotationDraft, context: &context)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func requestOfflineImageTranslation() {
        guard let request = document.pendingImageTranslationRequest else { return }
        let source = request.sourceLanguageIdentifier.map(Locale.Language.init(identifier:))
        let target = Locale.Language(identifier: request.targetLanguageIdentifier)
        if var configuration = imageTranslationConfiguration,
           configuration.source == source,
           configuration.target == target {
            configuration.invalidate()
            imageTranslationConfiguration = configuration
        } else {
            imageTranslationConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func dimMask(_ bounds: CGRect) -> some View {
        Canvas { context, _ in
            var path = Path()
            path.addRect(bounds)
            path.addRect(selection)
                context.fill(
                    path,
                    with: .color(.black.opacity(CaptureOverlayAppearance.editorDimOpacity)),
                    style: FillStyle(eoFill: true)
                )
        }
    }

    private var selectionBorder: some View {
        Rectangle()
            .stroke(HelloXTheme.accent, lineWidth: 2)
            .frame(width: selection.width, height: selection.height)
            .position(x: selection.midX, y: selection.midY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var selectedTextBorder: some View {
        if let annotation = selectedAnnotationDraft,
           !(isEditingText && annotation.tool == .text) {
            let rect = AnnotationEditingGeometry.displayBounds(
                for: annotation,
                imageRect: imageFrame,
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
    }

    private var sizeLabel: some View {
        let width = Int((selection.width / max(1, imageFrame.width)) * CGFloat(document.image.width))
        let height = Int((selection.height / max(1, imageFrame.height)) * CGFloat(document.image.height))
        return Text("\(width) × \(height)")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HelloXTheme.accent.opacity(0.96), in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius, style: .continuous))
            .position(
                x: selection.minX + 54,
                y: selection.minY > 34 ? selection.minY - 17 : selection.minY + 18
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func selectionHandles(bounds: CGRect) -> some View {
        ForEach(SelectionHandle.allCases, id: \.rawValue) { handle in
            SelectionResizeHandle(
                handle: handle,
                selection: selectionBinding,
                bounds: bounds
            )
        }
    }

    private var selectionBinding: Binding<CGRect> {
        Binding(
            get: { selection },
            set: { value in
                selection = value
                onSelectionChange(value)
            }
        )
    }

    private func toolbar(in bounds: CGRect) -> some View {
        let propertyVisible = showsPropertyBar
        let propertyTool = selectedAnnotationDraft?.tool ?? tool
        let availableWidth = max(132, bounds.width - 24)
        let mainButtonCount = scrollingModel.isActive ? 5 : toolbarTools.count + 10
        let mainRowWidth = CaptureToolbarLayout.buttonRowWidth(count: mainButtonCount)
        let wrapsControls = !scrollingModel.isActive && mainRowWidth > availableWidth
        let wrappedRowWidth = max(
            CaptureToolbarLayout.buttonRowWidth(count: toolbarTools.count + 1),
            CaptureToolbarLayout.buttonRowWidth(count: 9)
        )
        let propertyWidth = propertyVisible
            ? AnnotationPropertyBarLayout.propertyContentWidth(for: propertyTool)
            : 0
        let preferredWidth = max(wrapsControls ? wrappedRowWidth : mainRowWidth, propertyWidth)
        let toolbarWidth = min(preferredWidth, availableWidth)
        let controlsHeight: CGFloat = scrollingModel.isActive ? 55 : (wrapsControls ? 102.5 : 65)
        let toolbarHeight = controlsHeight + (propertyVisible ? 46 : 0)
        let toolbarSize = CGSize(width: toolbarWidth, height: toolbarHeight)
        let defaultOrigin = SelectionGeometry.toolbarOrigin(selection: selection, toolbarSize: toolbarSize, within: bounds)
        return MovableToolbarContainer(
            defaultOrigin: defaultOrigin,
            toolbarSize: toolbarSize,
            bounds: bounds,
            enabled: !scrollingModel.isActive,
            onDragBegan: { hoveredToolbarHelp = nil }
        ) { origin in
            VStack(spacing: 6) {
                toolbarControls(wrapped: wrapsControls)
                    .padding(.horizontal, 9)
                    .padding(.top, scrollingModel.isActive ? 0 : 10)

                if propertyVisible {
                    AnnotationPropertyBar(
                        tool: propertyTool,
                        color: propertyColorBinding,
                        lineWidth: propertyLineWidthBinding,
                        mosaicMode: propertyMosaicModeBinding,
                        mosaicBlockSize: propertyMosaicBlockSizeBinding,
                        text: propertyTextBinding,
                        watermarkSpacing: propertyWatermarkSpacingBinding
                    )
                    .padding(.horizontal, 7)
                    .padding(.bottom, 5)
                }
            }
            .frame(width: toolbarWidth, height: toolbarHeight)
            .background {
                Color(red: 0.97, green: 0.98, blue: 0.99)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(HelloXTheme.border(for: colorScheme)))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.16), radius: 18, y: 8)
            .overlay(alignment: .top) {
                if let hoveredToolbarHelp {
                    Text(hoveredToolbarHelp)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colorScheme == .dark ? Color.white : HelloXTheme.primaryText(for: colorScheme))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            colorScheme == .dark
                                ? Color(red: 0.08, green: 0.13, blue: 0.22).opacity(0.96)
                                : Color.white.opacity(0.98),
                            in: Capsule()
                        )
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16), radius: 8, y: 3)
                        .offset(y: origin.y < 38 ? toolbarHeight + 7 : -33)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func toolbarControls(wrapped: Bool) -> some View {
        if scrollingModel.isActive {
            HStack(spacing: CaptureToolbarLayout.buttonSpacing) {
                scrollingToolbarControls
            }
            .frame(height: CaptureToolbarLayout.buttonSize)
        } else if wrapped {
            VStack(spacing: CaptureToolbarLayout.buttonSpacing) {
                HStack(spacing: CaptureToolbarLayout.buttonSpacing) {
                    annotationToolbarControls
                }
                HStack(spacing: CaptureToolbarLayout.buttonSpacing) {
                    outputToolbarControls
                }
            }
        } else {
            HStack(spacing: CaptureToolbarLayout.buttonSpacing) {
                annotationToolbarControls
                outputToolbarControls
            }
            .frame(height: CaptureToolbarLayout.buttonSize)
        }
    }

    @ViewBuilder
    private var annotationToolbarControls: some View {
        ForEach(toolbarTools) { item in toolButton(item) }
        actionButton(
            .scrolling,
            help: "滚轮截长图",
            isSelected: scrollingModel.isActive,
            action: beginScrolling
        )
    }

    @ViewBuilder
    private var outputToolbarControls: some View {
        actionButton(.undo, help: "撤销", action: undo)
        actionButton(.redo, help: "重做", action: redo)
        actionButton(.textRecognition, help: "文字识别", action: recognizeText)
        actionButton(.qrCode, help: "二维码识别", action: onQRCode)
        if document.isPerformingTranslation {
            ProgressView()
                .controlSize(.small)
                .frame(width: CaptureToolbarLayout.buttonSize, height: CaptureToolbarLayout.buttonSize)
        } else {
            actionButton(.translation, help: "翻译图片", action: translate)
        }
        actionButton(.save, help: "保存", action: save)
        actionButton(.pin, help: "钉图", action: pin)
        actionButton(.close, help: "取消", role: .destructive, action: onCancel)
        if document.isExporting {
            ProgressView()
                .controlSize(.small)
                .frame(width: CaptureToolbarLayout.buttonSize, height: CaptureToolbarLayout.buttonSize)
        } else {
            actionButton(.confirm, help: "完成并复制", role: .accent, action: complete)
        }
    }

    @ViewBuilder
    private var scrollingToolbarControls: some View {
        actionButton(.close, help: "关闭长截图", role: .destructive, action: onCancel)
        actionButton(.pen, help: "编辑", action: onEdit)
        actionButton(.pin, help: "钉在桌面", action: pin)
        actionButton(.save, help: "下载长截图", action: save)
        if document.isExporting {
            ProgressView()
                .controlSize(.small)
                .frame(width: CaptureToolbarLayout.buttonSize, height: CaptureToolbarLayout.buttonSize)
        } else {
            actionButton(.confirm, help: "完成并复制", role: .accent, action: complete)
        }
    }

    private var toolbarTools: [AnnotationTool] {
        [.select, .rectangle, .ellipse, .arrow, .line, .pen, .pixelate, .text, .watermark]
    }

    private func toolButton(_ item: AnnotationTool) -> some View {
        HelloXIconButton(
            icon: item.helloXIcon,
            help: item.helloXToolbarHelp,
            isSelected: tool == item,
            size: CaptureToolbarLayout.buttonSize,
            iconSize: CaptureToolbarLayout.iconSize,
            isBorderless: true,
            usesWhiteBackground: true,
            onHoverChange: toolbarHoverHandler(for: item.helloXToolbarHelp),
            action: { selectTool(item) }
        )
    }

    private func actionButton(
        _ icon: HelloXIconKey,
        help: String,
        isSelected: Bool = false,
        role: HelloXButtonRole = .neutral,
        action: @escaping () -> Void
    ) -> some View {
        HelloXIconButton(
            icon: icon,
            help: help,
            isSelected: isSelected,
            role: role,
            size: CaptureToolbarLayout.buttonSize,
            iconSize: CaptureToolbarLayout.iconSize,
            isBorderless: true,
            usesWhiteBackground: true,
            onHoverChange: toolbarHoverHandler(for: help),
            action: action
        )
    }

    private func toolbarHoverHandler(for help: String) -> (Bool) -> Void {
        { hovering in
            if hovering {
                hoveredToolbarHelp = help
            } else if hoveredToolbarHelp == help {
                hoveredToolbarHelp = nil
            }
        }
    }

    @ViewBuilder
    private func exportStatus(in bounds: CGRect) -> some View {
        if let message = document.exportError ?? document.exportMessage {
            let isError = document.exportError != nil
            HStack(spacing: 8) {
                HelloXIcon(icon: isError ? .warning : .success, size: 16)
                Text(message).lineLimit(2)
                if isError {
                    HelloXIconButton(icon: .update, help: "重试复制", role: .accent, action: onComplete)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isError ? HelloXTheme.error : HelloXTheme.success)
            .background(HelloXTheme.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .position(x: bounds.midX, y: max(24, selection.minY - 48))
        }
    }

    @ViewBuilder
    private func scrollingThumbnailRail(in bounds: CGRect) -> some View {
        if scrollingModel.isActive {
            let frame = ScrollingOverlayGeometry.previewFrame(
                selection: selection,
                in: bounds,
                direction: scrollingModel.direction
            )
            ScrollingCapturePreviewView(
                model: scrollingModel,
                width: frame.width,
                height: frame.height
            )
            .position(x: frame.midX, y: frame.midY)
        }
    }

    private var annotationGesture: some Gesture {
        DragGesture(minimumDistance: tool == .text || tool == .select || (tool == .pixelate && mosaicMode == .brush) ? 0 : 2)
            .onChanged { value in
                guard !scrollingModel.isActive, selection.contains(value.startLocation) else { return }
                guard tool != .watermark else { return }
                if isEditingText {
                    finishInlineTextEditing()
                    return
                }
                guard interactionThrottle.shouldProcess(value.location) else { return }
                if tool == .select {
                    updateSelectionDrag(value)
                    return
                }
                let start = normalize(value.startLocation)
                let end = normalize(value.location)
                if dragStart == nil { dragStart = start; penPoints = [start] }
                let isFreehand = tool == .pen || (tool == .pixelate && mosaicMode == .brush)
                if isFreehand, shouldAppendPenPoint(end, to: penPoints) { penPoints.append(end) }
                draft = makeAnnotation(start: start, end: end, points: isFreehand ? penPoints : [])
            }
            .onEnded { value in
                interactionThrottle.reset()
                guard tool != .watermark else { return }
                if tool == .select {
                    finishSelectionDrag()
                    return
                }
                defer { dragStart = nil; penPoints.removeAll(); draft = nil }
                guard let start = dragStart else { return }
                let end = normalize(value.location)
                let isFreehand = tool == .pen || (tool == .pixelate && mosaicMode == .brush)
                var annotation = makeAnnotation(
                    start: start,
                    end: end,
                    points: isFreehand ? penPoints + [end] : []
                )
                if tool == .text { annotation.text = "" }
                if annotation.normalizedRect.width > 0.002 || annotation.normalizedRect.height > 0.002 || tool == .text || (tool == .pixelate && mosaicMode == .brush) {
                    document.add(annotation)
                    if tool == .text {
                        selectedAnnotationID = annotation.id
                        selectedAnnotationDraft = annotation
                        propertyEditRegistered = true
                        syncProperties(from: annotation)
                        tool = .select
                        beginInlineTextEditing()
                    }
                }
            }
    }

    private var sourceImageSize: CGSize {
        CGSize(width: document.image.width, height: document.image.height)
    }

    private var showsPropertyBar: Bool {
        guard !scrollingModel.isActive else { return false }
        return tool != .select || selectedAnnotationDraft != nil
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
        finishInlineTextEditing()
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
        syncProperties(from: annotation)
    }

    private func updateSelectionDrag(_ value: DragGesture.Value) {
        if originalSelectedAnnotation == nil, originalSelection == nil {
            commitSelectedAnnotation()
            if let hit = AnnotationEditingGeometry.hitAnnotation(
                at: value.startLocation,
                annotations: document.annotations,
                imageRect: imageFrame,
                editingBounds: selection,
                sourceImageSize: sourceImageSize
            ) {
                selectedAnnotationID = hit.id
                selectedAnnotationDraft = hit
                originalSelectedAnnotation = hit
                propertyEditRegistered = false
                syncProperties(from: hit)
                didMoveSelectedText = false
            } else {
                selectedAnnotationID = nil
                selectedAnnotationDraft = nil
                propertyEditRegistered = false
                originalSelection = selection
            }
        }

        if let originalSelectedAnnotation {
            didMoveSelectedText = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
            selectedAnnotationDraft = AnnotationEditingGeometry.moved(
                originalSelectedAnnotation,
                by: value.translation,
                imageRect: imageFrame,
                editingBounds: selection,
                sourceImageSize: sourceImageSize
            )
        } else if let originalSelection {
            selectionBinding.wrappedValue = SelectionGeometry.moved(
                originalSelection,
                by: value.translation,
                within: imageFrame
            )
        }
    }

    private func finishSelectionDrag() {
        let shouldEditInline = originalSelectedAnnotation != nil && !didMoveSelectedText
        if originalSelectedAnnotation != nil {
            commitSelectedAnnotation()
            propertyEditRegistered = false
        }
        originalSelectedAnnotation = nil
        originalSelection = nil
        didMoveSelectedText = false
        if shouldEditInline, selectedAnnotationDraft?.tool == .text { beginInlineTextEditing() }
    }

    @ViewBuilder
    private var inlineTextEditor: some View {
        if isEditingText,
           let annotation = selectedAnnotationDraft,
           annotation.tool == .text {
            InlineAnnotationTextEditor(
                annotation: annotation,
                imageRect: imageFrame,
                editingBounds: selection,
                sourceImageSize: sourceImageSize,
                buffer: inlineTextBuffer,
                onCommit: finishInlineTextEditing,
                onCancel: cancelInlineTextEditing
            )
            .id(annotation.id)
        }
    }

    private func beginInlineTextEditing() {
        guard selectedAnnotationDraft?.tool == .text else { return }
        inlineTextBuffer.text = selectedAnnotationDraft?.text ?? ""
        isEditingText = true
    }

    private func finishInlineTextEditing() {
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
            annotation = AnnotationEditingGeometry.moved(
                annotation,
                by: .zero,
                imageRect: imageFrame,
                editingBounds: selection,
                sourceImageSize: sourceImageSize
            )
            textValue = annotation.text
            selectedAnnotationDraft = annotation
            persistPropertyChange(annotation)
        }
        isEditingText = false
    }

    private func cancelInlineTextEditing() {
        if inlineTextBuffer.originalText.isEmpty, let id = selectedAnnotationDraft?.id {
            document.removeAnnotation(id: id)
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
        }
        isEditingText = false
    }

    private func syncProperties(from annotation: Annotation) {
        color = Color(
            red: annotation.color.red,
            green: annotation.color.green,
            blue: annotation.color.blue,
            opacity: annotation.color.alpha
        )
        lineWidth = annotation.lineWidth
        mosaicMode = annotation.mosaicMode
        mosaicBlockSize = annotation.mosaicBlockSize
        watermarkSpacing = annotation.watermarkSpacing
        textValue = annotation.text
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

    private func complete() {
        finishInlineTextEditing()
        commitSelectedAnnotation()
        onComplete()
    }

    private func save() {
        finishInlineTextEditing()
        commitSelectedAnnotation()
        onSave()
    }

    private func pin() {
        finishInlineTextEditing()
        commitSelectedAnnotation()
        onPin()
    }

    private func recognizeText() {
        finishInlineTextEditing()
        commitSelectedAnnotation()
        onOCR()
    }

    private func translate() {
        finishInlineTextEditing()
        commitSelectedAnnotation()
        onTranslate()
    }

    private func beginScrolling() {
        finishInlineTextEditing()
        commitSelectedAnnotation()
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
        onBeginScrolling()
    }

    private func undo() {
        finishInlineTextEditing()
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
        document.undo()
    }

    private func redo() {
        finishInlineTextEditing()
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
        document.redo()
    }

    private func makeAnnotation(start: CGPoint, end: CGPoint, points: [CGPoint]) -> Annotation {
        Annotation(
            tool: tool,
            start: start,
            end: end,
            points: points,
            text: textValue,
            color: rgbaColor,
            lineWidth: lineWidth,
            mosaicMode: mosaicMode,
            mosaicBlockSize: mosaicBlockSize
        )
    }

    private var rgbaColor: RGBAColor {
        rgbaColor(from: color)
    }

    private func rgbaColor(from color: Color) -> RGBAColor {
        let value = NSColor(color).usingColorSpace(.deviceRGB) ?? .systemRed
        return RGBAColor(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent, alpha: value.alphaComponent)
    }

    private func normalize(_ point: CGPoint) -> CGPoint {
        AnnotationEditingGeometry.normalizedPoint(point, imageRect: imageFrame, editingBounds: selection)
    }

    private func shouldAppendPenPoint(_ point: CGPoint, to points: [CGPoint]) -> Bool {
        guard let previous = points.last else { return true }
        return hypot(
            (point.x - previous.x) * imageFrame.width,
            (point.y - previous.y) * imageFrame.height
        ) >= 1.5
    }

    private func draw(_ annotation: Annotation, context: inout GraphicsContext) {
        AnnotationCanvasDrawing.draw(
            annotation,
            image: document.image,
            imageRect: imageFrame,
            mosaicCache: mosaicCache,
            context: &context
        )
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageFrame.minX + point.x * imageFrame.width, y: imageFrame.minY + point.y * imageFrame.height)
    }
}

private struct ImageTranslationCanvasOverlay: View {
    let blocks: [ImageTranslationBlock]
    let selection: CGRect
    let sourceImageSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(blocks) { block in
                let rect = displayRect(for: block.boundingBox)
                let preferredSize = block.appearance.fontSize * selection.height / max(1, sourceImageSize.height)
                let fittedFontSize = ImageTranslationTextLayout.fittedFontSize(
                    for: block.text,
                    in: rect,
                    preferredSize: preferredSize
                )
                let fontSize = fittedFontSize * ImageTranslationTextLayout.forcedFontScale
                Text(block.text)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(Color(
                        red: block.appearance.foregroundColor.red,
                        green: block.appearance.foregroundColor.green,
                        blue: block.appearance.foregroundColor.blue,
                        opacity: block.appearance.foregroundColor.alpha
                    ))
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
                    .padding(.horizontal, horizontalPadding(for: fontSize))
                    .padding(.vertical, verticalPadding(for: fontSize))
                    .frame(width: rect.width, height: rect.height, alignment: .leading)
                    .background(Color(
                        red: block.appearance.backgroundColor.red,
                        green: block.appearance.backgroundColor.green,
                        blue: block.appearance.backgroundColor.blue,
                        opacity: block.appearance.backgroundColor.alpha
                    ))
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private func displayRect(for boundingBox: CGRect) -> CGRect {
        let box = boundingBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGRect(
            x: selection.minX + box.minX * selection.width,
            y: selection.minY + (1 - box.maxY) * selection.height,
            width: max(1, box.width * selection.width),
            height: max(1, box.height * selection.height)
        )
    }

    private func horizontalPadding(for fontSize: CGFloat) -> CGFloat {
        max(2, fontSize * 0.16)
    }

    private func verticalPadding(for fontSize: CGFloat) -> CGFloat {
        max(1, fontSize * 0.10)
    }
}

private struct ScrollingCapturePreviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: ManualScrollingCaptureModel
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            heightLabel
            stitchedPreview
        }
        .padding(10)
        .frame(width: width, height: height)
        .background(
            HelloXTheme.cardGradient(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.18), radius: 18, y: 8)
    }

    private var heightLabel: some View {
        Text(model.direction.isHorizontal
            ? "宽度 \(model.pixelWidth) px"
            : "高度 \(model.pixelHeight) px")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stitchedPreview: some View {
        ScrollViewReader { reader in
            ScrollView(model.direction.isHorizontal ? .horizontal : .vertical, showsIndicators: false) {
                if let image = model.stitchedImage {
                    previewImage(image)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .scrollContentBackground(.hidden)
            .seamlessScrollChrome()
            .onChange(of: model.pixelWidth &* 31 &+ model.pixelHeight) { extent in
                guard extent > 0 else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    switch model.direction {
                    case .down: reader.scrollTo("preview-end", anchor: .bottom)
                    case .up: reader.scrollTo("preview-start", anchor: .top)
                    case .right: reader.scrollTo("preview-end", anchor: .trailing)
                    case .left: reader.scrollTo("preview-start", anchor: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func previewImage(_ image: CGImage) -> some View {
        if model.direction.isHorizontal {
            let contentHeight = max(1, height - 48)
            let previewWidth = max(
                1,
                CGFloat(image.width) * contentHeight / CGFloat(max(1, image.height))
            )
            HStack(spacing: 0) {
                Color.clear.frame(width: 1).id("preview-start")
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: previewWidth, height: contentHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Color.clear.frame(width: 1).id("preview-end")
            }
        } else {
            let contentWidth = max(1, width - 20)
            let previewHeight = max(
                1,
                CGFloat(image.height) * contentWidth / CGFloat(max(1, image.width))
            )
            VStack(spacing: 0) {
                Color.clear.frame(height: 1).id("preview-start")
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: contentWidth, height: previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Color.clear.frame(height: 1).id("preview-end")
            }
        }
    }

}

private struct SelectionMoveView: View {
    @Binding var selection: CGRect
    let bounds: CGRect
    @State private var original: CGRect?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: selection.width, height: selection.height)
            .position(x: selection.midX, y: selection.midY)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if original == nil { original = selection }
                    guard let original else { return }
                    selection = SelectionGeometry.moved(original, by: value.translation, within: bounds)
                }
                .onEnded { _ in original = nil })
    }
}

private struct SelectionResizeHandle: View {
    let handle: SelectionHandle
    @Binding var selection: CGRect
    let bounds: CGRect
    @State private var original: CGRect?

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(HelloXTheme.accent)
            .frame(width: 10, height: 10)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 1))
            .position(position)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if original == nil { original = selection }
                    guard let original else { return }
                    selection = SelectionGeometry.resized(original, handle: handle, by: value.translation, within: bounds)
                }
                .onEnded { _ in original = nil })
    }

    private var position: CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: selection.minX, y: selection.minY)
        case .top: CGPoint(x: selection.midX, y: selection.minY)
        case .topRight: CGPoint(x: selection.maxX, y: selection.minY)
        case .right: CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight: CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottom: CGPoint(x: selection.midX, y: selection.maxY)
        case .bottomLeft: CGPoint(x: selection.minX, y: selection.maxY)
        case .left: CGPoint(x: selection.minX, y: selection.midY)
        }
    }
}
