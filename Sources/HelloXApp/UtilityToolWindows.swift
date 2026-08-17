import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class UtilityToolWindowController: NSWindowController, NSWindowDelegate {
    let tool: UtilityTool
    private let markdownOpenRouter: MarkdownOpenRouter

    init(tool: UtilityTool) {
        self.tool = tool
        let markdownOpenRouter = MarkdownOpenRouter()
        self.markdownOpenRouter = markdownOpenRouter
        let minimumSize = tool == .markdown
            ? NSSize(width: 900, height: 640)
            : NSSize(width: 700, height: 520)
        let initialSize = tool == .markdown
            ? NSSize(width: 1180, height: 780)
            : minimumSize
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
        window.tabbingMode = .disallowed
        window.center()
        window.contentViewController = NSHostingController(rootView: UtilityToolRootView(
            tool: tool,
            markdownOpenRouter: markdownOpenRouter
        ))
        HelloXWindowStyle.apply(to: window, movableByBackground: false)
        window.setContentSize(initialSize)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        if let window,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.midY - window.frame.height / 2
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func openMarkdownDocuments(at urls: [URL]) {
        guard tool == .markdown else { return }
        markdownOpenRouter.open(urls)
        present()
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
        let window = HelloXWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "二维码识别结果"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 320)
        window.contentViewController = NSHostingController(rootView: QRCodeResultWindowView(values: values))
        HelloXWindowStyle.apply(to: window, movableByBackground: false)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(values: [String]) {
        window?.contentViewController = NSHostingController(rootView: QRCodeResultWindowView(values: values))
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
        ZStack {
            HelloXGlowBackground().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    HelloXRowIcon(icon: .qrCode, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("二维码识别结果")
                            .font(.system(size: 18, weight: .bold))
                        Text("共识别到 \(values.count) 条内容")
                            .font(.system(size: 11))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    }
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
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(HelloXTheme.accent)
                                        .frame(width: 24, height: 24)
                                        .background(HelloXTheme.accent.opacity(0.10), in: Circle())
                                    Text(value)
                                        .font(.system(size: 13, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
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
            }
            .padding(24)
        }
        .tint(HelloXTheme.accent)
    }
}

private struct UtilityToolRootView: View {
    let tool: UtilityTool
    @ObservedObject var markdownOpenRouter: MarkdownOpenRouter

    @ViewBuilder
    var body: some View {
        switch tool {
        case .csvToExcel: CSVExcelToolView()
        case .base64: Base64ToolView()
        case .qrCode: QRCodeToolView()
        case .password: PasswordToolView()
        case .markdown: MarkdownToolView(openRouter: markdownOpenRouter)
        }
    }
}

private struct UtilityToolShell<Content: View>: View {
    let tool: UtilityTool
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            HelloXGlowBackground().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    HelloXRowIcon(icon: tool.icon, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    }
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 26)
        }
        .frame(minWidth: 680, minHeight: 500)
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
        UtilityToolShell(tool: .csvToExcel, subtitle: "将 CSV 表格转换为可在 Excel 中打开的 .xlsx 文件") {
            VStack(spacing: 16) {
                Button(action: chooseCSV) {
                    VStack(spacing: 13) {
                        HelloXIcon(icon: .save, size: 28)
                            .foregroundStyle(HelloXTheme.accent)
                        Text(isDropTargeted ? "松开即可选择 CSV" : "点击或拖拽 CSV 文件到这里")
                            .font(.system(size: 15, weight: .semibold))
                        Text(sourceURL?.lastPathComponent ?? "支持 UTF-8、UTF-16 编码及带引号的 CSV")
                            .font(.system(size: 11))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 230)
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
                            .font(.system(size: 12, weight: .medium))
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

private enum Base64Direction: String, CaseIterable, Identifiable {
    case encode = "编码"
    case decode = "解码"
    var id: String { rawValue }
}

private struct Base64ToolView: View {
    @State private var direction: Base64Direction = .encode
    @State private var input = ""
    @State private var output = ""
    @State private var errorMessage = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UtilityToolShell(tool: .base64, subtitle: "在普通文本与 Base64 文本之间转换") {
            VStack(spacing: 14) {
                Picker("转换方式", selection: $direction) {
                    ForEach(Base64Direction.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .frame(width: 260)

                HStack(spacing: 14) {
                    editor(title: direction == .encode ? "原始文本" : "Base64", text: $input)
                    HelloXIcon(icon: .arrowRight, size: 18).foregroundStyle(HelloXTheme.accent)
                    editor(title: "转换结果", text: $output)
                }

                HStack {
                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(.system(size: 11)).foregroundStyle(HelloXTheme.error)
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
            Text(title).font(.system(size: 12, weight: .semibold))
            TextEditor(text: text)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
                .seamlessTextEditorChrome()
                .scrollContentBackground(.hidden)
                .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: HelloXTheme.controlRadius).stroke(HelloXTheme.border(for: colorScheme)))
        }
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

private struct QRCodeToolView: View {
    @State private var results: [String] = []
    @State private var selectedName = ""
    @State private var message = ""
    @State private var failed = false
    @State private var isDropTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UtilityToolShell(tool: .qrCode, subtitle: "从图片中识别二维码内容") {
            VStack(spacing: 16) {
                Button(action: chooseImage) {
                    VStack(spacing: 12) {
                        HelloXIcon(icon: .textRecognition, size: 32).foregroundStyle(HelloXTheme.accent)
                        Text(isDropTargeted ? "松开即可识别" : "点击或拖拽二维码图片")
                            .font(.system(size: 15, weight: .semibold))
                        Text(selectedName.isEmpty ? "支持 PNG、JPG、HEIC、TIFF" : selectedName)
                            .font(.system(size: 11))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    }
                    .frame(maxWidth: .infinity, minHeight: results.isEmpty ? 220 : 150)
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
                    HelloXCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("识别结果").font(.system(size: 13, weight: .bold))
                            ForEach(Array(results.enumerated()), id: \.offset) { _, value in
                                HStack {
                                    Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                                    Spacer()
                                    HelloXUtilityTextButton(title: "复制", help: "复制") {
                                        _ = UtilityClipboard.copy(value)
                                    }
                                }
                            }
                        }
                    }
                }
                if !message.isEmpty {
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
        UtilityToolShell(tool: .password, subtitle: "使用系统安全随机源生成高强度密码") {
            VStack(spacing: 18) {
                HelloXCard {
                    VStack(spacing: 16) {
                        TextField("随机密码", text: $password)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(14)
                            .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius))
                            .overlay(RoundedRectangle(cornerRadius: HelloXTheme.controlRadius).stroke(HelloXTheme.border(for: colorScheme)))
                        HStack {
                            Text("长度：\(length)").font(.system(size: 13, weight: .semibold))
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
                        Text(errorMessage).font(.system(size: 11)).foregroundStyle(HelloXTheme.error)
                    }
                    Spacer()
                    HelloXUtilityTextButton(title: "重新生成", help: "重新生成", role: .accent, action: generate)
                    HelloXUtilityTextButton(title: "复制密码", help: "复制密码") {
                        _ = UtilityClipboard.copy(password)
                    }
                        .disabled(password.isEmpty)
                }
                Spacer()
            }
            .onAppear(perform: generate)
            .onChange(of: length) { _ in generate() }
            .onChange(of: lowercase) { _ in generate() }
            .onChange(of: uppercase) { _ in generate() }
            .onChange(of: numbers) { _ in generate() }
            .onChange(of: symbols) { _ in generate() }
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

@MainActor
final class MarkdownPreviewModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private var renderKey = ""

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = true
        webView.magnification = 1
    }

    func render(markdown: String, title: String, baseURL: URL?) {
        let html = MarkdownHTMLConverter.convert(markdown, title: title)
        let key = "\(baseURL?.path ?? "")\u{0}\(html)"
        guard key != renderKey else { return }
        renderKey = key
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func scroll(to headingID: String) {
        webView.evaluateJavaScript("document.getElementById('\(headingID)')?.scrollIntoView({behavior:'smooth',block:'start'});")
    }

    func pdfData() async throws -> Data {
        try await waitUntilDocumentIsReady()
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
            NSWorkspace.shared.open(url)
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
    @Published var markdown: String
    @Published private(set) var savedMarkdown: String
    @Published var mode: MarkdownWorkspaceMode = .defaultMode
    @Published var isTableOfContentsExpanded = true
    let previewModel = MarkdownPreviewModel()

    init(url: URL?, markdown: String) {
        self.url = url?.standardizedFileURL
        self.markdown = markdown
        self.savedMarkdown = markdown
    }

    var displayName: String { url?.deletingPathExtension().lastPathComponent ?? "未命名" }
    var isModified: Bool { markdown != savedMarkdown }
    var headings: [MarkdownHeading] { MarkdownHeadingParser.headings(in: markdown) }
    var exportBaseName: String { url?.deletingPathExtension().lastPathComponent ?? "Markdown" }

    func markSaved(at url: URL) {
        self.url = url.standardizedFileURL
        savedMarkdown = markdown
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
            if scrollView.verticalScroller is HelloXOverlayScroller == false {
                scrollView.verticalScroller = HelloXOverlayScroller(frame: .zero)
            }
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
        UtilityToolShell(tool: .markdown, subtitle: "阅读、编辑并导出 Markdown 文档") {
            VStack(spacing: 12) {
                commandBar
                if !workspace.documents.isEmpty { tabBar }
                Group {
                    if let document = workspace.activeDocument {
                        MarkdownDocumentWorkspaceView(
                            document: document,
                            message: message,
                            failed: failed
                        )
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { consume(openRouter.request) }
        .onChange(of: openRouter.request) { consume($0) }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            commandButton("打开", help: "打开 Markdown", action: openMarkdown)
                .keyboardShortcut("o", modifiers: .command)
            if let document = workspace.activeDocument {
                MarkdownModePicker(document: document)
                commandButton("保存", help: "保存 Markdown", isAccent: true) {
                    _ = save(document, saveAs: false)
                }
                .keyboardShortcut("s", modifiers: .command)
                commandButton("另存为", help: "Markdown 另存为") {
                    _ = save(document, saveAs: true)
                }
                exportMenu(for: document)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius))
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.documents) { document in
                    MarkdownDocumentTabControl(
                        document: document,
                        isActive: workspace.activeDocumentID == document.id,
                        onActivate: { workspace.activate(document) },
                        onClose: { requestClose(document) }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 32)
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

    private func commandLabel(_ title: String) -> some View {
        HelloXUtilityButtonLabel(title: title, role: .neutral)
    }

    private func exportMenu(for document: MarkdownDocumentTab) -> some View {
        ZStack {
            commandLabel("导出")
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Menu {
                Button("导出 PDF") { exportPDF(document) }
                Button("导出 HTML") { exportHTML(document) }
            } label: {
                Color.clear
                    .frame(width: HelloXUtilityButtonMetrics.width, height: HelloXUtilityButtonMetrics.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: HelloXUtilityButtonMetrics.width, height: HelloXUtilityButtonMetrics.height)
            .accessibilityLabel("导出 Markdown")
        }
        .fixedSize()
        .help("导出 Markdown")
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
        let alert = NSAlert()
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
                HelloXIcon(icon: .close, size: 11)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭 \(document.displayName)")
            .accessibilityLabel("关闭 \(document.displayName)")
        }
        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
        .foregroundStyle(isActive ? HelloXTheme.primaryText(for: colorScheme) : HelloXTheme.secondaryText(for: colorScheme))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(
            isActive ? HelloXTheme.raisedSurface(for: colorScheme) : HelloXTheme.controlBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius, style: .continuous)
        )
    }
}

private struct MarkdownModePicker: View {
    @ObservedObject var document: MarkdownDocumentTab

    var body: some View {
        Picker("模式", selection: $document.mode) {
            ForEach(MarkdownWorkspaceMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .frame(width: 152, height: HelloXUtilityButtonMetrics.height)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar
        }
    }

    private var previewWorkspace: some View {
        HStack(spacing: 0) {
            if document.isTableOfContentsExpanded {
                tableOfContents
                    .frame(width: 230)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                collapsedTableOfContents
                    .frame(width: 44)
                    .transition(.opacity)
            }
            MarkdownWebPreview(
                model: document.previewModel,
                markdown: document.markdown,
                title: document.exportBaseName,
                baseURL: document.url?.deletingLastPathComponent()
            )
            .background(HelloXTheme.raisedSurface(for: colorScheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: document.isTableOfContentsExpanded)
    }

    private var tableOfContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HelloXIcon(icon: .text, size: 16)
                Text("目录").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(document.headings.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                Button {
                    document.isTableOfContentsExpanded = false
                } label: {
                    HelloXIcon(icon: .chevronRight, size: 14)
                        .rotationEffect(.degrees(180))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                .help("收起目录")
                .accessibilityLabel("收起目录")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if document.headings.isEmpty {
                Spacer()
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(document.headings) { heading in
                            Button {
                                document.previewModel.scroll(to: heading.id)
                            } label: {
                                Text(heading.title)
                                    .font(.system(size: heading.level == 1 ? 12 : 11, weight: heading.level <= 2 ? .semibold : .regular))
                                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
                .visibleScrollChrome()
            }
        }
        .background(HelloXTheme.controlBackground(for: colorScheme))
    }

    private var collapsedTableOfContents: some View {
        VStack(spacing: 0) {
            Button {
                document.isTableOfContentsExpanded = true
            } label: {
                HelloXIcon(icon: .chevronRight, size: 15)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            .help("展开目录")
            .accessibilityLabel("展开目录")
            .padding(.top, 9)
            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(HelloXTheme.controlBackground(for: colorScheme))
    }

    private var editorWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Markdown 源码")
                    .font(.system(size: 12, weight: .semibold))
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
        .font(.system(size: 11, weight: .medium))
    }
}

private extension UtilityTool {
    var icon: HelloXIconKey {
        switch self {
        case .csvToExcel: .save
        case .base64: .copy
        case .qrCode: .qrCode
        case .password: .privacy
        case .markdown: .text
        }
    }
}
