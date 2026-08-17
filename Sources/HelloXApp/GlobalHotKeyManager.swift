@preconcurrency import Carbon
import Foundation

final class GlobalHotKeyManager: @unchecked Sendable {
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var activeBindings: [ShortcutAction: ShortcutBinding] = [:]
    private var handlerRef: EventHandlerRef?
    private(set) var initialRegistrationError: ShortcutRegistrationError?
    private let handler: @Sendable (ShortcutAction) -> Void
    private static let signature: OSType = 0x4D534854 // MSHT

    init(handler: @escaping @Sendable (ShortcutAction) -> Void) {
        self.handler = handler
        installEventHandler()
        if case .failure(let error) = apply(ShortcutPreferences.load()) {
            initialRegistrationError = error
        }
    }

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Atomically replaces every registration. On failure, the previous set is restored.
    func apply(_ bindings: [ShortcutAction: ShortcutBinding]) -> Result<Void, ShortcutRegistrationError> {
        if let error = ShortcutConflictDetector.validationError(in: bindings) {
            return .failure(error)
        }

        let previous = activeBindings
        unregisterAll()
        var registered: [ShortcutAction: EventHotKeyRef] = [:]
        for action in ShortcutAction.configurableCases {
            guard let binding = bindings[action] else { continue }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: eventID(for: action))
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            guard status == noErr, let reference else {
                for item in registered.values { UnregisterEventHotKey(item) }
                hotKeyRefs.removeAll()
                activeBindings.removeAll()
                restore(previous)
                return .failure(ShortcutRegistrationError(action: action, reason: "快捷键已被系统或其他应用占用"))
            }
            registered[action] = reference
        }
        hotKeyRefs = registered
        activeBindings = bindings
        return .success(())
    }

    /// Checks availability without leaving a temporary registration active.
    func availabilityError(for action: ShortcutAction, binding: ShortcutBinding) -> ShortcutRegistrationError? {
        let existingReference = hotKeyRefs.removeValue(forKey: action)
        if let existingReference { UnregisterEventHotKey(existingReference) }
        defer {
            if let previousBinding = activeBindings[action] {
                var restoredReference: EventHotKeyRef?
                let restoredID = EventHotKeyID(signature: Self.signature, id: eventID(for: action))
                if RegisterEventHotKey(
                    previousBinding.keyCode,
                    previousBinding.modifiers,
                    restoredID,
                    GetApplicationEventTarget(),
                    0,
                    &restoredReference
                ) == noErr, let restoredReference {
                    hotKeyRefs[action] = restoredReference
                }
            }
        }

        var probeReference: EventHotKeyRef?
        let probeID = EventHotKeyID(signature: Self.signature, id: UInt32.max)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            probeID,
            GetApplicationEventTarget(),
            0,
            &probeReference
        )
        if status == noErr, let probeReference {
            UnregisterEventHotKey(probeReference)
            return nil
        }
        return ShortcutRegistrationError(action: action, reason: "快捷键已被其他应用占用")
    }

    private func restore(_ bindings: [ShortcutAction: ShortcutBinding]) {
        var restored: [ShortcutAction: EventHotKeyRef] = [:]
        for (action, binding) in bindings where ShortcutAction.configurableCases.contains(action) {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: eventID(for: action))
            if RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr,
               let reference {
                restored[action] = reference
            }
        }
        hotKeyRefs = restored
        activeBindings = bindings
    }

    private func unregisterAll() {
        for reference in hotKeyRefs.values { UnregisterEventHotKey(reference) }
        hotKeyRefs.removeAll()
    }

    private func eventID(for action: ShortcutAction) -> UInt32 {
        UInt32(ShortcutAction.allCases.firstIndex(of: action)! + 1)
    }

    private func action(for eventID: UInt32) -> ShortcutAction? {
        let index = Int(eventID) - 1
        guard ShortcutAction.allCases.indices.contains(index) else { return nil }
        return ShortcutAction.allCases[index]
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard status == noErr, id.signature == GlobalHotKeyManager.signature,
                      let action = manager.action(for: id.id) else { return OSStatus(eventNotHandledErr) }
                manager.handler(action)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
