import AppKit
import HelloXCore
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    var onClose: (() -> Void)?

    init(document: EditorDocument, startsWithWatermark: Bool = false, initialTool: AnnotationTool = .select) {
        self.editorDocument = document
        let window = HelloXWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "截图编辑器"
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.contentViewController = HXDialogHostingController(
            rootView: EditorView(document: document, startsWithWatermark: startsWithWatermark,
                                 initialTool: initialTool, onClose: { [weak window] in window?.performClose(nil) }),
            minimumSize: NSSize(width: 760, height: 520)
        )
        HelloXWindowStyle.applyDialog(to: window)
        // Canvas drags edit the image; only the document bar moves the window.
        window.isMovableByWindowBackground = false
        window.setContentSize(NSSize(width: 1080, height: 720))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorDocument.dirty else { return true }
        let alert = HelloXAlert()
        alert.messageText = "关闭前保存截图？"
        alert.informativeText = "未保存的标注将会丢失。"
        alert.addButton(withTitle: "保存并关闭")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return editorDocument.save() == .saved
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

}
