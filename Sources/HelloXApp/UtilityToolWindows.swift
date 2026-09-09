import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class UtilityToolWindowController: NSWindowController, NSWindowDelegate {
    let tool: UtilityTool
    private let markdownOpenRouter: MarkdownOpenRouter
    private let colorPickerModel: ColorPickerToolModel?

    init(tool: UtilityTool) {
        self.tool = tool
        let markdownOpenRouter = MarkdownOpenRouter()
        let colorPickerModel = tool == .colorPicker ? ColorPickerToolModel() : nil
        self.markdownOpenRouter = markdownOpenRouter
        self.colorPickerModel = colorPickerModel
        let minimumSize: NSSize
        let initialSize: NSSize
        switch tool {
        case .markdown:
            minimumSize = NSSize(width: 900, height: 580)
            initialSize = NSSize(width: 1200, height: 800)
        case .colorPicker:
            minimumSize = NSSize(width: 380, height: 320)
            initialSize = NSSize(width: 380, height: 320)
        case .csvToExcel:
            minimumSize = NSSize(width: 560, height: 320)
            initialSize = NSSize(width: 600, height: 340)
        case .base64:
            minimumSize = NSSize(width: 700, height: 440)
            initialSize = NSSize(width: 760, height: 520)
        case .qrCode:
            minimumSize = NSSize(width: 560, height: 320)
            initialSize = NSSize(width: 620, height: 340)
        case .password:
            minimumSize = NSSize(width: 600, height: 300)
            initialSize = NSSize(width: 640, height: 300)
        }
        let window = HelloXWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = tool.title
        window.minSize = minimumSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        if tool == .markdown {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        window.tabbingMode = .disallowed
        window.center()
        window.contentViewController = HXDialogHostingController(
            rootView: HXDialogWindowContent(usesNativeWindowControls: tool == .markdown,
                                           title: tool.title, subtitle: tool.dialogSubtitle,
                                           onClose: { [weak window] in window?.performClose(nil) }) {
                UtilityToolRootView(tool: tool, markdownOpenRouter: markdownOpenRouter, colorPickerModel: colorPickerModel)
            }, minimumSize: minimumSize
        )
        HelloXWindowStyle.applyDialog(to: window)
        if tool == .markdown {
            window.isMovableByWindowBackground = false
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.isHidden = false
            }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                HelloXWindowStyle.positionSettingsWindowControls(in: window, topInset: 26)
            }
        }
        window.setContentSize(initialSize)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        if let window,
           !window.styleMask.contains(.fullScreen),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.midY - window.frame.height / 2
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        colorPickerModel?.beginSampling()
    }

    func openMarkdownDocuments(at urls: [URL]) {
        guard tool == .markdown else { return }
        markdownOpenRouter.open(urls)
        present()
    }

    func windowDidResize(_ notification: Notification) {
        guard tool == .markdown, let window, !window.styleMask.contains(.fullScreen) else { return }
        HelloXWindowStyle.positionSettingsWindowControls(in: window, topInset: 26)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard tool == .markdown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            HelloXWindowStyle.positionSettingsWindowControls(in: window, topInset: 26)
        }
    }

    func windowWillClose(_ notification: Notification) {
        colorPickerModel?.cancelSampling()
    }
}

private struct MarkdownOpenRequest: Equatable {
    let id = UUID()
    let urls: [URL]
}

@MainActor
private final class MarkdownOpenRouter: ObservableObject {
    @Published private(set) var request: MarkdownOpenRequest?

    func open(_ urls: [URL]) {
        let normalizedURLs = urls.map(\.standardizedFileURL)
        guard !normalizedURLs.isEmpty else { return }
        request = MarkdownOpenRequest(urls: normalizedURLs)
    }
}

@MainActor
final class QRCodeResultWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(values: [String]) {
        let initialSize = NSSize(width: 580, height: min(520, 140 + CGFloat(max(1, values.count)) * 70))
        let window = HelloXWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "二维码识别结果"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 200)
        window.contentViewController = HXDialogHostingController(
            rootView: HXDialogWindowContent(title: "二维码识别结果", onClose: { [weak window] in window?.performClose(nil) }) {
                QRCodeResultWindowView(values: values)
            }, minimumSize: NSSize(width: 460, height: 200)
        )
        HelloXWindowStyle.applyDialog(to: window)
        window.setContentSize(initialSize)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(values: [String]) {
        window?.contentViewController = HXDialogHostingController(
            rootView: HXDialogWindowContent(title: "二维码识别结果", onClose: { [weak window] in window?.performClose(nil) }) {
                QRCodeResultWindowView(values: values)
            }, minimumSize: NSSize(width: 460, height: 200)
        )
        present()
    }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

private struct QRCodeResultWindowView: View {
    let values: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            HXDialogStyle.background(colorScheme).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("共识别到 \(values.count) 条内容")
                        .font(HXTypography.caption)
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    Spacer()
                    HelloXUtilityTextButton(title: "复制全部", help: "复制全部") {
                        _ = UtilityClipboard.copy(values.joined(separator: "\n"))
                    }
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            HelloXCard(padding: 14) {
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(HXTypography.section).monospacedDigit()
                                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                                        .frame(width: 24, height: 24)
                                        .background(HelloXTheme.controlBackground(for: colorScheme), in: Circle())
                                    Text(value)
                                        .font(.system(size: 13, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let url = QRCodePayload.webURL(from: value) {
                                        HelloXUtilityTextButton(title: "打开网址", help: "打开网址") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    HelloXUtilityTextButton(title: "复制", help: "复制") {
                                        _ = UtilityClipboard.copy(value)
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .seamlessScrollChrome()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(HXTypography.body)
        .tint(HelloXTheme.accent)
    }
}

private struct UtilityToolRootView: View {
    let tool: UtilityTool
    @ObservedObject var markdownOpenRouter: MarkdownOpenRouter
    let colorPickerModel: ColorPickerToolModel?

    @ViewBuilder
    var body: some View {
        switch tool {
        case .csvToExcel: CSVExcelToolView()
        case .base64: Base64ToolView()
        case .qrCode: QRCodeToolView()
        case .colorPicker:
            if let colorPickerModel {
                ColorPickerToolView(model: colorPickerModel)
            }
        case .password: PasswordToolView()
        case .markdown: MarkdownToolView(openRouter: markdownOpenRouter)
        }
    }
}

private struct UtilityToolShell<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .background(HXDialogStyle.background(colorScheme))
            .font(HXTypography.body)
            .tint(HelloXTheme.accent)
    }
}

private struct CSVExcelToolView: View {
    @State private var sourceURL: URL?
    @State private var isDropTargeted = false
    @State private var isConverting = false
    @State private var message = ""
    @State private var failed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UtilityToolShell {
            VStack(spacing: 16) {
                Button(action: chooseCSV) {
                    VStack(spacing: 13) {
                        HelloXIcon(icon: .upload, size: 24)
                            .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
                        Text(isDropTargeted ? "松开即可选择 CSV" : "点击或拖拽 CSV 文件到这里")
                            .font(HXTypography.section)
                        Text(sourceURL?.lastPathComponent ?? "支持 UTF-8、UTF-16 编码及带引号的 CSV")
                            .font(HXTypography.caption)
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                    .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: HelloXTheme.cardRadius)
                            .stroke(isDropTargeted ? HelloXTheme.accent : HelloXTheme.border(for: colorScheme), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    sourceURL = url
                    message = ""
                    return true
                } isTargeted: { isDropTargeted = $0 }

                HStack {
                    if !message.isEmpty {
                        Text(message)
                            .font(HXTypography.caption)
                            .foregroundStyle(failed ? HelloXTheme.error : HelloXTheme.success)
                    }
                    Spacer()
                    if isConverting { ProgressView().controlSize(.small) }
                    HelloXUtilityTextButton(
                        title: "转换并保存",
                        help: "转换并保存 Excel",
                        role: .accent,
                        action: convert
                    )
                        .disabled(sourceURL == nil || isConverting)
                }
            }
        }
    }

    private func chooseCSV() {
        let panel = NSOpenPanel()
        panel.title = "选择 CSV 文件"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url
        message = ""
    }

    private func convert() {
        guard let sourceURL else { return }
        let panel = NSSavePanel()
        panel.title = "保存 Excel 文件"
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")!]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".xlsx"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isConverting = true
        message = ""
        Task { @MainActor in
            let errorMessage = await Task.detached {
                do {
                    try CSVExcelConverter.convert(sourceURL: sourceURL, destinationURL: destination)
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            isConverting = false
            failed = errorMessage != nil
            message = errorMessage ?? "转换完成：\(destination.lastPathComponent)"
        }
    }
}

private enum Base64Direction {
    case encode
    case decode
}

private struct Base64ToolView: View {
    @State private var direction: Base64Direction = .encode
    @State private var input = ""
    @State private var output = ""
    @State private var errorMessage = ""
    @State private var isSwapHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UtilityToolShell {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    editor(title: direction == .encode ? "文本" : "Base64", text: $input)
                    Button(action: swapDirection) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
                            .frame(width: 32, height: 32)
                            .background(isSwapHovered ? HelloXTheme.hoverBackground(for: colorScheme) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isSwapHovered = $0 }
                    .help("切换文本与 Base64 转换方向")
                    .accessibilityLabel("切换文本与 Base64 转换方向")
                    editor(title: direction == .encode ? "Base64" : "文本", text: $output)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack {
                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(HXTypography.caption).foregroundStyle(HelloXTheme.error)
                    }
                    Spacer()
                    HelloXUtilityTextButton(title: "清空", help: "清空", role: .destructive) {
                        input = ""
                        output = ""
                        errorMessage = ""
                    }
                    HelloXUtilityTextButton(title: "转换", help: "转换", role: .accent, action: convert)
                    HelloXUtilityTextButton(title: "复制结果", help: "复制结果") {
                        _ = UtilityClipboard.copy(output)
                    }
                        .disabled(output.isEmpty)
                }
            }
        }
    }

    private func editor(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(HXTypography.section)
            TextEditor(text: text)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 180, maxHeight: .infinity)
                .padding(8)
                .seamlessTextEditorChrome()
                .scrollContentBackground(.hidden)
                .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: HelloXTheme.controlRadius).stroke(HelloXTheme.border(for: colorScheme)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func swapDirection() {
        direction = direction == .encode ? .decode : .encode
        (input, output) = (output, input)
        errorMessage = ""
    }

    private func convert() {
        errorMessage = ""
        do {
            output = direction == .encode ? Base64Converter.encode(input) : try Base64Converter.decode(input)
        } catch {
            output = ""
            errorMessage = error.localizedDescription
        }
    }
}

struct QRCodeToolView: View {
    @State private var results: [String] = []
    @State private var selectedName = ""
    @State private var message = ""
    @State private var failed = false
    @State private var isDropTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    init(results: [String] = [], selectedName: String = "") {
        _results = State(initialValue: results)
        _selectedName = State(initialValue: selectedName)
    }

    var body: some View {
        UtilityToolShell {
            VStack(spacing: 16) {
                Button(action: chooseImage) {
                    Group {
                        if results.isEmpty {
                            VStack(spacing: 12) {
                                HelloXIcon(icon: .qrCode, size: 24).foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
                                Text(isDropTargeted ? "松开即可识别" : "点击或拖拽二维码图片")
                                    .font(HXTypography.section)
                                Text(selectedName.isEmpty ? "支持 PNG、JPG、HEIC、TIFF" : selectedName)
                                    .font(HXTypography.caption)
                                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                            }
                        } else {
                            HStack(spacing: 12) {
                                HelloXIcon(icon: .qrCode, size: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isDropTargeted ? "松开即可识别" : "重新选择二维码图片")
                                        .font(HXTypography.section)
                                    Text("\(selectedName) · \(results.count) 条结果")
                                        .font(HXTypography.caption)
                                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: results.isEmpty ? 160 : 56,
                           maxHeight: results.isEmpty ? .infinity : nil)
                    .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: HelloXTheme.cardRadius)
                            .stroke(isDropTargeted ? HelloXTheme.accent : HelloXTheme.border(for: colorScheme), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    }
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    recognize(url)
                    return true
                } isTargeted: { isDropTargeted = $0 }

                if !results.isEmpty {
                    ScrollView {
                        HelloXCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("识别结果").font(HXTypography.section)
                                ForEach(Array(results.enumerated()), id: \.offset) { _, value in
                                    HStack(alignment: .top) {
                                        Text(value)
                                            .font(.system(size: 13, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HelloXUtilityTextButton(title: "复制", help: "复制") {
                                            _ = UtilityClipboard.copy(value)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .seamlessScrollChrome()
                }
                if !message.isEmpty && (failed || results.isEmpty) {
                    HelloXStatusBanner(message: message, kind: failed ? .error : .success)
                }
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择二维码图片"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recognize(url)
    }

    private func recognize(_ url: URL) {
        selectedName = url.lastPathComponent
        results = []
        do {
            results = try QRCodeRecognitionService.recognize(at: url)
            failed = false
            message = "识别到 \(results.count) 个二维码"
        } catch UtilityToolError.qrCodeNotFound {
            failed = false
            message = ""
            CopyFeedbackPresenter.shared.showFailure(UtilityToolError.qrCodeNotFound.localizedDescription)
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}

@MainActor
private final class ColorPickerToolModel: NSObject, ObservableObject {
    @Published var color = NSColor(srgbRed: 0.16, green: 0.46, blue: 0.96, alpha: 1)
    @Published private(set) var isSampling = false
    private var sampler: NSColorSampler?
    private var samplingSessionID: UUID?
    private var adjustmentWell: NSColorWell?

    var code: ColorCode { ColorCode(color: color) }

    func beginSampling() {
        guard !isSampling else { return }
        endAdjusting()
        let sampler = NSColorSampler()
        let sessionID = UUID()
        self.sampler = sampler
        samplingSessionID = sessionID
        isSampling = true
        sampler.show { [weak self] sampledColor in
            guard let self, self.samplingSessionID == sessionID else { return }
            self.isSampling = false
            self.sampler = nil
            self.samplingSessionID = nil
            if let sampledColor {
                self.color = sampledColor.usingColorSpace(.sRGB) ?? sampledColor
            }
        }
    }

    func cancelSampling() {
        endAdjusting()
        guard isSampling else { return }
        samplingSessionID = nil
        sampler = nil
        isSampling = false

        // NSColorSampler has no public cancellation method. Its native interface
        // treats Escape as cancellation, so post the same event when the owning
        // window closes to prevent the sampler from remaining active.
        let timestamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            ) else { continue }
            NSApp.postEvent(event, atStart: true)
        }
    }

    func beginAdjusting() {
        guard !isSampling else { return }
        let well = adjustmentWell ?? NSColorWell()
        well.supportsAlpha = true
        well.target = self
        well.action = #selector(updateAdjustedColor(_:))
        well.color = color
        adjustmentWell = well
        // Let the native well manage ownership of the shared color panel while
        // the visible control remains a regular HelloX button.
        well.activate(true)
        NSColorPanel.shared.orderFront(nil)
    }

    private func endAdjusting() {
        guard let well = adjustmentWell else { return }
        let ownsPanel = well.isActive
        well.deactivate()
        well.target = nil
        well.action = nil
        adjustmentWell = nil
        if ownsPanel { NSColorPanel.shared.orderOut(nil) }
    }

    @objc private func updateAdjustedColor(_ sender: NSColorWell) {
        color = sender.color.usingColorSpace(.sRGB) ?? sender.color
    }
}

private struct ColorPickerToolView: View {
    @ObservedObject var model: ColorPickerToolModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            HXDialogStyle.background(colorScheme).ignoresSafeArea()
            VStack(alignment: .leading, spacing: HXSpacing.md) {
                HStack(spacing: HXSpacing.md) {
                    colorPreview
                    VStack(alignment: .leading, spacing: HXSpacing.xxs) {
                        Text(model.isSampling ? "点击屏幕上的颜色" : "当前颜色")
                            .font(HXTypography.caption)
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        Text(model.code.hex)
                            .font(HXTypography.title.monospaced())
                            .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        HStack(spacing: HXSpacing.xs) {
                            HelloXUtilityTextButton(
                                title: model.isSampling ? "正在取色" : "重新取色",
                                help: "重新取色",
                                action: model.beginSampling
                            )
                            HelloXUtilityTextButton(title: "微调", help: "微调颜色和透明度", action: model.beginAdjusting)
                        }
                        .disabled(model.isSampling)
                        .padding(.top, HXSpacing.xxs)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 0) {
                    colorCodeRow(label: "HEX", value: model.code.hex)
                    codeDivider
                    colorCodeRow(label: model.code.alpha == 255 ? "RGB" : "RGBA", value: model.code.rgb)
                    codeDivider
                    colorCodeRow(label: model.code.alpha == 255 ? "HSL" : "HSLA", value: model.code.hsl)
                }
                .padding(.horizontal, HXSpacing.sm)
                .padding(.vertical, HXSpacing.xxs)
                .background(HelloXTheme.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: HelloXTheme.cardRadius)
                        .strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(HXTypography.body)
        .tint(HelloXTheme.accent)
    }

    private var colorPreview: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(HelloXTheme.surface(for: colorScheme)))
            let cell = HXSpacing.xs
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(HelloXTheme.controlBackground(for: colorScheme)))
                }
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: model.color)))
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: HelloXTheme.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HelloXTheme.controlRadius)
                .strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 1)
        }
        .accessibilityLabel("当前颜色 \(model.code.hex)")
    }

    private var codeDivider: some View {
        Rectangle()
            .fill(HelloXTheme.border(for: colorScheme))
            .frame(height: 1)
    }

    private func colorCodeRow(label: String, value: String) -> some View {
        HStack(spacing: HXSpacing.xs) {
            Text(label)
                .font(HXTypography.caption)
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(HXTypography.caption.monospaced())
                .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .leading)
            HelloXIconButton(icon: .copy, help: "复制 \(label) 颜色代码", size: 28, iconSize: 14) {
                _ = UtilityClipboard.copy(value)
            }
        }
        .frame(height: 36)
    }
}

private struct PasswordToolView: View {
    @State private var length = 20
    @State private var lowercase = true
    @State private var uppercase = true
    @State private var numbers = true
    @State private var symbols = true
    @State private var password = ""
    @State private var errorMessage = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UtilityToolShell {
            VStack(spacing: 12) {
                HelloXCard {
                    VStack(spacing: 16) {
                        TextField("随机密码", text: $password)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(14)
                            .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius))
                            .overlay(RoundedRectangle(cornerRadius: HelloXTheme.controlRadius).stroke(HelloXTheme.border(for: colorScheme)))
                        HStack {
                            Text("长度：\(length)").font(HXTypography.section)
                            Slider(value: Binding(get: { Double(length) }, set: { length = Int($0) }), in: 8...128, step: 1)
                        }
                        HStack(spacing: 18) {
                            Toggle("小写字母", isOn: $lowercase)
                            Toggle("大写字母", isOn: $uppercase)
                            Toggle("数字", isOn: $numbers)
                            Toggle("符号", isOn: $symbols)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(HXTypography.caption).foregroundStyle(HelloXTheme.error)
                    }
                    Spacer()
                    HelloXUtilityTextButton(title: "重新生成", help: "重新生成", role: .accent, action: generate)
                    HelloXUtilityTextButton(title: "复制密码", help: "复制密码") {
                        _ = UtilityClipboard.copy(password)
                    }
                        .disabled(password.isEmpty)
                }
            }
            .onAppear(perform: generate)
            .onChange(of: length) { generate() }
            .onChange(of: lowercase) { generate() }
            .onChange(of: uppercase) { generate() }
            .onChange(of: numbers) { generate() }
            .onChange(of: symbols) { generate() }
        }
    }

    private func generate() {
        do {
            password = try SecurePasswordGenerator.generate(
                length: length,
                lowercase: lowercase,
                uppercase: uppercase,
                numbers: numbers,
                symbols: symbols
            )
            errorMessage = ""
        } catch {
            password = ""
            errorMessage = error.localizedDescription
        }
    }
}

enum MarkdownWorkspaceMode: String, CaseIterable, Identifiable {
    case preview = "阅读"
    case edit = "编辑"

    static let defaultMode = MarkdownWorkspaceMode.preview
    var id: String { rawValue }
}

final class MarkdownLocalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let maximumConcurrentLoadCount = 3
    private static let maximumQueuedLoadCount = 128

    private struct LoadedImage: Sendable {
        let data: Data
        let mimeType: String
    }

    private enum LoadResult: Sendable {
        case success(LoadedImage)
        case failure(code: Int, description: String)
    }

    private final class SchemeTaskReference {
        let task: any WKURLSchemeTask

        init(_ task: any WKURLSchemeTask) {
            self.task = task
        }
    }

    private struct LoadRequest {
        let taskReference: SchemeTaskReference
        let requestURL: URL
        let fileURL: URL
        let allowedDirectoryURL: URL
        var worker: Task<Void, Never>?
    }

    private final class WeakHandlerReference: @unchecked Sendable {
        weak var handler: MarkdownLocalImageSchemeHandler?

        init(_ handler: MarkdownLocalImageSchemeHandler) {
            self.handler = handler
        }
    }

    private var allowedDirectoryURL: URL?
    private var loadRequests: [ObjectIdentifier: LoadRequest] = [:]
    private var pendingLoadIdentifiers: [ObjectIdentifier] = []
    private var runningLoadCount = 0

    func setAllowedDirectory(_ directoryURL: URL?) {
        let nextDirectoryURL = directoryURL.flatMap { url -> URL? in
            guard url.isFileURL else { return nil }
            return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        }
        guard nextDirectoryURL != allowedDirectoryURL else { return }
        loadRequests.values.forEach { $0.worker?.cancel() }
        loadRequests.removeAll()
        pendingLoadIdentifiers.removeAll()
        runningLoadCount = 0
        allowedDirectoryURL = nextDirectoryURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = MarkdownLocalImageScheme.fileURL(for: requestURL),
              let allowedDirectoryURL else {
            fail(urlSchemeTask, code: 400, description: "无效的本地图片地址。")
            return
        }

        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        cancelLoad(identifier)
        guard loadRequests.count < Self.maximumQueuedLoadCount else {
            fail(urlSchemeTask, code: 429, description: "Markdown 中待加载的本地图片过多。")
            return
        }
        loadRequests[identifier] = LoadRequest(
            taskReference: SchemeTaskReference(urlSchemeTask),
            requestURL: requestURL,
            fileURL: fileURL,
            allowedDirectoryURL: allowedDirectoryURL,
            worker: nil
        )
        pendingLoadIdentifiers.append(identifier)
        startPendingLoads()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        cancelLoad(identifier)
        startPendingLoads()
    }

    private func startPendingLoads() {
        while runningLoadCount < Self.maximumConcurrentLoadCount,
              !pendingLoadIdentifiers.isEmpty {
            let identifier = pendingLoadIdentifiers.removeFirst()
            guard var request = loadRequests[identifier], request.worker == nil else { continue }
            let handlerReference = WeakHandlerReference(self)
            let fileURL = request.fileURL
            let allowedDirectoryURL = request.allowedDirectoryURL
            request.worker = Task.detached(priority: .userInitiated) {
                let result = Self.loadImage(
                    at: fileURL,
                    containedIn: allowedDirectoryURL
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    handlerReference.handler?.finishLoad(identifier, with: result)
                }
            }
            loadRequests[identifier] = request
            runningLoadCount += 1
        }
    }

    private func cancelLoad(_ identifier: ObjectIdentifier) {
        guard let request = loadRequests.removeValue(forKey: identifier) else { return }
        if let worker = request.worker {
            worker.cancel()
            runningLoadCount = max(0, runningLoadCount - 1)
        } else {
            pendingLoadIdentifiers.removeAll { $0 == identifier }
        }
    }

    private func finishLoad(_ identifier: ObjectIdentifier, with result: LoadResult) {
        guard let request = loadRequests.removeValue(forKey: identifier),
              request.worker != nil else { return }
        runningLoadCount = max(0, runningLoadCount - 1)
        complete(request.taskReference.task, requestURL: request.requestURL, with: result)
        startPendingLoads()
    }

    private nonisolated static func loadImage(
        at fileURL: URL,
        containedIn allowedDirectoryURL: URL
    ) -> LoadResult {
        let maximumImageByteCount = 64 * 1_024 * 1_024
        guard let resolvedFileURL = MarkdownLocalImageScheme.resolvedFileURL(
            fileURL,
            containedIn: allowedDirectoryURL
        ) else {
            return .failure(code: 403, description: "图片路径超出了 Markdown 文档目录。")
        }

        do {
            let values = try resolvedFileURL.resourceValues(
                forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let contentType = values.contentType,
                  contentType.conforms(to: .image) else {
                return .failure(code: 415, description: "该本地资源不是支持的图片文件。")
            }
            if let fileSize = values.fileSize, fileSize > maximumImageByteCount {
                return .failure(code: 413, description: "本地图片超过 64 MB，无法预览。")
            }

            let fileHandle = try FileHandle(forReadingFrom: resolvedFileURL)
            defer { try? fileHandle.close() }
            var data = Data()
            data.reserveCapacity(min(values.fileSize ?? 0, maximumImageByteCount))
            while data.count <= maximumImageByteCount, !Task.isCancelled {
                let remainingByteCount = maximumImageByteCount + 1 - data.count
                guard let chunk = try fileHandle.read(upToCount: min(1_048_576, remainingByteCount)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= maximumImageByteCount else {
                return .failure(code: 413, description: "本地图片超过 64 MB，无法预览。")
            }
            return .success(LoadedImage(
                data: data,
                mimeType: contentType.preferredMIMEType ?? "application/octet-stream"
            ))
        } catch {
            return .failure(code: 404, description: error.localizedDescription)
        }
    }

    private func complete(
        _ urlSchemeTask: any WKURLSchemeTask,
        requestURL: URL,
        with result: LoadResult
    ) {
        switch result {
        case .success(let image):
            let response = URLResponse(
                url: requestURL,
                mimeType: image.mimeType,
                expectedContentLength: image.data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(image.data)
            urlSchemeTask.didFinish()
        case .failure(let code, let description):
            fail(urlSchemeTask, code: code, description: description)
        }
    }

    private func fail(
        _ urlSchemeTask: any WKURLSchemeTask,
        code: Int,
        description: String
    ) {
        urlSchemeTask.didFailWithError(NSError(
            domain: "HelloX.MarkdownLocalImage",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        ))
    }
}

@MainActor
final class MarkdownPreviewModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private let localImageSchemeHandler: MarkdownLocalImageSchemeHandler
    private var renderKey = ""
    private var imageBaseURL: URL?
    let imageOverlay = MarkdownWindowImageOverlay()

    override init() {
        let configuration = WKWebViewConfiguration()
        let localImageSchemeHandler = MarkdownLocalImageSchemeHandler()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: MarkdownImageViewer.script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.setURLSchemeHandler(
            localImageSchemeHandler,
            forURLScheme: MarkdownLocalImageScheme.name
        )
        self.localImageSchemeHandler = localImageSchemeHandler
        webView = MarkdownPreviewWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        configuration.userContentController.add(MarkdownImageMessageHandler(target: self), name: "hxOpenImageViewer")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = true
        webView.magnification = 1
    }

    func render(markdown: String, title: String, baseURL: URL?) {
        localImageSchemeHandler.setAllowedDirectory(baseURL)
        let previewBaseURL = MarkdownLocalImageScheme.previewBaseURL(for: baseURL)
        let html = MarkdownHTMLConverter.convert(
            markdown,
            title: title,
            baseURL: previewBaseURL,
            localFileImageScheme: MarkdownLocalImageScheme.name
        )
        let key = "\(baseURL?.path ?? "")\u{0}\(html)"
        guard key != renderKey else { return }
        imageOverlay.dismiss()
        imageBaseURL = baseURL
        renderKey = key
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        (webView as? MarkdownPreviewWebView)?.updateImageViewerScope()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let gallery = message.body as? [String: Any], let window = webView.window else { return }
        imageOverlay.present(gallery: gallery, in: window, source: webView, baseURL: imageBaseURL)
    }

    func scroll(to headingID: String) {
        webView.evaluateJavaScript("document.getElementById('\(headingID)')?.scrollIntoView({behavior:'smooth',block:'start'});")
    }

    func pdfData() async throws -> Data {
        imageOverlay.dismiss()
        try await waitUntilDocumentIsReady()
        _ = try await webView.evaluateJavaScript("document.getElementById('hx-image-viewer')?.close(); true;")
        let configuration = WKPDFConfiguration()
        let contentSize = try await documentSize()
        configuration.rect = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(760, contentSize.width),
                height: max(webView.bounds.height, contentSize.height)
            )
        )
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func waitUntilDocumentIsReady() async throws {
        for _ in 0..<100 {
            if !webView.isLoading,
               try await documentReadyState() == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "HelloX.MarkdownPreview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Markdown 预览尚未加载完成，请稍后重试。"]
        )
    }

    private func documentReadyState() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("document.readyState") { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String ?? "") }
            }
        }
    }

    private func documentSize() async throws -> CGSize {
        let script = """
        (() => {
          const root = document.documentElement;
          const body = document.body;
          const width = Math.max(root.scrollWidth, root.clientWidth, body?.scrollWidth || 0);
          const height = Math.max(root.scrollHeight, root.clientHeight, body?.scrollHeight || 0);
          return `${width},${height}`;
        })();
        """
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let components = (result as? String)?.split(separator: ",") ?? []
                guard components.count == 2,
                      let width = Double(components[0]),
                      let height = Double(components[1]) else {
                    continuation.resume(returning: self.webView.bounds.size)
                    return
                }
                continuation.resume(returning: CGSize(width: width, height: height))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(MarkdownLocalImageScheme.fileURL(for: url) ?? url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

@MainActor
final class MarkdownDocumentTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL?
    @Published var markdown: String {
        didSet {
            // Heading IDs are positional; changed headings must not inherit another branch's state.
            if MarkdownHeadingParser.headings(in: oldValue) != headings {
                collapsedHeadingIDs.removeAll()
            }
        }
    }
    @Published private(set) var savedMarkdown: String
    @Published var mode: MarkdownWorkspaceMode = .defaultMode {
        didSet { updateFileMonitoring() }
    }
    @Published var isTableOfContentsExpanded = true
    @Published private(set) var collapsedHeadingIDs: Set<String> = []
    let previewModel = MarkdownPreviewModel()
    private let fileMonitor = MarkdownFileMonitor()

    init(url: URL?, markdown: String) {
        self.url = url?.standardizedFileURL
        self.markdown = markdown
        self.savedMarkdown = markdown
        fileMonitor.onChange = { [weak self] in
            guard let self, self.mode == .preview, !self.isModified else { return }
            _ = try? self.reloadFromDisk()
        }
        updateFileMonitoring()
    }

    var displayName: String { url?.deletingPathExtension().lastPathComponent ?? "未命名" }
    var isModified: Bool { markdown != savedMarkdown }
    var headings: [MarkdownHeading] { MarkdownHeadingParser.headings(in: markdown) }
    var outlineRows: [MarkdownOutlineRow] {
        MarkdownOutline.visibleRows(headings: headings, collapsedIDs: collapsedHeadingIDs)
    }
    var exportBaseName: String { url?.deletingPathExtension().lastPathComponent ?? "Markdown" }

    func toggleHeading(_ id: String) {
        if !collapsedHeadingIDs.insert(id).inserted {
            collapsedHeadingIDs.remove(id)
        }
    }

    func markSaved(at url: URL) {
        self.url = url.standardizedFileURL
        savedMarkdown = markdown
        updateFileMonitoring()
    }

    @discardableResult
    func reloadFromDisk(discardingUnsavedChanges: Bool = false) throws -> Bool {
        guard let url else { return false }
        guard discardingUnsavedChanges || !isModified else { return false }
        let latestMarkdown = try MarkdownFileService.read(from: url)
        let didChange = latestMarkdown != markdown
        savedMarkdown = latestMarkdown
        markdown = latestMarkdown
        return didChange
    }

    private func updateFileMonitoring() {
        guard mode == .preview, let url else {
            fileMonitor.stop()
            return
        }
        fileMonitor.start(for: url)
        guard !isModified else { return }
        _ = try? reloadFromDisk()
    }
}

@MainActor
private final class MarkdownFileMonitor {
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var monitoredDirectoryURL: URL?
    private var pendingReload: DispatchWorkItem?

    func start(for fileURL: URL) {
        let directoryURL = fileURL.deletingLastPathComponent().standardizedFileURL
        guard monitoredDirectoryURL != directoryURL || source == nil else { return }
        stop()

        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleReload()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        monitoredDirectoryURL = directoryURL
        source.activate()
    }

    func stop() {
        pendingReload?.cancel()
        pendingReload = nil
        source?.cancel()
        source = nil
        monitoredDirectoryURL = nil
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        pendingReload = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    deinit {
        source?.cancel()
    }
}

@MainActor
final class MarkdownWorkspace: ObservableObject {
    @Published private(set) var documents: [MarkdownDocumentTab] = []
    @Published private(set) var activeDocumentID: UUID?

    var activeDocument: MarkdownDocumentTab? {
        documents.first { $0.id == activeDocumentID }
    }

    @discardableResult
    func openDocument(url: URL, markdown: String) -> MarkdownDocumentTab {
        let standardizedURL = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url == standardizedURL }) {
            activate(existing)
            return existing
        }
        let document = MarkdownDocumentTab(url: standardizedURL, markdown: markdown)
        documents.append(document)
        activate(document)
        return document
    }

    func openDocuments(at urls: [URL]) -> [Error] {
        var errors: [Error] = []
        for url in urls {
            let standardizedURL = url.standardizedFileURL
            if let existing = documents.first(where: { $0.url == standardizedURL }) {
                activate(existing)
                continue
            }
            do {
                _ = openDocument(url: standardizedURL, markdown: try MarkdownFileService.read(from: standardizedURL))
            } catch {
                errors.append(error)
            }
        }
        return errors
    }

    func activate(_ document: MarkdownDocumentTab) {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        activeDocumentID = document.id
    }

    func close(_ document: MarkdownDocumentTab) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let wasActive = activeDocumentID == document.id
        documents.remove(at: index)
        guard wasActive else { return }
        activeDocumentID = documents.indices.contains(index)
            ? documents[index].id
            : documents.last?.id
    }
}

private struct MarkdownWebPreview: NSViewRepresentable {
    @ObservedObject var model: MarkdownPreviewModel
    let markdown: String
    let title: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        model.render(markdown: markdown, title: title, baseURL: baseURL)
        DispatchQueue.main.async { MarkdownScrollChrome.apply(to: model.webView) }
        return model.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        DispatchQueue.main.async { MarkdownScrollChrome.apply(to: webView) }
        model.render(markdown: markdown, title: title, baseURL: baseURL)
    }
}

@MainActor
private enum MarkdownScrollChrome {
    static func apply(to webView: WKWebView) {
        scrollViews(in: webView).forEach { scrollView in
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            HelloXScrollChrome.apply(to: scrollView)
            scrollView.verticalScroller?.isHidden = false
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.reduce(into: view is NSScrollView ? [view as! NSScrollView] : []) { result, child in
            result.append(contentsOf: scrollViews(in: child))
        }
    }
}

private struct MarkdownToolView: View {
    @StateObject private var workspace = MarkdownWorkspace()
    @State private var message = ""
    @State private var failed = false
    @State private var consumedOpenRequestID: UUID?
    @ObservedObject var openRouter: MarkdownOpenRouter
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UtilityToolShell {
            VStack(spacing: 10) {
                commandBar
                if !workspace.documents.isEmpty { tabBar }
                Group {
                    if let document = workspace.activeDocument {
                        MarkdownDocumentWorkspaceView(
                            document: document,
                            message: message,
                            failed: failed
                        )
                        // The editor and preview are stateful AppKit/SwiftUI views.
                        // Recreate this subtree when the active tab changes so they
                        // cannot retain the previously selected document's content.
                        .id(document.id)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { consume(openRouter.request) }
        .onChange(of: openRouter.request) { _, request in consume(request) }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            fileMenu
            if let document = workspace.activeDocument {
                MarkdownModePicker(document: document)
                if document.mode == .preview {
                    commandButton("刷新", help: "重新读取磁盘上的 Markdown") {
                        refresh(document)
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
        .background {
            // Keep the established document shortcuts available while the
            // visible commands live in the shared dropdown menu.
            VStack {
                Button("打开 Markdown", action: openMarkdown)
                    .keyboardShortcut("o", modifiers: .command)
                if let document = workspace.activeDocument {
                    Button("保存 Markdown") { _ = save(document, saveAs: false) }
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.documents) { document in
                    MarkdownDocumentTabControl(
                        document: document,
                        isActive: workspace.activeDocumentID == document.id,
                        onActivate: { workspace.activate(document) },
                        onClose: { requestClose(document) }
                    )
                }
            }
            .padding(2)
            .background(HXSegmentedStyle.track(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(height: 28)
    }

    private func commandButton(
        _ title: String,
        help: String,
        isAccent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HelloXUtilityTextButton(
            title: title,
            help: help,
            role: isAccent ? .accent : .neutral,
            action: action
        )
    }

    private var fileMenu: some View {
        let document = workspace.activeDocument
        return HXDropdownMenu("文件", showsChevron: false, actions: [
            HXDropdownAction("打开", action: openMarkdown),
            HXDropdownAction("保存", isEnabled: document != nil) {
                if let document { _ = save(document, saveAs: false) }
            },
            HXDropdownAction("另存为", isEnabled: document != nil) {
                if let document { _ = save(document, saveAs: true) }
            },
            HXDropdownAction("导出 PDF", isEnabled: document != nil) {
                if let document { exportPDF(document) }
            },
            HXDropdownAction("导出 HTML", isEnabled: document != nil) {
                if let document { exportHTML(document) }
            }
        ])
        .fixedSize()
        .accessibilityLabel("文件")
        .help("打开、保存或导出 Markdown")
    }

    private func openMarkdown() {
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文件"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md")!,
            UTType(filenameExtension: "markdown")!,
            UTType(filenameExtension: "mdown")!,
            UTType(filenameExtension: "mkd")!,
            .plainText
        ]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    private func consume(_ request: MarkdownOpenRequest?) {
        guard let request, request.id != consumedOpenRequestID else { return }
        consumedOpenRequestID = request.id
        open(urls: request.urls)
    }

    private func open(urls: [URL]) {
        let errors = workspace.openDocuments(at: urls)
        if let error = errors.first {
            failed = true
            message = error.localizedDescription
        } else if let document = workspace.activeDocument {
            failed = false
            message = "已打开：\(document.displayName)"
        }
    }

    private func requestClose(_ document: MarkdownDocumentTab) {
        guard document.isModified else {
            workspace.close(document)
            return
        }
        let alert = HelloXAlert()
        alert.alertStyle = .warning
        alert.messageText = "要保存对“\(document.displayName)”的更改吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if save(document, saveAs: document.url == nil) { workspace.close(document) }
        case .alertSecondButtonReturn:
            workspace.close(document)
        default:
            break
        }
    }

    private func refresh(_ document: MarkdownDocumentTab) {
        if document.isModified {
            let alert = HelloXAlert()
            alert.alertStyle = .warning
            alert.messageText = "要放弃对“\(document.displayName)”的未保存更改并刷新吗？"
            alert.informativeText = "刷新后将显示磁盘上的最新内容。"
            alert.addButton(withTitle: "放弃更改并刷新")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            let didChange = try document.reloadFromDisk(discardingUnsavedChanges: true)
            failed = false
            message = didChange
                ? "已刷新：\(document.displayName)"
                : "已是最新：\(document.displayName)"
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }

    @discardableResult
    private func save(_ document: MarkdownDocumentTab, saveAs: Bool) -> Bool {
        var destination = saveAs ? nil : document.url
        if destination == nil {
            let panel = NSSavePanel()
            panel.title = saveAs ? "Markdown 另存为" : "保存 Markdown 文件"
            panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
            panel.nameFieldStringValue = document.url?.lastPathComponent ?? "未命名.md"
            guard panel.runModal() == .OK else { return false }
            destination = panel.url
        }
        guard let destination else { return false }
        do {
            try MarkdownFileService.write(document.markdown, to: destination)
            document.markSaved(at: destination)
            failed = false
            message = "已保存：\(destination.lastPathComponent)"
            return true
        } catch {
            failed = true
            message = error.localizedDescription
            return false
        }
    }

    private func exportHTML(_ document: MarkdownDocumentTab) {
        let panel = NSSavePanel()
        panel.title = "导出 HTML"
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(document.exportBaseName).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let html = MarkdownHTMLConverter.convert(
                document.markdown,
                title: document.exportBaseName,
                baseURL: document.url?.deletingLastPathComponent()
            )
            try Data(html.utf8).write(to: url, options: .atomic)
            failed = false
            message = "HTML 已导出：\(url.lastPathComponent)"
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }

    private func exportPDF(_ document: MarkdownDocumentTab) {
        let panel = NSSavePanel()
        panel.title = "导出 PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(document.exportBaseName).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.mode = .preview
        document.previewModel.render(
            markdown: document.markdown,
            title: document.exportBaseName,
            baseURL: document.url?.deletingLastPathComponent()
        )
        Task { @MainActor in
            do {
                try (await document.previewModel.pdfData()).write(to: url, options: .atomic)
                failed = false
                message = "PDF 已导出：\(url.lastPathComponent)"
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }
}

private struct MarkdownDocumentTabControl: View {
    @ObservedObject var document: MarkdownDocumentTab
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onActivate) {
                HStack(spacing: 6) {
                    Text(document.displayName)
                        .lineLimit(1)
                    if document.isModified {
                        Circle()
                            .fill(HelloXTheme.accent)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(maxWidth: 180)
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                HelloXIcon(icon: .close, size: 16)
                    .foregroundStyle(HelloXTheme.iconForeground(for: colorScheme))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭 \(document.displayName)")
            .accessibilityLabel("关闭 \(document.displayName)")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(HXSegmentedStyle.foreground(isSelected: isActive, for: colorScheme))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 8).fill(HXSegmentedStyle.selection(for: colorScheme))
                    .shadow(color: HXSegmentedStyle.shadow(for: colorScheme), radius: 1, y: 1)
            }
        }
    }
}

private struct MarkdownModePicker: View {
    @ObservedObject var document: MarkdownDocumentTab

    var body: some View {
        HXSegmentedControl("模式", selection: $document.mode, options:
            MarkdownWorkspaceMode.allCases.map { HXSegment($0, $0.rawValue) }
        )
    }
}

private struct MarkdownDocumentWorkspaceView: View {
    @ObservedObject var document: MarkdownDocumentTab
    let message: String
    let failed: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if document.mode == .preview { previewWorkspace }
                else { editorWorkspace }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            statusBar
        }
    }

    private var previewWorkspace: some View {
        HStack(spacing: 0) {
            MarkdownTableOfContents(document: document)
                .id(document.id)
            MarkdownWebPreview(
                model: document.previewModel,
                markdown: document.markdown,
                title: document.exportBaseName,
                baseURL: document.url?.deletingLastPathComponent()
            )
            .background(HelloXTheme.raisedSurface(for: colorScheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
    }

    private var editorWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Markdown 源码")
                    .font(HXTypography.section)
                Spacer()
                HelloXUtilityTextButton(title: "完成并预览", help: "完成编辑并预览", role: .accent) {
                    document.mode = .preview
                }
            }
            TextEditor(text: $document.markdown)
                .font(.system(size: 14, design: .monospaced))
                .padding(14)
                .visibleScrollChrome()
                .scrollContentBackground(.hidden)
                .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
        }
    }

    private var statusBar: some View {
        HStack {
            if !message.isEmpty {
                Text(message)
                    .foregroundStyle(failed ? HelloXTheme.error : HelloXTheme.success)
            }
            Spacer()
            Text("\(document.markdown.count) 字符 · \(document.headings.count) 个标题")
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
        }
        .font(HXTypography.caption)
    }
}
