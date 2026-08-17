import AppKit
import Darwin
import Foundation

struct IconOutput {
    let filename: String
    let pixels: Int
}

let outputs = [
    IconOutput(filename: "icon_16x16.png", pixels: 16),
    IconOutput(filename: "icon_16x16@2x.png", pixels: 32),
    IconOutput(filename: "icon_32x32.png", pixels: 32),
    IconOutput(filename: "icon_32x32@2x.png", pixels: 64),
    IconOutput(filename: "icon_128x128.png", pixels: 128),
    IconOutput(filename: "icon_128x128@2x.png", pixels: 256),
    IconOutput(filename: "icon_256x256.png", pixels: 256),
    IconOutput(filename: "icon_256x256@2x.png", pixels: 512),
    IconOutput(filename: "icon_512x512.png", pixels: 512),
    IconOutput(filename: "icon_512x512@2x.png", pixels: 1024)
]

enum IconStyle: String {
    case blueX = "blue-x"
    case captureFocus = "capture-focus"
    case framedSpark = "framed-spark"
}

guard (2...3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data("usage: AppIcon.swift <iconset-directory> [blue-x|capture-focus|framed-spark]\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconStyle = CommandLine.arguments.count == 3
    ? IconStyle(rawValue: CommandLine.arguments[2]) ?? .framedSpark
    : .framedSpark
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    graphicsContext.imageInterpolation = .high

    // macOS does not mask application artwork in Finder/Desktop. Keep the
    // artwork inside the standard optical footprint and provide real alpha in
    // the corners so the icon matches other rounded macOS application icons.
    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    let iconRect = canvas.insetBy(dx: CGFloat(pixels) * 0.082, dy: CGFloat(pixels) * 0.082)
    let cornerRadius = iconRect.width * 0.225
    let iconPath = CGPath(
        roundedRect: iconRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    let blue = NSColor(calibratedRed: 0.055, green: 0.39, blue: 0.95, alpha: 1)
    let lightBlue = NSColor(calibratedRed: 0.36, green: 0.72, blue: 1, alpha: 1)
    let paleBlue = NSColor(calibratedRed: 0.90, green: 0.95, blue: 1, alpha: 1)

    func fillIcon(_ color: NSColor) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -CGFloat(pixels) * 0.014),
            blur: CGFloat(pixels) * 0.035,
            color: NSColor.black.withAlphaComponent(0.16).cgColor
        )
        context.addPath(iconPath)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: iconRect.minX + iconRect.width * x, y: iconRect.minY + iconRect.height * y)
    }

    func ribbonPath(from start: CGPoint, control1: CGPoint, control2: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    func stroke(
        _ path: CGPath,
        color: NSColor,
        width: CGFloat,
        lineCap: CGLineCap = .round,
        lineJoin: CGLineJoin = .round
    ) {
        context.saveGState()
        context.addPath(iconPath)
        context.clip()
        context.addPath(path)
        context.setLineWidth(iconRect.width * width)
        context.setLineCap(lineCap)
        context.setLineJoin(lineJoin)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
        context.restoreGState()
    }

    func linePath(_ points: [CGPoint], closes: Bool = false) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        if closes { path.closeSubpath() }
        return path
    }

    switch iconStyle {
    case .blueX:
        fillIcon(.white)
        let falling = ribbonPath(
            from: point(0.28, 0.72),
            control1: point(0.40, 0.60),
            control2: point(0.60, 0.40),
            to: point(0.72, 0.28)
        )
        let rising = ribbonPath(
            from: point(0.28, 0.28),
            control1: point(0.40, 0.40),
            control2: point(0.60, 0.60),
            to: point(0.72, 0.72)
        )
        stroke(falling, color: lightBlue, width: 0.175)
        stroke(rising, color: blue, width: 0.175)
        stroke(rising, color: NSColor.white.withAlphaComponent(0.30), width: 0.032)

    case .captureFocus:
        fillIcon(blue)
        let corners: [[CGPoint]] = [
            [point(0.22, 0.40), point(0.22, 0.22), point(0.40, 0.22)],
            [point(0.60, 0.22), point(0.78, 0.22), point(0.78, 0.40)],
            [point(0.78, 0.60), point(0.78, 0.78), point(0.60, 0.78)],
            [point(0.40, 0.78), point(0.22, 0.78), point(0.22, 0.60)]
        ]
        corners.forEach { stroke(linePath($0), color: .white, width: 0.058) }
        let ringRect = CGRect(
            x: point(0.36, 0.36).x,
            y: point(0.36, 0.36).y,
            width: iconRect.width * 0.28,
            height: iconRect.height * 0.28
        )
        stroke(CGPath(ellipseIn: ringRect, transform: nil), color: .white, width: 0.052)
        let dotRect = ringRect.insetBy(dx: ringRect.width * 0.36, dy: ringRect.height * 0.36)
        context.setFillColor(paleBlue.cgColor)
        context.fillEllipse(in: dotRect)

    case .framedSpark:
        fillIcon(.white)
        let frame = CGPath(
            roundedRect: CGRect(
                x: point(0.21, 0.27).x,
                y: point(0.21, 0.27).y,
                width: iconRect.width * 0.58,
                height: iconRect.height * 0.46
            ),
            cornerWidth: iconRect.width * 0.08,
            cornerHeight: iconRect.width * 0.08,
            transform: nil
        )
        stroke(frame, color: blue, width: 0.065)
        let sparkle = linePath([
            point(0.66, 0.48),
            point(0.70, 0.59),
            point(0.81, 0.63),
            point(0.70, 0.67),
            point(0.66, 0.78),
            point(0.62, 0.67),
            point(0.51, 0.63),
            point(0.62, 0.59)
        ], closes: true)
        context.addPath(sparkle)
        context.setFillColor(lightBlue.cgColor)
        context.fillPath()
        let cursor = linePath([point(0.35, 0.37), point(0.48, 0.50), point(0.41, 0.53), point(0.38, 0.61)], closes: true)
        context.addPath(cursor)
        context.setFillColor(blue.cgColor)
        context.fillPath()
    }

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for output in outputs {
    try renderIcon(pixels: output.pixels).write(
        to: outputDirectory.appendingPathComponent(output.filename),
        options: .atomic
    )
}
