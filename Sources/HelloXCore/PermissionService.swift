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

@MainActor
public final class PermissionService: ObservableObject {
    @Published public private(set) var canRecordScreen = CGPreflightScreenCaptureAccess()
    @Published public private(set) var canUseAccessibility = AXIsProcessTrusted()
    @Published public private(set) var screenRecordingState: ScreenRecordingPermissionState
    private var screenPermissionFlowStarted = false

    public init() {
        screenRecordingState = CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    public func refresh(returnedFromSettings: Bool = false) {
        canRecordScreen = CGPreflightScreenCaptureAccess()
        canUseAccessibility = AXIsProcessTrusted()
        if canRecordScreen {
            screenRecordingState = .authorized
            screenPermissionFlowStarted = false
        } else if screenPermissionFlowStarted {
            screenRecordingState = .requiresRelaunch
        } else {
            screenRecordingState = .denied
        }
    }

    @discardableResult
    public func requestScreenRecording() -> Bool {
        screenPermissionFlowStarted = true
        let granted = CGRequestScreenCaptureAccess()
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

    public func openScreenRecordingSettings() {
        screenPermissionFlowStarted = true
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public func markScreenCaptureFailure(_ message: String) {
        refresh()
        screenRecordingState = canRecordScreen ? .error(message) : .requiresRelaunch
    }

    public func resetScreenPermissionFlow() {
        screenPermissionFlowStarted = false
        refresh()
    }

    public func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
