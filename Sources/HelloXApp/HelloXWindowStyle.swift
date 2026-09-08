import AppKit

@MainActor
final class HelloXWindow: NSWindow {
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { DockVisibilityController.shared.windowWillShow(self) }
        super.order(place, relativeTo: otherWin)
    }

    override func close() {
        super.close()
        DockVisibilityController.shared.windowDidClose(self)
    }

    override func sendEvent(_ event: NSEvent) {
        if shouldToggleZoom(for: event) {
            zoom(nil)
            return
        }
        super.sendEvent(event)
    }

    func shouldToggleZoom(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              event.clickCount == 2,
              styleMask.contains(.resizable),
              !styleMask.contains(.fullScreen),
              !isMiniaturized,
              event.locationInWindow.y >= contentLayoutRect.maxY else { return false }

        return !isWindowControl(at: event.locationInWindow)
    }

    private func isWindowControl(at locationInWindow: NSPoint) -> Bool {
        guard let frameView = contentView?.superview else { return false }
        let point = frameView.convert(locationInWindow, from: nil)
        var hitView = frameView.hitTest(point)
        while let view = hitView {
            if view is NSControl { return true }
            hitView = view.superview
        }
        return false
    }
}

final class HelloXResizeCursorView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("HelloXResizeCursorView")
    private let edgeThickness: CGFloat = 7
    private let cornerThickness: CGFloat = 16
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let AppKit route cursor updates to this view only in the resize
        // bands. Mouse-down/drag events must continue to reach the window's
        // native borderless-resize handling and the SwiftUI content.
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return nil
        default:
            break
        }
        guard Self.resizeCursor(at: point, in: bounds, window: window) != nil else { return nil }
        return self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingArea()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingArea()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func updateCursor(at point: NSPoint) {
        let cursor = Self.resizeCursor(at: point, in: bounds, window: window) ?? .arrow
        DispatchQueue.main.async {
            cursor.set()
        }
    }

    static func resizeCursor(at point: NSPoint, in bounds: NSRect, window: NSWindow?) -> NSCursor? {
        let edgeThickness: CGFloat = 7
        let cornerThickness: CGFloat = 16
        guard let window,
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen),
              bounds.width > cornerThickness * 2,
              bounds.height > cornerThickness * 2 else { return nil }

        // Borderless windows have no visible frame, and AppKit can report the
        // resize hotspot a few points outside their content bounds.
        guard bounds.insetBy(dx: -4, dy: -4).contains(point) else { return nil }

        let nearLeft = point.x <= cornerThickness
        let nearRight = point.x >= bounds.maxX - cornerThickness
        let nearBottom = point.y <= cornerThickness
        let nearTop = point.y >= bounds.maxY - cornerThickness
        let position: NSCursor.FrameResizePosition?
        if nearTop && nearLeft { position = .topLeft }
        else if nearTop && nearRight { position = .topRight }
        else if nearBottom && nearLeft { position = .bottomLeft }
        else if nearBottom && nearRight { position = .bottomRight }
        else if point.x <= edgeThickness { position = .left }
        else if point.x >= bounds.maxX - edgeThickness { position = .right }
        else if point.y <= edgeThickness { position = .bottom }
        else if point.y >= bounds.maxY - edgeThickness { position = .top }
        else { position = nil }

        guard let position else { return nil }
        return .frameResize(position: position, directions: .all)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let window,
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen),
              bounds.width > cornerThickness * 2,
              bounds.height > cornerThickness * 2 else { return }

        addCursorRect(
            NSRect(x: bounds.minX, y: bounds.minY + cornerThickness, width: edgeThickness, height: bounds.height - cornerThickness * 2),
            cursor: .frameResize(position: .left, directions: .all)
        )
        addCursorRect(
            NSRect(x: bounds.maxX - edgeThickness, y: bounds.minY + cornerThickness, width: edgeThickness, height: bounds.height - cornerThickness * 2),
            cursor: .frameResize(position: .right, directions: .all)
        )
        addCursorRect(
            NSRect(x: bounds.minX + cornerThickness, y: bounds.minY, width: bounds.width - cornerThickness * 2, height: edgeThickness),
            cursor: .frameResize(position: .bottom, directions: .all)
        )
        addCursorRect(
            NSRect(x: bounds.minX + cornerThickness, y: bounds.maxY - edgeThickness, width: bounds.width - cornerThickness * 2, height: edgeThickness),
            cursor: .frameResize(position: .top, directions: .all)
        )

        let corners: [(NSRect, NSCursor.FrameResizePosition)] = [
            (NSRect(x: bounds.minX, y: bounds.maxY - cornerThickness, width: cornerThickness, height: cornerThickness), .topLeft),
            (NSRect(x: bounds.maxX - cornerThickness, y: bounds.maxY - cornerThickness, width: cornerThickness, height: cornerThickness), .topRight),
            (NSRect(x: bounds.minX, y: bounds.minY, width: cornerThickness, height: cornerThickness), .bottomLeft),
            (NSRect(x: bounds.maxX - cornerThickness, y: bounds.minY, width: cornerThickness, height: cornerThickness), .bottomRight)
        ]
        for (rect, position) in corners {
            addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
        }
    }
}

@MainActor
enum HelloXWindowStyle {
    private static let windowControlLeadingInset: CGFloat = 16
    private static let windowControlTopInset: CGFloat = 10

    static func applyDialog(to window: NSWindow) {
        window.appearance = nil
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.tabbingMode = .disallowed
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
    }

    /// Standard document/tool windows leave title-bar layout and traffic-light
    /// positioning to AppKit. Capture overlays keep their specialized chrome.
    static func applyNative(to window: NSWindow) {
        window.appearance = nil
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = HelloXTheme.windowBackground
        window.isOpaque = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
    }

    static func applySettingsReference(to window: NSWindow) {
        applyNative(to: window)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            positionSettingsWindowControls(in: window)
        }
    }

    /// Codex uses hiddenInset with trafficLightPosition (16, 16), in points.
    static func positionSettingsWindowControls(in window: NSWindow, topInset: CGFloat = 16) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let frameView = window.contentView?.superview else { return }
        // Move the complete titlebar container. Moving only the button's
        // immediate parent can draw the controls outside its ancestor's bounds,
        // where AppKit hit testing routes clicks to the SwiftUI content instead.
        var container: NSView = close
        while let parent = container.superview, parent !== frameView {
            container = parent
        }
        guard container !== close, container.superview === frameView else { return }
        let closeInFrame = close.convert(close.bounds, to: frameView)
        let desiredY = frameView.isFlipped ? topInset : frameView.bounds.height - topInset - close.frame.height
        let offset = NSSize(width: 16 - closeInFrame.minX, height: desiredY - closeInFrame.minY)
        container.setFrameOrigin(NSPoint(x: container.frame.minX + offset.width,
                                         y: container.frame.minY + offset.height))
    }

    static func apply(to window: NSWindow, movableByBackground: Bool = true) {
        window.appearance = nil
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.remove(.stationary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.tabbingMode = .disallowed
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = movableByBackground
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.standardWindowButton(.zoomButton)?.toolTip = "进入全屏幕"

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = HelloXTheme.windowRadius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        installResizeCursorOverlay(in: contentView, for: window)

        // AppKit lays out the standard controls after the transparent title bar
        // is installed. Apply our visual inset on the next layout pass so the
        // close button does not sit against the rounded window edge.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            positionWindowControls(in: window)
        }
    }

    private static func positionWindowControls(in window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let container = closeButton.superview else { return }

        let desiredCloseOrigin = NSPoint(
            x: windowControlLeadingInset,
            y: container.isFlipped
                ? windowControlTopInset
                : container.bounds.maxY - windowControlTopInset - closeButton.frame.height
        )
        let offset = NSSize(
            width: desiredCloseOrigin.x - closeButton.frame.origin.x,
            height: desiredCloseOrigin.y - closeButton.frame.origin.y
        )

        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            button.setFrameOrigin(NSPoint(
                x: button.frame.origin.x + offset.width,
                y: button.frame.origin.y + offset.height
            ))
        }
    }

    static func installResizeCursorOverlay(in contentView: NSView, for window: NSWindow) {
        guard contentView.subviews.contains(where: { $0.identifier == HelloXResizeCursorView.identifier }) == false else { return }
        let cursorView = HelloXResizeCursorView(frame: contentView.bounds)
        contentView.addSubview(cursorView, positioned: .above, relativeTo: nil)
        window.invalidateCursorRects(for: cursorView)
    }
}
