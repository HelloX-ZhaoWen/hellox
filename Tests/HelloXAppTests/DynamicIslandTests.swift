import AppKit
import Combine
import Foundation
import Testing
@testable import HelloXApp

@Suite("Dynamic Island")
struct DynamicIslandTests {
    @MainActor
    @Test func dockReopenShowsMainWindowEvenWhenIslandOrToolsAreVisible() {
        let delegate = HelloXApplicationDelegate()
        var reopenCount = 0
        delegate.reopenHandler = { reopenCount += 1 }
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(reopenCount == 2)
    }

    @Test func includesRegularAppsAndMenuBarAccessoryAppsRegardlessOfVisibility() {
        var hidden = application(1, "Hidden")
        hidden.isHidden = true
        var frontmost = application(2, "Frontmost")
        frontmost.isActive = true
        var menuBarApp = application(3, "Menu Bar App")
        menuBarApp.activationPolicy = .accessory
        menuBarApp.hasMenuBarItem = true
        var helloX = application(4, "HelloX", bundleIdentifier: "com.hellox.app")
        helloX.activationPolicy = .accessory
        helloX.hasMenuBarItem = true
        // A regular app need not expose windows, a bundle, or a menu-bar item.
        let unbundled = RunningApplicationSnapshot(processIdentifier: 5, bundleIdentifier: nil,
            localizedName: "Regular Tool", bundleURL: nil)
        let items = RunningApplicationCatalog.items(from: [hidden, frontmost, menuBarApp, helloX, unbundled])
        #expect(Set(items.map(\.processIdentifier)) == [1, 2, 3, 5])
    }

    @Test func excludesHelloXWithOrWithoutDockIcon() {
        var helloX = application(1, "HelloX", bundleIdentifier: "com.hellox.app")
        helloX.hasMenuBarItem = true
        #expect(RunningApplicationCatalog.items(from: [helloX]).isEmpty)
        helloX.activationPolicy = .accessory
        #expect(RunningApplicationCatalog.items(from: [helloX]).isEmpty)
    }

    @Test func excludesBackgroundProcessesAndUnbundledAccessoryAgents() {
        var background = application(1, "System Agent")
        background.activationPolicy = .prohibited
        var terminated = application(2, "Closed")
        terminated.isTerminated = true
        let accessory = RunningApplicationSnapshot(processIdentifier: 3, bundleIdentifier: "com.example.agent",
            localizedName: "Agent", bundleURL: nil, activationPolicy: .accessory)
        let plugin = RunningApplicationSnapshot(processIdentifier: 4, bundleIdentifier: "com.example.plugin",
            localizedName: "Plugin", bundleURL: URL(fileURLWithPath: "/Library/Plugin.bundle"), activationPolicy: .accessory)
        #expect(RunningApplicationCatalog.items(from: [background, terminated, accessory, plugin]).isEmpty)
    }

    @Test func excludesSystemServicesEvenWhenPackagedAsApplications() {
        let services = ["ControlCenter", "NotificationCenter", "Spotlight", "TextInputMenuAgent", "Wallpaper"]
            .enumerated().map { index, name in
                RunningApplicationSnapshot(processIdentifier: pid_t(index + 10),
                    bundleIdentifier: "com.apple." + name, localizedName: name,
                    bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/\(name).app"),
                    activationPolicy: .accessory, hasMenuBarItem: true)
            }
        let finder = RunningApplicationSnapshot(processIdentifier: 20, bundleIdentifier: "com.apple.finder",
            localizedName: "访达", bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        #expect(RunningApplicationCatalog.items(from: services + [finder]).map(\.processIdentifier) == [20])
    }

    @Test func includesNestedMenuBarAppsButExcludesHelpersWithoutStatusItems() {
        let monitor = RunningApplicationSnapshot(processIdentifier: 30,
            bundleIdentifier: "com.example.monitor", localizedName: "Monitor",
            bundleURL: URL(fileURLWithPath: "/Applications/Cleaner.app/Contents/Library/LoginItems/Monitor.app"),
            activationPolicy: .accessory, hasMenuBarItem: true)
        let officeService = RunningApplicationSnapshot(processIdentifier: 31,
            bundleIdentifier: "com.example.office.service", localizedName: "Office Service",
            bundleURL: URL(fileURLWithPath: "/Applications/Office.app/Contents/SharedSupport/Service.app"),
            activationPolicy: .accessory, hasMenuBarItem: true)
        var helper = monitor
        helper.hasMenuBarItem = false
        #expect(Set(RunningApplicationCatalog.items(from: [monitor, officeService, helper]).map(\.processIdentifier)) == [30, 31])
        let item = RunningApplicationCatalog.items(from: [monitor])[0]
        #expect(RunningApplicationCatalog.matches(monitor, item: item))
    }

    @Test func statusWindowMetadataIncludesOffscreenItemsAndDeduplicatesDisplays() {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let windows: [[String: Any]] = [
            [kCGWindowOwnerPID as String: 30, kCGWindowLayer as String: statusLevel,
             kCGWindowIsOnscreen as String: false],
            [kCGWindowOwnerPID as String: 30, kCGWindowLayer as String: statusLevel],
            [kCGWindowOwnerPID as String: 31, kCGWindowLayer as String: statusLevel],
            [kCGWindowOwnerPID as String: 32, kCGWindowLayer as String: 0],
            [kCGWindowOwnerPID as String: 0, kCGWindowLayer as String: statusLevel],
            [kCGWindowLayer as String: statusLevel]
        ]
        #expect(RunningApplicationCatalog.menuBarProcessIdentifiers(from: windows) == [30, 31])
    }

    @Test func retainsDifferentRunningInstancesAndDeduplicatesOnlyTheSameProcess() {
        let first = application(1, "Editor", bundleIdentifier: "com.example.editor")
        let second = application(2, "Editor", bundleIdentifier: "com.example.editor")
        let items = RunningApplicationCatalog.items(from: [first, first, second])
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(Set(items.map(\.preferenceID)).count == 1)
        let relaunched = application(3, "Editor", bundleIdentifier: "com.example.editor")
        #expect(relaunched.preferenceID == first.preferenceID)
    }

    @MainActor
    @Test func migratesOldMenuBarPinsAndOrderWithoutHidingExcludedApps() throws {
        let suiteName = "DynamicIslandMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var legacy = DynamicIslandPreferences()
        legacy.selectedSection = .helloX
        legacy.pinnedItemIDs = [MenuBarItemIdentity(rawValue: "com.example.editor|first|0"),
                                MenuBarItemIdentity(rawValue: "com.example.editor|second|0")]
        legacy.excludedItemIDs = [MenuBarItemIdentity(rawValue: "com.example.editor|first|0")]
        legacy.menuBarItemOrder = [MenuBarItemIdentity(rawValue: "com.example.editor|second|0"),
                                   MenuBarItemIdentity(rawValue: "com.example.editor|first|0")]
        legacy.helloXActionOrder = [.markdown, .markdown, .regionCapture]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "preferences")
        let store = DynamicIslandPreferencesStore(defaults: defaults, storageKey: "preferences")
        let expectedID = application(1, "Editor", bundleIdentifier: "com.example.editor").preferenceID
        #expect(store.value.pinnedItemIDs == [expectedID])
        #expect(store.value.menuBarItemOrder == [expectedID])
        #expect(store.value.excludedItemIDs.isEmpty)
        #expect(store.value.selectedSection == .helloX)
        #expect(store.value.helloXActionOrder.first == .markdown)
        #expect(store.value.helloXActionOrder.count == ShortcutAction.configurableCases.count)
        store.setPinned(expectedID, pinned: false)
        let restored = DynamicIslandPreferencesStore(defaults: defaults, storageKey: "preferences")
        #expect(restored.value.pinnedItemIDs.isEmpty)
        #expect(restored.value.excludedItemIDs.isEmpty)
    }

    @Test func pinsOnlyChangeOrderAndNeverFilterRunningApps() {
        let apps = [application(1, "Alpha"), application(2, "Beta"), application(3, "Charlie")]
        var preferences = DynamicIslandPreferences()
        preferences.pinnedItemIDs = [apps[2].preferenceID]
        preferences.menuBarItemOrder = [apps[1].preferenceID, apps[0].preferenceID, apps[2].preferenceID]
        preferences.excludedItemIDs = [apps[1].preferenceID]
        let items = RunningApplicationCatalog.ordered(RunningApplicationCatalog.items(from: apps), preferences: preferences)
        #expect(items.map(\.processIdentifier) == [3, 2, 1])
    }

    @MainActor
    @Test func runningAppNotificationsRefreshWhileIslandIsOpenAndRemoveExitedAppsImmediately() async {
        let source = RunningAppTestSource([application(1, "First")])
        let center = NotificationCenter()
        let service = MenuBarOverflowService(applicationsProvider: { source.applications },
            activateApplication: { _ in false }, workspaceNotificationCenter: center)
        service.start()
        defer { service.stop() }
        service.setPresentationActive(true)
        source.applications.append(application(2, "Second"))
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await waitUntil { service.items.count == 2 }
        #expect(service.items.count == 2)
        source.applications = []
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await waitUntil { service.items.isEmpty }
        #expect(service.items.isEmpty)
        #expect(service.statusMessage == "没有正在运行的应用")
    }

    @MainActor
    @Test func stoppingUnsubscribesAndRestartingUsesCurrentRunningApps() async {
        let source = RunningAppTestSource([application(1, "First")])
        let center = NotificationCenter()
        let service = MenuBarOverflowService(applicationsProvider: { source.applications },
            activateApplication: { _ in false }, workspaceNotificationCenter: center)
        service.start()
        service.stop()
        source.applications = [application(2, "Second")]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        for _ in 0..<5 { await Task.yield() }
        #expect(service.items.map(\.processIdentifier) == [1])
        service.start()
        defer { service.stop() }
        #expect(service.items.map(\.processIdentifier) == [2])
    }

    @MainActor
    @Test func identicalSnapshotsDoNotRepublishItems() {
        let applications = [application(1, "Stable")]
        let service = MenuBarOverflowService(applicationsProvider: { applications },
            activateApplication: { _ in false }, workspaceNotificationCenter: nil)
        var publicationCount = 0
        let observation = service.$items.dropFirst().sink { _ in publicationCount += 1 }
        service.start()
        service.refreshManually()
        service.setPresentationActive(true)
        #expect(publicationCount == 1)
        service.stop()
        withExtendedLifetime(observation) {}
    }

    @MainActor
    @Test func clickActivatesTheSelectedProcessIncludingHiddenAndFrontmostApps() async throws {
        var hidden = application(1, "Editor", bundleIdentifier: "com.example.editor")
        hidden.isHidden = true
        var active = application(2, "Editor", bundleIdentifier: "com.example.editor")
        active.isActive = true
        let source = RunningAppTestSource([hidden, active])
        var activatedPIDs: [pid_t] = []
        let service = MenuBarOverflowService(applicationsProvider: { source.applications },
            activateApplication: { activatedPIDs.append($0.processIdentifier); return true }, workspaceNotificationCenter: nil)
        service.start()
        defer { service.stop() }
        let hiddenItem = try #require(service.items.first(where: { $0.processIdentifier == 1 }))
        let activeItem = try #require(service.items.first(where: { $0.processIdentifier == 2 }))
        #expect(await service.openApplication(for: activeItem))
        #expect(await service.openApplication(for: hiddenItem))
        #expect(activatedPIDs == [2, 1])
    }

    @MainActor
    @Test func staleClickDoesNotActivateReplacementOrRelaunchAnExitedApp() async throws {
        var original = application(1, "Editor", bundleIdentifier: "com.example.editor")
        original.launchDate = Date(timeIntervalSince1970: 100)
        let source = RunningAppTestSource([original])
        var activationCount = 0
        let service = MenuBarOverflowService(applicationsProvider: { source.applications },
            activateApplication: { _ in activationCount += 1; return true }, workspaceNotificationCenter: nil)
        service.start()
        defer { service.stop() }
        let oldItem = try #require(service.items.first)
        var replacement = original
        replacement.launchDate = Date(timeIntervalSince1970: 200)
        source.applications = [replacement]
        #expect(!(await service.openApplication(for: oldItem)))
        #expect(activationCount == 0)
        source.applications = []
        #expect(!(await service.openApplication(for: oldItem)))
        #expect(activationCount == 0)
        #expect(service.items.isEmpty)
    }

    @MainActor
    @Test func activationFailureIsReturnedWithoutAlternateAppRouting() async throws {
        let applications = [application(1, "系统设置", bundleIdentifier: "com.apple.systempreferences")]
        var activationCount = 0
        let service = MenuBarOverflowService(applicationsProvider: { applications },
            activateApplication: { _ in activationCount += 1; return false }, workspaceNotificationCenter: nil)
        service.start()
        defer { service.stop() }
        let item = try #require(service.items.first)
        #expect(!(await service.openApplication(for: item)))
        #expect(activationCount == 1)
    }

    @MainActor
    @Test func corruptPreferencesFallBackToDefaults() throws {
        let suiteName = "DynamicIslandCorruptTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "preferences")
        let restored = DynamicIslandPreferencesStore(defaults: defaults, storageKey: "preferences").value
        #expect(restored == DynamicIslandPreferences())
    }

    @Test func exposesEveryHelloXActionToTheIsland() {
        #expect(ShortcutAction.configurableCases.count == 16)
        #expect(Set(ShortcutAction.configurableCases) == Set(ShortcutAction.allCases))
        #expect(ShortcutAction.configurableCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func everyCaptureEntryPointRequestsIslandSuppression() {
        #expect(HelloXActionSource.globalHotKey.hidesDynamicIslandDuringCapture)
        #expect(HelloXActionSource.statusMenu.hidesDynamicIslandDuringCapture)
        #expect(HelloXActionSource.dynamicIsland.hidesDynamicIslandDuringCapture)
    }

    private func application(_ pid: pid_t, _ name: String, bundleIdentifier: String? = nil) -> RunningApplicationSnapshot {
        RunningApplicationSnapshot(processIdentifier: pid, bundleIdentifier: bundleIdentifier ?? "com.example.app\(pid)",
            localizedName: name, bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class RunningAppTestSource {
    var applications: [RunningApplicationSnapshot]
    init(_ applications: [RunningApplicationSnapshot]) { self.applications = applications }
}
