import AppKit
import MemBarCore

/// Geometry shared by the two cards that live under the memory panel.
///
/// Every card uses the same width, the same left inset and the same row rhythm, so the popup reads
/// as one continuous sheet instead of a native menu with a painted block stapled on top.
@MainActor
enum PanelRowMetrics {
    static let width = PanelCardView.Layout.width
    static let inset = PanelCardView.Layout.inset
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 10
    static let row: CGFloat = 32
    static let rowCorner: CGFloat = 7

    /// Hover/press wash. Text never dims in this app; only the row background moves.
    static func rowBackground(hovered: Bool, pressed: Bool) -> NSColor? {
        if pressed { return NSColor.labelColor.withAlphaComponent(0.14) }
        if hovered { return NSColor.labelColor.withAlphaComponent(0.08) }
        return nil
    }
}

/// One hover-tracking area per row, so a card can highlight exactly the row under the pointer.
@MainActor
private func makeRowTrackingAreas(
    owner: NSView,
    rects: [NSRect],
    label: String
) -> [NSTrackingArea] {
    rects.enumerated().map { index, rect in
        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: owner,
            userInfo: ["row": index, "label": label]
        )
        owner.addTrackingArea(area)
        return area
    }
}

/// The rows that used to be a native menu: 高占用进程 / 刷新间隔 / 登录时自动启动 / 退出 MemBar.
///
/// AppKit draws native items with its own row metrics, check-mark gutter and marquee highlight,
/// which never lined up with the hand-drawn panel above. Drawing them here keeps one grid: same
/// inset, same 32 pt rows, same rounded hover wash, values right-aligned on the card edge.
@MainActor
final class PanelActionsCard: NSView {
    enum Layout {
        static let segmentHeight: CGFloat = 20
        static let segmentWidth: CGFloat = 38
        static let segmentGap: CGFloat = 4
        static let switchWidth: CGFloat = 36
        static let switchHeight: CGFloat = 20
        static let noteHeight: CGFloat = 15
        static let chevronGap: CGFloat = 6
    }

    enum LoginState: Equatable {
        case on
        case off
        case requiresApproval
        case notFound

        /// Only the two blocked states replace the row rhythm with an extra line of explanation.
        var note: String? {
            switch self {
            case .on, .off: return nil
            case .requiresApproval: return "需在系统设置 → 登录项中允许"
            case .notFound: return "请先把 MemBar 放到 /Applications"
            }
        }

        var isOn: Bool { self == .on }
    }

    struct Model: Equatable {
        var processCount: Int
        var intervalSeconds: Int
        var login: LoginState
    }

    private enum Row: Int, CaseIterable {
        case processes, interval, login, quit
    }

    private(set) var model: Model?

    /// `高占用应用` switches the sheet to the ranked process list; the other three act in place.
    var onOpenProcesses: (() -> Void)?
    var onSelectInterval: ((Int) -> Void)?
    var onToggleLogin: (() -> Void)?
    var onQuit: (() -> Void)?

    private var trackingAreas_: [NSTrackingArea] = []
    private var hoveredRow: Int?
    private var pressedRow: Int?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: PanelRowMetrics.width,
            height: PanelRowMetrics.topPadding
                + PanelRowMetrics.row * 4
                + PanelRowMetrics.bottomPadding
        ))
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Model

    func update(_ model: Model) {
        let previousHeight = frame.height
        self.model = model
        let height = frames(for: model).height
        if abs(height - previousHeight) > 0.5 {
            frame = NSRect(x: 0, y: 0, width: PanelRowMetrics.width, height: height)
        }
        needsLayout = true
        refreshTrackingAreas()
        needsDisplay = true
        setAccessibilityLabel(renderedText)
    }

    /// Plain-text dump for `--selftest` and VoiceOver.
    var renderedText: String {
        guard let model else { return "" }
        var lines = [
            "高占用应用 \(model.processCount) 个 ›",
            "刷新间隔 " + Prefs.refreshOptions
                .map { "\($0) 秒" + ($0 == model.intervalSeconds ? "(选中)" : "") }
                .joined(separator: " "),
            "登录时自动启动 " + (model.login.isOn ? "开" : "关"),
        ]
        if let note = model.login.note { lines.append(note) }
        lines.append("退出 MemBar ⌘Q")
        return lines.joined(separator: "\n")
    }

    // MARK: - Geometry

    private struct Frames {
        var rows: [NSRect]
        var note: CGFloat?
        var height: CGFloat
    }

    private func frames(for model: Model) -> Frames {
        var y = PanelRowMetrics.topPadding
        var rects: [NSRect] = []
        var note: CGFloat?
        for row in Row.allCases {
            rects.append(NSRect(x: 0, y: y, width: PanelRowMetrics.width, height: PanelRowMetrics.row))
            y += PanelRowMetrics.row
            if row == .login, model.login.note != nil {
                note = y - 3
                y += Layout.noteHeight
            }
        }
        y += PanelRowMetrics.bottomPadding
        return Frames(rows: rects, note: note, height: y)
    }

    private var currentFrames: Frames {
        guard let model else {
            return Frames(
                rows: (0..<Row.allCases.count).map {
                    NSRect(
                        x: 0,
                        y: PanelRowMetrics.topPadding + PanelRowMetrics.row * CGFloat($0),
                        width: PanelRowMetrics.width,
                        height: PanelRowMetrics.row
                    )
                },
                note: nil,
                height: bounds.height
            )
        }
        return frames(for: model)
    }

    private func segmentRects(in rowRect: NSRect) -> [NSRect] {
        let options = Prefs.refreshOptions
        let gap = Layout.segmentGap
        let total = CGFloat(options.count) * Layout.segmentWidth
            + CGFloat(max(0, options.count - 1)) * gap
        var x = PanelRowMetrics.width - PanelRowMetrics.inset - total
        return options.map { _ in
            let rect = NSRect(
                x: x,
                y: rowRect.midY - Layout.segmentHeight / 2,
                width: Layout.segmentWidth,
                height: Layout.segmentHeight
            )
            x += Layout.segmentWidth + gap
            return rect
        }
    }

    private var switchRect: NSRect {
        let rowRect = currentFrames.rows[Row.login.rawValue]
        return NSRect(
            x: PanelRowMetrics.width - PanelRowMetrics.inset - Layout.switchWidth,
            y: rowRect.midY - Layout.switchHeight / 2,
            width: Layout.switchWidth,
            height: Layout.switchHeight
        )
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        currentFrames.rows.firstIndex { $0.contains(point) }
    }

    private func segmentIndex(at point: NSPoint, rowRect: NSRect) -> Int? {
        segmentRects(in: rowRect).firstIndex { $0.contains(point) }
    }

    private func refreshTrackingAreas() {
        for area in trackingAreas_ { removeTrackingArea(area) }
        trackingAreas_ = makeRowTrackingAreas(
            owner: self,
            rects: currentFrames.rows,
            label: "actions"
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingAreas()
    }

    // MARK: - Interaction

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["row"] as? Int else { return }
        hoveredRow = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["row"] as? Int else { return }
        if hoveredRow == index {
            hoveredRow = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressedRow = rowIndex(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = rowIndex(at: point)
        let pressed = pressedRow
        pressedRow = nil
        needsDisplay = true
        guard let pressed, clicked == pressed, let row = Row(rawValue: pressed) else { return }

        switch row {
        case .processes:
            onOpenProcesses?()
        case .interval:
            let segments = segmentRects(in: currentFrames.rows[pressed])
            if let index = segmentIndex(at: point, rowRect: currentFrames.rows[pressed]),
               index < Prefs.refreshOptions.count {
                _ = segments
                onSelectInterval?(Prefs.refreshOptions[index])
            }
        case .login:
            onToggleLogin?()
        case .quit:
            onQuit?()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let frames = frames(for: model)

        for row in Row.allCases {
            let rect = frames.rows[row.rawValue]
            if let fill = PanelRowMetrics.rowBackground(
                hovered: hoveredRow == row.rawValue,
                pressed: pressedRow == row.rawValue
            ) {
                fill.setFill()
                let wash = rect.insetBy(dx: PanelRowMetrics.inset - 8, dy: 1)
                NSBezierPath(
                    roundedRect: wash,
                    xRadius: PanelRowMetrics.rowCorner,
                    yRadius: PanelRowMetrics.rowCorner
                ).fill()
            }
        }

        drawRow(.processes, in: frames, text: "高占用应用") { rect in
            let chevron = "›"
            let chevronSize = MenuStyle.size(chevron, font: MenuStyle.chevronFont)
            (chevron as NSString).draw(
                at: NSPoint(
                    x: PanelRowMetrics.width - PanelRowMetrics.inset - chevronSize.width,
                    y: rect.midY - chevronSize.height / 2
                ),
                withAttributes: [
                    .font: MenuStyle.chevronFont,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            drawValue(
                "\(model.processCount) 个",
                font: MenuStyle.rowValueFont,
                right: PanelRowMetrics.width - PanelRowMetrics.inset
                    - chevronSize.width - Layout.chevronGap,
                centerY: rect.midY
            )
        }

        drawRow(.interval, in: frames, text: "刷新间隔") { rect in
            let options = Prefs.refreshOptions
            for (index, segment) in segmentRects(in: rect).enumerated() where index < options.count {
                drawSegment(
                    seconds: options[index],
                    selected: options[index] == model.intervalSeconds,
                    in: segment
                )
            }
        }

        drawRow(.login, in: frames, text: "登录时自动启动") { _ in
            drawSwitch(on: model.login.isOn, in: switchRect)
        }

        drawRow(.quit, in: frames, text: "退出 MemBar") { rect in
            drawValue(
                "⌘Q",
                font: MenuStyle.captionFont,
                right: PanelRowMetrics.width - PanelRowMetrics.inset,
                centerY: rect.midY
            )
        }

        if let noteY = frames.note, let note = model.login.note {
            (note as NSString).draw(
                at: NSPoint(x: PanelRowMetrics.inset, y: noteY),
                withAttributes: [
                    .font: MenuStyle.captionFont,
                    .foregroundColor: NSColor.systemOrange,
                ]
            )
        }
    }

    private func drawRow(
        _ row: Row,
        in frames: Frames,
        text: String,
        accessory: (NSRect) -> Void
    ) {
        let rect = frames.rows[row.rawValue]
        let labelSize = MenuStyle.size(text, font: MenuStyle.rowLabelFont)
        (text as NSString).draw(
            at: NSPoint(x: PanelRowMetrics.inset, y: rect.midY - labelSize.height / 2),
            withAttributes: [
                .font: MenuStyle.rowLabelFont,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        accessory(rect)
    }

    private func drawValue(_ text: String, font: NSFont, right: CGFloat, centerY: CGFloat) {
        let size = MenuStyle.size(text, font: font)
        (text as NSString).draw(
            at: NSPoint(x: right - size.width, y: centerY - size.height / 2),
            withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }

    /// 2 秒 / 5 秒 / 10 秒 as small pills: the selected one is filled with the accent colour, the
    /// others keep a hairline outline. Both keep white / full-contrast text.
    private func drawSegment(seconds: Int, selected: Bool, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if selected {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let text = "\(seconds) 秒"
        let size = MenuStyle.size(text, font: MenuStyle.segmentFont)
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: [
                .font: MenuStyle.segmentFont,
                .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
            ]
        )
    }

    private func drawSwitch(on: Bool, in rect: NSRect) {
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        if on {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.20).setFill()
        }
        track.fill()

        let knobSize = rect.height - 4
        let knobX = on ? rect.maxX - knobSize - 2 : rect.minX + 2
        let knob = NSRect(
            x: knobX,
            y: rect.minY + 2,
            width: knobSize,
            height: knobSize
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}

/// The 高占用应用 section: a ranked list with one shared column grid.
///
/// It is a live view inside the sheet — not a second popup page. Ticking a row only repaints this
/// view, so there is no tracking cancellation, no re-open and no re-layout of the whole popup.
///
/// Grid: `[✓] 应用名（·N）  ─────────── 大小`, with a thin proportional bar under each row so the
/// ranking is visible without reading the numbers.
@MainActor
final class PanelProcessesCard: NSView {
    enum Layout {
        static let header: CGFloat = 28
        static let headerGap: CGFloat = 4
        static let row: CGFloat = 34
        static let checkbox: CGFloat = 15
        static let checkGap: CGFloat = 10
        static let footer: CGFloat = 34
        static let footerGap: CGFloat = 8
        static let backWidth: CGFloat = 56
        /// Rank bar under each row: thin enough to sit behind the text without competing with it.
        static let bar: CGFloat = 3
        static let barInset: CGFloat = 2
    }

    struct Row: Equatable {
        var key: String
        var name: String
        var bytes: String
        /// Raw resident size, only used to size the rank bar.
        var size: UInt64
        var processCount: Int
        var checked: Bool
    }

    private(set) var rows: [Row] = []
    private(set) var subtitle = ""
    private(set) var isBusy = false
    private(set) var isKillAvailable = false

    let killButton = PanelActionButton()

    var onBack: (() -> Void)?
    var onToggle: ((String) -> Void)?
    var onKill: (() -> Void)?

    private var trackingAreas_: [NSTrackingArea] = []
    private var hoveredRow: Int?
    private var pressedRow: Int?
    private var pressedBack = false
    private var hoveredBack = false
    private var backTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: PanelRowMetrics.width, height: 260))
        killButton.title = "结束选中应用"
        killButton.hint = nil
        killButton.onActivate = { [weak self] in self?.onKill?() }
        killButton.isHidden = true
        addSubview(killButton)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Model

    /// `rows` is replaced wholesale on every rebuild (rescan, toggle, kill), so the card never
    /// holds a stale pid list.
    func update(rows: [Row], subtitle: String, isBusy: Bool, selection: Set<String>) {
        let previousHeight = frame.height
        self.rows = rows
        self.subtitle = subtitle
        self.isBusy = isBusy

        let selectedCount = rows.filter { selection.contains($0.key) }.count
        isKillAvailable = selectedCount > 0 && !isBusy
        killButton.isHidden = !isKillAvailable
        killButton.isEnabledForClicks = isKillAvailable
        killButton.isBusy = isBusy
        killButton.title = isBusy
            ? "正在清理…"
            : "结束选中应用 (\(selectedCount))"

        let height = frames.height
        if abs(height - previousHeight) > 0.5 {
            frame = NSRect(x: 0, y: 0, width: PanelRowMetrics.width, height: height)
        }
        needsLayout = true
        refreshTrackingAreas()
        needsDisplay = true
        setAccessibilityLabel(renderedText)
    }

    var renderedText: String {
        var lines = ["‹ 返回 · 高占用应用 " + subtitle]
        for row in rows {
            lines.append(
                (row.checked ? "[x] " : "[ ] ")
                    + row.name
                    + (row.processCount > 1 ? " ·\(row.processCount)" : "")
                    + "  "
                    + row.bytes
            )
        }
        lines.append(
            isKillAvailable
                ? killButton.title
                : (isBusy ? "正在清理…" : "点按应用即可勾选，可多选结束")
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - Geometry

    private struct Frames {
        var back: NSRect
        var rowRects: [NSRect]
        var footer: NSRect
        var height: CGFloat
    }

    private var frames: Frames {
        var y = PanelRowMetrics.topPadding
        let back = NSRect(
            x: PanelRowMetrics.inset - 6,
            y: y,
            width: Layout.backWidth,
            height: Layout.header
        )
        y += Layout.header + Layout.headerGap
        var rects: [NSRect] = []
        for _ in rows {
            rects.append(NSRect(x: 0, y: y, width: PanelRowMetrics.width, height: Layout.row))
            y += Layout.row
        }
        y += Layout.footerGap
        let footer = NSRect(x: 0, y: y, width: PanelRowMetrics.width, height: Layout.footer)
        y += Layout.footer + PanelRowMetrics.bottomPadding
        return Frames(back: back, rowRects: rects, footer: footer, height: y)
    }

    override func layout() {
        super.layout()
        let footer = frames.footer
        killButton.frame = NSRect(
            x: PanelRowMetrics.inset,
            y: footer.minY,
            width: bounds.width - PanelRowMetrics.inset * 2,
            height: Layout.footer
        )
    }

    private var contentWidth: CGFloat {
        bounds.width - PanelRowMetrics.inset * 2
    }

    private func checkboxRect(in rowRect: NSRect) -> NSRect {
        NSRect(
            x: PanelRowMetrics.inset,
            y: rowRect.midY - Layout.checkbox / 2,
            width: Layout.checkbox,
            height: Layout.checkbox
        )
    }

    private func nameOriginX(in rowRect: NSRect) -> CGFloat {
        checkboxRect(in: rowRect).maxX + Layout.checkGap
    }

    /// The rank bar lives inside the name column: it must never look like an underline for the
    /// size column, and every bar shares one baseline so the list reads as a ranking.
    private func barRect(in rowRect: NSRect, fraction: Double) -> NSRect {
        let startX = nameOriginX(in: rowRect)
        let full = columns(in: rowRect).barWidth
        let width = max(Layout.bar, full * CGFloat(min(1, max(0, fraction))))
        return NSRect(
            x: startX,
            y: rowRect.maxY - Layout.bar - Layout.barInset,
            width: width,
            height: Layout.bar
        )
    }

    /// One grid for every row: `[✓] 名称 ·N ……… 大小`.
    private struct Columns {
        var nameX: CGFloat
        var valueX: CGFloat
        var valueWidth: CGFloat
        var barWidth: CGFloat
    }

    private func columns(in rowRect: NSRect, hint: Row? = nil) -> Columns {
        // Measured against the widest size string so the name column never jumps between rows.
        let widest = rows.map { MenuStyle.width($0.bytes, font: MenuStyle.valueFont) }.max() ?? 40
        let valueX = PanelRowMetrics.width - PanelRowMetrics.inset - widest
        let nameX = nameOriginX(in: rowRect)
        return Columns(
            nameX: nameX,
            valueX: valueX,
            valueWidth: widest,
            barWidth: max(Layout.bar, valueX - nameX - 8)
        )
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        frames.rowRects.firstIndex { $0.contains(point) }
    }

    private func refreshTrackingAreas() {
        for area in trackingAreas_ { removeTrackingArea(area) }
        trackingAreas_ = makeRowTrackingAreas(owner: self, rects: frames.rowRects, label: "processes")
        if let backTrackingArea { removeTrackingArea(backTrackingArea) }
        let area = NSTrackingArea(
            rect: frames.back,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: ["row": "back"]
        )
        addTrackingArea(area)
        backTrackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingAreas()
    }

    // MARK: - Interaction

    override func mouseEntered(with event: NSEvent) {
        if (event.trackingArea?.userInfo?["row"] as? String) == "back" {
            hoveredBack = true
        } else if let index = event.trackingArea?.userInfo?["row"] as? Int {
            hoveredRow = index
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if (event.trackingArea?.userInfo?["row"] as? String) == "back" {
            hoveredBack = false
        } else if let index = event.trackingArea?.userInfo?["row"] as? Int {
            if hoveredRow == index { hoveredRow = nil }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedBack = frames.back.contains(point)
        pressedRow = rowIndex(at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let wasBack = pressedBack
        let pressed = pressedRow
        pressedBack = false
        pressedRow = nil
        needsDisplay = true

        if wasBack, frames.back.contains(point) {
            onBack?()
            return
        }
        // The whole row is the hit target: hunting for a 15pt checkbox is not a test anyone wants.
        guard let pressed, rowIndex(at: point) == pressed, pressed < rows.count else { return }
        onToggle?(rows[pressed].key)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let frames = frames
        drawHeader(in: frames)

        let maxSize = rows.map(\.size).max() ?? 0
        for (index, row) in rows.enumerated() {
            let rect = frames.rowRects[index]
            if let fill = PanelRowMetrics.rowBackground(
                hovered: hoveredRow == index,
                pressed: pressedRow == index
            ) {
                fill.setFill()
                NSBezierPath(
                    roundedRect: rect.insetBy(dx: PanelRowMetrics.inset - 8, dy: 1),
                    xRadius: PanelRowMetrics.rowCorner,
                    yRadius: PanelRowMetrics.rowCorner
                ).fill()
            }
            if maxSize > 0 {
                NSColor.controlAccentColor.withAlphaComponent(row.checked ? 0.55 : 0.28).setFill()
                let bar = barRect(in: rect, fraction: Double(row.size) / Double(maxSize))
                NSBezierPath(roundedRect: bar, xRadius: Layout.bar / 2, yRadius: Layout.bar / 2).fill()
            }
            drawRow(row, in: rect)
        }

        if !isKillAvailable {
            let hint = isBusy ? "正在清理…" : "点按应用即可勾选，可多选结束"
            let size = MenuStyle.size(hint, font: MenuStyle.captionFont)
            (hint as NSString).draw(
                at: NSPoint(
                    x: PanelRowMetrics.inset,
                    y: frames.footer.midY - size.height / 2
                ),
                withAttributes: [
                    .font: MenuStyle.captionFont,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }
    }

    /// Header: `‹ 返回` on the left (the only navigation), aggregate size and count on the right.
    private func drawHeader(in frames: Frames) {
        let back = "‹ 返回"
        let color = hoveredBack
            ? (NSColor.controlAccentColor.blended(withFraction: 0.25, of: .black)
                ?? NSColor.controlAccentColor)
            : NSColor.controlAccentColor
        let backSize = MenuStyle.size(back, font: MenuStyle.rowValueFont)
        (back as NSString).draw(
            at: NSPoint(x: PanelRowMetrics.inset, y: frames.back.midY - backSize.height / 2),
            withAttributes: [.font: MenuStyle.rowValueFont, .foregroundColor: color]
        )

        let subtitleSize = MenuStyle.size(subtitle, font: MenuStyle.captionFont)
        (subtitle as NSString).draw(
            at: NSPoint(
                x: PanelRowMetrics.width - PanelRowMetrics.inset - subtitleSize.width,
                y: frames.back.midY - subtitleSize.height / 2
            ),
            withAttributes: [.font: MenuStyle.captionFont, .foregroundColor: NSColor.labelColor]
        )
    }

    private func drawRow(_ row: Row, in rect: NSRect) {
        // Checkbox
        let box = checkboxRect(in: rect)
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        if row.checked {
            NSColor.controlAccentColor.setFill()
            boxPath.fill()
            let mark = "✓"
            let markSize = MenuStyle.size(mark, font: MenuStyle.segmentFont)
            (mark as NSString).draw(
                at: NSPoint(x: box.midX - markSize.width / 2, y: box.midY - markSize.height / 2),
                withAttributes: [
                    .font: MenuStyle.segmentFont,
                    .foregroundColor: NSColor.white,
                ]
            )
        } else {
            NSColor.separatorColor.setStroke()
            boxPath.lineWidth = 1.5
            boxPath.stroke()
        }

        let grid = columns(in: rect)

        // Size column: right-aligned on one shared x, whether or not the row is checked.
        let valueFont = row.checked ? MenuStyle.valueBoldFont : MenuStyle.valueFont
        let valueSize = MenuStyle.size(row.bytes, font: valueFont)
        (row.bytes as NSString).draw(
            at: NSPoint(
                x: grid.valueX + grid.valueWidth - valueSize.width,
                y: rect.midY - valueSize.height / 2 - 1
            ),
            withAttributes: [.font: valueFont, .foregroundColor: NSColor.labelColor]
        )

        // Helper count: "18 进程" right after the name, quiet but at full contrast.
        let suffix = row.processCount > 1 ? "\(row.processCount) 进程" : ""
        let suffixSize = suffix.isEmpty
            ? .zero
            : MenuStyle.size(suffix, font: MenuStyle.captionFont)
        let suffixX = grid.valueX - suffixSize.width - (suffix.isEmpty ? 0 : 10)

        let nameFont = row.checked ? MenuStyle.sectionFont : MenuStyle.rowLabelFont
        let nameX = grid.nameX
        let available = max(20, suffixX - nameX - 6)
        let name = Self.truncated(row.name, font: nameFont, width: available)
        let nameSize = MenuStyle.size(name, font: nameFont)
        (name as NSString).draw(
            at: NSPoint(x: nameX, y: rect.midY - nameSize.height / 2 - 2),
            withAttributes: [.font: nameFont, .foregroundColor: NSColor.labelColor]
        )

        if !suffix.isEmpty {
            (suffix as NSString).draw(
                at: NSPoint(x: suffixX, y: rect.midY - suffixSize.height / 2 - 1),
                withAttributes: [
                    .font: MenuStyle.captionFont,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }
    }

    /// Shortens a name until it fits, so a long app name never runs under the size column.
    private static func truncated(_ text: String, font: NSFont, width: CGFloat) -> String {
        guard MenuStyle.width(text, font: font) > width else { return text }
        var candidate = text
        while !candidate.isEmpty {
            candidate.removeLast()
            let shortened = candidate + "…"
            if MenuStyle.width(shortened, font: font) <= width { return shortened }
        }
        return "…"
    }
}
