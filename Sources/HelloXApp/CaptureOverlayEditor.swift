import AppKit
import ApplicationServices
import HelloXCore
import SwiftUI
@preconcurrency import Translation

struct ManualScrollingCaptureContext {
    let service: ScrollingCaptureService
    let target: HelloXCore.ScrollTarget
}

enum ScrollingOverlayGeometry {
    // Keep the passthrough exclusion in sync with the real five-button
    // scrolling toolbar. The old 186 x 44 approximation left part of the
    // toolbar clickable through the overlay and blocked nearby content.
    static var toolbarSize: CGSize {
        CGSize(
            width: CaptureToolbarLayout.buttonRowWidth(count: 5),
            height: CaptureToolbarLayout.scrollingHeight + CaptureToolbarLayout.bottomInset
        )
    }

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
    static let iconSize: CGFloat = 16
    static let buttonSpacing = AnnotationPropertyBarLayout.toolbarButtonSpacing * scale
    static let edgeInset: CGFloat = 10
    static let bottomInset: CGFloat = 3
    static let horizontalPadding = edgeInset * 2
    static let cornerRadius: CGFloat = 12
    static let singleRowHeight: CGFloat = 62
    static let wrappedRowsHeight: CGFloat = 102.5
    static let scrollingHeight: CGFloat = 46
    static let propertyRowHeight: CGFloat = 42
    static let groupSeparatorWidth: CGFloat = 5

    static func buttonRowWidth(count: Int, includesGroupSeparator: Bool = false) -> CGFloat {
        guard count > 0 else { return horizontalPadding }
        return CGFloat(count) * buttonSize
            + CGFloat(count - 1) * buttonSpacing
            + horizontalPadding
            + (includesGroupSeparator ? groupSeparatorWidth + buttonSpacing : 0)
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
                        HelloXIcon(icon: .line, size: 16)
                            .foregroundStyle(HXTextStyle.secondary)
                            .opacity(0.6)
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
            .onChange(of: enabled) { _, isEnabled in
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

@MainActor
final class ManualScrollingCaptureModel: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isReady = false
    @Published private(set) var stitchedImage: CGImage?
    @Published private(set) var pixelHeight = 0
    @Published private(set) var pixelWidth = 0
    @Published private(set) var direction: ScrollDirection = .down
    @Published private(set) var lastCaptureError: String?

    private var session: ManualScrollingCaptureSession?
    private var startTask: Task<Void, Never>?
    private var scheduledCaptureTask: Task<Void, Never>?
    private var idleCaptureTask: Task<Void, Never>?
    private var scrollDirectionHint: ScrollDirection?
    private var lastScrollDirectionHint: ScrollDirection?
    private var hasPendingScrollIntent = false
    private var pendingHorizontalDistance: CGFloat = 0
    private var pendingVerticalDistance: CGFloat = 0
    private var firstPendingScrollEventDate: Date?
    private var pendingCaptureWaitsForMovement = false
    private var wheelIntent = ScrollingWheelIntentAccumulator()
    private var eventGeneration: UInt64 = 0
    private var processedEventGeneration: UInt64 = 0
    private var captureInFlight = false

    // Capture on the leading edge of a wheel burst. A trailing debounce lets
    // fast trackpad motion cross most of a viewport before the first frame.
    private let leadingCaptureDelay: TimeInterval = 0.018
    private let idleFinalCaptureDelay: TimeInterval = 0.12

    var isPreparing: Bool { isActive && !isReady }

    func noteScroll(
        deltaX: CGFloat,
        deltaY: CGFloat,
        explicitHorizontalIntent: Bool,
        timestamp: TimeInterval
    ) {
        guard isActive, isReady else { return }
        guard let direction = wheelIntent.resolve(
            deltaX: deltaX,
            deltaY: deltaY,
            explicitHorizontalIntent: explicitHorizontalIntent,
            timestamp: timestamp
        ) else { return }
        let distance = max(abs(deltaX), abs(deltaY))
        if direction.isHorizontal {
            pendingHorizontalDistance += (direction == .right ? distance : -distance)
        } else {
            pendingVerticalDistance += (direction == .down ? distance : -distance)
        }
        hasPendingScrollIntent = true
        scrollDirectionHint = pendingBatchDirection()
        let now = Date()
        if firstPendingScrollEventDate == nil {
            firstPendingScrollEventDate = now
        }
        pendingCaptureWaitsForMovement = true
        eventGeneration &+= 1
        scheduleCaptureIfNeeded()
        scheduleIdleFinalCapture()
    }

    func begin(
        _ context: ManualScrollingCaptureContext,
        onReady: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard !isActive else { return }
        isActive = true
        isReady = false
        lastCaptureError = nil
        let session = context.service.makeManualSession(target: context.target)
        self.session = session
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Let SwiftUI remove the selection chrome before the initial
                // scrolling frame is requested.
                await Task.yield()
                self.apply(try await session.begin())
                // Publish readiness and install event routing in the same
                // MainActor turn. SwiftUI cannot render a ready state before
                // wheel monitoring and passthrough are both installed.
                self.isReady = true
                onReady()
                self.scheduleCaptureIfNeeded()
            } catch is CancellationError {
            } catch {
                let message: String
                if let helloXError = error as? HelloXError {
                    message = helloXError.errorDescription ?? error.localizedDescription
                } else {
                    message = error.localizedDescription
                }
                self.lastCaptureError = message
                // A failed initial ScreenCaptureKit request must not leave a
                // fake active session with no wheel monitors installed.
                self.session = nil
                self.isReady = false
                self.isActive = false
                self.captureInFlight = false
                self.firstPendingScrollEventDate = nil
                self.pendingCaptureWaitsForMovement = false
                onFailure(message)
            }
            self.startTask = nil
        }
    }

    func snapshot() async throws -> CaptureResult {
        guard isActive, let session else {
            throw HelloXError.captureFailed("长截图尚未开始")
        }
        await startTask?.value
        guard isReady else {
            throw HelloXError.captureFailed(lastCaptureError ?? "长截图准备失败")
        }
        return try await session.result()
    }

    func cancel() {
        startTask?.cancel()
        scheduledCaptureTask?.cancel()
        idleCaptureTask?.cancel()
        startTask = nil
        scheduledCaptureTask = nil
        idleCaptureTask = nil
        session = nil
        isActive = false
        isReady = false
        captureInFlight = false
        firstPendingScrollEventDate = nil
        pendingCaptureWaitsForMovement = false
        wheelIntent.reset()
        scrollDirectionHint = nil
        lastScrollDirectionHint = nil
        hasPendingScrollIntent = false
        pendingHorizontalDistance = 0
        pendingVerticalDistance = 0
        eventGeneration = 0
        processedEventGeneration = 0
        lastCaptureError = nil
    }

    private func scheduleCaptureIfNeeded() {
        guard isActive, isReady, session != nil, !captureInFlight,
              eventGeneration > processedEventGeneration,
              let firstPendingScrollEventDate,
              scheduledCaptureTask == nil else { return }

        let deadline = firstPendingScrollEventDate.addingTimeInterval(leadingCaptureDelay)
        let delay = max(0, deadline.timeIntervalSinceNow)
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
        guard isActive, isReady, !captureInFlight, let session,
              eventGeneration > processedEventGeneration else { return }
        scheduledCaptureTask = nil
        captureInFlight = true
        let attemptedGeneration = eventGeneration
        let direction: ScrollDirection?
        if hasPendingScrollIntent {
            direction = scrollDirectionHint
            if let direction {
                lastScrollDirectionHint = direction
            }
        } else {
            direction = lastScrollDirectionHint
        }
        let waitsForMovement = pendingCaptureWaitsForMovement
        // Events arriving while the screenshot is being captured form the next batch.
        firstPendingScrollEventDate = nil
        pendingCaptureWaitsForMovement = false
        scrollDirectionHint = nil
        hasPendingScrollIntent = false
        pendingHorizontalDistance = 0
        pendingVerticalDistance = 0
        defer {
            processedEventGeneration = max(processedEventGeneration, attemptedGeneration)
            captureInFlight = false
            scheduleCaptureIfNeeded()
        }
        do {
            if let update = try await session.captureCurrentFrame(
                directionHint: direction,
                waitsForMovement: waitsForMovement
            ) {
                lastCaptureError = nil
                apply(update)
            }
        } catch is CancellationError {
        } catch {
            if let helloXError = error as? HelloXError {
                lastCaptureError = helloXError.errorDescription
            } else {
                lastCaptureError = error.localizedDescription
            }
        }
    }

    private func scheduleIdleFinalCapture() {
        idleCaptureTask?.cancel()
        idleCaptureTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(nanoseconds: UInt64(idleFinalCaptureDelay * 1_000_000_000))
                guard !Task.isCancelled, isActive, isReady, session != nil else { return }
                idleCaptureTask = nil
                wheelIntent.reset()
                eventGeneration &+= 1
                if firstPendingScrollEventDate == nil {
                    firstPendingScrollEventDate = Date().addingTimeInterval(-leadingCaptureDelay)
                }
                scheduleCaptureIfNeeded()
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func apply(_ update: ManualScrollingCaptureUpdate) {
        stitchedImage = update.stitchedImage
        pixelHeight = update.pixelHeight
        pixelWidth = update.pixelWidth
        direction = update.direction
    }

    private func pendingBatchDirection() -> ScrollDirection? {
        let horizontalMagnitude = abs(pendingHorizontalDistance)
        let verticalMagnitude = abs(pendingVerticalDistance)
        if horizontalMagnitude > verticalMagnitude {
            guard horizontalMagnitude > 0 else { return nil }
            return pendingHorizontalDistance > 0 ? .right : .left
        }
        guard verticalMagnitude > 0 else { return nil }
        return pendingVerticalDistance > 0 ? .down : .up
    }

}

@MainActor
final class CaptureOverlayEditorController: NSWindowController {
    private static let forwardedScrollEventMarker: Int64 = 0x48454C4C4F58

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
    private var scrollingPointerMonitor: Any?
    private var localScrollingPointerMonitor: Any?
    private var scrollingTargetProcessID: pid_t?
    private var scrollingTargetCaptureRect: CGRect?
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
            onTranslate: { [weak self] in self?.translateScreenshot() },
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
        panel.acceptsMouseMovedEvents = interactive
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
            editorDocument.clearScreenshotTranslation()
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

    private func translateScreenshot() {
        editorDocument.toggleScreenshotTranslation()
    }

    private func beginScrolling() {
        guard !scrollingModel.isActive else { return }
        editorDocument.exportError = nil
        let globalFrame = Self.globalAppKitRect(currentSelection, on: targetScreen)
        guard let context = makeScrollingContext?(globalFrame) else {
            editorDocument.exportError = "找不到需要滚动的目标应用"
            NSSound.beep()
            return
        }
        scrollingModel.begin(
            context,
            onReady: { [weak self] in
                self?.startScrollingPassthrough(target: context.target)
            },
            onFailure: { [weak self] message in
                self?.stopScrollingPassthrough()
                self?.editorDocument.exportError = message
                NSSound.beep()
            }
        )
    }

    private func startScrollingPassthrough(target: HelloXCore.ScrollTarget) {
        stopScrollingPassthrough()
        scrollingTargetProcessID = target.processID
        scrollingTargetCaptureRect = target.captureRect
        let handleWheel: (NSEvent) -> Void = { [weak self] event in
            let rawDeltaX = event.scrollingDeltaX
            let rawDeltaY = event.scrollingDeltaY
            let explicitHorizontalIntent = event.modifierFlags.contains(.shift)
            // Some mouse drivers report an ordinary vertical wheel through X.
            // Preserve that compatibility while allowing precise trackpad X
            // motion to participate in axis accumulation.
            let deltaX: CGFloat
            let deltaY: CGFloat
            if !explicitHorizontalIntent, !event.hasPreciseScrollingDeltas {
                deltaX = 0
                deltaY = abs(rawDeltaY) >= 0.18 ? rawDeltaY : rawDeltaX
            } else {
                deltaX = rawDeltaX
                deltaY = rawDeltaY
            }
            let timestamp = event.timestamp
            let eventLocation = event.cgEvent?.location
            // NSEvent monitor callbacks are delivered on the main thread.
            // Handle the event synchronously and use the event's frozen Quartz
            // location so later pointer movement cannot retroactively accept
            // or reject this wheel sample.
            MainActor.assumeIsolated {
                guard let self,
                      self.shouldCaptureScrollingEvent(at: eventLocation) else { return }
                self.scrollingModel.noteScroll(
                    deltaX: deltaX,
                    deltaY: deltaY,
                    explicitHorizontalIntent: explicitHorizontalIntent,
                    timestamp: timestamp
                )
            }
        }
        localScrollingWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // If the pointer entered the capture region immediately before
            // this wheel event, AppKit may still have routed the event to the
            // overlay using the previous hit-test state. Forward that one
            // event to the target process so the first wheel tick is not lost.
            if self.shouldPassScrollingMouseEvents(),
               let targetProcessID = self.scrollingTargetProcessID,
               AXIsProcessTrusted(),
               CGPreflightPostEventAccess(),
               let cgEvent = event.cgEvent {
                self.targetPanel.ignoresMouseEvents = true
                cgEvent.setIntegerValueField(
                    .eventSourceUserData,
                    value: Self.forwardedScrollEventMarker
                )
                cgEvent.postToPid(targetProcessID)
                handleWheel(event)
                return nil
            }
            // Toolbar and preview scrolling remains local and must not create
            // a phantom capture for content that never moved.
            return event
        }
        scrollingWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                == Self.forwardedScrollEventMarker {
                return
            }
            handleWheel(event)
        }
        let pointerEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        let handlePointerMovement: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateScrollingPassthrough()
            }
        }
        localScrollingPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { event in
            handlePointerMovement(event)
            return event
        }
        scrollingPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { event in
            handlePointerMovement(event)
        }
        updateScrollingPassthrough()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateScrollingPassthrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        passthroughTimer = timer
    }

    private func updateScrollingPassthrough() {
        targetPanel.ignoresMouseEvents = shouldPassScrollingMouseEvents()
    }

    private func shouldPassScrollingMouseEvents() -> Bool {
        guard scrollingModel.isActive, scrollingModel.isReady else { return false }
        let pointer = NSEvent.mouseLocation
        let localPoint = CGPoint(
            x: pointer.x - targetScreen.frame.minX,
            y: targetScreen.frame.maxY - pointer.y
        )
        let bounds = CGRect(origin: .zero, size: targetScreen.frame.size)
        return ScrollingOverlayGeometry.shouldPassMouseEvents(
            at: localPoint,
            selection: currentSelection,
            in: bounds,
            direction: scrollingModel.direction
        )
    }

    private func shouldCaptureScrollingEvent(at eventLocation: CGPoint?) -> Bool {
        guard scrollingModel.isActive,
              scrollingModel.isReady,
              let eventLocation,
              let scrollingTargetCaptureRect else { return false }
        return scrollingTargetCaptureRect.contains(eventLocation)
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
        if let scrollingPointerMonitor {
            NSEvent.removeMonitor(scrollingPointerMonitor)
            self.scrollingPointerMonitor = nil
        }
        if let localScrollingPointerMonitor {
            NSEvent.removeMonitor(localScrollingPointerMonitor)
            self.localScrollingPointerMonitor = nil
        }
        scrollingTargetProcessID = nil
        scrollingTargetCaptureRect = nil
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
    @State private var highlightShowsBorder = false
    @State private var highlightShape: AnnotationHighlightShape = .rectangle
    @State private var textValue = "文字"
    @State private var draft: Annotation?
    @State private var dragStart: CGPoint?
    @State private var penPoints: [CGPoint] = []
    @State private var didStartAutomaticTextAction = false
    @State private var selectedAnnotationID: UUID?
    @State private var selectedAnnotationDraft: Annotation?
    @State private var originalSelectedAnnotation: Annotation?
    @State private var resizeOriginalAnnotation: Annotation?
    @State private var originalSelection: CGRect?
    @State private var propertyEditRegistered = false
    @State private var hoveredToolbarHelp: String?
    @State private var isEditingText = false
    @State private var didMoveSelectedText = false
    @State private var editsSelectedStepTextOnRelease = false
    @State private var isDraggingStepBadge = false
    @State private var isDraggingStepCard = false
    @State private var hoveredAnnotationID: UUID?
    @State private var isAnnotationSelectionInteraction = false
    @State private var inlineTextBuffer = InlineAnnotationTextBuffer()
    @State private var mosaicCache = MosaicPreviewCache()
    @State private var interactionThrottle = AnnotationInteractionThrottle()
    @State private var screenshotTranslationConfiguration: TranslationSession.Configuration?

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
                AnnotationInteractionEventView(
                    hitTarget: { point in
                        guard !scrollingModel.isActive,
                              tool != .watermark,
                              tool != .pixelate,
                              !isEditingText else { return nil }
                        return hitAnnotation(at: point)?.id
                    },
                    onHoverTargetChange: { hoveredAnnotationID = $0 },
                    onDelete: deleteSelectedAnnotation
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                dimMask(screenBounds)
                    .allowsHitTesting(false)

                if !scrollingModel.isActive {
                    selectionBorder
                }
                selectedTextBorder
                inlineTextEditor
                annotationResizeHandles
                if !scrollingModel.isActive {
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
        .onChange(of: tool) { _, newTool in
            guard newTool == .pixelate else { return }
            _ = mosaicCache.image(for: document.image, blockSize: mosaicBlockSize)
        }
        .onChange(of: mosaicBlockSize) { _, value in
            guard tool == .pixelate else { return }
            _ = mosaicCache.image(for: document.image, blockSize: value)
        }
        .onChange(of: scrollingModel.isActive) { _, active in
            if active { hoveredToolbarHelp = nil }
        }
        .onChange(of: document.pendingScreenshotTranslationRequest?.id) {
            requestOfflineScreenshotTranslation()
        }
        .translationTask(screenshotTranslationConfiguration) { session in
            guard let request = document.pendingScreenshotTranslationRequest else { return }
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
                    let sample = request.paragraphs
                        .map { ScreenshotTranslationContentPolicy.textForTranslation($0.text) }
                        .joined(separator: "\n")
                    status = try await availability.status(for: sample, to: target)
                }
                guard status != .unsupported else { throw HelloXError.languageNotSupported }
                if status == .supported { try await session.prepareTranslation() }

                var translations: [UUID: String] = [:]
                translations.reserveCapacity(request.paragraphs.count)
                for paragraph in request.paragraphs {
                    try Task.checkCancellation()
                    let protected = ScreenshotTranslationContentPolicy.protectedText(
                        ScreenshotTranslationContentPolicy.textForTranslation(paragraph.text)
                    )
                    let response = try await session.translate(protected.text)
                    translations[paragraph.id] = protected.restoring(in: response.targetText)
                }
                try Task.checkCancellation()
                document.completeOfflineScreenshotTranslation(
                    requestID: request.id,
                    translations: translations,
                    errorMessage: nil
                )
            } catch is CancellationError {
            } catch {
                document.completeOfflineScreenshotTranslation(
                    requestID: request.id,
                    translations: nil,
                    errorMessage: TranslationWindowModel.offlineMessage(for: error)
                )
            }
        }
    }

    private var previewCanvas: some View {
        let physicalScale = imageFrame.width * document.displayScale / max(1, CGFloat(document.image.width))
        return ZStack(alignment: .topLeading) {
            // The editor frame is already expressed in screen points. Passing
            // the capture's backing scale here makes SwiftUI reinterpret the
            // CGImage inside the transparent overlay and can produce a blank
            // layer on Retina displays. Keep the preview's image scale neutral.
            Image(decorative: document.image, scale: 1)
                .resizable()
                .interpolation(abs(physicalScale - 1) < 0.02 ? .none : .high)
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .allowsHitTesting(false)
            if document.showsScreenshotTranslation {
                if let reconstructedBackground = document.screenshotTranslationBackgroundImage {
                    Image(decorative: reconstructedBackground, scale: 1)
                        .resizable()
                        .interpolation(abs(physicalScale - 1) < 0.02 ? .none : .high)
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)
                }
                ScreenshotTranslationCanvasOverlay(
                    blocks: document.screenshotTranslationBlocks,
                    selection: selection,
                    sourceImageSize: document.screenshotTranslationBackgroundImage.map {
                        CGSize(width: $0.width, height: $0.height)
                    } ?? CGSize(
                        width: CGFloat(document.image.width) * selection.width / max(1, imageFrame.width),
                        height: CGFloat(document.image.height) * selection.height / max(1, imageFrame.height)
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            Canvas { context, _ in
                context.clip(to: Path(selection))
                var stepNumber = 0
                for annotation in document.annotations {
                    if annotation.tool == .step { stepNumber += 1 }
                    guard annotation.id != selectedAnnotationID else { continue }
                    draw(
                        annotation,
                        stepNumber: annotation.tool == .step ? stepNumber : nil,
                        context: &context
                    )
                }
                for block in document.hasScreenshotTranslation ? [] : (document.ocrResult?.blocks ?? []) {
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
            .allowsHitTesting(false)
            .drawingGroup(opaque: false, colorMode: .linear)
            Canvas { context, _ in
                context.clip(to: Path(selection))
                if let draft { draw(draft, stepNumber: nil, context: &context) }
                if let selectedAnnotationDraft,
                   !(isEditingText && selectedAnnotationDraft.tool.isTextual) {
                    draw(
                        selectedAnnotationDraft,
                        stepNumber: StepAnnotationNumbering.number(
                            for: selectedAnnotationDraft.id,
                            in: document.annotations
                        ),
                        context: &context
                    )
                }
            }
            .allowsHitTesting(false)
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
            .stroke(Color.white.opacity(0.88), lineWidth: 4)
            .overlay(Rectangle().stroke(HelloXTheme.accent, lineWidth: 2))
            .frame(width: selection.width, height: selection.height)
            .position(x: selection.midX, y: selection.midY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var selectedTextBorder: some View {
        if let annotation = selectedAnnotationDraft,
           !(isEditingText && annotation.tool.isTextual) {
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

    @ViewBuilder
    private var annotationResizeHandles: some View {
        if !scrollingModel.isActive,
           let annotation = selectedAnnotationDraft,
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
                        imageRect: imageFrame,
                        sourceImageSize: sourceImageSize
                    ),
                    onChanged: { translation in
                        if resizeOriginalAnnotation == nil { resizeOriginalAnnotation = annotation }
                        guard let original = resizeOriginalAnnotation else { return }
                        selectedAnnotationDraft = AnnotationEditingGeometry.resized(
                            original,
                            handle: handle,
                            by: translation,
                            imageRect: imageFrame,
                            editingBounds: selection,
                            sourceImageSize: sourceImageSize
                        )
                    },
                    onEnded: {
                        if selectedAnnotationDraft != nil, resizeOriginalAnnotation != nil {
                            commitSelectedAnnotation()
                        }
                        resizeOriginalAnnotation = nil
                        propertyEditRegistered = false
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func selectionHandles(bounds: CGRect) -> some View {
        if !document.isScreenshotTranslationSelectionLocked {
            ForEach(SelectionHandle.allCases, id: \.rawValue) { handle in
                SelectionResizeHandle(
                    handle: handle,
                    selection: selectionBinding,
                    bounds: bounds,
                    onEnded: commitSelectionChange
                )
            }
        }
    }

    private var selectionBinding: Binding<CGRect> {
        Binding(
            get: { selection },
            set: { value in
                guard !document.isScreenshotTranslationSelectionLocked else { return }
                selection = value
            }
        )
    }

    private func commitSelectionChange() {
        guard !document.isScreenshotTranslationSelectionLocked else { return }
        onSelectionChange(selection)
    }

    private func toolbar(in bounds: CGRect) -> some View {
        let propertyVisible = showsPropertyBar
        let propertyTool = selectedAnnotationDraft?.tool ?? tool
        let availableWidth = max(132, bounds.width - 24)
        let mainButtonCount = scrollingModel.isActive ? 5 : toolbarTools.count + 10
        let mainRowWidth = CaptureToolbarLayout.buttonRowWidth(
            count: mainButtonCount, includesGroupSeparator: !scrollingModel.isActive
        )
        let wrapsControls = !scrollingModel.isActive && mainRowWidth > availableWidth
        let wrappedRowWidth = max(
            CaptureToolbarLayout.buttonRowWidth(count: toolbarTools.count + 1),
            CaptureToolbarLayout.buttonRowWidth(count: 9)
        )
        let propertyWidth = propertyVisible
            ? AnnotationPropertyBarLayout.propertyContentWidth(for: propertyTool) + CaptureToolbarLayout.horizontalPadding
            : 0
        let preferredWidth = max(wrapsControls ? wrappedRowWidth : mainRowWidth, propertyWidth)
        let toolbarWidth = min(preferredWidth, availableWidth)
        let controlsHeight = scrollingModel.isActive ? CaptureToolbarLayout.scrollingHeight
            : (wrapsControls ? CaptureToolbarLayout.wrappedRowsHeight : CaptureToolbarLayout.singleRowHeight)
        let toolbarHeight = controlsHeight + (propertyVisible ? CaptureToolbarLayout.propertyRowHeight : 0)
            + CaptureToolbarLayout.bottomInset
        let toolbarSize = CGSize(width: toolbarWidth, height: toolbarHeight)
        let defaultOrigin = SelectionGeometry.toolbarOrigin(selection: selection, toolbarSize: toolbarSize, within: bounds)
        return MovableToolbarContainer(
            defaultOrigin: defaultOrigin,
            toolbarSize: toolbarSize,
            bounds: bounds,
            enabled: !scrollingModel.isActive,
            onDragBegan: { hoveredToolbarHelp = nil }
        ) { origin in
            VStack(spacing: 4) {
                if !scrollingModel.isActive {
                    HStack {
                        Text(captureSizeDescription)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 14)
                    .padding(.horizontal, CaptureToolbarLayout.edgeInset)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
                }

                toolbarControls(wrapped: wrapsControls)
                    .padding(.horizontal, CaptureToolbarLayout.edgeInset)

                if propertyVisible {
                    AnnotationPropertyBar(
                        tool: propertyTool,
                        color: propertyColorBinding,
                        lineWidth: propertyLineWidthBinding,
                        mosaicMode: propertyMosaicModeBinding,
                        mosaicBlockSize: propertyMosaicBlockSizeBinding,
                        text: propertyTextBinding,
                        watermarkSpacing: propertyWatermarkSpacingBinding,
                        highlightShowsBorder: propertyHighlightShowsBorderBinding,
                        highlightShape: propertyHighlightShapeBinding
                    )
                    .padding(.horizontal, CaptureToolbarLayout.edgeInset)
                    .padding(.bottom, 3)
                }
            }
            .padding(.bottom, CaptureToolbarLayout.bottomInset)
            .frame(width: toolbarWidth, height: toolbarHeight)
            .background {
                HelloXTheme.surface(for: colorScheme)
                    .opacity(0.97)
                    .clipShape(RoundedRectangle(cornerRadius: CaptureToolbarLayout.cornerRadius, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: CaptureToolbarLayout.cornerRadius).stroke(HelloXTheme.border(for: colorScheme)))
            .shadow(color: .black.opacity(0.20), radius: 12, y: 4)
            .overlay(alignment: .top) {
                if let hoveredToolbarHelp {
                    Text(hoveredToolbarHelp)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            HelloXTheme.controlBackground(for: colorScheme).opacity(0.98),
                            in: Capsule()
                        )
                        .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 8, y: 3)
                        .offset(y: origin.y < 38 ? toolbarHeight + 7 : -33)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var captureSizeDescription: String {
        let width = Int((selection.width / max(1, imageFrame.width)) * CGFloat(document.image.width))
        let height = Int((selection.height / max(1, imageFrame.height)) * CGFloat(document.image.height))
        return "\(width) × \(height) px"
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
                Rectangle()
                    .fill(HelloXTheme.border(for: colorScheme))
                    .frame(width: 1, height: 22)
                    .frame(width: CaptureToolbarLayout.groupSeparatorWidth)
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
            actionButton(
                .translation,
                help: !document.hasScreenshotTranslation
                    ? "截图翻译"
                    : (document.showsScreenshotTranslation ? "查看原图" : "查看译文"),
                isSelected: document.hasScreenshotTranslation && document.showsScreenshotTranslation,
                action: translate
            )
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
        if scrollingModel.isPreparing {
            ProgressView()
                .controlSize(.small)
                .frame(width: CaptureToolbarLayout.buttonSize, height: CaptureToolbarLayout.buttonSize)
            Text("正在准备长截图…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                .frame(maxWidth: .infinity)
        } else {
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
    }

    private var toolbarTools: [AnnotationTool] {
        [.select, .rectangle, .highlight, .ellipse, .arrow, .line, .pen, .pixelate, .text, .step, .watermark]
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
            usesPureWhiteIconInDarkMode: true,
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
            usesPureWhiteIconInDarkMode: true,
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
        if let message = document.screenshotTranslationError ?? document.exportError ?? document.exportMessage {
            let isTranslationError = document.screenshotTranslationError != nil
            let isError = isTranslationError || document.exportError != nil
            HStack(spacing: 8) {
                HelloXIcon(icon: isError ? .warning : .success, size: 16)
                Text(message).lineLimit(2)
                if isError {
                    HelloXIconButton(
                        icon: .update,
                        help: isTranslationError ? "重试截图翻译" : "重试复制",
                        role: .accent,
                        action: isTranslationError ? translate : onComplete
                    )
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
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(CaptureOverlayCoordinateSpace.name)
        )
            .onChanged { value in
                guard !scrollingModel.isActive, selection.contains(value.startLocation) else { return }
                guard tool != .watermark else { return }
                if isEditingText {
                    let startsStepBadgeDrag = selectedAnnotationDraft.map {
                        AnnotationEditingGeometry.isStepBadge(
                            at: value.startLocation,
                            annotation: $0,
                            number: StepAnnotationNumbering.number(
                                for: $0.id,
                                in: document.annotations
                            ) ?? 1,
                            imageRect: imageFrame,
                            sourceImageSize: sourceImageSize
                        )
                    } ?? false
                    finishInlineTextEditing(
                        keepsSelection: startsStepBadgeDrag,
                        whenStartingStepBadgeDrag: startsStepBadgeDrag
                    )
                    if startsStepBadgeDrag, let selectedAnnotationDraft {
                        originalSelectedAnnotation = selectedAnnotationDraft
                        isDraggingStepBadge = true
                        isDraggingStepCard = false
                        didMoveSelectedText = false
                        editsSelectedStepTextOnRelease = false
                        isAnnotationSelectionInteraction = true
                        updateSelectionDrag(value)
                    }
                    return
                }
                guard interactionThrottle.shouldProcess(value.location) else { return }
                if dragStart == nil, originalSelectedAnnotation == nil, originalSelection == nil,
                   !isAnnotationSelectionInteraction {
                    let hit = hitAnnotation(at: value.startLocation)
                    if hoveredAnnotationID != hit?.id { hoveredAnnotationID = hit?.id }
                    if tool == .select || (tool != .pixelate && hit != nil) {
                        isAnnotationSelectionInteraction = true
                    } else {
                        selectedAnnotationID = nil
                        selectedAnnotationDraft = nil
                        propertyEditRegistered = false
                    }
                }
                if isAnnotationSelectionInteraction {
                    updateSelectionDrag(value)
                    return
                }
                let start = normalize(value.startLocation)
                let end = normalize(value.location)
                if dragStart == nil { dragStart = start; penPoints = [start] }
                if tool == .step {
                    draft = nil
                    return
                }
                let isFreehand = tool == .pen || (tool == .pixelate && mosaicMode == .brush)
                if isFreehand, shouldAppendPenPoint(end, to: penPoints) { penPoints.append(end) }
                draft = makeAnnotation(start: start, end: end, points: isFreehand ? penPoints : [])
            }
            .onEnded { value in
                interactionThrottle.reset()
                guard tool != .watermark else { return }
                if isAnnotationSelectionInteraction {
                    finishSelectionDrag()
                    isAnnotationSelectionInteraction = false
                    return
                }
                defer { dragStart = nil; penPoints.removeAll(); draft = nil }
                guard let start = dragStart else { return }
                let end = normalize(value.location)
                let isFreehand = tool == .pen || (tool == .pixelate && mosaicMode == .brush)
                var annotation: Annotation
                if tool == .step {
                    annotation = AnnotationEditingGeometry.makeStepAnnotation(
                        at: value.startLocation,
                        number: document.annotations.filter { $0.tool == .step }.count + 1,
                        imageRect: imageFrame,
                        editingBounds: selection,
                        sourceImageSize: sourceImageSize,
                        color: rgbaColor,
                        lineWidth: lineWidth
                    )
                } else {
                    annotation = makeAnnotation(
                        start: start,
                        end: end,
                        points: isFreehand ? penPoints + [end] : []
                    )
                }
                if tool == .text || tool == .step { annotation.text = "" }
                if annotation.normalizedRect.width > 0.002 || annotation.normalizedRect.height > 0.002 || tool == .text || tool == .step || (tool == .pixelate && mosaicMode == .brush) {
                    document.add(annotation)
                    if tool == .text || tool == .step {
                        selectedAnnotationID = annotation.id
                        selectedAnnotationDraft = annotation
                        propertyEditRegistered = true
                        syncProperties(from: annotation)
                        if AnnotationInlineEditingPolicy.beginsImmediatelyAfterCreation(for: tool) {
                            beginInlineTextEditing()
                        }
                    } else {
                        selectedAnnotationID = nil
                        selectedAnnotationDraft = nil
                        propertyEditRegistered = false
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
                if selected.tool == .step {
                    selected = AnnotationEditingGeometry.fittedStepAnnotation(
                        selected,
                        number: StepAnnotationNumbering.number(
                            for: selected.id,
                            in: document.annotations
                        ) ?? 1,
                        imageRect: imageFrame,
                        editingBounds: selection,
                        sourceImageSize: sourceImageSize
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
        finishInlineTextEditing()
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
                didMoveSelectedText = false
                let stepNumber = StepAnnotationNumbering.number(
                    for: hit.id,
                    in: document.annotations
                ) ?? 1
                isDraggingStepBadge = hit.tool == .step
                    && AnnotationEditingGeometry.isStepBadge(
                        at: value.startLocation,
                        annotation: hit,
                        number: stepNumber,
                        imageRect: imageFrame,
                        sourceImageSize: sourceImageSize
                    )
                isDraggingStepCard = hit.tool == .step
                    && !isDraggingStepBadge
                    && AnnotationEditingGeometry.isStepTextInput(
                        at: value.startLocation,
                        annotation: hit,
                        number: stepNumber,
                        imageRect: imageFrame,
                        sourceImageSize: sourceImageSize
                    )
                editsSelectedStepTextOnRelease = isDraggingStepCard
            } else {
                selectedAnnotationID = nil
                selectedAnnotationDraft = nil
                propertyEditRegistered = false
                if !document.isScreenshotTranslationSelectionLocked {
                    originalSelection = selection
                }
            }
        }

        if let originalSelectedAnnotation {
            didMoveSelectedText = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
            if isDraggingStepBadge {
                selectedAnnotationDraft = AnnotationEditingGeometry.movedStepBadge(
                    originalSelectedAnnotation,
                    by: value.translation,
                    number: StepAnnotationNumbering.number(
                        for: originalSelectedAnnotation.id,
                        in: document.annotations
                    ) ?? 1,
                    imageRect: imageFrame,
                    editingBounds: selection,
                    sourceImageSize: sourceImageSize
                )
            } else if isDraggingStepCard {
                selectedAnnotationDraft = AnnotationEditingGeometry.movedStepCard(
                    originalSelectedAnnotation,
                    by: value.translation,
                    number: StepAnnotationNumbering.number(
                        for: originalSelectedAnnotation.id,
                        in: document.annotations
                    ) ?? 1,
                    imageRect: imageFrame,
                    editingBounds: selection,
                    sourceImageSize: sourceImageSize
                )
            } else {
                selectedAnnotationDraft = AnnotationEditingGeometry.moved(
                    originalSelectedAnnotation,
                    by: value.translation,
                    imageRect: imageFrame,
                    editingBounds: selection,
                    sourceImageSize: sourceImageSize
                )
            }
        } else if let originalSelection,
                  !document.isScreenshotTranslationSelectionLocked {
            selectionBinding.wrappedValue = SelectionGeometry.moved(
                originalSelection,
                by: value.translation,
                within: imageFrame
            )
        }
    }

    private func finishSelectionDrag() {
        let shouldEditInline = originalSelectedAnnotation != nil && !didMoveSelectedText
        let shouldEditStepText = shouldEditInline && editsSelectedStepTextOnRelease
        if originalSelectedAnnotation != nil {
            commitSelectedAnnotation()
            propertyEditRegistered = false
        } else if originalSelection != nil,
                  !document.isScreenshotTranslationSelectionLocked {
            commitSelectionChange()
        }
        originalSelectedAnnotation = nil
        originalSelection = nil
        didMoveSelectedText = false
        editsSelectedStepTextOnRelease = false
        isDraggingStepBadge = false
        isDraggingStepCard = false
        if shouldEditInline, selectedAnnotationDraft?.tool == .text {
            beginInlineTextEditing()
        } else if shouldEditStepText, selectedAnnotationDraft?.tool == .step {
            beginInlineTextEditing()
        }
    }

    @ViewBuilder
    private var inlineTextEditor: some View {
        if isEditingText,
           let annotation = selectedAnnotationDraft,
           annotation.tool == .text || annotation.tool == .step {
            InlineAnnotationTextEditor(
                annotation: annotation,
                imageRect: imageFrame,
                editingBounds: selection,
                sourceImageSize: sourceImageSize,
                stepNumber: StepAnnotationNumbering.number(for: annotation.id, in: document.annotations),
                buffer: inlineTextBuffer,
                onCommit: { finishInlineTextEditing() },
                onCancel: cancelInlineTextEditing
            )
            .id(annotation.id)
        }
    }

    private func beginInlineTextEditing() {
        guard selectedAnnotationDraft?.tool == .text || selectedAnnotationDraft?.tool == .step else { return }
        inlineTextBuffer.text = selectedAnnotationDraft?.text ?? ""
        isEditingText = true
    }

    private func finishInlineTextEditing(
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
                    document.removeAnnotation(id: annotation.id)
                    selectedAnnotationID = nil
                    selectedAnnotationDraft = nil
                } else {
                    annotation.text = ""
                    selectedAnnotationDraft = annotation
                    persistPropertyChange(annotation)
                }
                isEditingText = false
                propertyEditRegistered = false
                return
            }
            annotation.text = value
            if annotation.tool == .step {
                annotation = AnnotationEditingGeometry.fittedStepAnnotation(
                    annotation,
                    number: StepAnnotationNumbering.number(
                        for: annotation.id,
                        in: document.annotations
                    ) ?? 1,
                    imageRect: imageFrame,
                    editingBounds: selection,
                    sourceImageSize: sourceImageSize
                )
            }
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
        if !keepsSelection {
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
        }
        propertyEditRegistered = false
    }

    private func cancelInlineTextEditing() {
        if inlineTextBuffer.originalText.isEmpty, let id = selectedAnnotationDraft?.id {
            document.removeAnnotation(id: id)
            selectedAnnotationID = nil
            selectedAnnotationDraft = nil
        }
        isEditingText = false
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        propertyEditRegistered = false
    }

    private func hitAnnotation(at point: CGPoint) -> Annotation? {
        AnnotationEditingGeometry.hitAnnotation(
            at: point,
            annotations: document.annotations,
            imageRect: imageFrame,
            editingBounds: selection,
            sourceImageSize: sourceImageSize
        )
    }

    private func deleteSelectedAnnotation() -> Bool {
        guard !isEditingText, let id = selectedAnnotationID else { return false }
        document.removeAnnotation(id: id)
        selectedAnnotationID = nil
        selectedAnnotationDraft = nil
        originalSelectedAnnotation = nil
        resizeOriginalAnnotation = nil
        propertyEditRegistered = false
        isAnnotationSelectionInteraction = false
        editsSelectedStepTextOnRelease = false
        isDraggingStepBadge = false
        isDraggingStepCard = false
        return true
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

    private func requestOfflineScreenshotTranslation() {
        guard let request = document.pendingScreenshotTranslationRequest else { return }
        let source = request.sourceLanguageIdentifier.map(Locale.Language.init(identifier:))
        let target = Locale.Language(identifier: request.targetLanguageIdentifier)
        if var configuration = screenshotTranslationConfiguration,
           configuration.source == source,
           configuration.target == target {
            configuration.invalidate()
            screenshotTranslationConfiguration = configuration
        } else {
            screenshotTranslationConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
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
            mosaicBlockSize: mosaicBlockSize,
            highlightShowsBorder: highlightShowsBorder,
            highlightShape: highlightShape
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

    private func draw(
        _ annotation: Annotation,
        stepNumber: Int?,
        context: inout GraphicsContext
    ) {
        AnnotationCanvasDrawing.draw(
            annotation,
            stepNumber: stepNumber,
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

private struct ScreenshotTranslationCanvasOverlay: NSViewRepresentable {
    let blocks: [ScreenshotTranslationBlock]
    let selection: CGRect
    let sourceImageSize: CGSize

    func makeNSView(context: Context) -> ScreenshotTranslationOverlayNSView {
        ScreenshotTranslationOverlayNSView()
    }

    func updateNSView(_ nsView: ScreenshotTranslationOverlayNSView, context: Context) {
        nsView.blocks = blocks
        nsView.selection = selection
        nsView.sourceImageSize = sourceImageSize
        nsView.needsDisplay = true
    }
}

private final class ScreenshotTranslationOverlayNSView: NSView {
    var blocks: [ScreenshotTranslationBlock] = []
    var selection: CGRect = .zero
    var sourceImageSize: CGSize = .zero

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard selection.width > 0, selection.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        ScreenshotTranslationDrawing.draw(
            blocks,
            in: selection,
            sourceImageSize: sourceImageSize
        )
        NSGraphicsContext.restoreGraphicsState()
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
        .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 18, y: 8)
    }

    private var heightLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isPreparing {
                Text("正在取得初始画面…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
            } else {
                Text(model.direction.isHorizontal
                    ? "宽度 \(model.pixelWidth) px"
                    : "高度 \(model.pixelHeight) px")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                Text("将鼠标移入截图区域后滚动")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            }
            if let error = model.lastCaptureError {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
            }
        }
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
            .onChange(of: model.pixelWidth &* 31 &+ model.pixelHeight) { _, extent in
                guard extent > 0 else { return }
                switch model.direction {
                case .down: reader.scrollTo("preview-end", anchor: .bottom)
                case .up: reader.scrollTo("preview-start", anchor: .top)
                case .right: reader.scrollTo("preview-end", anchor: .trailing)
                case .left: reader.scrollTo("preview-start", anchor: .leading)
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

private struct SelectionResizeHandle: View {
    let handle: SelectionHandle
    @Binding var selection: CGRect
    let bounds: CGRect
    let onEnded: () -> Void
    @State private var original: CGRect?

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(HelloXTheme.accent)
            .frame(width: 10, height: 10)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(HelloXTheme.prominentForeground, lineWidth: 1))
            .position(position)
            .gesture(DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(CaptureOverlayCoordinateSpace.name)
            )
                .onChanged { value in
                    if original == nil { original = selection }
                    guard let original else { return }
                    selection = SelectionGeometry.resized(original, handle: handle, by: value.translation, within: bounds)
                }
                .onEnded { _ in
                    original = nil
                    onEnded()
                })
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
