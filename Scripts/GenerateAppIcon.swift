#!/usr/bin/env swift
import AppKit
import Foundation

// Renders the MemBar app icon into an .icns bundle.
// Design: a deep teal squircle, a white progress ring at ~72%, and three rising bars inside it —
// the same visual language as the menu-bar capsule, and still legible at 16×16.
// Usage: swift Scripts/GenerateAppIcon.swift <output.icns>

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputPath)
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MemBar-icon-\(UUID().uuidString).iconset")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func drawIcon(in rect: CGRect) {
    let scale = rect.width / 1024.0
    func p(_ value: CGFloat) -> CGFloat { value * scale }

    NSGraphicsContext.current?.shouldAntialias = true

    // MARK: Background squircle (deep teal, top-lit)

    let background = NSBezierPath(
        roundedRect: rect.insetBy(dx: p(44), dy: p(44)),
        xRadius: p(210),
        yRadius: p(210)
    )
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.13, green: 0.55, blue: 0.50, alpha: 1.0),
        NSColor(srgbRed: 0.04, green: 0.17, blue: 0.24, alpha: 1.0),
    ])!
    gradient.draw(in: background, angle: -90)

    // Subtle inner rim so the tile reads as a physical chip on any wallpaper.
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let rim = NSBezierPath(
        roundedRect: rect.insetBy(dx: p(52), dy: p(52)),
        xRadius: p(202),
        yRadius: p(202)
    )
    rim.lineWidth = p(3)
    rim.stroke()

    // MARK: Progress ring

    let center = CGPoint(x: rect.midX, y: rect.midY)
    let ringRadius = p(300)
    let ringWidth = p(74)

    // Track.
    let track = NSBezierPath()
    track.appendArc(
        withCenter: center,
        radius: ringRadius,
        startAngle: 0,
        endAngle: 360
    )
    track.lineWidth = ringWidth
    NSColor.white.withAlphaComponent(0.16).setStroke()
    track.stroke()

    // Progress: 72% of the circle, starting at 12 o'clock and running clockwise.
    let progress: CGFloat = 0.72
    let startAngle: CGFloat = 90
    let endAngle = startAngle - 360 * progress
    let arc = NSBezierPath()
    arc.appendArc(
        withCenter: center,
        radius: ringRadius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: true
    )
    arc.lineWidth = ringWidth
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    // MARK: Three rising bars inside the ring

    // Centred inside the ring: bars span from -160 to +160 and are vertically centred on the
    // ring's centre of mass, so the group reads as balanced rather than sunk to the bottom.
    let barWidth = p(78)
    let gap = p(22)
    let bars: [(index: CGFloat, height: CGFloat)] = [
        (0, p(150)),
        (1, p(240)),
        (2, p(330)),
    ]
    let totalWidth = barWidth * 3 + gap * 2
    let baseline = rect.midY - p(165)

    for bar in bars {
        let x = center.x - totalWidth / 2 + bar.index * (barWidth + gap)
        let path = NSBezierPath(
            roundedRect: CGRect(
                x: x,
                y: baseline,
                width: barWidth,
                height: bar.height
            ),
            xRadius: barWidth / 2,
            yRadius: barWidth / 2
        )
        NSColor.white.setFill()
        path.fill()
    }
}

func pngData(size: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("could not allocate \(size)x\(size) bitmap") }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG at \(size)")
    }
    return data
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for variant in variants {
    let url = iconsetURL.appendingPathComponent("\(variant.name).png")
    try pngData(size: variant.size).write(to: url)
}

// Preview of the 512 pt tile, handy when tweaking the artwork.
let previewURL = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
    .appendingPathComponent("AppIcon-preview.png")
try? pngData(size: 512).write(to: previewURL)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()

try? FileManager.default.removeItem(at: iconsetURL)
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print("wrote \(outputURL.path)")
