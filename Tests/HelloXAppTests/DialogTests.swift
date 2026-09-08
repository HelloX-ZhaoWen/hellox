import AppKit
import HelloXCore
import SwiftUI
import Testing
@testable import HelloXApp

@MainActor
@Suite(.serialized)
struct DialogTests {
    init() {
        HXTypography.configureRendering()
        _ = NSApplication.shared
    }

    @Test func markdownUsesNativeWindowControlsAndSupportsFullScreen() async throws {
        let controller = UtilityToolWindowController(tool: .markdown)
        let window = try #require(controller.window)
        defer { window.close() }
        await settleLayout(of: window)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(type))
            #expect(!button.isHidden)
            #expect(button.isEnabled)
            let frameView = try #require(window.contentView?.superview)
            let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            let point = button.convert(center, to: frameView)
            #expect(frameView.hitTest(point) === button, "Native button must receive clicks at its visible position")

        }
        for size in [NSSize(width: 960, height: 620), NSSize(width: 1200, height: 800)] {
            window.setContentSize(size)
            await settleLayout(of: window)
            let frameView = try #require(window.contentView?.superview)
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try #require(window.standardWindowButton(type))
                let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
                #expect(frameView.hitTest(button.convert(center, to: frameView)) === button)
            }
        }
        if let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            controller.openMarkdownDocuments(at: [repository.appendingPathComponent("README.md")])
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(400))
                await settleLayout(of: window)
                let frameView = try #require(window.contentView?.superview)
                let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("markdown-window-\(name).png"))
            }
        }
    }

    @Test func windowContentStaysAtTheTopWhenTheWindowGrows() async throws {
        let marker = NSView()
        let content = HXDialogWindowContent(title: "文本翻译", onClose: {}) {
            DialogLayoutMarker(view: marker)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
        }
        let host = HXDialogHostingController(rootView: content)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        HelloXWindowStyle.applyDialog(to: window)
        window.contentViewController = host
        defer { window.close() }

        var firstTop: CGFloat?
        for size in [NSSize(width: 560, height: 380), NSSize(width: 560, height: 780)] {
            window.setContentSize(size)
            await settleLayout(of: window)
            let contentView = try #require(window.contentView)
            #expect(marker.window === window)
            #expect(abs(contentView.bounds.width - size.width) < 0.5)
            #expect(abs(contentView.bounds.height - size.height) < 0.5)
            let rect = marker.convert(marker.bounds, to: contentView)
            let top = contentView.isFlipped ? rect.minY : contentView.bounds.maxY - rect.maxY
            // A 20-point top inset, the 32-point close button, and a compact
            // header/body gap should fit comfortably inside the first 72 points.
            #expect(top >= 48)
            #expect(top <= 72)
            #expect(abs(rect.height - 24) < 0.5)
            if let firstTop {
                #expect(abs(top - firstTop) < 0.5)
            } else {
                firstTop = top
            }
        }
    }

    @Test func changingDialogContentDoesNotResizeItsWindow() async throws {
        let marker = NSView()
        let state = DialogLayoutState()
        let host = HXDialogHostingController(rootView: DialogLayoutFixture(state: state, marker: marker))
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        HelloXWindowStyle.applyDialog(to: window)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 640, height: 480))
        defer { window.close() }
        await settleLayout(of: window)
        let frame = window.frame
        let contentView = try #require(window.contentView)
        let markerFrame = marker.convert(marker.bounds, to: contentView)

        for message in [String(repeating: "翻译结果已更新。\n", count: 12), ""] {
            state.message = message
            await settleLayout(of: window)
            #expect(window.frame == frame)
            #expect(marker.convert(marker.bounds, to: contentView) == markerFrame)
        }
    }

    @Test func dialogMinimumSizeSurvivesDeferredHostingLayout() async throws {
        let minimum = NSSize(width: 460, height: 200)
        let host = HXDialogHostingController(
            rootView: HXDialogWindowContent(title: "识别结果", onClose: {}) { Text("示例内容") },
            minimumSize: minimum
        )
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        HelloXWindowStyle.applyDialog(to: window)
        window.contentViewController = host
        defer { window.close() }
        for size in [NSSize(width: 740, height: 390), NSSize(width: 100, height: 100),
                     NSSize(width: 600, height: 320)] {
            window.setContentSize(size)
            await settleLayout(of: window)
            let view = try #require(window.contentView)
            #expect(view.bounds.width == max(size.width, minimum.width))
            #expect(view.bounds.height == max(size.height, minimum.height))
        }
    }

    @Test func closingDialogsAlwaysUsesTheCancelBranch() {
        for titles in [["保存并关闭", "取消", "不保存"], ["保存", "放弃", "取消"], ["重启并继续", "稍后"]] {
            let alert = HelloXAlert()
            titles.forEach { alert.addButton(withTitle: $0) }
            let index = titles.firstIndex(where: { $0 == "取消" || $0 == "稍后" })!
            #expect(alert.cancelResponse == HelloXAlert.response(for: index))
            #expect(alert.cancelResponse != .alertFirstButtonReturn)
        }
        #expect(HelloXAlert.response(for: 1) == .alertSecondButtonReturn)
        #expect(HelloXAlert.response(for: 2) == .alertThirdButtonReturn)
    }

    // NSApplication.runModal owns a process-wide event loop. Suite serialization
    // does not isolate it from other AppKit suites, so run this integration check
    // explicitly: HELLOX_MODAL_INTEGRATION_TESTS=1 swift test --filter
    // DialogTests.escapeStopsTheModalSessionWithoutConfirming
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HELLOX_MODAL_INTEGRATION_TESTS"] == "1",
                   "Run separately from other AppKit tests with HELLOX_MODAL_INTEGRATION_TESTS=1"))
    func escapeStopsTheModalSessionWithoutConfirming() {
        let alert = HelloXAlert()
        alert.messageText = "关闭前保存截图？"
        alert.informativeText = "未保存的标注将会丢失。"
        ["保存并关闭", "取消", "不保存"].forEach { alert.addButton(withTitle: $0) }
        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow else {
                    Issue.record("Modal window did not appear")
                    NSApp.abortModal()
                    return
                }
                #expect(window.title == "关闭前保存截图？")
                #expect(window.isOpaque == false)
                #expect(window.frame.width == 520)
                window.cancelOperation(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        #expect(alert.runModal() == .alertSecondButtonReturn)
        #expect(NSApp.modalWindow == nil)
    }

    @Test func renderDialogSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let cases: [(String, String, String, [String])] = [
                ("save", "关闭前保存截图？", "未保存的标注将会丢失。", ["保存并关闭", "取消", "不保存"]),
                ("permission", "划词翻译需要授权", "HelloX 需要以下权限才能继续：\n\n辅助功能：读取当前选中文字。\n\n确认后，将打开系统授权页面。请开启开关并完成密码或 Touch ID 验证。", ["前往开启", "使用剪贴板保留排版", "取消"]),
                ("error", "贴图操作失败", "无法写入系统剪贴板，请重试。", ["好"])
            ]
            for (name, title, message, buttons) in cases {
                let content = HXAlertContent(title: title, message: message, buttons: buttons,
                                             cancelResponse: HelloXAlert.response(for: buttons.firstIndex(of: "取消") ?? 0), onResponse: { _ in })
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.setContentSize(host.fittingSize)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("dialog-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                #expect(host.bounds.width == 520)
                #expect(host.bounds.height > 125)
            }
        }
    }

    @Test func renderImportAndResultWindows() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        let model = AppModel(translationProfileState: .init(
            profiles: [], defaultProfileID: nil, apiKeys: [:], isOfflineTranslationEnabled: false
        ))
        for scheme in ["light", "dark"] {
            app.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
            let controllers: [(String, NSWindowController, NSSize)] = [
                ("watermark", WatermarkImportWindowController(model: model), NSSize(width: 520, height: 292)),
                ("qr-result", QRCodeResultWindowController(values: ["https://example.com"]), NSSize(width: 460, height: 200))
            ]
            for (name, controller, minimumSize) in controllers {
                let window = try #require(controller.window)
                defer { window.close() }
                #expect(window.titleVisibility == .hidden)
                #expect(window.titlebarSeparatorStyle == .none)
                #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
                let normalSize = window.contentRect(forFrameRect: window.frame).size
                var sizes: [(String, NSSize)] = [("", normalSize)]
                if minimumSize != normalSize {
                    sizes.append(("-minimum", minimumSize))
                }
                sizes.append(("-large", NSSize(width: normalSize.width + 160, height: normalSize.height + 180)))
                for (suffix, size) in sizes {
                    window.setContentSize(size)
                    let frame = window.frame
                    await settleLayout(of: window)
                    let view = try #require(window.contentView)
                    view.layoutSubtreeIfNeeded()
                    #expect(window.frame == frame)
                    #expect(view.bounds.size == size)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("tool-\(name)-\(scheme)\(suffix).png"))
                }
            }
        }
    }

    @Test func renderTranslationAndOCRInitialWindows() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }

        var profile = TranslationProfile.preset(.zhipu)
        profile.name = "示例翻译服务"
        profile.isEnabled = true
        let appModel = AppModel(translationProfileState: .init(
            profiles: [profile], defaultProfileID: profile.id,
            apiKeys: [:], isOfflineTranslationEnabled: false
        ))
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let result = OCRResult(
            text: "会议纪要\n项目界面已更新，请确认文字内容与阅读顺序。\n\n下一步\n审核翻译结果，整理相关资料。",
            language: "zh-Hans", averageConfidence: 1, blocks: []
        )

        for scheme in ["light", "dark"] {
            app.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
            // A manual translation window never starts a request on creation;
            // supplying OCR payload bypasses recognition entirely.
            let translation = TranslationWindowController(context: .manual, appModel: appModel)
            let ocr = OCRResultWindowController(image: image, payload: .init(image: image, result: result), appModel: appModel)
            let controllers: [(String, NSWindowController)] = [("translation", translation), ("ocr", ocr)]
            for (name, controller) in controllers {
                let window = try #require(controller.window)
                defer { window.close() }
                let normalSize = window.contentRect(forFrameRect: window.frame).size
                let sizes = [("normal", normalSize),
                             ("large", NSSize(width: normalSize.width + 160, height: normalSize.height + 220))]
                for (sizeName, size) in sizes {
                    window.setContentSize(size)
                    let frame = window.frame
                    await settleLayout(of: window)
                    #expect(window.frame == frame)
                    let view = try #require(window.contentView)
                    #expect(abs(view.bounds.width - size.width) < 0.5)
                    #expect(abs(view.bounds.height - size.height) < 0.5)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("tool-\(name)-initial-\(scheme)-\(sizeName).png"))
                }
            }
            #expect(translation.model.sourceText.isEmpty)
            #expect(!translation.model.isLoadingTranslation)
            #expect(translation.model.offlineTranslationConfiguration == nil)
            #expect(translation.model.outputs.allSatisfy { $0.translatedText.isEmpty && $0.errorMessage.isEmpty })
            #expect(!ocr.model.isLoading)
            #expect(ocr.model.text == result.text)
        }
    }

    @Test func renderPopulatedQRCodeAtMinimumSize() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let host = HXDialogHostingController(rootView:
                HXDialogWindowContent(title: "二维码识别", subtitle: UtilityTool.qrCode.dialogSubtitle, onClose: {}) {
                    QRCodeToolView(results: ["https://example.com", String(repeating: "可换行的二维码文本。", count: 12)],
                                   selectedName: "二维码示例.png")
                }.environment(\.colorScheme, scheme)
            )
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            HelloXWindowStyle.applyDialog(to: window)
            window.contentViewController = host
            window.setContentSize(NSSize(width: 560, height: 320))
            defer { window.close() }
            let frame = window.frame
            await settleLayout(of: window)
            #expect(window.frame == frame)
            let view = try #require(window.contentView)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                "tool-qr-populated-\(scheme == .dark ? "dark" : "light")-minimum.png"
            ))
        }
    }

    private func settleLayout(of window: NSWindow) async {
        // Give SwiftUI's deferred updates an opportunity to commit between
        // AppKit layout passes, without opening a window or a modal event loop.
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

@MainActor
private struct DialogLayoutMarker: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class DialogLayoutState: ObservableObject {
    @Published var message = ""
}

@MainActor
private struct DialogLayoutFixture: View {
    @ObservedObject var state: DialogLayoutState
    let marker: NSView

    var body: some View {
        HXDialogWindowContent(title: "文本翻译", onClose: {}) {
            VStack(alignment: .leading, spacing: 12) {
                DialogLayoutMarker(view: marker).frame(height: 24)
                Text(state.message).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
