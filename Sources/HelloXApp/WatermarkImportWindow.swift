import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WatermarkImportWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let minimumSize = NSSize(width: 480, height: 360)
        let rootView = WatermarkImportView(
            onChoose: { [weak model] in
                model?.chooseImageForWatermark()
            },
            onDrop: { [weak model] url in
                model?.openWatermarkEditor(for: url) ?? false
            }
        )
        let window = HelloXWindow(
            contentRect: NSRect(origin: .zero, size: minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "图片加水印"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.minSize = minimumSize
        window.center()
        window.contentViewController = NSHostingController(rootView: rootView)
        HelloXWindowStyle.apply(to: window, movableByBackground: false)
        window.setContentSize(minimumSize)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        if let window,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WatermarkImportView: View {
    let onChoose: () -> Void
    let onDrop: (URL) -> Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false
    @State private var dropError: String?

    var body: some View {
        ZStack {
            HelloXGlowBackground()
                .ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    HelloXIcon(icon: .watermark, size: 28)
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(HelloXTheme.accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("图片加水印")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                    Text("上传图片后，将自动进入水印编辑器")
                        .font(.system(size: 12))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }

                Button {
                    dropError = nil
                    onChoose()
                } label: {
                    VStack(spacing: 12) {
                        HelloXIcon(icon: .save, size: 27)
                            .foregroundStyle(HelloXTheme.accent)
                        VStack(spacing: 4) {
                            Text(isDropTargeted ? "松开即可上传" : "点击或拖拽上传图片")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                            Text("支持 PNG、JPG、HEIC、TIFF 等常见图片格式")
                                .font(.system(size: 11))
                                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        }
                        HelloXUtilityButtonLabel(title: "选择图片", role: .accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(
                        (isDropTargeted
                            ? HelloXTheme.selectedBackground(for: colorScheme)
                            : HelloXTheme.raisedSurface(for: colorScheme)),
                        in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous)
                            .stroke(
                                isDropTargeted ? HelloXTheme.accent : HelloXTheme.border(for: colorScheme),
                                style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: [7, 5])
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("点击或拖拽上传图片")
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    dropError = nil
                    let didOpen = onDrop(url)
                    if !didOpen { dropError = "无法读取该图片，请选择其他文件。" }
                    return didOpen
                } isTargeted: { isTargeted in
                    isDropTargeted = isTargeted
                }

                if let dropError {
                    HelloXStatusBanner(message: dropError, kind: .error)
                } else {
                    Text("图片仅在本机处理，不会上传到服务器")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
