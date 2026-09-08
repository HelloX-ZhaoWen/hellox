@preconcurrency import Carbon
import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var binding: ShortcutBinding?
    var hasConflict = false

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = { binding = $0 }
        view.binding = binding
        view.hasConflict = hasConflict
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("快捷键录入，Delete 清空")
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.binding = binding
        nsView.hasConflict = hasConflict
    }
}

final class ShortcutRecorderView: NSView {
    private let clearHitWidth: CGFloat = 25
    private let clearTrailingInset: CGFloat = 7
    var binding: ShortcutBinding? {
        didSet {
            if binding == nil {
                isPointerOverClear = false
            }
            updateClearToolTip()
            needsDisplay = true
        }
    }
    var hasConflict = false { didSet { needsDisplay = true } }
    var onChange: ((ShortcutBinding?) -> Void)?
    private var isRecording = false
    private var pressedModifiers: UInt32 = 0
    private var isPointerInside = false
    private var isPointerOverClear = false
    private var hoverTrackingArea: NSTrackingArea?
    private var outsideClickMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 90, height: HelloXTheme.minimumHitSize) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopOutsideClickMonitoring()
        }
        window?.acceptsMouseMovedEvents = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func layout() {
        super.layout()
        updateClearToolTip()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updatePointerLocation(event)
    }

    override func mouseMoved(with event: NSEvent) {
        isPointerInside = true
        updatePointerLocation(event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        isPointerOverClear = false
        needsDisplay = true
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String { "清空快捷键" }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if showsClearAffordance, clearHitRect.contains(point) {
            clear()
            return
        }
        window?.makeFirstResponder(self)
        isRecording = true
        pressedModifiers = Self.carbonModifiers(from: event.modifierFlags)
        startOutsideClickMonitoring()
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        pressedModifiers = 0
        stopOutsideClickMonitoring()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        pressedModifiers = Self.carbonModifiers(from: event.modifierFlags)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            clear()
            return
        }
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0 else {
            NSSound.beep()
            return
        }
        let newBinding = ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        binding = newBinding
        isRecording = false
        pressedModifiers = 0
        onChange?(newBinding)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 8,
            yRadius: 8
        )
        let backgroundColor = isRecording
            ? NSColor(HelloXTheme.accent).withAlphaComponent(0.08)
            : recorderBackgroundColor
        backgroundColor.setFill()
        path.fill()
        let borderColor = hasConflict
            ? NSColor.systemRed
            : (isRecording ? NSColor(HelloXTheme.accent) : recorderBorderColor)
        borderColor.setStroke()
        path.lineWidth = hasConflict || isRecording ? 1.25 : 1
        path.stroke()
        let text: String
        if isRecording {
            let modifierText = ShortcutBinding(keyCode: UInt32.max, modifiers: pressedModifiers)
                .displayName
                .replacingOccurrences(of: "键码 \(UInt32.max)", with: "")
            text = modifierText.isEmpty ? "请按组合键…" : modifierText
        } else {
            text = binding.map { Self.spacedDisplayName($0.displayName) } ?? "未设置"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: 11,
                weight: .semibold
            ),
            .foregroundColor: NSColor(HelloXTheme.primaryText(for: recorderScheme))
        ]
        let size = NSString(string: text).size(withAttributes: attributes)
        let reservedClearWidth = showsClearAffordance ? clearHitWidth + clearTrailingInset : 0
        NSString(string: text).draw(
            at: CGPoint(x: max(10, (bounds.width - reservedClearWidth - size.width) / 2), y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
        guard showsClearAffordance else { return }

        let buttonRect = CGRect(x: clearHitRect.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        if isPointerOverClear {
            NSColor(HelloXTheme.hoverBackground(for: recorderScheme)).setFill()
            NSBezierPath(roundedRect: buttonRect, xRadius: 5, yRadius: 5).fill()
        }
        let iconSize: CGFloat = 14
        let iconRect = CGRect(x: clearHitRect.midX - iconSize / 2,
                              y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
        let iconColor = NSColor(isPointerOverClear
            ? HelloXTheme.primaryText(for: recorderScheme)
            : HelloXTheme.secondaryText(for: recorderScheme))
        HelloXIconImages.tintedImage(for: .close, color: iconColor, size: iconSize)?.draw(in: iconRect)

    }

    private var clearHitRect: CGRect {
        CGRect(
            x: bounds.maxX - clearTrailingInset - clearHitWidth,
            y: bounds.minY,
            width: clearHitWidth,
            height: bounds.height
        )
    }

    private var recorderScheme: ColorScheme { HelloXAppearance.colorScheme(for: effectiveAppearance) }
    private var recorderBackgroundColor: NSColor { NSColor(HelloXTheme.controlBackground(for: recorderScheme)) }
    private var recorderBorderColor: NSColor { NSColor(HelloXTheme.border(for: recorderScheme)) }

    private var showsClearAffordance: Bool {
        binding != nil
            && !isRecording
            && isPointerInside
    }

    private func updatePointerLocation(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newValue = binding != nil && clearHitRect.contains(point)
        if isPointerOverClear != newValue {
            isPointerOverClear = newValue
        }
        needsDisplay = true
    }

    private func updateClearToolTip() {
        removeAllToolTips()
        guard binding != nil else { return }
        addToolTip(clearHitRect, owner: self, userData: nil)
    }

    private func startOutsideClickMonitoring() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let clickedInsideRecorder = event.window === self.window
                && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !clickedInsideRecorder {
                self.cancelRecording()
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func cancelRecording() {
        isRecording = false
        pressedModifiers = 0
        stopOutsideClickMonitoring()
        needsDisplay = true
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private func clear() {
        binding = nil
        isRecording = false
        pressedModifiers = 0
        stopOutsideClickMonitoring()
        onChange?(nil)
        needsDisplay = true
        window?.makeFirstResponder(nil)
    }

    private static func carbonModifiers(from eventFlags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = eventFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private static func spacedDisplayName(_ displayName: String) -> String {
        let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var components: [String] = []
        var remainder = displayName[...]
        while let first = remainder.first, modifierGlyphs.contains(first) {
            components.append(String(first))
            remainder.removeFirst()
        }
        if !remainder.isEmpty {
            components.append(String(remainder))
        }
        return components.joined(separator: " ")
    }
}
