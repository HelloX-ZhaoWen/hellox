@preconcurrency import ApplicationServices
import AppKit
import HelloXCore
import QuartzCore
import SwiftUI

enum CaptureOverlayAppearance {
    static let selectionDimOpacity: CGFloat = 0.44
    static let liveDimOpacity: CGFloat = selectionDimOpacity
    static let frozenDimOpacity: CGFloat = selectionDimOpacity
    static let editorDimOpacity: CGFloat = selectionDimOpacity
}

struct SelectionFrozenDisplay {
    let frame: CGRect
    let image: CGImage
}

enum SelectionWindowTargetPolicy {
    // Capturing HelloX itself is supported, so ownership must not disqualify an
    // otherwise normal window. Capture overlay panels use a nonzero window layer.
    static func isEligible(
        ownerPID: pid_t?,
        layer: Int?,
        alpha: Double,
        rect: CGRect,
        allowedRect: CGRect?
    ) -> Bool {
        guard ownerPID != nil,
              layer == 0,
              alpha > 0.01,
              rect.width >= 80,
              rect.height >= 60 else {
            return false
        }
        return allowedRect.map { $0.intersects(rect) } ?? true
    }

    static func blocksLowerTargets(
        ownerPID: pid_t?,
        layer: Int?,
        alpha: Double,
        rect: CGRect,
        screenFrames: [CGRect],
        allowedRect: CGRect?
    ) -> Bool {
        guard ownerPID != nil,
              layer != nil,
              alpha > 0.01,
              rect.width >= 8,
              rect.height >= 8,
              allowedRect.map({ $0.intersects(rect) }) ?? true else {
            return false
        }
        return !screenFrames.contains { isSystemBackdrop(rect: rect, screenFrame: $0) }
    }

    private static func isSystemBackdrop(rect: CGRect, screenFrame: CGRect) -> Bool {
        let screenArea = max(1, screenFrame.width * screenFrame.height)
        let rectArea = rect.width * rect.height
        guard rectArea >= screenArea * 0.80,
              abs(rect.minX - screenFrame.minX) <= 2,
              abs(rect.minY - screenFrame.minY) <= 2,
              abs(rect.width - screenFrame.width) <= 4,
              abs(rect.height - screenFrame.height) <= 4 else {
            return false
        }
        return true
    }

    static func hitIndex<Candidate>(
        in candidates: [Candidate],
        at point: CGPoint,
        rect: (Candidate) -> CGRect,
        isSelectable: (Candidate) -> Bool,
        blocksLowerTargets: (Candidate) -> Bool
    ) -> Int? {
        for index in candidates.indices where rect(candidates[index]).contains(point) {
            if isSelectable(candidates[index]) { return index }
            if blocksLowerTargets(candidates[index]) { return nil }
        }
        return nil
    }
}

enum SelectionScreenPolicy {
    static func dragBounds(
        at point: CGPoint,
        allowedRect: CGRect?,
        screenFrames: [CGRect]
    ) -> CGRect? {
        allowedRect ?? screenFrames.first(where: { $0.contains(point) })
    }

    static func bestDisplayIndex(for selection: CGRect, displayFrames: [CGRect]) -> Int? {
        displayFrames.indices.max { lhs, rhs in
            intersectionArea(selection, displayFrames[lhs]) < intersectionArea(selection, displayFrames[rhs])
        }.flatMap { intersectionArea(selection, displayFrames[$0]) > 0 ? $0 : nil }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

struct SelectionSemanticCandidate: Equatable, Sendable {
    let rect: CGRect
    let role: String
    let depth: Int
}

enum SelectionSemanticTargetPolicy {
    static func preferredIndex(
        in candidates: [SelectionSemanticCandidate],
        windowRect: CGRect,
        pointer: CGPoint
    ) -> Int? {
        candidates.indices
            .filter { isSelectable(candidates[$0], windowRect: windowRect, pointer: pointer) }
            .min { lhs, rhs in
                score(candidates[lhs], windowRect: windowRect) < score(candidates[rhs], windowRect: windowRect)
            }
    }

    static func isSelectable(
        _ candidate: SelectionSemanticCandidate,
        windowRect: CGRect,
        pointer: CGPoint
    ) -> Bool {
        guard candidate.rect.contains(pointer),
              candidate.rect.width >= 24,
              candidate.rect.height >= 18,
              candidate.rect.width * candidate.rect.height >= 900 else {
            return false
        }
        let area = candidate.rect.width * candidate.rect.height
        let windowArea = max(1, windowRect.width * windowRect.height)
        guard area < windowArea * 0.92 else { return false }
        return !ignoredRoles.contains(candidate.role)
    }

    static func label(for role: String) -> String {
        switch role {
        case "AXButton", "AXCheckBox", "AXRadioButton": return "按钮"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "输入框"
        case "AXStaticText": return "文本"
        case "AXTable": return "表格"
        case "AXOutline", "AXList", "AXBrowser": return "列表"
        case "AXRow": return "行"
        case "AXCell": return "单元格"
        case "AXImage": return "图片"
        case "AXLink": return "链接"
        case "AXToolbar": return "工具栏"
        case "AXScrollArea": return "滚动区域"
        case "AXGroup", "AXRadioGroup": return "区域"
        case "AXSheet", "AXDialog", "AXPopover": return "弹窗"
        default: return "区域"
        }
    }

    private static let ignoredRoles: Set<String> = [
        "AXWindow",
        "AXApplication",
        "AXMenuBar",
        "AXMenu",
        "AXMenuItem",
        "AXUnknown"
    ]

    private static func score(_ candidate: SelectionSemanticCandidate, windowRect: CGRect) -> CGFloat {
        let area = candidate.rect.width * candidate.rect.height
        let windowArea = max(1, windowRect.width * windowRect.height)
        let areaRatio = area / windowArea
        let tinyPenalty: CGFloat = area < 2_500 ? 6 : 0
        let smallControlPenalty: CGFloat = smallControlRoles.contains(candidate.role) ? 2.5 : 0
        let hugePenalty: CGFloat = areaRatio > 0.72 ? 4 : 0
        return CGFloat(candidate.depth) + tinyPenalty + smallControlPenalty + hugePenalty
    }

    private static let smallControlRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXCell",
        "AXStaticText",
        "AXLink"
    ]
}

struct CaptureOverlayPanelHandoff {
    let targetPanel: SelectionPanel
    let targetCanvas: CaptureOverlayCanvasView
    let dimPanels: [SelectionPanel]
}

/// Owns the overlay's entire lifetime. Selection and editing are sibling layers
/// inside this one root view, so the handoff never replaces the panel contentView
/// or waits for another run-loop turn to present a second window tree.
@MainActor
final class CaptureOverlayCanvasView: NSView {
    private let selectionContentView: NSView
    private(set) var editorContentView: NSView?

    init(frame: CGRect, selectionContentView: NSView) {
        self.selectionContentView = selectionContentView
        super.init(frame: CGRect(origin: .zero, size: frame.size))
        wantsLayer = true
        layer?.drawsAsynchronously = false
        selectionContentView.frame = bounds
        selectionContentView.autoresizingMask = [.width, .height]
        selectionContentView.wantsLayer = true
        addSubview(selectionContentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stageEditor(_ view: NSView) {
        guard editorContentView == nil else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.alphaValue = 0
        addSubview(view, positioned: .above, relativeTo: selectionContentView)
        editorContentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    func activateEditor() {
        guard let editorContentView else { return }
        layoutSubtreeIfNeeded()
        editorContentView.layoutSubtreeIfNeeded()
        editorContentView.displayIfNeeded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionContentView.isHidden = true
        editorContentView.alphaValue = 1
        CATransaction.commit()
        displayIfNeeded()
    }

}

/// Uses one overlay per display so selection remains reliable across Spaces and
/// mixed multi-display layouts.
@MainActor
final class SelectionOverlayController: NSObject {
    private enum HoverTiming {
        static let semanticDebounceNanoseconds: UInt64 = 220_000_000
        static let semanticRetentionOutset: CGFloat = 4
    }

    private enum TargetKind: Sendable { case semantic, window, display }
    private struct Target: Sendable {
        let rect: CGRect
        let kind: TargetKind
        let label: String
        let processID: pid_t?
        let windowID: CGWindowID?
        let role: String?
        let depth: Int
    }
    private struct WindowHitCandidate {
        let rect: CGRect
        let target: Target?
        let blocksLowerTargets: Bool
    }

    private let completion: (Result<CGRect, Error>) -> Void
    private let allowedRect: CGRect?
    private let frozenImage: CGImage?
    private let frozenDisplays: [SelectionFrozenDisplay]
    private let rendersFrozenBackdrop: Bool
    private let preservesSuccessfulSelectionForHandoff: Bool
    private let prefersDisplayTargetForClick: Bool
    private var windows: [SelectionPanel] = []
    private var views: [SelectionView] = []
    private var canvases: [CaptureOverlayCanvasView] = []
    private var windowHitCandidates: [WindowHitCandidate] = []
    private var hoveredTarget: Target?
    private var hoverCycleTargets: [Target] = []
    private var hoverCycleIndex = 0
    private var semanticHoverTask: Task<Void, Never>?
    private var semanticHoverGeneration = 0
    private var canUseSemanticSelection = AXIsProcessTrusted()
    private var acceptsMouseInputAfter: CFTimeInterval = 0
    private var pressedTarget: Target?
    private var selectionStart: CGPoint?
    private var activeSelectionBounds: CGRect?
    private var isDragging = false
    private var escapeMonitor: Any?
    private var finished = false

    init(
        allowedRect: CGRect? = nil,
        frozenImage: CGImage? = nil,
        frozenDisplays: [SelectionFrozenDisplay] = [],
        rendersFrozenBackdrop: Bool = true,
        preservesSuccessfulSelectionForHandoff: Bool = false,
        prefersDisplayTargetForClick: Bool = false,
        completion: @escaping (Result<CGRect, Error>) -> Void
    ) {
        self.completion = completion
        self.allowedRect = allowedRect
        self.frozenImage = frozenImage
        self.frozenDisplays = frozenDisplays
        self.rendersFrozenBackdrop = rendersFrozenBackdrop
        self.preservesSuccessfulSelectionForHandoff = preservesSuccessfulSelectionForHandoff
        self.prefersDisplayTargetForClick = prefersDisplayTargetForClick
        super.init()
        windowHitCandidates = Self.discoverWindowHitCandidates(inside: allowedRect)
        createWindows()
    }

    deinit {
        semanticHoverTask?.cancel()
    }

    func show() {
        acceptsMouseInputAfter = CACurrentMediaTime() + 0.18
        let mouseLocation = NSEvent.mouseLocation
        // Resolve the highlighted target before the panels become visible. If
        // this happens after orderFront, WindowServer can present one fully
        // dimmed frame before the selection hole is drawn.
        hover(at: mouseLocation)
        for window in windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        for window in windows {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
        let keyWindow = windows.first(where: { $0.frame.contains(mouseLocation) }) ?? windows.first
        // Every panel is already visible. Only change keyboard focus here;
        // ordering the key panel a second time can produce another WindowServer
        // presentation transaction on the first capture frame.
        keyWindow?.makeKey()
        if let keyWindow,
           let viewIndex = windows.firstIndex(where: { $0 === keyWindow }) {
            keyWindow.makeFirstResponder(views[viewIndex])
        } else {
            keyWindow?.makeFirstResponder(keyWindow?.contentView)
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.finish(.failure(HelloXError.cancelled))
                return nil
            }
            if event.keyCode == 48 {
                let direction = event.modifierFlags.contains(.shift) ? -1 : 1
                self?.cycleHoverTarget(by: direction)
                return nil
            }
            return event
        }
    }

    private func createWindows() {
        for screen in NSScreen.screens {
            let panel = SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.setFrame(screen.frame, display: true)
            let screenFrozenImage = allowedRect.map {
                screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY))
            } == true ? frozenImage : nil
            let displayImage = frozenDisplays.first(where: {
                $0.frame == screen.frame || $0.frame.contains(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            })?.image
            let resolvedFrozenImage = displayImage ?? screenFrozenImage
            let drawsFrozenImage = resolvedFrozenImage != nil && rendersFrozenBackdrop
            panel.animationBehavior = .none
            panel.alphaValue = 1
            panel.isOpaque = drawsFrozenImage
            panel.backgroundColor = drawsFrozenImage ? .black : .clear
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hasShadow = false
            panel.isMovable = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false

            let view = SelectionView(
                screenFrame: screen.frame,
                frozenImage: resolvedFrozenImage,
                rendersFrozenBackdrop: rendersFrozenBackdrop
            )
            view.onHover = { [weak self] point in self?.hover(at: point) }
            view.onBegin = { [weak self] point in self?.begin(at: point) }
            view.onChange = { [weak self] point in self?.change(to: point) }
            view.onComplete = { [weak self] point in self?.complete(at: point) }
            view.onCycleTarget = { [weak self] direction in self?.cycleHoverTarget(by: direction) }
            view.onCancel = { [weak self] in self?.finish(.failure(HelloXError.cancelled)) }
            let canvas = CaptureOverlayCanvasView(frame: screen.frame, selectionContentView: view)
            panel.contentView = canvas
            windows.append(panel)
            views.append(view)
            canvases.append(canvas)
        }
    }

    private func hover(at point: CGPoint) {
        guard selectionStart == nil else { return }
        let target = target(at: point)
        if keepsCurrentSemanticTarget(at: point, hostTarget: target) {
            scheduleSemanticHover(at: point, hostTarget: semanticHostTarget(fallback: target))
            return
        }
        applyHoverTarget(target, cycleTargets: target.map { [$0] } ?? [])
        scheduleSemanticHover(at: point, hostTarget: target)
    }

    private func applyHoverTarget(_ target: Target?, cycleTargets: [Target]) {
        let nextCycleIndex = target.flatMap { selected in
            cycleTargets.firstIndex { Self.sameTarget($0, selected) }
        } ?? 0
        if Self.sameTarget(hoveredTarget, target),
           hoverCycleIndex == nextCycleIndex,
           Self.sameTargets(hoverCycleTargets, cycleTargets) {
            return
        }
        hoveredTarget = target
        hoverCycleTargets = cycleTargets
        hoverCycleIndex = nextCycleIndex
        for view in views {
            view.highlightedRect = target?.rect
            view.highlightLabel = target?.label ?? ""
            view.highlightCutsOut = target?.kind != .display
            view.needsDisplay = true
        }
    }

    private func keepsCurrentSemanticTarget(at point: CGPoint, hostTarget: Target?) -> Bool {
        guard let hoveredTarget,
              hoveredTarget.kind == .semantic,
              hoveredTarget.rect.insetBy(
                  dx: -HoverTiming.semanticRetentionOutset,
                  dy: -HoverTiming.semanticRetentionOutset
              ).contains(point) else {
            return false
        }
        guard let hostTarget,
              hostTarget.kind == .window,
              hostTarget.windowID == hoveredTarget.windowID else {
            return false
        }
        return true
    }

    private func semanticHostTarget(fallback: Target?) -> Target? {
        if let fallback, fallback.kind == .window { return fallback }
        return hoverCycleTargets.first { $0.kind == .window }
    }

    private func scheduleSemanticHover(at point: CGPoint, hostTarget: Target?) {
        semanticHoverGeneration += 1
        let generation = semanticHoverGeneration
        semanticHoverTask?.cancel()
        canUseSemanticSelection = AXIsProcessTrusted()
        guard let hostTarget,
              hostTarget.kind == .window,
              hostTarget.processID != nil,
              canUseSemanticSelection else {
            return
        }
        let request = SemanticHitRequest(
            point: point,
            windowRect: hostTarget.rect,
            processID: hostTarget.processID,
            windowID: hostTarget.windowID,
            allowedRect: allowedRect,
            appKitDesktopBounds: CoordinateMapper.union(NSScreen.screens.map(\.frame)),
            coreGraphicsDesktopBounds: Self.coreGraphicsDesktopBounds()
        )
        semanticHoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: HoverTiming.semanticDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let candidates = await Task.detached(priority: .userInitiated) {
                Self.semanticCandidates(for: request)
            }.value
            guard !Task.isCancelled else { return }
            guard let self,
                  !self.finished,
                  self.selectionStart == nil,
                  self.semanticHoverGeneration == generation,
                  self.hoveredTarget?.windowID == hostTarget.windowID else {
                return
            }
            guard let preferredIndex = SelectionSemanticTargetPolicy.preferredIndex(
                in: candidates,
                windowRect: request.windowRect,
                pointer: request.point
            ) else {
                return
            }
            let semanticTargets = candidates.map {
                Target(
                    rect: $0.rect,
                    kind: .semantic,
                    label: SelectionSemanticTargetPolicy.label(for: $0.role),
                    processID: request.processID,
                    windowID: request.windowID,
                    role: $0.role,
                    depth: $0.depth
                )
            }
            let cycleTargets = Self.deduplicatedTargets(
                semanticTargets + [hostTarget],
                allowedRect: request.allowedRect
            )
            let preferred = candidates[preferredIndex]
            let selectedIndex = cycleTargets.firstIndex {
                $0.kind == .semantic &&
                $0.role == preferred.role &&
                $0.rect.equalTo(preferred.rect)
            } ?? 0
            guard selectedIndex < cycleTargets.count else { return }
            self.hoverCycleTargets = cycleTargets
            self.hoverCycleIndex = selectedIndex
            self.applyHoverTarget(cycleTargets[selectedIndex], cycleTargets: cycleTargets)
        }
    }

    private func cycleHoverTarget(by direction: Int) {
        guard selectionStart == nil, !hoverCycleTargets.isEmpty else { return }
        hoverCycleIndex = (hoverCycleIndex + direction + hoverCycleTargets.count) % hoverCycleTargets.count
        applyHoverTarget(hoverCycleTargets[hoverCycleIndex], cycleTargets: hoverCycleTargets)
    }

    private func begin(at point: CGPoint) {
        guard CACurrentMediaTime() >= acceptsMouseInputAfter else { return }
        guard allowedRect?.contains(point) ?? true else { return }
        activeSelectionBounds = SelectionScreenPolicy.dragBounds(
            at: point,
            allowedRect: allowedRect,
            screenFrames: NSScreen.screens.map(\.frame)
        )
        guard activeSelectionBounds != nil else { return }
        let point = clamped(point)
        selectionStart = point
        pressedTarget = hoveredTarget
        semanticHoverTask?.cancel()
        isDragging = false
        for view in views {
            view.selectionStart = point
            view.selectionEnd = point
            view.highlightCutsOut = true
            view.needsDisplay = true
        }
    }

    private func change(to point: CGPoint) {
        guard let start = selectionStart else { return }
        let point = clamped(point)
        if hypot(point.x - start.x, point.y - start.y) >= 4 { isDragging = true }
        guard isDragging else { return }
        semanticHoverTask?.cancel()
        for view in views {
            view.highlightedRect = nil
            view.selectionEnd = point
            view.needsDisplay = true
        }
    }

    private func complete(at point: CGPoint) {
        guard CACurrentMediaTime() >= acceptsMouseInputAfter else { return }
        guard let start = selectionStart else { return }
        if !isDragging, let target = pressedTarget {
            finish(.success(target.rect))
            return
        }
        let point = clamped(point)
        let rect = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        guard rect.width >= 4, rect.height >= 4 else {
            finish(.failure(HelloXError.cancelled))
            return
        }
        finish(.success(rect))
    }

    private func target(at point: CGPoint) -> Target? {
        guard allowedRect?.contains(point) ?? true else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return nil }
        let rect = allowedRect.map { screen.frame.intersection($0) } ?? screen.frame
        if prefersDisplayTargetForClick {
            return Target(
                rect: rect,
                kind: .display,
                label: "全屏",
                processID: nil,
                windowID: nil,
                role: nil,
                depth: 0
            )
        }
        if let window = windowTarget(at: point) { return window }
        return Target(
            rect: rect,
            kind: .display,
            label: "全屏",
            processID: nil,
            windowID: nil,
            role: nil,
            depth: 0
        )
    }

    private func windowTarget(at point: CGPoint) -> Target? {
        guard let index = SelectionWindowTargetPolicy.hitIndex(
            in: windowHitCandidates,
            at: point,
            rect: \.rect,
            isSelectable: { $0.target != nil },
            blocksLowerTargets: \.blocksLowerTargets
        ) else {
            return nil
        }
        return windowHitCandidates[index].target
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        guard let allowedRect = activeSelectionBounds ?? allowedRect else { return point }
        return CGPoint(
            x: min(max(point.x, allowedRect.minX), allowedRect.maxX),
            y: min(max(point.y, allowedRect.minY), allowedRect.maxY)
        )
    }

    private func finish(_ result: Result<CGRect, Error>) {
        guard !finished else { return }
        finished = true
        semanticHoverTask?.cancel()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        let succeeded: Bool
        switch result {
        case .success: succeeded = true
        case .failure: succeeded = false
        }
        if SelectionOverlayHandoffPolicy.dismissesImmediately(
            succeeded: succeeded,
            preservesSuccessfulSelectionForHandoff: preservesSuccessfulSelectionForHandoff
        ) {
            dismiss()
        } else {
            for window in windows { window.ignoresMouseEvents = true }
        }
        completion(result)
    }

    func dismiss() {
        for panel in windows { panel.orderOut(nil) }
    }

    /// Transfers the already-visible capture panels to the editor. The target
    /// panel stays on screen and becomes the editor container, so completing a
    /// selection never swaps two full-screen windows.
    func takePanels(for targetScreen: NSScreen) -> CaptureOverlayPanelHandoff? {
        guard finished,
              let targetIndex = windows.firstIndex(where: { $0.frame == targetScreen.frame }) else {
            return nil
        }
        let targetCanvas = canvases[targetIndex]
        let targetPanel = windows.remove(at: targetIndex)
        targetPanel.ignoresMouseEvents = false
        let dimPanels = windows
        for panel in dimPanels { panel.ignoresMouseEvents = true }
        windows.removeAll()
        views.removeAll()
        canvases.removeAll()
        return CaptureOverlayPanelHandoff(
            targetPanel: targetPanel,
            targetCanvas: targetCanvas,
            dimPanels: dimPanels
        )
    }

    private static func discoverWindowHitCandidates(inside allowedRect: CGRect?) -> [WindowHitCandidate] {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let appKitBounds = CoordinateMapper.union(NSScreen.screens.map(\.frame))
        let screenFrames = NSScreen.screens.map(\.frame)
        let coreGraphicsBounds = coreGraphicsDesktopBounds()
        return items.compactMap { item in
            guard let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let coreRect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return nil
            }
            let rect = CoordinateMapper.coreGraphicsToAppKit(
                coreRect,
                appKitDesktopBounds: appKitBounds,
                coreGraphicsDesktopBounds: coreGraphicsBounds
            )
            let ownerPID = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let candidateRect = allowedRect.map { rect.intersection($0) } ?? rect
            let isEligible = SelectionWindowTargetPolicy.isEligible(
                ownerPID: ownerPID,
                layer: layer,
                alpha: alpha,
                rect: rect,
                allowedRect: allowedRect
            )
            let blocksLowerTargets = SelectionWindowTargetPolicy.blocksLowerTargets(
                ownerPID: ownerPID,
                layer: layer,
                alpha: alpha,
                rect: rect,
                screenFrames: screenFrames,
                allowedRect: allowedRect
            )
            guard isEligible || blocksLowerTargets else { return nil }
            let target = isEligible ? Target(
                rect: candidateRect,
                kind: .window,
                label: AXIsProcessTrusted() ? "窗口" : "窗口 · 需辅助功能",
                processID: ownerPID,
                windowID: (item[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) },
                role: nil,
                depth: 0
            ) : nil
            return WindowHitCandidate(
                rect: candidateRect,
                target: target,
                blocksLowerTargets: blocksLowerTargets
            )
        }
    }

    private struct SemanticHitRequest: Sendable {
        let point: CGPoint
        let windowRect: CGRect
        let processID: pid_t?
        let windowID: CGWindowID?
        let allowedRect: CGRect?
        let appKitDesktopBounds: CGRect
        let coreGraphicsDesktopBounds: CGRect
    }

    nonisolated private static func semanticCandidates(for request: SemanticHitRequest) -> [SelectionSemanticCandidate] {
        guard let processID = request.processID else { return [] }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.18)

        let corePoint = CoordinateMapper.appKitToCoreGraphics(
            CGRect(origin: request.point, size: .zero),
            appKitDesktopBounds: request.appKitDesktopBounds,
            coreGraphicsDesktopBounds: request.coreGraphicsDesktopBounds
        ).origin
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            app,
            Float(corePoint.x),
            Float(corePoint.y),
            &hitElement
        ) == .success, let hitElement else {
            return []
        }

        var candidates: [SelectionSemanticCandidate] = []
        var current: AXUIElement? = hitElement
        var depth = 0
        while let element = current, depth < 10 {
            AXUIElementSetMessagingTimeout(element, 0.08)
            let role = stringAttribute(kAXRoleAttribute, from: element) ?? "AXUnknown"
            if let rect = appKitRect(
                for: element,
                appKitDesktopBounds: request.appKitDesktopBounds,
                coreGraphicsDesktopBounds: request.coreGraphicsDesktopBounds
            ) {
                let clipped = clippedRect(rect, hostWindow: request.windowRect, allowedRect: request.allowedRect)
                if let clipped, !containsSimilarRect(clipped, in: candidates) {
                    candidates.append(SelectionSemanticCandidate(rect: clipped, role: role, depth: depth))
                }
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                break
            }
            current = unsafeDowncast(parentValue, to: AXUIElement.self)
            depth += 1
        }
        return candidates
    }

    nonisolated private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func appKitRect(
        for element: AXUIElement,
        appKitDesktopBounds: CGRect,
        coreGraphicsDesktopBounds: CGRect
    ) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CoordinateMapper.coreGraphicsToAppKit(
            CGRect(origin: position, size: size),
            appKitDesktopBounds: appKitDesktopBounds,
            coreGraphicsDesktopBounds: coreGraphicsDesktopBounds
        )
    }

    nonisolated private static func clippedRect(
        _ rect: CGRect,
        hostWindow: CGRect,
        allowedRect: CGRect?
    ) -> CGRect? {
        var clipped = rect.intersection(hostWindow)
        if let allowedRect { clipped = clipped.intersection(allowedRect) }
        guard !clipped.isNull,
              clipped.width >= 8,
              clipped.height >= 8 else {
            return nil
        }
        return clipped
    }

    nonisolated private static func containsSimilarRect(
        _ rect: CGRect,
        in candidates: [SelectionSemanticCandidate]
    ) -> Bool {
        candidates.contains {
            abs($0.rect.minX - rect.minX) < 2 &&
            abs($0.rect.minY - rect.minY) < 2 &&
            abs($0.rect.width - rect.width) < 2 &&
            abs($0.rect.height - rect.height) < 2
        }
    }

    private static func deduplicatedTargets(_ targets: [Target], allowedRect: CGRect?) -> [Target] {
        var values: [Target] = []
        for target in targets {
            let rect = allowedRect.map { target.rect.intersection($0) } ?? target.rect
            guard !rect.isNull,
                  rect.width >= 8,
                  rect.height >= 8,
                  !values.contains(where: {
                      $0.kind == target.kind &&
                      abs($0.rect.minX - rect.minX) < 2 &&
                      abs($0.rect.minY - rect.minY) < 2 &&
                      abs($0.rect.width - rect.width) < 2 &&
                      abs($0.rect.height - rect.height) < 2
                  }) else {
                continue
            }
            values.append(Target(
                rect: rect,
                kind: target.kind,
                label: target.label,
                processID: target.processID,
                windowID: target.windowID,
                role: target.role,
                depth: target.depth
            ))
        }
        return values
    }

    private static func sameTargets(_ lhs: [Target], _ rhs: [Target]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { sameTarget($0, $1) }
    }

    private static func sameTarget(_ lhs: Target?, _ rhs: Target?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return sameTarget(lhs, rhs)
        default:
            return false
        }
    }

    private static func sameTarget(_ lhs: Target, _ rhs: Target) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.windowID == rhs.windowID &&
        lhs.role == rhs.role &&
        abs(lhs.rect.minX - rhs.rect.minX) < 1 &&
        abs(lhs.rect.minY - rhs.rect.minY) < 1 &&
        abs(lhs.rect.width - rhs.rect.width) < 1 &&
        abs(lhs.rect.height - rhs.rect.height) < 1
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

enum SelectionOverlayHandoffPolicy {
    static func dismissesImmediately(
        succeeded: Bool,
        preservesSuccessfulSelectionForHandoff: Bool
    ) -> Bool {
        !succeeded || !preservesSuccessfulSelectionForHandoff
    }
}

enum SelectionOverlayRenderingPolicy {
    static func dimOpacity(hasFrozenImage: Bool, rendersFrozenBackdrop: Bool) -> CGFloat {
        if hasFrozenImage && rendersFrozenBackdrop {
            return CaptureOverlayAppearance.frozenDimOpacity
        }
        return CaptureOverlayAppearance.liveDimOpacity
    }

    static func redrawsFrozenPixelsInsideSelection(hasFrozenImage: Bool) -> Bool {
        hasFrozenImage
    }

    static func cutsOutSelection(hasTarget: Bool) -> Bool {
        hasTarget
    }
}

class SelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onComplete: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onCancel { onCancel(); return }
        let editingText = firstResponder is NSTextView
        if !editingText,
           (event.keyCode == 36 || event.keyCode == 76),
           let onComplete {
            onComplete()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch characters {
        case "c" where onCopy != nil: onCopy?(); return true
        case "s" where onSave != nil: onSave?(); return true
        case "z" where event.modifierFlags.contains(.shift) && onRedo != nil: onRedo?(); return true
        case "z" where onUndo != nil: onUndo?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

private final class SelectionView: NSView {
    let screenFrame: CGRect
    let frozenImage: CGImage?
    private let frozenNSImage: NSImage?
    private let rendersFrozenBackdrop: Bool
    var selectionStart: CGPoint?
    var selectionEnd: CGPoint?
    var highlightedRect: CGRect?
    var highlightLabel = ""
    var highlightCutsOut = true
    var onHover: ((CGPoint) -> Void)?
    var onBegin: ((CGPoint) -> Void)?
    var onChange: ((CGPoint) -> Void)?
    var onComplete: ((CGPoint) -> Void)?
    var onCycleTarget: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(screenFrame: CGRect, frozenImage: CGImage?, rendersFrozenBackdrop: Bool = true) {
        self.screenFrame = screenFrame
        self.frozenImage = frozenImage
        self.rendersFrozenBackdrop = rendersFrozenBackdrop
        frozenNSImage = frozenImage.map { NSImage(cgImage: $0, size: screenFrame.size) }
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        if let frozenNSImage, rendersFrozenBackdrop {
            NSGraphicsContext.current?.imageInterpolation = .high
            frozenNSImage.draw(in: bounds)
        }
        let dimOpacity = SelectionOverlayRenderingPolicy.dimOpacity(
            hasFrozenImage: frozenNSImage != nil,
            rendersFrozenBackdrop: rendersFrozenBackdrop
        )
        if dimOpacity > 0 {
            NSColor.black.withAlphaComponent(dimOpacity).setFill()
            bounds.fill()
        }

        let globalRect: CGRect?
        let showsSize: Bool
        if let start = selectionStart, let end = selectionEnd,
           hypot(start.x - end.x, start.y - end.y) >= 4 {
            globalRect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            showsSize = true
        } else {
            globalRect = highlightedRect
            showsSize = false
        }
        guard let globalRect else { return }
        let intersection = globalRect.intersection(screenFrame)
        guard !intersection.isNull else { return }
        let localRect = intersection.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)

        if SelectionOverlayRenderingPolicy.cutsOutSelection(
            hasTarget: showsSize || highlightCutsOut
        ) {
            NSGraphicsContext.current?.saveGraphicsState()
            if SelectionOverlayRenderingPolicy.redrawsFrozenPixelsInsideSelection(
                hasFrozenImage: frozenNSImage != nil && rendersFrozenBackdrop
            ), let frozenNSImage {
                // Keep the selected area backed by the exact same frozen pixels as the editor.
                // Clearing this rect would expose the live desktop and cause a visible flash when
                // the opaque editor preview replaces it during the handoff.
                NSBezierPath(rect: localRect).addClip()
                frozenNSImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            } else {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSColor.clear.setFill()
                localRect.fill()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        let path = NSBezierPath(rect: localRect.insetBy(dx: 1, dy: 1))
        NSColor.white.withAlphaComponent(0.88).setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor(HelloXTheme.accent).setStroke()
        path.lineWidth = 2
        path.stroke()

        if showsSize, let end = selectionEnd, screenFrame.contains(end) {
            drawLabel(
                "\(Int(globalRect.width)) × \(Int(globalRect.height))",
                at: CGPoint(x: end.x - screenFrame.minX, y: end.y - screenFrame.minY),
                showsBackground: false
            )
        } else if screenFrame.contains(CGPoint(x: globalRect.midX, y: globalRect.midY)) {
            drawLabel("\(highlightLabel)  单击选择 · 拖动自定义", at: CGPoint(x: localRect.minX + 8, y: localRect.maxY - 8))
        }
    }

    override func mouseMoved(with event: NSEvent) { onHover?(NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { onBegin?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onChange?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onComplete?(NSEvent.mouseLocation) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if event.keyCode == 48 {
            let direction = event.modifierFlags.contains(.shift) ? -1 : 1
            onCycleTarget?(direction)
        } else {
            super.keyDown(with: event)
        }
    }

    private func drawLabel(_ label: String, at point: CGPoint, showsBackground: Bool = true) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        if !showsBackground {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.90)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2
            attributes[.shadow] = shadow
        }
        let text = NSString(string: label)
        let size = text.size(withAttributes: attributes)
        let horizontalInset: CGFloat = showsBackground ? 9 : 3
        let verticalInset: CGFloat = showsBackground ? 5 : 2
        let backgroundSize = CGSize(
            width: size.width + horizontalInset * 2,
            height: size.height + verticalInset * 2
        )
        let origin = CGPoint(
            x: min(max(6, point.x + 8), bounds.maxX - backgroundSize.width - 6),
            y: min(max(6, point.y - backgroundSize.height - 8), bounds.maxY - backgroundSize.height - 6)
        )
        if showsBackground {
            let backgroundRect = CGRect(origin: origin, size: backgroundSize)
            NSColor(HelloXTheme.accent).withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8).fill()
            NSColor.white.withAlphaComponent(0.32).setStroke()
            NSBezierPath(roundedRect: backgroundRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        }
        text.draw(
            at: CGPoint(x: origin.x + horizontalInset, y: origin.y + verticalInset),
            withAttributes: attributes
        )
    }
}
