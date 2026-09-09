import AppKit
import SwiftUI
import Testing
@testable import HelloXApp
@testable import HelloXCore

@MainActor
@Suite(.serialized)
struct AnnotationTextFocusTests {
    @Test func textEditorAcquiresFocusWhenAttachedAfterCreation() async throws {
        _ = NSApplication.shared
        let buffer = InlineAnnotationTextBuffer()
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let host = NSHostingView(rootView: InlineAnnotationTextEditor(
            annotation: Annotation(tool: .text, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.2, y: 0.2)),
            imageRect: bounds, editingBounds: bounds, sourceImageSize: bounds.size,
            buffer: buffer, onCommit: {}
        ))
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        // SwiftUI may construct its native text view before attaching the
        // editor to the reused capture panel. Let creation callbacks finish.
        try await Task.sleep(for: .milliseconds(50))
        let input = try #require(textView(in: host))
        #expect(input.window == nil)

        let panel = SelectionPanel(contentRect: bounds,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.firstResponder === input)

        input.insertText("截图文字\n第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(buffer.text == "截图文字\n第二行")
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let input = view as? NSTextView { return input }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
