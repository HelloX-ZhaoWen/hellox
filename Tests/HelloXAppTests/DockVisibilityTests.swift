import AppKit
import Testing
@testable import HelloXApp

@MainActor
struct DockVisibilityTests {
    @Test func dockTracksOpenWindowsUntilTheLastOneCloses() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = DockVisibilityController { policies.append($0) }
        let main = makeWindow()
        let tool = makeWindow()
        controller.start()
        controller.windowWillShow(main)
        controller.windowWillShow(main)
        controller.windowWillShow(tool)
        controller.windowDidClose(main)
        #expect(policies == [.accessory, .regular])
        controller.windowDidClose(tool)
        #expect(policies == [.accessory, .regular, .accessory])
        controller.windowWillShow(main)
        #expect(policies.last == .regular)
    }

    @Test func hiddenOrMinimizedOpenWindowsKeepDockEntry() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = DockVisibilityController { policies.append($0) }
        let window = makeWindow()
        controller.start(windows: [window])
        // An ordered-out window is still open. The window integration only
        // removes it on close, never on orderOut, hide or miniaturization.
        window.orderOut(nil)
        #expect(policies == [.regular])
        controller.windowDidClose(window)
        #expect(policies == [.regular, .accessory])
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
