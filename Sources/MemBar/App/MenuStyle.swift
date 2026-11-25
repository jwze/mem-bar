import AppKit
import MemBarCore

/// Typography, colours and column maths shared by the popup.
///
/// Two rules drive everything here:
/// 1. Hierarchy comes from **size and weight**, never from dimming. AppKit dims disabled menu items
///    by itself, so read-only rows are drawn by `PanelCardView` in `labelColor` and stay readable;
///    nothing informational is painted with `secondaryLabelColor` or with a reduced alpha.
/// 2. Columns are real: values are right-aligned against the card edge (submenu rows use padding,
///    because plain `NSMenuItem`s can only be aligned with spaces or tabs).
@MainActor
enum MenuStyle {
    // MARK: - Fonts

    static let headlineFont = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
    static let headlineUnitFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let legendFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let valueBoldFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let pillFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let buttonFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// New panel vocabulary: every row of the popup is a card, so the typography of a row lives
    /// here instead of in AppKit's menu defaults.
    static let rowLabelFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let rowValueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let sectionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let segmentFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let chevronFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// The clean verdict line: one short phrase (`已释放 297 MB`) plus a relative timestamp.
    static let resultValueFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

    // MARK: - Colours

    static func color(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return .systemGreen
        case .elevated: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Composition-bar segments share their colours with the legend dots.
    static let usedSegmentColor: NSColor = .labelColor
    static let cacheSegmentColor: NSColor = .systemBlue
    static let freeSegmentColor: NSColor = .systemTeal

    // MARK: - Measurement

    static func size(_ text: String, font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        size(text, font: font).width
    }

    // MARK: - Composition bar

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
            (usedFraction, usedSegmentColor),
            (cacheFraction, cacheSegmentColor),
            (freeFraction, freeSegmentColor),
        ]
    }
}
