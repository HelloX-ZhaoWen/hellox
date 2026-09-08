import AppKit
import HelloXCore
import SwiftUI

enum ScreenRecordingControlGeometry {
    static let controlSize = CGSize(width: 350, height: 64)
    static let buttonSize = CaptureToolbarLayout.buttonSize
    static let iconSize = CaptureToolbarLayout.iconSize

    static func controlOrigin(
        selection: CGRect,
        controlSize: CGSize = controlSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let preferredY = selection.maxY + 12
        let fallbackY = selection.minY - controlSize.height - 12
        let y = preferredY + controlSize.height <= visibleFrame.maxY ? preferredY : fallbackY
        return CGPoint(
            x: min(
                max(visibleFrame.minX + 8, selection.midX - controlSize.width / 2),
                visibleFrame.maxX - controlSize.width - 8
            ),
            y: min(
                max(visibleFrame.minY + 8, y),
                visibleFrame.maxY - controlSize.height - 8
            )
        )
    }
}

private enum ScreenRecordingControlPhase: Equatable {
    case ready
    case starting
    case recording
    case stopping
}

@MainActor
private final class ScreenRecordingControlModel: ObservableObject {
    @Published var elapsedSeconds = 0
    @Published var phase: ScreenRecordingControlPhase = .ready

    var elapsedText: String {
        let hours = elapsedSeconds / 3_600
        let minutes = elapsedSeconds % 3_600 / 60
        let seconds = elapsedSeconds % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var statusText: String {
        switch phase {
        case .ready: "准备录制"
        case .starting: "正在开始…"
        case .recording: "录制中  \(elapsedText)"
        case .stopping: "正在保存…"
        }
    }
}

@MainActor
final class ScreenRecordingControlWindowController: NSObject {
    var onFinish: ((URL) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onCancel: (() -> Void)?

    private let recorder: ScreenRecordingService
    private let selectionFrame: CGRect
    private let recordingRegion: CGRect
    private let outputURL: URL
    private let model = ScreenRecordingControlModel()
    private let borderPanel: NSPanel
    private let controlPanel: NSPanel
    private var timer: Timer?
    private var completed = false

    var recordingOverlayWindowIDs: Set<CGWindowID> {
        Set([borderPanel.windowNumber, controlPanel.windowNumber]
            .filter { $0 > 0 }
            .map(CGWindowID.init))
    }

    init(
        recorder: ScreenRecordingService,
        selectionFrame: CGRect,
        recordingRegion: CGRect,
        outputURL: URL
    ) {
        self.recorder = recorder
        self.selectionFrame = selectionFrame
        self.recordingRegion = recordingRegion
        self.outputURL = outputURL

        borderPanel = NSPanel(
            contentRect: selectionFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selectionFrame) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? selectionFrame
        let controlOrigin = ScreenRecordingControlGeometry.controlOrigin(
            selection: selectionFrame,
            visibleFrame: visibleFrame
        )
        controlPanel = NSPanel(
            contentRect: CGRect(origin: controlOrigin, size: ScreenRecordingControlGeometry.controlSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanels()
    }

    func present() {
        borderPanel.orderFrontRegardless()
        controlPanel.orderFrontRegardless()
    }

    func failBecauseStreamStopped(_ error: Error) {
        guard !completed else { return }
        completed = true
        timer?.invalidate()
        closePanels()
        onFailure?(error)
    }

    private func configurePanels() {
        borderPanel.level = .screenSaver
        borderPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderPanel.isOpaque = false
        borderPanel.backgroundColor = .clear
        borderPanel.hasShadow = false
        borderPanel.ignoresMouseEvents = true
        borderPanel.hidesOnDeactivate = false
        borderPanel.isReleasedWhenClosed = false
        borderPanel.contentView = NSHostingView(
            rootView: ScreenRecordingBorderView()
        )

        controlPanel.level = .screenSaver
        controlPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        controlPanel.isOpaque = false
        controlPanel.backgroundColor = .clear
        controlPanel.hasShadow = false
        controlPanel.hidesOnDeactivate = false
        controlPanel.isReleasedWhenClosed = false
        controlPanel.contentView = NSHostingView(
            rootView: ScreenRecordingControlView(
                model: model,
                pixelSizeText: "\(Int(selectionFrame.width)) × \(Int(selectionFrame.height))",
                close: { [weak self] in self?.closeAndCancel() },
                toggleRecording: { [weak self] in self?.toggleRecording() }
            )
        )
    }

    private func toggleRecording() {
        switch model.phase {
        case .ready: startRecording()
        case .recording: stopAndSave()
        case .starting, .stopping: break
        }
    }

    private func startRecording() {
        guard model.phase == .ready, !completed else { return }
        model.phase = .starting
        let recorder = recorder
        let region = recordingRegion
        let outputURL = outputURL
        let excludedWindowIDs = recordingOverlayWindowIDs
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await recorder.startRecording(
                    region: region,
                    outputURL: outputURL,
                    excludingWindowIDs: excludedWindowIDs
                )
                guard !completed else {
                    await recorder.cancelRecording()
                    return
                }
                model.elapsedSeconds = 0
                model.phase = .recording
                startTimer()
            } catch {
                guard !completed else { return }
                completed = true
                closePanels()
                onFailure?(error)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.elapsedSeconds += 1 }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopAndSave() {
        guard model.phase == .recording, !completed else { return }
        model.phase = .stopping
        timer?.invalidate()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await recorder.stopRecording()
                guard !completed else { return }
                completed = true
                closePanels()
                onFinish?(url)
            } catch {
                guard !completed else { return }
                completed = true
                closePanels()
                onFailure?(error)
            }
        }
    }

    private func closeAndCancel() {
        guard !completed else { return }
        completed = true
        closePanels()
        let recorder = recorder
        Task { @MainActor [weak self] in
            await recorder.cancelRecording()
            self?.onCancel?()
        }
    }

    private func closePanels() {
        timer?.invalidate()
        timer = nil
        borderPanel.orderOut(nil)
        controlPanel.orderOut(nil)
    }
}

private struct ScreenRecordingBorderView: View {
    var body: some View {
        Rectangle()
            .strokeBorder(HelloXTheme.error, lineWidth: 3)
            .background(Color.clear)
            .accessibilityHidden(true)
    }
}

private struct ScreenRecordingControlView: View {
    @ObservedObject var model: ScreenRecordingControlModel
    let pixelSizeText: String
    let close: () -> Void
    let toggleRecording: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: CaptureToolbarLayout.buttonSpacing) {
            HelloXIcon(icon: .recording, size: 16)
                .foregroundStyle(model.phase == .recording ? HelloXTheme.error : HelloXTheme.iconForeground(for: .dark))
                .shadow(
                    color: model.phase == .recording ? HelloXTheme.error.opacity(0.35) : .clear,
                    radius: 5
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                Text(pixelSizeText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 139 / 255, green: 152 / 255, blue: 165 / 255))
            }
            Spacer(minLength: 4)
            recordingButton(
                icon: .close,
                help: "关闭录屏",
                role: .destructive,
                action: close
            )
            .disabled(model.phase == .stopping)
            if model.phase == .starting || model.phase == .stopping {
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        width: ScreenRecordingControlGeometry.buttonSize,
                        height: ScreenRecordingControlGeometry.buttonSize
                    )
            } else {
                recordingButton(
                    icon: model.phase == .recording ? .rectangle : .play,
                    help: model.phase == .recording ? "停止并保存录屏" : "开始录屏",
                    role: .accent,
                    action: toggleRecording
                )
            }
        }
        .padding(.horizontal, 14)
        .frame(width: ScreenRecordingControlGeometry.controlSize.width, height: ScreenRecordingControlGeometry.controlSize.height)
        .background(
            Color.black.opacity(0.96),
            in: Capsule()
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private func recordingButton(
        icon: HelloXIconKey,
        help: String,
        role: HelloXButtonRole,
        action: @escaping () -> Void
    ) -> some View {
        HelloXIconButton(
            icon: icon,
            help: help,
            role: role,
            size: ScreenRecordingControlGeometry.buttonSize,
            iconSize: ScreenRecordingControlGeometry.iconSize,
            isBorderless: true,
            usesWhiteBackground: true,
            action: action
        )
    }
}
