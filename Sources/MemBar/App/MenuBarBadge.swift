import AppKit
import MemBarCore

/// Draws the menu-bar badge: a rounded capsule filled with the pressure colour and the
/// percentage in white, so the level is readable at a glance without parsing the number.
///
/// The badge has a **fixed width** (sized for `100%`) on purpose: a variable-width item makes the
/// window server re-lay-out the whole menu bar whenever the text changes, which used to dominate
/// this app's CPU time.
@MainActor
enum MenuBarBadge {
    static let height: CGFloat = 18
    static let cornerRadius: CGFloat = 6
    static let horizontalPadding: CGFloat = 7
    static let fontSize: CGFloat = 10

    static let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)

    /// Widest label the item ever has to show; the status item is pinned to this width.
    static let referenceText = "100%"

    static var fixedWidth: CGFloat { ceil(textSize(referenceText).width) + horizontalPadding * 2 }

    /// Capsule fill per level. Slightly darkened so white text keeps enough contrast on both
    /// light and dark menu bars, while the hue still reads as green / yellow / red.
    static func fillColor(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal:
            return NSColor.systemGreen.blended(withFraction: 0.22, of: .black) ?? .systemGreen
        case .elevated:
            return NSColor.systemYellow.blended(withFraction: 0.30, of: .black) ?? .systemOrange
        case .critical:
            return NSColor.systemRed.blended(withFraction: 0.12, of: .black) ?? .systemRed
        }
    }

    static func accessibilityDescription(text: String, pressure: MemoryPressure) -> String {
        "内存 \(text)，\(pressure.label)"
    }

    /// Renders (and caches) the badge for one percentage/level pair. Cached because the image is
    /// only rebuilt when the rounded percentage or the pressure level actually changes.
    static func image(text: String, pressure: MemoryPressure) -> NSImage {
        let key = "\(text)|\(pressure.rawValue)"
        if let cached = cache[key] { return cached }

        let size = NSSize(width: fixedWidth, height: height)

        // Draw at 2x into a bitmap rep: an `NSImage(size:flipped:)` block draws at 1x and would be
        // upscaled by the window server on a Retina menu bar, which softens the text badly.
        let scale: CGFloat = 2
        let pixels = NSSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width.rounded()),
            pixelsHigh: Int(pixels.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage(size: size) }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            draw(in: NSRect(origin: .zero, size: size), text: text, pressure: pressure)
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        cache[key] = image
        return image
    }

    private static func draw(in rect: NSRect, text: String, pressure: MemoryPressure) {
        let capsule = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        fillColor(for: pressure).setFill()
        capsule.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let labelSize = textSize(text)
        let textRect = NSRect(
            x: rect.midX - labelSize.width / 2,
            y: rect.midY - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private static var cache: [String: NSImage] = [:]

    private static func textSize(_ text: String) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }
}
