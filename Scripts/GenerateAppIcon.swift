#!/usr/bin/env swift
import AppKit
import Foundation

// Renders the MemBar app icon (gradient squircle + memory chip bars) into an .icns bundle.
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

    // Background squircle.
    let background = NSBezierPath(
        roundedRect: rect.insetBy(dx: p(40), dy: p(40)),
        xRadius: p(205),
        yRadius: p(205)
    )
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.66, blue: 0.52, alpha: 1.0),
        NSColor(srgbRed: 0.09, green: 0.27, blue: 0.35, alpha: 1.0),
    ])!
    gradient.draw(in: background, angle: -90)

    // Soft highlight at the top.
    let highlight = NSBezierPath(
        roundedRect: CGRect(x: p(120), y: p(650), width: p(784), height: p(300)),
        xRadius: p(150),
        yRadius: p(150)
    )
    NSColor.white.withAlphaComponent(0.10).setFill()
    highlight.fill()

    // Chip body.
    let body = NSBezierPath(
        roundedRect: CGRect(x: p(220), y: p(220), width: p(584), height: p(584)),
        xRadius: p(96),
        yRadius: p(96)
    )
    NSColor.white.setFill()
    body.fill()

    // Three memory bars, growing left to right.
    let barColor = NSColor(srgbRed: 0.16, green: 0.48, blue: 0.42, alpha: 1.0)
    barColor.setFill()
    let bars: [(x: CGFloat, height: CGFloat)] = [
        (p(316), p(200)),
        (p(468), p(320)),
        (p(620), p(430)),
    ]
    for bar in bars {
        let path = NSBezierPath(
            roundedRect: CGRect(x: bar.x, y: p(300), width: p(88), height: bar.height),
            xRadius: p(28),
            yRadius: p(28)
        )
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