import AppKit
import HelloXCore
import SwiftUI

@main
struct HelloXApp: App {
    @NSApplicationDelegateAdaptor(HelloXApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model: AppModel
    private let hotKeyManager: GlobalHotKeyManager
    private let statusItemController: StatusItemController

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let manager = GlobalHotKeyManager { action in
            Task { @MainActor in
                switch action {
                case .regionCapture: model.startCapture(.region)
                case .windowCapture: model.startCapture(.window)
                case .fullScreenCapture: model.startCapture(.fullScreen)
                case .scrollingCapture: model.startCapture(.scrolling)
                case .screenRecording: model.startScreenRecording()
                case .watermarkImage: model.importImageForWatermark()
                case .captureAndOCR: model.captureAndOCR()
                case .textTranslation: model.showTextTranslation()
                case .captureAndTranslate: model.captureAndTranslate()
                case .translateSelection: model.translateSelectedText()
                case .csvToExcel: model.showUtilityTool(.csvToExcel)
                case .base64: model.showUtilityTool(.base64)
                case .qrCode: model.showUtilityTool(.qrCode)
                case .password: model.showUtilityTool(.password)
                case .markdown: model.showUtilityTool(.markdown)
                }
            }
        }
        hotKeyManager = manager
        statusItemController = StatusItemController(model: model)
        applicationDelegate.openDocumentsHandler = { [weak model] urls in
            model?.openDocuments(urls)
        }
        model.shortcutApplyHandler = { manager.apply($0) }
        model.shortcutAvailabilityHandler = { action, binding in
            manager.availabilityError(for: action, binding: binding)
        }
        if let error = manager.initialRegistrationError {
            model.shortcutValidationMessage = error.localizedDescription
            model.lastError = error.localizedDescription
        }

        if InstallationGate.requiresInstallation {
            Task { @MainActor in InstallationGate.presentRequirementAndTerminate() }
            return
        }

        // 首次启动时请求屏幕录制和辅助功能权限
        if !UserDefaults.standard.bool(forKey: "HelloXDidRequestPermissions") {
            UserDefaults.standard.set(true, forKey: "HelloXDidRequestPermissions")
            Task { @MainActor in
                _ = model.permissions.requestScreenRecording()
                _ = model.permissions.requestAccessibility(prompt: true)
            }
        }

    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class HelloXApplicationDelegate: NSObject, NSApplicationDelegate {
    var openDocumentsHandler: (([URL]) -> Void)? {
        didSet { deliverPendingDocumentsIfPossible() }
    }

    private var pendingDocumentURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        routeOpenDocuments(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0).standardizedFileURL }
        routeOpenDocuments(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    private func routeOpenDocuments(_ urls: [URL]) {
        let standardizedURLs = urls.map(\.standardizedFileURL)
        if let openDocumentsHandler {
            openDocumentsHandler(standardizedURLs)
        } else {
            pendingDocumentURLs.append(contentsOf: standardizedURLs)
        }
    }

    private func deliverPendingDocumentsIfPossible() {
        guard let openDocumentsHandler, !pendingDocumentURLs.isEmpty else { return }
        let urls = pendingDocumentURLs
        pendingDocumentURLs.removeAll()
        openDocumentsHandler(urls)
    }
}

@MainActor
private final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image
        button.imagePosition = .imageOnly
        button.toolTip = "HelloX — 点击显示功能菜单"
        button.setAccessibilityLabel("HelloX")
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addActions(ShortcutAction.configurableCases, to: menu)
        menu.addItem(.separator())

        if let error = model.lastError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(item(title: "清除提示", action: #selector(clearError)))
            menu.addItem(.separator())
        }

        menu.addItem(item(title: "打开主页面", action: #selector(openMainWindow)))
        menu.addItem(.separator())
        menu.addItem(item(title: "退出 HelloX", action: #selector(terminateApplication)))
    }

    private func addActions(_ actions: [ShortcutAction], to menu: NSMenu) {
        for action in actions {
            let shortcut = model.shortcutBindings[action]?.displayName ?? "未设置"
            let item = item(
                title: "\(action.title)    \(shortcut)",
                action: #selector(performAction(_:))
            )
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = ShortcutAction(rawValue: rawValue) else { return }
        switch action {
        case .regionCapture: model.startCapture(.region)
        case .windowCapture: model.startCapture(.window)
        case .fullScreenCapture: model.startCapture(.fullScreen)
        case .scrollingCapture: model.startCapture(.scrolling)
        case .screenRecording: model.startScreenRecording()
        case .watermarkImage: model.importImageForWatermark()
        case .captureAndOCR: model.captureAndOCR()
        case .textTranslation: model.showTextTranslation()
        case .captureAndTranslate: model.captureAndTranslate()
        case .translateSelection: model.translateSelectedText()
        case .csvToExcel: model.showUtilityTool(.csvToExcel)
        case .base64: model.showUtilityTool(.base64)
        case .qrCode: model.showUtilityTool(.qrCode)
        case .password: model.showUtilityTool(.password)
        case .markdown: model.showUtilityTool(.markdown)
        }
    }

    @objc private func clearError() {
        model.lastError = nil
    }

    @objc private func openMainWindow() {
        model.showMainWindow()
    }

    @objc private func terminateApplication() {
        NSApp.terminate(nil)
    }
}

enum InstallationGate {
    static let installedApplicationURL = URL(fileURLWithPath: "/Applications/HelloX.app", isDirectory: true)

    static var requiresInstallation: Bool {
        requiresInstallation(bundleURL: Bundle.main.bundleURL)
    }

    static func requiresInstallation(bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return resolved != installedApplicationURL.resolvingSymlinksInPath().standardizedFileURL
    }

    @MainActor
    static func presentRequirementAndTerminate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "请先安装 HelloX"
        alert.informativeText = "HelloX 必须安装到“应用程序”文件夹后才能使用。请打开安装镜像中的“安装 HelloX.pkg”完成安装。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@MainActor
private enum MenuBarIcon {
    static let image: NSImage = {
        let source = NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "x.circle.fill", accessibilityDescription: "HelloX")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()
}
