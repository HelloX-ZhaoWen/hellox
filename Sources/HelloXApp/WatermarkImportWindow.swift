import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WatermarkImportWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let minimumSize = NSSize(width: 520, height: 292)
        let window = HelloXWindow(
            contentRect: NSRect(origin: .zero, size: minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let rootView = WatermarkImportView(
            onClose: { [weak window] in window?.performClose(nil) },
            onChoose: { [weak model] in
                model?.chooseImageForWatermark()
            },
            onDrop: { [weak model] url in
                model?.openWatermarkEditor(for: url) ?? false
            }
        )
        window.title = "图片加水印"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.minSize = minimumSize
        window.center()
        window.contentViewController = HXDialogHostingController(
            rootView: HXDialogWindowContent(title: "图片加水印", subtitle: "上传图片后，将自动进入水印编辑器", onClose: { [weak window] in window?.performClose(nil) }) {
                rootView
            }, minimumSize: minimumSize
        )
        HelloXWindowStyle.applyDialog(to: window)
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
    var onClose: () -> Void = {}
    let onChoose: () -> Void
    let onDrop: (URL) -> Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false
    @State private var dropError: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HXDialogStyle.background(colorScheme)
                .ignoresSafeArea()

            VStack(spacing: HXSpacing.md) {
                Button {
                    dropError = nil
                    onChoose()
                } label: {
                    VStack(spacing: 12) {
                        HelloXIcon(icon: .upload, size: 24)
                            .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
                        VStack(spacing: 4) {
                            Text(isDropTargeted ? "松开即可上传" : "点击或拖拽上传图片")
                                .font(HXTypography.section)
                                .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                            Text("支持 PNG、JPG、HEIC、TIFF 等常见图片格式")
                                .font(HXTypography.caption)
                                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 128, maxHeight: .infinity)
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
                                lineWidth: isDropTargeted ? 2 : 1
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
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
                        .font(HXTypography.caption)
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(HXTypography.body)
        .onExitCommand(perform: onClose)
    }
}
