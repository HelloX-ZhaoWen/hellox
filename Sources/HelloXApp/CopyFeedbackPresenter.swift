import AppKit
import SwiftUI

@MainActor
final class CopyFeedbackPresenter {
    static let shared = CopyFeedbackPresenter()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func showSuccess(_ message: String = "已复制到剪贴板") {
        show(message: message, isSuccess: true)
    }

    func showFailure(_ message: String = "复制失败") {
        show(message: message, isSuccess: false)
    }

    private func show(message: String, isSuccess: Bool) {
        dismissTask?.cancel()
        let size = NSSize(width: 220, height: 48)
        let anchorWindow = NSApp.keyWindow
        let screen = anchorWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let anchor = anchorWindow?.frame ?? screen?.visibleFrame ?? .zero
        let frame = NSRect(
            x: anchor.midX - size.width / 2,
            y: max(anchor.minY + 24, (screen?.visibleFrame.minY ?? 0) + 24),
            width: size.width,
            height: size.height
        )

        let panel = self.panel ?? makePanel(frame: frame)
        self.panel = panel
        panel.setFrame(frame, display: true)
        panel.contentView = NSHostingView(
            rootView: CopyFeedbackToast(message: message, isSuccess: isSuccess)
        )
        panel.orderFrontRegardless()

        dismissTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
            self?.dismissTask = nil
        }
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct CopyFeedbackToast: View {
    let message: String
    let isSuccess: Bool

    var body: some View {
        HStack(spacing: 9) {
            HelloXIcon(icon: isSuccess ? .success : .warning, size: 16)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(isSuccess ? HelloXTheme.success : HelloXTheme.error)
        .padding(.horizontal, 16)
        .frame(width: 220, height: 42)
        .background(
            Color.black.opacity(0.94),
            in: Capsule()
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(.vertical, 3)
    }
}
