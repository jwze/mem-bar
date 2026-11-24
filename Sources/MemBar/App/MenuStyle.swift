import AppKit
import MemBarCore

/// Typography and layout shared by every menu row.
///
/// Everything is expressed with `NSTextTab`-free padding via `NSMutableParagraphStyle` so the
/// numbers line up in a real column instead of drifting with the label length. Rows stay plain
/// `NSMenuItem`s: no custom views, so keyboard navigation, highlighting and VoiceOver keep working.
@MainActor
enum MenuStyle {
    // MARK: - Fonts

    static let headlineFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let headlineUnitFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let captionBoldFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let valueBoldFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)



    // MARK: - Colours

    static func color(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return .systemGreen
        case .elevated: return .systemOrange
        case .critical: return .systemRed
        }
    }

    static let secondaryText = NSColor.secondaryLabelColor

    // MARK: - Paragraph styles

    /// Space width in `rowFont`, used to build the gap between label and value.
    static let spaceWidth: CGFloat =
        (" " as NSString).size(withAttributes: [.font: rowFont]).width

    static func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Column width that fits every label/value pair with at least `minimumGap` between them.
    ///
    /// Rows are laid out with plain spaces rather than `NSTextTab`. A tab stop is a fixed point,
    /// so a label even slightly wider than the stop (emoji and CJK measure inconsistently) makes
    /// AppKit skip to the next default stop — the values then jump around. Padding is exact.
    static func columnWidth(
        for pairs: [(label: String, value: String)],
        minimumGap: CGFloat = 14
    ) -> CGFloat {
        pairs.reduce(0) { partial, pair in
            let labelWidth = width(pair.label, font: rowFont)
            let valueWidth = width(pair.value, font: valueFont)
            return max(partial, labelWidth + valueWidth + minimumGap)
        }
    }

    /// Left-aligned label, right-aligned value, both on one line.
    static func row(
        _ label: String,
        value: String,
        valueColor: NSColor = .labelColor,
        columnWidth: CGFloat
    ) -> NSAttributedString {
        let labelWidth = width(label, font: rowFont)
        let valueWidth = width(value, font: valueFont)
        let gap = max(spaceWidth * 2, columnWidth - labelWidth - valueWidth)
        // Round down so the value never overshoots the column edge.
        let spaces = String(repeating: " ", count: max(1, Int(gap / spaceWidth)))

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: label + spaces,
            attributes: [.font: rowFont, .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(
            string: value,
            attributes: [.font: valueFont, .foregroundColor: valueColor]
        ))
        return result
    }

    /// Dimmed caption row, used for the "构成" legend and the last-clean result.
    static func caption(_ text: String, color: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: captionFont, .foregroundColor: color ?? secondaryText]
        )
    }

    /// Headline: big percentage, then the used/total figure in a smaller unit style.
    static func headline(percent: String, used: String, total: String, pressure: MemoryPressure) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: percent,
            attributes: [
                .font: headlineFont,
                .foregroundColor: color(for: pressure),
            ]
        ))
        result.append(NSAttributedString(
            string: "   " + used + " / " + total,
            attributes: [
                .font: headlineUnitFont,
                .foregroundColor: secondaryText,
            ]
        ))
        return result
    }

    /// One process row: name on the left, size on the right, optional "·N" for folded helpers.
    static func processAttributedTitle(
        name: String,
        bytes: String,
        processCount: Int,
        checked: Bool,
        columnWidth: CGFloat
    ) -> NSAttributedString {
        let label = name + (processCount > 1 ? "  ·\(processCount)" : "")
        let font = checked ? valueBoldFont : rowFont
        let valueFont = checked ? valueBoldFont : self.valueFont

        let labelWidth = width(label, font: font)
        let valueWidth = width(bytes, font: valueFont)
        let gap = max(spaceWidth * 2, columnWidth - labelWidth - valueWidth)
        let spaces = String(repeating: " ", count: max(1, Int(gap / spaceWidth)))

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: label + spaces,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(
            string: bytes,
            attributes: [.font: valueFont, .foregroundColor: secondaryText]
        ))
        return result
    }

    /// Plain-text variant (self test / accessibility).
    static func processRow(name: String, bytes: String, processCount: Int) -> String {
        let suffix = processCount > 1 ? "  ·\(processCount)" : ""
        return name + suffix + "  " + bytes
    }

    // MARK: - Composition bar

    /// Legend for the stacked composition bar: which segment means what.
    static func compositionLegend(
        used: UInt64,
        cache: UInt64,
        free: UInt64,
        total: UInt64
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let entries: [(String, NSColor)] = [
            ("已用 " + Fmt.bytes(used), .labelColor),
            ("缓存 " + Fmt.bytes(cache), .systemBlue),
            ("空闲 " + Fmt.bytes(free), .systemTeal),
        ]
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "   ",
                    attributes: [.font: captionFont]
                ))
            }
            result.append(NSAttributedString(
                string: "● ",
                attributes: [.font: captionFont, .foregroundColor: entry.1]
            ))
            result.append(NSAttributedString(
                string: entry.0,
                attributes: [.font: captionFont, .foregroundColor: secondaryText]
            ))
        }
        return result
    }

    /// Renders the stacked composition bar as an image (used as the row's `image`).
    static func compositionBarImage(
        used: UInt64,
        cache: UInt64,
        free: UInt64,
        total: UInt64,
        width: CGFloat = 236,
        height: CGFloat = 6
    ) -> NSImage? {
        let segments = compositionSegments(used: used, cache: cache, free: free, total: total)
        guard !segments.isEmpty else { return nil }

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((width * scale).rounded()),
            pixelsHigh: Int((height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)

            let bounds = NSRect(x: 0, y: 0, width: width, height: height)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: height / 2, yRadius: height / 2).fill()

            let radius = height / 2
            var x: CGFloat = 0
            for segment in segments where segment.fraction > 0 {
                let segmentWidth = width * CGFloat(segment.fraction)
                let rect = NSRect(x: x, y: 0, width: segmentWidth, height: height)
                // Only the outer ends stay rounded; interior joints are square so the bar reads
                // as one continuous gauge.
                let path: NSBezierPath
                if x <= 0.01 {
                    path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                } else {
                    path = NSBezierPath(rect: rect)
                }
                segment.color.setFill()
                path.fill()
                x += segmentWidth
            }
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    /// Segments of the composition bar as fractions, always summing to ≤ 1.
    static func compositionSegments(
        used: UInt64,
        cache: UInt64,
        free: UInt64,
        total: UInt64
    ) -> [(fraction: Double, color: NSColor)] {
        guard total > 0 else { return [] }
        let denominator = Double(total)
        let usedFraction = min(1, Double(used) / denominator)
        let cacheFraction = min(1 - usedFraction, Double(cache) / denominator)
        let freeFraction = max(0, 1 - usedFraction - cacheFraction)
        return [
            (usedFraction, .labelColor),
            (cacheFraction, .systemBlue),
            (freeFraction, .systemTeal),
        ]
    }
}
