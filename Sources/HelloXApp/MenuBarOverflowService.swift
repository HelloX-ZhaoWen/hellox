import AppKit
import Carbon
import CoreGraphics
import Foundation

struct MenuBarItemDescriptor: Identifiable, Equatable, Sendable {
    let id: MenuBarItemIdentity
    let preferenceID: MenuBarItemIdentity
    let title: String
    let applicationName: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let processIdentifier: pid_t
    let launchDate: Date?
}

struct RunningApplicationSnapshot: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String
    let bundleURL: URL?
    var activationPolicy: NSApplication.ActivationPolicy = .regular
    var hasMenuBarItem = false
    var isTerminated = false
    var isHidden = false
    var isActive = false
    var launchDate: Date?

    var preferenceID: MenuBarItemIdentity {
        let identity: String
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            identity = "bundle:\(bundleIdentifier)"
        } else if let bundleURL {
            identity = "path:\(bundleURL.standardizedFileURL.path)"
        } else {
            identity = "pid:\(processIdentifier)"
        }
        return MenuBarItemIdentity(rawValue: "application:\(identity)")
    }
}

enum RunningApplicationCatalog {
    static func isUserApplication(_ application: RunningApplicationSnapshot) -> Bool {
        guard !application.isTerminated, application.processIdentifier > 0,
              application.bundleIdentifier != "com.hellox.app" else { return false }
        if application.activationPolicy == .regular { return true }
        // Menu-only apps (including nested login items such as LemonMonitor)
        // are accessory processes. Require an actual status item so that app
        // helpers and updaters do not appear just because they are .app bundles.
        guard application.activationPolicy == .accessory,
              application.hasMenuBarItem,
              let bundleURL = application.bundleURL,
              bundleURL.pathExtension.lowercased() == "app" else { return false }
        let path = bundleURL.standardizedFileURL.path
        return !["/System/", "/usr/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    static func menuBarProcessIdentifiers(from windows: [[String: Any]]) -> Set<pid_t> {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return Set(windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == statusLevel,
                  let pid = window[kCGWindowOwnerPID as String] as? Int, pid > 0 else { return nil }
            return pid_t(exactly: pid)
        })
    }

    static func items(from applications: [RunningApplicationSnapshot]) -> [MenuBarItemDescriptor] {
        var seenProcesses: Set<pid_t> = []
        return applications.filter {
            isUserApplication($0) && seenProcesses.insert($0.processIdentifier).inserted
        }.map { application in
            let name = application.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty
                ? application.bundleURL?.deletingPathExtension().lastPathComponent ?? application.bundleIdentifier ?? "应用"
                : name
            return MenuBarItemDescriptor(
                id: MenuBarItemIdentity(rawValue: "\(application.preferenceID.rawValue)|pid:\(application.processIdentifier)"),
                preferenceID: application.preferenceID,
                title: title,
                applicationName: title,
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                processIdentifier: application.processIdentifier,
                launchDate: application.launchDate
            )
        }.sorted(by: stableOrder)
    }

    static func ordered(_ items: [MenuBarItemDescriptor], preferences: DynamicIslandPreferences) -> [MenuBarItemDescriptor] {
        let ordering = Dictionary(preferences.menuBarItemOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.sorted { lhs, rhs in
            let leftPinned = preferences.pinnedItemIDs.contains(lhs.preferenceID)
            let rightPinned = preferences.pinnedItemIDs.contains(rhs.preferenceID)
            if leftPinned != rightPinned { return leftPinned }
            let leftIndex = ordering[lhs.preferenceID] ?? Int.max
            let rightIndex = ordering[rhs.preferenceID] ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return stableOrder(lhs, rhs)
        }
    }

    static func matches(_ application: RunningApplicationSnapshot, item: MenuBarItemDescriptor) -> Bool {
        isUserApplication(application)
            && application.processIdentifier == item.processIdentifier
            && application.preferenceID == item.preferenceID
            && application.launchDate == item.launchDate
    }

    private static func stableOrder(_ lhs: MenuBarItemDescriptor, _ rhs: MenuBarItemDescriptor) -> Bool {
        let nameOrder = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

/// The Menu Bar tab lists running applications. Its legacy service name is kept
/// for the existing island controller. Status-window metadata also identifies
/// menu-only apps without reading window contents or requesting accessibility.
@MainActor
final class MenuBarOverflowService: ObservableObject {
    @Published private(set) var items: [MenuBarItemDescriptor] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage = "正在运行的应用"

    private let applicationsProvider: @MainActor () -> [RunningApplicationSnapshot]
    private let activateApplication: @MainActor (RunningApplicationSnapshot) -> Bool
    private let workspaceNotificationCenter: NotificationCenter?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(
        applicationsProvider: @escaping @MainActor () -> [RunningApplicationSnapshot] = MenuBarOverflowService.runningApplications,
        activateApplication: @escaping @MainActor (RunningApplicationSnapshot) -> Bool = MenuBarOverflowService.activateRunningApplication,
        workspaceNotificationCenter: NotificationCenter? = NSWorkspace.shared.notificationCenter
    ) {
        self.applicationsProvider = applicationsProvider
        self.activateApplication = activateApplication
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    func start() {
        guard !started else { return }
        started = true
        observeWorkspace()
        refreshManually()
    }

    func stop() {
        started = false
        if let workspaceNotificationCenter {
            for observer in observers { workspaceNotificationCenter.removeObserver(observer) }
        }
        observers.removeAll()
        isScanning = false
    }

    func setPresentationActive(_ isActive: Bool) {
        if isActive { refreshManually() }
    }

    func refreshManually() {
        guard started else { return }
        isScanning = true
        publish(applicationsProvider())
        isScanning = false
    }

    func openApplication(for item: MenuBarItemDescriptor) async -> Bool {
        let applications = applicationsProvider()
        guard let application = applications.first(where: { RunningApplicationCatalog.matches($0, item: item) }) else {
            publish(applications)
            return false
        }
        let activated = activateApplication(application)
        if !activated { refreshManually() }
        return activated
    }

    private func publish(_ applications: [RunningApplicationSnapshot]) {
        let currentItems = RunningApplicationCatalog.items(from: applications)
        if items != currentItems { items = currentItems }
        statusMessage = currentItems.isEmpty ? "没有正在运行的应用" : "正在运行 \(currentItems.count) 个应用"
    }

    private func observeWorkspace() {
        guard let workspaceNotificationCenter else { return }
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didWakeNotification
        ] {
            observers.append(workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshManually() }
            })
        }
    }

    static func runningApplications() -> [RunningApplicationSnapshot] {
        // Include offscreen status items, which may be hidden by the notch or
        // live on another display. No window image or title is needed.
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let menuBarPIDs = RunningApplicationCatalog.menuBarProcessIdentifiers(from: windows)
        return NSWorkspace.shared.runningApplications.map { application in
            RunningApplicationSnapshot(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName ?? "",
                bundleURL: application.bundleURL,
                activationPolicy: application.activationPolicy,
                hasMenuBarItem: menuBarPIDs.contains(application.processIdentifier),
                isTerminated: application.isTerminated,
                isHidden: application.isHidden,
                isActive: application.isActive,
                launchDate: application.launchDate
            )
        }
    }

    static func activateRunningApplication(_ snapshot: RunningApplicationSnapshot) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: snapshot.processIdentifier),
              !application.isTerminated,
              application.bundleIdentifier == snapshot.bundleIdentifier,
              application.launchDate == snapshot.launchDate else { return false }
        if application.isHidden { _ = application.unhide() }
        // A PID-addressed reopen event restores the app's window like a Dock
        // click, without launching a replacement if the process just exited.
        let reopen = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: snapshot.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let noConsentPrompt = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
        _ = try? reopen.sendEvent(options: [.noReply, .canInteract, noConsentPrompt], timeout: 1)
        return application.activate(options: [.activateAllWindows])
    }
}
