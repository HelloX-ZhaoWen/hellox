@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum ScreenRecordingPermissionState: Equatable, Sendable {
    case authorized
    case denied
    case requiresRelaunch
    case error(String)
}

public enum PrivacyPermission: String, CaseIterable, Codable, Sendable, Identifiable {
    case screenRecording
    case accessibility

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        }
    }

    public var settingsURL: String {
        switch self {
        case .screenRecording: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
    }
}

@MainActor
public final class PermissionService: ObservableObject {
    @Published public private(set) var canRecordScreen = CGPreflightScreenCaptureAccess()
    @Published public private(set) var canUseAccessibility = AXIsProcessTrusted()
    @Published public private(set) var screenRecordingState: ScreenRecordingPermissionState
    private var screenPermissionRequiresRelaunch = false

    public init() {
        screenRecordingState = CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    public func refresh(returnedFromSettings _: Bool = false) {
        canRecordScreen = CGPreflightScreenCaptureAccess()
        canUseAccessibility = AXIsProcessTrusted()
        if canRecordScreen {
            screenRecordingState = .authorized
            screenPermissionRequiresRelaunch = false
        } else if screenPermissionRequiresRelaunch {
            screenRecordingState = .requiresRelaunch
        } else {
            screenRecordingState = .denied
        }
    }

    public func isGranted(_ permission: PrivacyPermission) -> Bool {
        switch permission {
        case .screenRecording: canRecordScreen
        case .accessibility: canUseAccessibility
        }
    }

    @discardableResult
    public func request(_ permission: PrivacyPermission) -> Bool {
        switch permission {
        case .screenRecording: requestScreenRecording()
        case .accessibility: requestAccessibility(prompt: true)
        }
    }

    public func openSettings(for permission: PrivacyPermission) {
        openSettings(permission.settingsURL)
    }

    @discardableResult
    public func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        screenPermissionRequiresRelaunch = granted && !CGPreflightScreenCaptureAccess()
        refresh()
        return granted
    }

    @discardableResult
    public func requestAccessibility(prompt: Bool = true) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
        return canUseAccessibility
    }

    public func markScreenCaptureFailure(_ message: String) {
        refresh()
        if canRecordScreen {
            screenRecordingState = .error(message)
        } else {
            screenPermissionRequiresRelaunch = true
            screenRecordingState = .requiresRelaunch
        }
    }

    public func openAccessibilitySettings() {
        openSettings(for: .accessibility)
    }

    private func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
