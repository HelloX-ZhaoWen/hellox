import AppKit
import SwiftUI

/// Codex uses its border tokens for scrollbar thumbs: 8% at rest, 12% in
/// light appearance and 16% in dark appearance while hovering or dragging.
final class HelloXOverlayScroller: NSScroller {
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        var knobRect = rect(for: .knob)
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        let horizontal = bounds.width > bounds.height
        if horizontal {
            let thickness = min(4, knobRect.height)
            knobRect = NSRect(x: knobRect.minX + 1, y: knobRect.midY - thickness / 2,
                              width: max(0, knobRect.width - 2), height: thickness)
        } else {
            let thickness = min(4, knobRect.width)
            knobRect = NSRect(x: knobRect.midX - thickness / 2, y: knobRect.minY + 1,
                              width: thickness, height: max(0, knobRect.height - 2))
        }
        guard knobRect.width > 0, knobRect.height > 0 else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let opacity: CGFloat = isHovered || isHighlighted ? (isDark ? 0.16 : 0.12) : 0.08
        let foreground = isDark ? NSColor.white : NSColor(srgbRed: 26 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1)
        foreground.withAlphaComponent(opacity).setFill()
        let radius = min(knobRect.width, knobRect.height) / 2
        NSBezierPath(roundedRect: knobRect, xRadius: radius, yRadius: radius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        super.mouseExited(with: event)
    }
}

@MainActor
enum HelloXScrollChrome {
    /// This entry point only changes existing scrollbar artwork. It preserves
    /// each native scroll view's axes, visibility, wheel and dragging behavior.
    static func apply(to scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        if scrollView.hasVerticalScroller, scrollView.verticalScroller is HelloXOverlayScroller == false {
            let previous = scrollView.verticalScroller
            let scroller = replacement(for: previous, horizontal: false)
            scrollView.verticalScroller = scroller
            // NSScrollView installs its own target/action in this setter.
            // Restore an existing routing pair after attachment, including nil
            // targets that intentionally use the responder chain.
            if let previous {
                scroller.target = previous.target
                scroller.action = previous.action
            }
        }
        if scrollView.hasHorizontalScroller, scrollView.horizontalScroller is HelloXOverlayScroller == false {
            let previous = scrollView.horizontalScroller
            let scroller = replacement(for: previous, horizontal: true)
            scrollView.horizontalScroller = scroller
            if let previous {
                scroller.target = previous.target
                scroller.action = previous.action
            }
        }
        scrollView.verticalScroller?.needsDisplay = true
        scrollView.horizontalScroller?.needsDisplay = true
    }

    private static func replacement(for previous: NSScroller?, horizontal: Bool) -> HelloXOverlayScroller {
        let fallback = horizontal ? NSRect(x: 0, y: 0, width: 100, height: 15)
                                  : NSRect(x: 0, y: 0, width: 15, height: 100)
        let scroller = HelloXOverlayScroller(frame: previous?.frame ?? fallback)
        if let previous {
            scroller.controlSize = previous.controlSize
            scroller.knobStyle = previous.knobStyle
            scroller.doubleValue = previous.doubleValue
            scroller.knobProportion = previous.knobProportion
            scroller.isEnabled = previous.isEnabled
            scroller.isHidden = previous.isHidden
        }
        return scroller
    }
}

private enum ScrollChromeVisibility: Equatable {
    case preserve, visibleVertical, hidden
}

private struct LocalScrollChrome: NSViewRepresentable {
    let visibility: ScrollChromeVisibility
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> ScrollChromeMarkerView {
        let marker = ScrollChromeMarkerView(frame: .zero)
        update(marker)
        return marker
    }

    func updateNSView(_ marker: ScrollChromeMarkerView, context: Context) {
        update(marker)
    }

    private func update(_ marker: ScrollChromeMarkerView) {
        marker.configure = { scrollView in
            switch visibility {
            case .preserve:
                break
            case .visibleVertical:
                if scrollView.autohidesScrollers { scrollView.autohidesScrollers = false }
                if !scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = true }
                if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
                clearBackground(of: scrollView)
            case .hidden:
                if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
                if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
                if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
                clearBackground(of: scrollView)
            }
            HelloXScrollChrome.apply(to: scrollView)
            if visibility == .visibleVertical { scrollView.verticalScroller?.isHidden = false }
        }
        marker.scheduleConfiguration()
    }

    private func clearBackground(of scrollView: NSScrollView) {
        if scrollView.borderType != .noBorder { scrollView.borderType = .noBorder }
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
    }
}

/// The marker searches only sibling branches around its own modifier and
/// requires matching viewport geometry. It never walks a window's content tree
/// or chooses a nested editor merely because it overlaps the marker's center.
final class ScrollChromeMarkerView: NSView {
    var configure: ((NSScrollView) -> Void)?
    private var configurationScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleConfiguration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    override func layout() {
        super.layout()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        guard !configurationScheduled else { return }
        configurationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configurationScheduled = false
            guard self.window != nil, let target = self.localScrollView() else { return }
            self.configure?(target)
        }
    }

    private func localScrollView() -> NSScrollView? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var branch: NSView = self
        while let container = branch.superview {
            let markerRect = convert(bounds, to: container)
            let candidates = container.subviews.filter { $0 !== branch }.flatMap {
                scrollViews(in: $0, intersecting: markerRect, relativeTo: container)
            }
            let matching = candidates.compactMap { candidate -> (NSScrollView, CGFloat)? in
                let rect = candidate.convert(candidate.bounds, to: container)
                guard let error = viewportError(rect, markerRect) else { return nil }
                return (candidate, error)
            }
            if let target = matching.min(by: { $0.1 < $1.1 })?.0 { return target }
            if let scrollView = container as? NSScrollView,
               viewportError(scrollView.bounds, markerRect) != nil { return scrollView }
            branch = container
        }
        return nil
    }

    private func scrollViews(in view: NSView, intersecting rect: NSRect, relativeTo container: NSView) -> [NSScrollView] {
        let frame = view.convert(view.bounds, to: container)
        guard frame.intersects(rect) else { return [] }
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0, intersecting: rect, relativeTo: container) }
    }

    private func viewportError(_ candidate: NSRect, _ marker: NSRect) -> CGFloat? {
        guard candidate.width > 0, candidate.height > 0 else { return nil }
        let overlap = candidate.intersection(marker)
        let smallerArea = min(candidate.width * candidate.height, marker.width * marker.height)
        guard overlap.width * overlap.height >= smallerArea * 0.95 else { return nil }
        // Padding around TextEditor is allowed; unrelated inner/outer scroll
        // views have substantially different viewport dimensions.
        let error = (abs(candidate.width - marker.width) + abs(candidate.height - marker.height))
            / (marker.width + marker.height)
        return error <= 0.2 ? error : nil
    }
}

extension View {
    /// Match Codex's pale scrollbar while keeping this view's visibility policy.
    func codexScrollChrome() -> some View {
        background(LocalScrollChrome(visibility: .preserve))
    }

    func seamlessTextEditorChrome() -> some View {
        scrollIndicators(.hidden)
            .background(LocalScrollChrome(visibility: .hidden))
    }

    func seamlessScrollChrome() -> some View {
        background(LocalScrollChrome(visibility: .hidden))
    }

    func visibleScrollChrome() -> some View {
        scrollIndicators(.visible)
            .background(LocalScrollChrome(visibility: .visibleVertical))
    }
}
