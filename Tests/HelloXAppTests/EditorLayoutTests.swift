import AppKit
import HelloXCore
import SwiftUI
import Testing
@testable import HelloXApp

@MainActor
@Suite(.serialized)
struct EditorLayoutTests {
    init() {
        HXTypography.configureRendering()
        _ = NSApplication.shared
    }

    /// Opt-in production-window samples. The source image and crop rectangle
    /// are generated locally, with no capture, OCR, translation, or file dialogs.
    @Test func renderEditorWindowSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }
        let appModel = AppModel(translationProfileState: .init(
            profiles: [], defaultProfileID: nil, apiKeys: [:], isOfflineTranslationEnabled: false
        ))
        let image = try makeFixtureImage()
        let result = CaptureResult(
            image: image, displayScale: 2,
            capturedRect: CGRect(x: 0, y: 0, width: 640, height: 400),
            createdAt: Date(timeIntervalSince1970: 0), mode: .region
        )
        var frameRecords: [[String: Any]] = []

        for scheme in ["light", "dark"] {
            app.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
            for (mode, tool) in [("select", AnnotationTool.select), ("crop", .crop)] {
                let document = EditorDocument(result: result, appModel: appModel)
                if tool == .crop {
                    document.cropSelection = CGRect(x: 0.12, y: 0.16, width: 0.66, height: 0.64)
                }
                let controller = EditorWindowController(document: document, initialTool: tool)
                let window = try #require(controller.window)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let defaultSize = window.contentRect(forFrameRect: window.frame).size
                // Hosting can reset NSWindow.minSize; render the editor's
                // supported minimum directly, as enforced by its constraints.
                let sizes: [(String, NSSize)] = [("", defaultSize), ("-minimum", NSSize(width: 760, height: 520))]

                for (suffix, size) in sizes {
                    window.setContentSize(size)
                    let assignedFrame = window.frame
                    // SwiftUI can replace its hosting view during the first
                    // layout. Reacquire contentView after deferred updates.
                    for _ in 0..<3 {
                        window.contentView?.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    let view = try #require(window.contentView)
                    view.layoutSubtreeIfNeeded()
                    #expect(window.frame == assignedFrame)
                    #expect(window.contentRect(forFrameRect: window.frame).size == size)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "editor-\(mode)-\(scheme)\(suffix)"
                    try png.write(to: output.appendingPathComponent("\(name).png"))
                    frameRecords.append([
                        "sample": name,
                        "requestedContentSize": ["width": Double(size.width), "height": Double(size.height)],
                        "assignedWindowFrame": frameRecord(assignedFrame),
                        "renderedWindowFrame": frameRecord(window.frame),
                        "contentViewFrame": frameRecord(view.frame),
                        "contentViewBounds": frameRecord(view.bounds),
                        "contentLayoutRect": frameRecord(window.contentLayoutRect),
                        "backingScaleFactor": Double(window.backingScaleFactor),
                        "bitmapPixels": ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]
                    ])
                }
                #expect(!document.isPerformingOCR)
                #expect(!document.isPerformingTranslation)
                #expect(!document.dirty)
            }
        }
        let records = try JSONSerialization.data(withJSONObject: frameRecords, options: [.prettyPrinted, .sortedKeys])
        try records.write(to: output.appendingPathComponent("editor-layout-frames.json"))
    }

    private func frameRecord(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY),
         "width": Double(rect.width), "height": Double(rect.height)]
    }

    private func makeFixtureImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1280, height: 800).fill()
        draw("项目进度", at: NSPoint(x: 64, y: 682), size: 44, weight: .semibold)
        draw("2026 · 工作记录", at: NSPoint(x: 66, y: 638), size: 24, color: .gray)

        for (index, title) in ["资料整理", "方案确认", "成果交付"].enumerated() {
            let x = CGFloat(index) * 390 + 64
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 132, width: 364, height: 438),
                         xRadius: 24, yRadius: 24).fill()
            draw(title, at: NSPoint(x: x + 28, y: 492), size: 30, weight: .medium)
            draw("持续推进，记录每一步。", at: NSPoint(x: x + 28, y: 449),
                 size: 20, color: .gray)
            let colors: [NSColor] = [.systemBlue, .systemTeal, .systemOrange]
            colors[index].withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 102, y: 288, width: 160, height: 120)).fill()
            colors[index].setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 60, y: 250, width: 180, height: 98),
                         xRadius: 16, yRadius: 16).fill()
            for line in 0..<3 {
                NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 28, y: 202 - CGFloat(line) * 22,
                                                width: line == 2 ? 180 : 306, height: 8),
                             xRadius: 4, yRadius: 4).fill()
            }
        }
        draw("更新于 9 月 7 日", at: NSPoint(x: 64, y: 62), size: 20, color: .gray)
        return try #require(context.makeImage())
    }

    private func draw(_ text: String, at point: NSPoint, size: CGFloat,
                      weight: NSFont.Weight = .regular, color: NSColor = .black) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ])
    }
}
