import Foundation
import SwiftUI

enum DynamicIslandSection: String, Codable, CaseIterable, Sendable {
    case menuBar
    case helloX
}

struct MenuBarItemIdentity: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var runningApplicationPreferenceID: MenuBarItemIdentity? {
        if rawValue.hasPrefix("application:") {
            return MenuBarItemIdentity(rawValue: rawValue.components(separatedBy: "|pid:")[0])
        }
        // Old menu-bar identities stored bundle|AX item|ordinal. Multiple
        // status items from one app now share its persistent app preference.
        guard rawValue.contains("|"),
              let bundleIdentifier = rawValue.split(separator: "|", omittingEmptySubsequences: false).first,
              !bundleIdentifier.isEmpty,
              !bundleIdentifier.hasPrefix("pid-owner-") else { return nil }
        return MenuBarItemIdentity(rawValue: "application:bundle:\(bundleIdentifier)")
    }
}

struct DynamicIslandPreferences: Codable, Equatable, Sendable {
    var isEnabled = true
    var showsInFullScreen = true
    var selectedSection: DynamicIslandSection = .menuBar
    var pinnedItemIDs: Set<MenuBarItemIdentity> = []
    var excludedItemIDs: Set<MenuBarItemIdentity> = []
    var menuBarItemOrder: [MenuBarItemIdentity] = []
    var helloXActionOrder: [ShortcutAction] = ShortcutAction.configurableCases

    mutating func normalize() {
        pinnedItemIDs = Set(pinnedItemIDs.compactMap(\.runningApplicationPreferenceID))
        menuBarItemOrder = Self.unique(menuBarItemOrder.compactMap(\.runningApplicationPreferenceID))
        // The running-app list always shows every eligible app, including
        // entries excluded by the previous overflow-only menu-bar feature.
        excludedItemIDs.removeAll()

        let validActions = Set(ShortcutAction.configurableCases)
        var normalizedActions = Self.unique(helloXActionOrder).filter(validActions.contains)
        normalizedActions.append(contentsOf: ShortcutAction.configurableCases.filter { !normalizedActions.contains($0) })
        helloXActionOrder = normalizedActions
    }

    private static func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class DynamicIslandPreferencesStore: ObservableObject {
    @Published var value: DynamicIslandPreferences {
        didSet {
            var normalized = value
            normalized.normalize()
            if normalized != value {
                value = normalized
                return
            }
            save()
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "dynamic-island-preferences-v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           var decoded = try? JSONDecoder().decode(DynamicIslandPreferences.self, from: data) {
            decoded.normalize()
            value = decoded
        } else {
            value = DynamicIslandPreferences()
        }
    }

    func reset() {
        value = DynamicIslandPreferences()
    }

    func setPinned(_ itemID: MenuBarItemIdentity, pinned: Bool) {
        guard let preferenceID = itemID.runningApplicationPreferenceID else { return }
        var updated = value
        if pinned {
            updated.pinnedItemIDs.insert(preferenceID)
        } else {
            updated.pinnedItemIDs.remove(preferenceID)
        }
        value = updated
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
