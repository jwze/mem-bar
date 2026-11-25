import AppKit
import MemBarCore

/// The unified card at the top of the popup: headline, composition bar, legend, the numeric
/// column, the prominent clean button and the last-result line.
///
/// Why one custom view instead of seven menu items: AppKit paints *disabled* menu items with its
/// dimmed "unavailable" appearance no matter what colour an attributed title carries, so the
/// read-only rows of the old menu came out washed out and half transparent. A view draws exactly
/// the colours it is given, so every line of this card keeps full contrast — nothing is greyed and
/// nothing is faded just because it cannot be clicked.
@MainActor
final class PanelCardView: NSView {
    /// Everything the card needs to draw itself. A plain value type so the self test can assert on
    /// the rendered text without reaching into AppKit.
    struct Model: Equatable {
        var snapshot: MemorySnapshot
        var result: ResultLine
        var isCleaning: Bool
    }

    /// The verdict line under the button, split into three pieces so the number stays dominant
    /// while its context and timestamp stay quiet: `上次清理  已释放 297 MB        31 秒前`.
    struct ResultLine: Equatable {
        enum Tone: Equatable {
            case idle, busy, good, warn
        }

        var prefix: String
        var value: String
        var tail: String
        var tone: Tone

        static let placeholder = ResultLine(
            prefix: "上次清理",
            value: "尚未清理",
            tail: "",
            tone: .idle
        )
    }

    enum Layout {
        /// Width of the card. The hosting menu item grows to this width, so every popup is the
        /// same size no matter how long the numbers get.
        static let width: CGFloat = 300
        static let inset: CGFloat = 16
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 12
        static let headline: CGFloat = 30
        static let headlineGap: CGFloat = 10
        static let bar: CGFloat = 8
        static let barGap: CGFloat = 8
        static let legend: CGFloat = 14
        static let legendGap: CGFloat = 12
        static let hairline: CGFloat = 1
        static let hairlineGap: CGFloat = 10
        static let metricRow: CGFloat = 19
        static let metricRowCount = 4
        static let metricsGap: CGFloat = 12
        static let button: CGFloat = 34
        static let buttonGap: CGFloat = 10
        /// The verdict line is always exactly one row: `已释放 297 MB` must never wrap.
        static let resultRow: CGFloat = 20

        static let cleanTitle = "⚡ 一键清理"
        static let busyTitle = "正在清理…"
    }

    private(set) var model: Model?
    let cleanButton = PanelActionButton()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: 260))
        cleanButton.title = Layout.cleanTitle
        cleanButton.onActivate = { [weak self] in self?.onClean?() }
        addSubview(cleanButton)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fired when the prominent button is clicked.
    var onClean: (() -> Void)?

    // The card is read-only; swallow clicks so the hosting menu item never treats a click on the
    // numbers as "run the clean action". The button is a subview and handles its own clicks.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// Applies a new model, resizing the view so the hosting menu item fits exactly.
    func update(_ model: Model) {
        let previousHeight = frame.height
        self.model = model
        cleanButton.title = model.isCleaning ? Layout.busyTitle : Layout.cleanTitle
        cleanButton.isBusy = model.isCleaning
        cleanButton.isEnabledForClicks = !model.isCleaning
        let height = frames(for: model).height
        if abs(height - previousHeight) > 0.5 {
            frame = NSRect(x: 0, y: 0, width: Layout.width, height: height)
        }
        needsLayout = true
        needsDisplay = true
        setAccessibilityLabel(renderedText)
    }

    /// Plain-text dump of everything the card shows, for `--selftest` and accessibility.
    var renderedText: String {
        guard let model else { return "" }
        let snapshot = model.snapshot
        var lines = [
            "\(Fmt.percent(snapshot.percent)) 已用 \(Fmt.bytes(snapshot.used)) / \(Fmt.bytes(snapshot.total))"
                + " · \(snapshot.pressure.label)",
            legendText,
            "缓存 \(Fmt.bytes(snapshot.cache))",
            "空闲 \(Fmt.bytes(snapshot.free))",
            "压缩 \(Fmt.bytes(snapshot.compressed))",
            "交换 \(Fmt.bytes(snapshot.swapUsed)) / \(Fmt.bytes(snapshot.swapTotal))"
                + " (\(Fmt.ratioPercent(snapshot.swapRatio)))",
            cleanButton.title,
            [model.result.prefix, model.result.value, model.result.tail]
                .filter { !$0.isEmpty }
                .joined(separator: " "),
        ]
        lines.removeAll { $0.isEmpty }
        return lines.joined(separator: "\n")
    }

    // MARK: - Layout

    private struct Frames {
        var headline: CGFloat
        var bar: CGFloat
        var legend: CGFloat
        var hairline: CGFloat
        var metrics: CGFloat
        var button: CGFloat
        var result: CGFloat
        var height: CGFloat
    }
    private var contentWidth: CGFloat { max(40, bounds.width - Layout.inset * 2) }

    private func frames(for model: Model) -> Frames {
        var y = Layout.topPadding
        let headline = y
        y += Layout.headline + Layout.headlineGap
        let bar = y
        y += Layout.bar + Layout.barGap
        let legend = y
        y += Layout.legend + Layout.legendGap
        let hairline = y
        y += Layout.hairline + Layout.hairlineGap
        let metrics = y
        y += Layout.metricRow * CGFloat(Layout.metricRowCount) + Layout.metricsGap
        let button = y
        y += Layout.button + Layout.buttonGap
        let result = y
        y += Layout.resultRow + Layout.bottomPadding
        return Frames(
            headline: headline,
            bar: bar,
            legend: legend,
            hairline: hairline,
            metrics: metrics,
            button: button,
            result: result,
            height: y
        )
    }
    override func layout() {
        super.layout()
        guard let model else { return }
        let frames = frames(for: model)
        cleanButton.frame = NSRect(
            x: Layout.inset,
            y: frames.button,
            width: contentWidth,
            height: Layout.button
        )
    }

    // MARK: - Drawing

    private func toneColor(_ tone: ResultLine.Tone) -> NSColor {
        switch tone {
        case .idle, .busy: return .labelColor
        case .good: return .systemGreen
        case .warn: return .systemOrange
        }
    }

    /// `上次清理  已释放 297 MB                        31 秒前`
    ///
    /// The amount is the only bold, coloured word on the line; the label and the timestamp sit at
    /// `labelColor` (never secondary) so nothing is faded — hierarchy comes from weight and size.
    private func drawResult(_ result: ResultLine, at y: CGFloat) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuStyle.captionFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuStyle.resultValueFont,
            .foregroundColor: toneColor(result.tone),
        ]
        let midY = y + Layout.resultRow / 2

        var x = Layout.inset
        if !result.prefix.isEmpty {
            let size = MenuStyle.size(result.prefix, font: MenuStyle.captionFont)
            (result.prefix as NSString).draw(
                at: NSPoint(x: x, y: midY - size.height / 2),
                withAttributes: labelAttrs
            )
            x += size.width + 8
        }

        let valueSize = MenuStyle.size(result.value, font: MenuStyle.resultValueFont)
        (result.value as NSString).draw(
            at: NSPoint(x: x, y: midY - valueSize.height / 2),
            withAttributes: valueAttrs
        )

        if !result.tail.isEmpty {
            let tailSize = MenuStyle.size(result.tail, font: MenuStyle.captionFont)
            (result.tail as NSString).draw(
                at: NSPoint(
                    x: Layout.inset + contentWidth - tailSize.width,
                    y: midY - tailSize.height / 2
                ),
                withAttributes: labelAttrs
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let frames = frames(for: model)
        let snapshot = model.snapshot

        drawHeadline(snapshot, at: frames.headline)
        drawCompositionBar(snapshot, at: frames.bar)
        drawLegend(at: frames.legend)

        NSColor.separatorColor.setFill()
        NSRect(x: Layout.inset, y: frames.hairline, width: contentWidth, height: 1).fill()

        drawMetrics(snapshot, at: frames.metrics)
        drawResult(model.result, at: frames.result)
    }

    private func drawHeadline(_ snapshot: MemorySnapshot, at y: CGFloat) {
        let percent = Fmt.percent(snapshot.percent)
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuStyle.headlineFont,
            .foregroundColor: MenuStyle.color(for: snapshot.pressure),
        ]
        (percent as NSString).draw(at: NSPoint(x: Layout.inset, y: y), withAttributes: percentAttrs)
        let percentWidth = (percent as NSString).size(withAttributes: percentAttrs).width

        let unit = "已用 " + Fmt.bytes(snapshot.used) + " / " + Fmt.bytes(snapshot.total)
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuStyle.headlineUnitFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let unitSize = (unit as NSString).size(withAttributes: unitAttrs)
        (unit as NSString).draw(
            at: NSPoint(x: Layout.inset + percentWidth + 10, y: y + Layout.headline - unitSize.height - 5),
            withAttributes: unitAttrs
        )

        drawPressurePill(snapshot.pressure, centerY: y + Layout.headline / 2 - 1)
    }

    /// Small capsule mirroring the menu-bar badge, so the popup and the bar speak the same language.
    private func drawPressurePill(_ pressure: MemoryPressure, centerY: CGFloat) {
        let label = pressure.label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MenuStyle.pillFont,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let size = NSSize(width: ceil(textSize.width) + 16, height: 18)
        let rect = NSRect(
            x: bounds.width - Layout.inset - size.width,
            y: (centerY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        MenuBarBadge.fillColor(for: pressure).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        (label as NSString).draw(
            at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attrs
        )
    }

    private func drawCompositionBar(_ snapshot: MemorySnapshot, at y: CGFloat) {
        let segments = MenuStyle.compositionSegments(
            used: snapshot.used,
            cache: snapshot.cache,
            free: snapshot.free,
            total: snapshot.total
        )
        guard !segments.isEmpty else { return }
        let height = Layout.bar
        let radius = height / 2
        let totalWidth = contentWidth
        var x = Layout.inset
        let end = Layout.inset + totalWidth
        for (index, segment) in segments.enumerated() where segment.fraction > 0 {
            let width = totalWidth * CGFloat(segment.fraction)
            let rect = NSRect(x: x, y: y, width: width, height: height)
            // Only the outer ends stay rounded; interior joints stay square so the bar reads as one
            // continuous gauge instead of three pills.
            let path: NSBezierPath
            if index == 0 || x + width >= end - 0.01 {
                path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            } else {
                path = NSBezierPath(rect: rect)
            }
            segment.color.setFill()
            path.fill()
            x += width
        }
    }

    /// Colour key for the bar. The numbers live in the column below, so they are not repeated here.
    private var legendText: String { "● 已用    ● 缓存    ● 空闲" }

    /// The legend line, with each `●` painted in its segment colour and the text left at full
    /// contrast (`labelColor`, never a secondary/grey tone).
    private func drawLegend(at y: CGFloat) {
        let text = legendText
        let colors: [NSColor] = [
            MenuStyle.usedSegmentColor,
            MenuStyle.cacheSegmentColor,
            MenuStyle.freeSegmentColor,
        ]
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: MenuStyle.legendFont, .foregroundColor: NSColor.labelColor]
        )
        let nsText = text as NSString
        var searchStart = 0
        for color in colors {
            let range = nsText.range(
                of: "●",
                options: [],
                range: NSRange(location: searchStart, length: nsText.length - searchStart)
            )
            guard range.location != NSNotFound else { break }
            attributed.addAttribute(.foregroundColor, value: color, range: range)
            searchStart = range.location + range.length
        }
        attributed.draw(at: NSPoint(x: Layout.inset, y: y))
    }

    private func drawMetrics(_ snapshot: MemorySnapshot, at y: CGFloat) {
        let swapColor: NSColor = snapshot.swapRatio > 0.8 ? .systemRed : .labelColor
        let rows: [(label: String, value: String, color: NSColor)] = [
            ("缓存", Fmt.bytes(snapshot.cache), .labelColor),
            ("空闲", Fmt.bytes(snapshot.free), .labelColor),
            ("压缩", Fmt.bytes(snapshot.compressed), .labelColor),
            (
                "交换 · 已用 \(Fmt.ratioPercent(snapshot.swapRatio))",
                "\(Fmt.bytes(snapshot.swapUsed)) / \(Fmt.bytes(snapshot.swapTotal))",
                swapColor
            ),
        ]
        var rowY = y
        for row in rows {
            (row.label as NSString).draw(
                at: NSPoint(x: Layout.inset, y: rowY),
                withAttributes: [.font: MenuStyle.rowFont, .foregroundColor: NSColor.labelColor]
            )
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: MenuStyle.valueBoldFont,
                .foregroundColor: row.color,
            ]
            let valueSize = (row.value as NSString).size(withAttributes: valueAttrs)
            (row.value as NSString).draw(
                at: NSPoint(x: Layout.inset + contentWidth - valueSize.width, y: rowY),
                withAttributes: valueAttrs
            )
            rowY += Layout.metricRow
        }
    }
}

/// The one prominent, filled button of the popup. Drawn by hand so it stays at full contrast in
/// every state — the system's own disabled styling is exactly what we do not want here.
@MainActor
final class PanelActionButton: NSView {
    var title = "" {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(title)
        }
    }

    /// Keyboard hint next to the title; hidden while a clean is running.
    var hint: String? = "⌘K" {
        didSet { needsDisplay = true }
    }

    var isBusy = false {
        didSet { needsDisplay = true }
    }

    var isEnabledForClicks = true

    var onActivate: (() -> Void)?

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabledForClicks else { return }
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabledForClicks else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if inside { onActivate?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let fill: NSColor
        if isBusy {
            // Busy keeps the accent colour: a faded button would be harder to read than the state
            // it is trying to communicate.
            fill = accent.blended(withFraction: 0.25, of: .black) ?? accent
        } else if isPressed {
            fill = accent.blended(withFraction: 0.18, of: .black) ?? accent
        } else if isHovering {
            fill = accent.blended(withFraction: 0.10, of: .white) ?? accent
        } else {
            fill = accent
        }
        let rect = bounds.insetBy(dx: 0, dy: 1)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuStyle.buttonFont,
            .foregroundColor: NSColor.white,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: MenuStyle.pillFont,
            .foregroundColor: NSColor.white,
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let hintText = isBusy ? "" : (hint ?? "")
        let hintSize = (hintText as NSString).size(withAttributes: hintAttrs)

        if hintSize.width > 0 {
            let spacing: CGFloat = 10
            let total = titleSize.width + spacing + hintSize.width
            let x = rect.midX - total / 2
            (title as NSString).draw(
                at: NSPoint(x: x, y: rect.midY - titleSize.height / 2),
                withAttributes: titleAttrs
            )
            (hintText as NSString).draw(
                at: NSPoint(x: x + titleSize.width + spacing, y: rect.midY - hintSize.height / 2 + 0.5),
                withAttributes: hintAttrs
            )
        } else {
            (title as NSString).draw(
                at: NSPoint(x: rect.midX - titleSize.width / 2, y: rect.midY - titleSize.height / 2),
                withAttributes: titleAttrs
            )
        }
    }
}

