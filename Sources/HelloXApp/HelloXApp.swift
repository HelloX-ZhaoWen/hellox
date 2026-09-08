import AppKit
import HelloXCore
import SwiftUI

@main
enum HelloXLauncher {
    @MainActor static func main() {
        // CoreText reads this on first font creation, before SwiftUI initializes
        // the application delegate and its system fonts.
        HXTypography.configureRendering()
        HelloXApp.main()
    }
}

struct HelloXApp: App {
    @NSApplicationDelegateAdaptor(HelloXApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model: AppModel
    private let hotKeyManager: GlobalHotKeyManager
    private let statusItemController: StatusItemController
    private let actionDispatcher: HelloXActionDispatcher
    private let dynamicIslandController: DynamicIslandWindowController

    init() {
        HelloXAppearance.applyGlobally()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let dispatcher = HelloXActionDispatcher(model: model)
        let manager = GlobalHotKeyManager { action, initialCaptures in
            dispatcher.perform(
                action,
                source: .globalHotKey,
                initialDisplayCaptures: initialCaptures
            )
        }
        hotKeyManager = manager
        actionDispatcher = dispatcher
        statusItemController = StatusItemController(model: model, dispatcher: dispatcher)
        dynamicIslandController = DynamicIslandWindowController(model: model, dispatcher: dispatcher)
        applicationDelegate.openDocumentsHandler = { [weak model] urls in
            model?.openDocuments(urls)
        }
        applicationDelegate.reopenHandler = { [weak model] in
            model?.showSettingsWindow()
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

        dynamicIslandController.start()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置") { model.showSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("HelloX 帮助", destination: URL(string: "https://github.com/HelloX-ZhaoWen/hellox")!)
            }
        }
    }
}

@MainActor
final class HelloXApplicationDelegate: NSObject, NSApplicationDelegate {
    var reopenHandler: (() -> Void)?
    var openDocumentsHandler: (([URL]) -> Void)? {
        didSet { deliverPendingDocumentsIfPossible() }
    }

    private var pendingDocumentURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockVisibilityController.shared.start(windows: NSApp.windows.filter {
            $0 is HelloXWindow && ($0.isVisible || $0.isMiniaturized)
        })
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // The always-visible island or a utility window must not prevent a
        // Dock click from opening the main HelloX window.
        reopenHandler?()
        return true
    }

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
    private let dispatcher: HelloXActionDispatcher
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()

    init(model: AppModel, dispatcher: HelloXActionDispatcher) {
        self.model = model
        self.dispatcher = dispatcher
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

        menu.addItem(item(title: "设置", action: #selector(openSettingsWindow)))
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
        dispatcher.perform(action, source: .statusMenu)
    }

    @objc private func clearError() {
        model.lastError = nil
    }

    @objc private func openSettingsWindow() {
        model.showSettingsWindow()
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
        let alert = HelloXAlert()
        alert.alertStyle = .informational
        alert.messageText = "请先安装 HelloX"
        alert.informativeText = "HelloX 必须安装到“应用程序”文件夹后才能使用。请打开安装镜像中的“安装 HelloX.pkg”完成安装。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let image = HelloXResourceBundle.bundle
            .url(forResource: "HelloXMenuBarIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "infinity", accessibilityDescription: "HelloX")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        // Status-bar icons must be template images so AppKit automatically
        // renders them light on a dark menu bar and dark on a light one.
        image.isTemplate = true
        return image
    }()
}
