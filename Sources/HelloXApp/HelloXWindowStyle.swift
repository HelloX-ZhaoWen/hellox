import AppKit

@MainActor
final class HelloXWindow: NSWindow {
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
    static func apply(to window: NSWindow, movableByBackground: Bool = true) {
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
    }

    static func installResizeCursorOverlay(in contentView: NSView, for window: NSWindow) {
        guard contentView.subviews.contains(where: { $0.identifier == HelloXResizeCursorView.identifier }) == false else { return }
        let cursorView = HelloXResizeCursorView(frame: contentView.bounds)
        contentView.addSubview(cursorView, positioned: .above, relativeTo: nil)
        window.invalidateCursorRects(for: cursorView)
    }
}
