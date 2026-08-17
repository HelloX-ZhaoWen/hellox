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
    private let clearIconSize: CGFloat = 8
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
    private var isPointerOverClear = false
    private var hoverTrackingArea: NSTrackingArea?
    private var outsideClickMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 152, height: 32) }

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
        updatePointerLocation(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointerLocation(event)
    }

    override func mouseExited(with event: NSEvent) {
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        let backgroundColor = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.14)
            : recorderBackgroundColor
        backgroundColor.setFill()
        path.fill()
        if hasConflict || isRecording {
            let focusColor = hasConflict ? NSColor.systemRed : NSColor.controlAccentColor
            focusColor.setStroke()
            path.lineWidth = 1.25
            path.stroke()
        }
        let text: String
        if isRecording {
            let modifierText = ShortcutBinding(keyCode: UInt32.max, modifiers: pressedModifiers)
                .displayName
                .replacingOccurrences(of: "键码 \(UInt32.max)", with: "")
            text = modifierText.isEmpty ? "请按组合键…" : modifierText
        } else {
            text = binding?.displayName ?? "未设置"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = NSString(string: text).size(withAttributes: attributes)
        let reservedClearWidth = binding == nil ? 0 : clearHitWidth + clearTrailingInset
        NSString(string: text).draw(
            at: CGPoint(x: max(10, (bounds.width - reservedClearWidth - size.width) / 2), y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
        guard showsClearAffordance else { return }

        let buttonRect = CGRect(
            x: clearHitRect.midX - 9,
            y: bounds.midY - 9,
            width: 18,
            height: 18
        )
        let buttonPath = NSBezierPath(ovalIn: buttonRect)
        let buttonColor = isPointerOverClear
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.20)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.10)
        buttonColor.setFill()
        buttonPath.fill()
        let iconRect = CGRect(
            x: clearHitRect.midX - clearIconSize / 2,
            y: bounds.midY - clearIconSize / 2,
            width: clearIconSize,
            height: clearIconSize
        )
        (isPointerOverClear ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
        let clearPath = NSBezierPath()
        clearPath.move(to: iconRect.origin)
        clearPath.line(to: CGPoint(x: iconRect.maxX, y: iconRect.maxY))
        clearPath.move(to: CGPoint(x: iconRect.maxX, y: iconRect.minY))
        clearPath.line(to: CGPoint(x: iconRect.minX, y: iconRect.maxY))
        clearPath.lineWidth = 1.1
        clearPath.stroke()
    }

    private var clearHitRect: CGRect {
        CGRect(
            x: bounds.maxX - clearTrailingInset - clearHitWidth,
            y: bounds.minY,
            width: clearHitWidth,
            height: bounds.height
        )
    }

    private var recorderBackgroundColor: NSColor {
        let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(calibratedRed: 20 / 255, green: 42 / 255, blue: 73 / 255, alpha: 0.90)
        }
        return NSColor(calibratedRed: 244 / 255, green: 247 / 255, blue: 251 / 255, alpha: 1)
    }

    private var showsClearAffordance: Bool {
        binding != nil
            && !isRecording
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
}
