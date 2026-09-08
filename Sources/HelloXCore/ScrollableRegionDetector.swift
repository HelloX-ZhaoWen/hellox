@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// A rectangular region on screen that the accessibility tree reports as
/// scrollable.  Coordinates are in global CoreGraphics screen space (origin
/// at top-left of the primary display, points, not pixels).
public struct ScrollableRegion: Sendable, Equatable {
    public let bounds: CGRect
    public let processID: pid_t
    public let windowID: CGWindowID?
    /// Estimated total content height in points.  `nil` when the
    /// accessibility element does not expose `AXContents`.
    public let estimatedContentHeight: CGFloat?
    /// Role reported by the accessibility element (e.g. `AXScrollArea`,
    /// `AXWebArea`).
    public let role: String

    public init(
        bounds: CGRect,
        processID: pid_t,
        windowID: CGWindowID? = nil,
        estimatedContentHeight: CGFloat? = nil,
        role: String
    ) {
        self.bounds = bounds
        self.processID = processID
        self.windowID = windowID
        self.estimatedContentHeight = estimatedContentHeight
        self.role = role
    }
}

/// Walks the macOS accessibility tree to discover scrollable content areas
/// in the frontmost application.  Requires the host process to be trusted
/// (`AXIsProcessTrusted()`).  Untrusted callers receive an empty result
/// rather than an error so the caller can silently fall back to manual
/// region selection.
public enum ScrollableRegionDetector {

    /// Roles that typically wrap scrollable content.
    private static let scrollRoles: Set<String> = [
        kAXScrollAreaRole as String,
        "AXWebArea",
        "AXTable",
        "AXOutline",
    ]

    // MARK: - Public API

    /// Detects scrollable regions in the frontmost application.
    /// - Parameters:
    ///   - processID: The target application's PID.  Pass `nil` to use the
    ///     current frontmost application.
    ///   - maximumRegions: Upper bound on the number of regions returned.
    ///     The largest regions (by visible area) are kept.
    /// - Returns: Sorted by visible area, descending.
    public static func detect(
        processID: pid_t? = nil,
        maximumRegions: Int = 8
    ) -> [ScrollableRegion] {
        guard AXIsProcessTrusted() else { return [] }

        let pid: pid_t
        if let processID {
            pid = processID
        } else if let front = NSWorkspace.shared.frontmostApplication {
            pid = front.processIdentifier
        } else {
            return []
        }

        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }

        var candidates: [ScrollableRegion] = []
        for window in windows {
            guard let windowFrame = frame(of: window) else { continue }
            let windowID = windowIdentifier(of: window, processID: pid)
            collectScrollableRegions(
                element: window,
                processID: pid,
                windowID: windowID,
                windowFrame: windowFrame,
                depth: 0,
                result: &candidates
            )
        }

        // Deduplicate overlapping regions (keep the smaller / more specific one).
        let deduplicated = deduplicate(candidates)

        return deduplicated
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .prefix(maximumRegions)
            .filter { $0.bounds.width >= 80 && $0.bounds.height >= 60 }
            .map { $0 }
    }

    // MARK: - Tree traversal

    private static func collectScrollableRegions(
        element: AXUIElement,
        processID: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect,
        depth: Int,
        result: inout [ScrollableRegion]
    ) {
        // Guard against runaway traversal in pathological trees.
        guard depth < 24 else { return }

        if let role = stringAttribute(element, kAXRoleAttribute) {
            let isScrollRole = scrollRoles.contains(role)
            let isLargeGroup = role == kAXGroupRole as String
                && hasScrollableChildren(element)

            if isScrollRole || isLargeGroup {
                if let region = buildRegion(
                    element: element,
                    processID: processID,
                    windowID: windowID,
                    windowFrame: windowFrame,
                    role: role
                ) {
                    result.append(region)
                    // Don't recurse into children of a scroll area — the
                    // scroll area itself is the best target.
                    return
                }
            }
        }

        guard let children = children(of: element) else { return }
        for child in children {
            collectScrollableRegions(
                element: child,
                processID: processID,
                windowID: windowID,
                windowFrame: windowFrame,
                depth: depth + 1,
                result: &result
            )
        }
    }

    // MARK: - Region construction

    private static func buildRegion(
        element: AXUIElement,
        processID: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect,
        role: String
    ) -> ScrollableRegion? {
        guard let frame = frame(of: element),
              frame.width >= 40, frame.height >= 40 else { return nil }

        // Only report regions that are actually larger than their visible
        // area (i.e. content extends beyond the viewport).
        let contentHeight = contentSize(of: element)?.height
        let isScrollable = contentHeight.map { $0 > frame.height + 8 } ?? true
        guard isScrollable else { return nil }

        // AX coordinates use the CoreGraphics global desktop space. NSScreen
        // frames use AppKit's bottom-left space and cannot be intersected here
        // directly, especially for displays above or to the left of the main
        // display. Clamp against Quartz display bounds instead and keep the
        // display containing the largest visible part of this element.
        let displays = visibleDisplayBounds()
        let clamped = displays.isEmpty
            ? frame
            : displays
                .map { frame.intersection($0) }
                .filter { !$0.isNull }
                .max { $0.width * $0.height < $1.width * $1.height }
                ?? .null
        guard !clamped.isEmpty, clamped.width >= 40, clamped.height >= 40 else { return nil }

        return ScrollableRegion(
            bounds: clamped,
            processID: processID,
            windowID: windowID,
            estimatedContentHeight: contentHeight,
            role: role
        )
    }

    // MARK: - Accessibility attribute helpers

    private static func frame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let positionValue = value, CFGetTypeID(positionValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point) else { return nil }

        value = nil
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let sizeValue = value, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }

        return CGRect(origin: point, size: size)
    }

    private static func visibleDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }
        return displayIDs.prefix(Int(count)).map(CGDisplayBounds)
    }

    private static func contentSize(of element: AXUIElement) -> CGSize? {
        // Some elements expose AXContents whose frame reveals the full
        // scrollable area.  This is more reliable than
        // AXHorizontalScrollBar / AXVerticalScrollBar heuristics.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXContentsAttribute as CFString, &value) == .success,
              let contents = value as? [AXUIElement], !contents.isEmpty else { return nil }

        var unionRect: CGRect?
        for child in contents {
            if let childFrame = frame(of: child) {
                unionRect = unionRect.map { $0.union(childFrame) } ?? childFrame
            }
        }
        return unionRect?.size
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        return children
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func windowIdentifier(of window: AXUIElement, processID: pid_t) -> CGWindowID? {
        guard let frame = frame(of: window) else { return nil }
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"] else { continue }
            let infoFrame = CGRect(x: x, y: y, width: w, height: h)
            if abs(infoFrame.midX - frame.midX) < 4, abs(infoFrame.midY - frame.midY) < 4 {
                return info[kCGWindowNumber as String] as? CGWindowID
            }
        }
        return nil
    }

    private static func hasScrollableChildren(_ element: AXUIElement) -> Bool {
        guard let children = children(of: element) else { return false }
        for child in children.prefix(6) {
            if let role = stringAttribute(child, kAXRoleAttribute), scrollRoles.contains(role) {
                return true
            }
        }
        return false
    }

    // MARK: - Deduplication

    /// Removes regions whose bounds are substantially contained inside a
    /// smaller, more specific sibling.  This prevents a full-window
    /// `AXGroup` from shadowing the actual `AXScrollArea` it contains.
    private static func deduplicate(_ regions: [ScrollableRegion]) -> [ScrollableRegion] {
        guard regions.count > 1 else { return regions }
        var kept: [ScrollableRegion] = []
        let sorted = regions.sorted { $0.bounds.area < $1.bounds.area }
        for candidate in sorted {
            let dominated = kept.contains { existing in
                let overlap = candidate.bounds.intersection(existing.bounds)
                return overlap.area > candidate.bounds.area * 0.85
            }
            if !dominated {
                kept.append(candidate)
            }
        }
        return kept
    }
}

extension CGRect {
    public var area: CGFloat { width * height }
}
