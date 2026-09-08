import AppKit
import SwiftUI
import Testing
@testable import HelloXApp

@MainActor
@Suite(.serialized)
struct ScrollChromeTests {
    @Test func settingsDetailUsesPaleScrollerWithoutLosingScrollableContent() async throws {
        let model = AppModel()
        model.mainDestination = .shortcuts
        let controller = SettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 820, height: 600))
        await settleLayout(in: window)

        let root = try #require(window.contentView)
        let detail = try #require(scrollViews(in: root).first { scrollView in
            scrollView.bounds.width > 450 && scrollView.hasVerticalScroller
        })
        #expect(detail.verticalScroller is HelloXOverlayScroller)
        #expect(detail.verticalScroller?.target === detail)
        #expect(detail.verticalScroller?.action != nil)
        #expect(detail.scrollerStyle == .overlay)
        let document = try #require(detail.documentView)
        #expect(document.frame.height > detail.contentView.bounds.height + 100)
        let before = detail.contentView.bounds.origin
        let maximumY = document.frame.height - detail.contentView.bounds.height
        detail.contentView.scroll(to: NSPoint(x: before.x, y: min(before.y + 120, maximumY)))
        detail.reflectScrolledClipView(detail.contentView)
        #expect(detail.contentView.bounds.origin.y > before.y)
    }

    @Test func nativeBothAxesKeepPositionAndActionAfterRestyling() async throws {
        let scrollView = makeScrollView(size: NSSize(width: 480, height: 320), documentSize: NSSize(width: 1400, height: 1800))
        let window = makeWindow(content: scrollView)
        defer { window.close() }
        await settleLayout(in: window)
        scrollView.contentView.scroll(to: NSPoint(x: 170, y: 260))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let oldVertical = try #require(scrollView.verticalScroller)
        let oldHorizontal = try #require(scrollView.horizontalScroller)
        let verticalValue = oldVertical.doubleValue
        let horizontalValue = oldHorizontal.doubleValue
        let verticalProportion = oldVertical.knobProportion
        let horizontalProportion = oldHorizontal.knobProportion
        let origin = scrollView.contentView.bounds.origin
        let spy = ScrollActionSpy()
        oldVertical.target = spy
        oldVertical.action = #selector(ScrollActionSpy.scrollAction(_:))
        oldHorizontal.target = spy
        oldHorizontal.action = #selector(ScrollActionSpy.scrollAction(_:))
        oldHorizontal.isHidden = true
        oldHorizontal.isEnabled = false

        HelloXScrollChrome.apply(to: scrollView)

        let vertical = try #require(scrollView.verticalScroller)
        let horizontal = try #require(scrollView.horizontalScroller)
        #expect(vertical is HelloXOverlayScroller)
        #expect(horizontal is HelloXOverlayScroller)
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.hasHorizontalScroller)
        #expect(scrollView.contentView.bounds.origin == origin)
        #expect(abs(vertical.doubleValue - verticalValue) < 0.001)
        #expect(abs(horizontal.doubleValue - horizontalValue) < 0.001)
        #expect(abs(vertical.knobProportion - verticalProportion) < 0.001)
        #expect(abs(horizontal.knobProportion - horizontalProportion) < 0.001)
        #expect(horizontal.isHidden)
        #expect(!horizontal.isEnabled)
        #expect(vertical.target === spy)
        #expect(horizontal.target === spy)
        #expect(vertical.action == #selector(ScrollActionSpy.scrollAction(_:)))
        #expect(horizontal.action == #selector(ScrollActionSpy.scrollAction(_:)))
        #expect(vertical.sendAction(vertical.action, to: vertical.target))
        #expect(spy.callCount == 1)

        // A deliberately absent horizontal indicator must stay absent.
        scrollView.hasHorizontalScroller = false
        HelloXScrollChrome.apply(to: scrollView)
        #expect(!scrollView.hasHorizontalScroller)
    }

    @Test func localMarkerDistinguishesNestedViewports() async throws {
        let root = ScrollTestDocumentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let outer = makeScrollView(size: root.frame.size, documentSize: NSSize(width: 600, height: 900))
        outer.hasHorizontalScroller = false
        root.addSubview(outer)
        let document = try #require(outer.documentView)
        let inner = makeScrollView(size: NSSize(width: 400, height: 240), documentSize: NSSize(width: 400, height: 800))
        inner.hasHorizontalScroller = false
        // Its viewport covers the outer marker's center. A center-point search
        // would wrongly choose this smaller nested scroll view.
        inner.setFrameOrigin(NSPoint(x: 100, y: 80))
        document.addSubview(inner)
        let outerMarker = ScrollChromeMarkerView(frame: root.bounds)
        var configuredOuter: NSScrollView?
        outerMarker.configure = { configuredOuter = $0; HelloXScrollChrome.apply(to: $0) }
        root.addSubview(outerMarker)
        let window = makeWindow(content: root)
        defer { window.close() }
        await settleLayout(in: window)

        #expect(configuredOuter === outer)
        #expect(outer.verticalScroller is HelloXOverlayScroller)
        #expect(inner.verticalScroller is HelloXOverlayScroller == false)

        let innerMarker = ScrollChromeMarkerView(frame: inner.frame)
        var configuredInner: NSScrollView?
        innerMarker.configure = { configuredInner = $0; HelloXScrollChrome.apply(to: $0) }
        document.addSubview(innerMarker)
        await settleLayout(in: window)
        #expect(configuredInner === inner)
        #expect(inner.verticalScroller is HelloXOverlayScroller)
    }

    private func makeScrollView(size: NSSize, documentSize: NSSize) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = ScrollTestDocumentView(frame: NSRect(origin: .zero, size: documentSize))
        return scrollView
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func settleLayout(in window: NSWindow) async {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            // Yield the MainActor so the production modifier's main-queue
            // configuration can run; nested RunLoop.run does not drain it.
            try? await Task.sleep(for: .milliseconds(70))
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }
}

@MainActor
private final class ScrollActionSpy: NSObject {
    var callCount = 0
    @objc func scrollAction(_ sender: Any?) { callCount += 1 }
}

@MainActor
private final class ScrollTestDocumentView: NSView {
    override var isFlipped: Bool { true }
}
