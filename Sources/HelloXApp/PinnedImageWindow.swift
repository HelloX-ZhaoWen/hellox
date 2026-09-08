import AppKit
import HelloXCore
import SwiftUI

enum PinnedImageGeometry {
    static let minimumZoom: CGFloat = 1
    static let maximumZoom: CGFloat = 10

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, zoom))
    }

    static func aspectFillSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        let scale = max(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func renderedSize(imageSize: CGSize, viewportSize: CGSize, zoom: CGFloat) -> CGSize {
        let baseSize = aspectFillSize(imageSize: imageSize, viewportSize: viewportSize)
        let zoom = clampedZoom(zoom)
        return CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
    }

    static func clampedOffset(
        _ offset: CGSize,
        renderedSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        let horizontalLimit = max(0, (renderedSize.width - viewportSize.width) / 2)
        let verticalLimit = max(0, (renderedSize.height - viewportSize.height) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }

    static func constrainedWindowSize(
        proposedSize: CGSize,
        currentSize: CGSize,
        minimumSize: CGSize,
        aspectRatio: CGFloat
    ) -> CGSize {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return proposedSize }
        let isVerticalEdgeDrag = abs(proposedSize.width - currentSize.width) < 0.5
            && abs(proposedSize.height - currentSize.height) >= 0.5
        if isVerticalEdgeDrag {
            let height = max(minimumSize.height, proposedSize.height)
            return CGSize(width: max(minimumSize.width, height * aspectRatio), height: height)
        }
        let width = max(minimumSize.width, proposedSize.width)
        return CGSize(width: width, height: max(minimumSize.height, width / aspectRatio))
    }
}

@MainActor
private final class PinnedImageModel: ObservableObject {
    @Published var isDesktopLayer = false
    @Published var errorMessage: String?
}

@MainActor
final class PinnedImageWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    private let image: CGImage
    private let aspectRatio: CGFloat
    private let model = PinnedImageModel()

    init(image: CGImage, frame requestedFrame: CGRect) {
        self.image = image
        aspectRatio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let frame = Self.constrainedInitialFrame(requestedFrame, image: image)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 100, height: max(60, 100 / aspectRatio))
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        let contentView = PinnedImageHostingView(
            rootView: PinnedImageView(
                image: image,
                model: model,
                close: { [weak panel] in panel?.close() },
                edit: { [weak self] in self?.editImage() },
                copy: { [weak self] in self?.copyImage() },
                save: { [weak self] in self?.saveImage() },
                toggleLayer: { [weak self] in self?.toggleLayer() }
            )
        )
        panel.contentView = contentView
        HelloXWindowStyle.apply(to: panel, movableByBackground: true)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // `contentRect` is interpreted before the titled frame is installed;
        // restore the requested outer frame after applying the shared window
        // style so the transparent wrapper does not grow beyond the image.
        panel.setFrame(frame, display: false)
        panel.hasShadow = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() { window?.orderFrontRegardless() }
    func windowWillClose(_ notification: Notification) { onClose?() }

    private func editImage() { onEdit?() }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        PinnedImageGeometry.constrainedWindowSize(
            proposedSize: frameSize,
            currentSize: sender.frame.size,
            minimumSize: sender.minSize,
            aspectRatio: aspectRatio
        )
    }

    private func copyImage() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ImageExporter.copyToPasteboardAsync(image)
            switch result {
            case .success:
                CopyFeedbackPresenter.shared.showSuccess("贴图已复制")
            case .failure(let message):
                CopyFeedbackPresenter.shared.showFailure(message)
                showError(message)
            }
        }
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "HelloX-贴图.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: ImageExportFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        let image = image
        Task { @MainActor [weak self] in
            do { try await ImageExporter.writeAsync(image, to: url, format: format) }
            catch { self?.showError(error.localizedDescription) }
        }
    }

    private func toggleLayer() {
        model.isDesktopLayer.toggle()
        if model.isDesktopLayer {
            window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        } else {
            window?.level = .floating
        }
        window?.orderFrontRegardless()
    }

    private func showError(_ message: String) {
        model.errorMessage = message
        let alert = HelloXAlert()
        alert.alertStyle = .warning
        alert.messageText = "贴图操作失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func constrainedInitialFrame(_ requested: CGRect, image: CGImage) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(requested) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? requested
        // Use the requested size as-is (no auto-shrink) — only clamp position
        // so the window stays on screen.
        var size = requested.size
        if size.width <= 0 || size.height <= 0 { size = CGSize(width: image.width, height: image.height) }
        let origin = CGPoint(
            x: min(max(visible.minX, requested.minX), visible.maxX - size.width),
            y: min(max(visible.minY, requested.minY), visible.maxY - size.height)
        )
        return CGRect(origin: origin, size: size)
    }
}

/// A titled window can report the titlebar's traffic-light area as a SwiftUI
/// safe-area inset even when the controls are hidden. The pinned image must
/// occupy the exact outer window bounds, so opt out of that inset at the
/// AppKit hosting boundary as well as in the SwiftUI view.
private final class PinnedImageHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

private final class PinnedImageMonitorView: NSView {
    var onWindowChange: ((Int?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window?.windowNumber)
    }
}

private struct PinnedImageScrollMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PinnedImageMonitorView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        private var windowNumber: Int?
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func attach(to view: PinnedImageMonitorView) {
            view.onWindowChange = { [weak self] windowNumber in
                self?.windowNumber = windowNumber
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.windowNumber == self.windowNumber,
                      abs(event.deltaY) > 0 else { return event }
                self.onScroll(event.deltaY)
                return nil
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct PinnedImageView: View {
    let image: CGImage
    @ObservedObject var model: PinnedImageModel
    let close: () -> Void
    let edit: () -> Void
    let copy: () -> Void
    let save: () -> Void
    let toggleLayer: () -> Void
    @State private var hovering = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let renderedSize = PinnedImageGeometry.renderedSize(
                imageSize: CGSize(width: image.width, height: image.height),
                viewportSize: viewportSize,
                zoom: zoomScale
            )
            ZStack(alignment: .topTrailing) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: renderedSize.width, height: renderedSize.height)
                    .position(
                        x: viewportSize.width / 2 + panOffset.width,
                        y: viewportSize.height / 2 + panOffset.height
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                updateZoom(lastZoomScale * value, viewportSize: viewportSize)
                            }
                            .onEnded { _ in
                                lastZoomScale = zoomScale
                                constrainPan(viewportSize: viewportSize)
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard zoomScale > 1.0 else { return }
                                let proposedOffset = CGSize(
                                    width: lastPanOffset.width + value.translation.width,
                                    height: lastPanOffset.height + value.translation.height
                                )
                                panOffset = PinnedImageGeometry.clampedOffset(
                                    proposedOffset,
                                    renderedSize: renderedSize,
                                    viewportSize: viewportSize
                                )
                            }
                            .onEnded { _ in
                                lastPanOffset = panOffset
                            }
                    )

                if hovering {
                    HStack(spacing: 4) {
                        HelloXIconButton(icon: .edit, help: "编辑贴图", size: 30, iconSize: 16, action: edit)
                        HelloXIconButton(icon: .close, help: "关闭贴图", role: .destructive, size: 30, iconSize: 16, action: close)
                    }
                    .padding(6)
                }
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .clipped()
            .background(
                PinnedImageScrollMonitor { deltaY in
                    let multiplier: CGFloat = deltaY > 0 ? 0.9 : 1.1
                    updateZoom(zoomScale * multiplier, viewportSize: viewportSize)
                    lastZoomScale = zoomScale
                }
                .allowsHitTesting(false)
            )
            .onChange(of: viewportSize) { _, newSize in
                constrainPan(viewportSize: newSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.26), radius: 22, y: 10)
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .contextMenu {
            Button("编辑", action: edit)
            Button("复制", action: copy)
            Button("保存", action: save)
            Divider()
            Button(model.isDesktopLayer ? "切换为始终置顶" : "切换到桌面层", action: toggleLayer)
            Button("关闭", action: close)
        }
    }

    private var sourceImageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    private func updateZoom(_ proposedZoom: CGFloat, viewportSize: CGSize) {
        zoomScale = PinnedImageGeometry.clampedZoom(proposedZoom)
        let renderedSize = PinnedImageGeometry.renderedSize(
            imageSize: sourceImageSize,
            viewportSize: viewportSize,
            zoom: zoomScale
        )
        panOffset = PinnedImageGeometry.clampedOffset(
            panOffset,
            renderedSize: renderedSize,
            viewportSize: viewportSize
        )
        if zoomScale == PinnedImageGeometry.minimumZoom {
            panOffset = .zero
        }
        lastPanOffset = panOffset
    }

    private func constrainPan(viewportSize: CGSize) {
        let renderedSize = PinnedImageGeometry.renderedSize(
            imageSize: sourceImageSize,
            viewportSize: viewportSize,
            zoom: zoomScale
        )
        panOffset = PinnedImageGeometry.clampedOffset(
            panOffset,
            renderedSize: renderedSize,
            viewportSize: viewportSize
        )
        lastPanOffset = panOffset
    }
}
