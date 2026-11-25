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
        static let row: CGFloat = 30
        /// Gap between two rows: the occupancy fill must read as separate bars, not one column.
        static let rowGap: CGFloat = 3
        static let footer: CGFloat = 34
        static let footerGap: CGFloat = 8
        static let backWidth: CGFloat = 56
        /// Horizontal padding inside a row, so text never touches the card edge.
        static let rowInset: CGFloat = 9
        static let rowCorner: CGFloat = 6
        /// Right-aligned size column; measured once from the widest string.
        static let valueGap: CGFloat = 8
        /// The 进程 count follows the name; the bar lane starts at one shared x for every row.
        static let countGap: CGFloat = 6
        static let barGap: CGFloat = 8
        static let barHeight: CGFloat = 8
        /// A tiny row must still show a sliver, otherwise the ranking has holes in it.
        static let barMinWidth: CGFloat = 3
        /// The name column gets roughly half the card; long names truncate rather than starve the bar.
        static let nameColumnShare: CGFloat = 0.54
        /// The name column never drops below this.
        static let nameColumnMin: CGFloat = 84
        /// And the bar lane never shrinks below this, so the ranking stays readable.
        static let minBarLane: CGFloat = 56
    }

    struct Row: Equatable {
        var key: String
        var name: String
        var bytes: String
        /// Raw resident size, only used to size the occupancy fill.
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
        // No hint line: when nothing is checked the card simply ends after the last row, and the
        // footer (button) does not exist at all. Saying "点按即可勾选" is what made this read as a
        // half-finished list.
        if isKillAvailable {
            lines.append(killButton.title)
        } else if isBusy {
            lines.append("正在清理…")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Geometry

    private struct Frames {
        var back: NSRect
        var rowRects: [NSRect]
        /// `nil` when nothing is checked: the card then ends after the last row.
        var footer: NSRect?
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
        for index in rows.indices {
            if index > 0 { y += Layout.rowGap }
            rects.append(NSRect(x: 0, y: y, width: PanelRowMetrics.width, height: Layout.row))
            y += Layout.row
        }
        // Dynamic height instead of a fixed 34pt strip: an unchecked list has nothing to offer, so
        // the popover shrinks by exactly the footer's height and the button appears with the
        // first check.
        var footer: NSRect?
        if isKillAvailable {
            y += Layout.footerGap
            footer = NSRect(x: 0, y: y, width: PanelRowMetrics.width, height: Layout.footer)
            y += Layout.footer
        }
        y += PanelRowMetrics.bottomPadding
        return Frames(back: back, rowRects: rects, footer: footer, height: y)
    }

    override func layout() {
        super.layout()
        // Hidden with the footer: a button floating below a shorter card would be clipped anyway.
        killButton.frame = frames.footer.map {
            NSRect(
                x: PanelRowMetrics.inset,
                y: $0.minY,
                width: bounds.width - PanelRowMetrics.inset * 2,
                height: Layout.footer
            )
        } ?? .zero
    }

    private var contentWidth: CGFloat {
        bounds.width - PanelRowMetrics.inset * 2
    }

    /// Right edge of the size column. Measured once from the widest string so the column never
    /// jumps between rows.
    private var valueRight: CGFloat {
        PanelRowMetrics.width - PanelRowMetrics.inset
    }

    private var valueWidth: CGFloat {
        rows.map { MenuStyle.width($0.bytes, font: MenuStyle.valueFont) }.max() ?? 40
    }

    private var valueX: CGFloat { valueRight - valueWidth }

    /// Left edge of the name column.
    private var nameColumnX: CGFloat { PanelRowMetrics.inset + Layout.rowInset }

    private var widestName: CGFloat { rows.map { nameWidth($0) }.max() ?? 0 }

    /// Width of the name column: as wide as the longest name wants, inside a fixed share of the
    /// card. Reserving a separate column for the 进程 count is what truncated "Google Chrome" to
    /// "Goog…", so the count is drawn inside this column only when it still fits.
    private var nameColumn: CGFloat {
        let cap = (PanelRowMetrics.width - PanelRowMetrics.inset * 2) * Layout.nameColumnShare
        let upper = min(widestName, cap)
        let lower = max(Layout.nameColumnMin, upper)
        let budget = fillLimit - nameColumnX - Layout.barGap - Layout.minBarLane
        return max(Layout.nameColumnMin, min(lower, budget))
    }

    /// One shared x for every bar, so the lane reads as a column and not as a ragged edge.
    private var barLaneX: CGFloat { nameColumnX + nameColumn + Layout.barGap }

    private var barLaneWidth: CGFloat { max(0, fillLimit - barLaneX) }

    /// Where the bar lane ends: before the size column, so the number always sits on plain ground.
    private var fillLimit: CGFloat { valueX - Layout.valueGap }

    private func nameWidth(_ row: Row) -> CGFloat {
        MenuStyle.width(row.name, font: nameFont(for: row))
    }
    private func nameFont(for row: Row) -> NSFont {
        row.checked ? MenuStyle.sectionFont : MenuStyle.rowLabelFont
    }

    /// `名称 ·N ████████░░░░  大小` — the bar is its own lane between the text and the size.
    ///
    /// The first attempt filled the whole row instead, which swallowed the text and made each row
    /// look like a differently sized pill. A dedicated lane keeps the labels on plain background
    /// and still turns the ranking into one readable column.
    private func barRect(in rowRect: NSRect, fraction: Double) -> NSRect {
        let lane = barLaneWidth
        guard lane > 0 else { return .zero }
        let width = max(Layout.barMinWidth, lane * CGFloat(min(1, max(0, fraction))))
        return NSRect(
            x: barLaneX,
            y: rowRect.midY - Layout.barHeight / 2,
            width: width,
            height: Layout.barHeight
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
            drawRowBackground(
                for: row,
                in: rect,
                hovered: hoveredRow == index,
                pressed: pressedRow == index
            )
            if maxSize > 0 {
                drawBar(for: row, in: rect, fraction: Double(row.size) / Double(maxSize))
            }
            drawRow(row, in: rect)
        }
        // No hint text and no reserved strip: the footer only exists while the button does.
    }

    /// Row wash first, then the bar: the bar keeps its own accent strength so a hovered row does
    /// not change the ranking colour.
    private func drawRowBackground(
        for row: Row,
        in rect: NSRect,
        hovered: Bool,
        pressed: Bool
    ) {
        let wash = PanelRowMetrics.rowBackground(hovered: hovered, pressed: pressed)
            ?? (row.checked ? NSColor.controlAccentColor.withAlphaComponent(0.14) : nil)
        guard let wash else { return }
        wash.setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: PanelRowMetrics.inset - 8, dy: 1),
            xRadius: PanelRowMetrics.rowCorner,
            yRadius: PanelRowMetrics.rowCorner
        ).fill()
    }

    /// The bar lane. Checked rows get the solid accent, unchecked rows a lighter one; the empty tail
    /// stays a faint track so the lane's full width is visible even for the smallest row.
    private func drawBar(for row: Row, in rect: NSRect, fraction: Double) {
        let lane = NSRect(
            x: barLaneX,
            y: rect.midY - Layout.barHeight / 2,
            width: barLaneWidth,
            height: Layout.barHeight
        )
        guard lane.width > 0 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(
            roundedRect: lane,
            xRadius: Layout.barHeight / 2,
            yRadius: Layout.barHeight / 2
        ).fill()

        let bar = barRect(in: rect, fraction: fraction)
        guard bar.width > 0 else { return }
        NSColor.controlAccentColor
            .withAlphaComponent(row.checked ? 0.95 : 0.55)
            .setFill()
        NSBezierPath(
            roundedRect: bar,
            xRadius: Layout.barHeight / 2,
            yRadius: Layout.barHeight / 2
        ).fill()
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
        // Size column: right-aligned on one shared x, whether or not the row is checked.
        let valueFont = row.checked ? MenuStyle.valueBoldFont : MenuStyle.valueFont
        let valueSize = MenuStyle.size(row.bytes, font: valueFont)
        (row.bytes as NSString).draw(
            at: NSPoint(
                x: valueRight - valueSize.width,
                y: rect.midY - valueSize.height / 2
            ),
            withAttributes: [.font: valueFont, .foregroundColor: NSColor.labelColor]
        )

        // The name owns the column. The helper count lives in `renderedText` only: as a second
        // column it either truncated the name ("Google Chro…") or appeared on some rows and not
        // others, and both read as a bug rather than as information.
        let nameFont = nameFont(for: row)
        let name = Self.truncated(row.name, font: nameFont, width: nameColumn)
        let nameSize = MenuStyle.size(name, font: nameFont)
        (name as NSString).draw(
            at: NSPoint(x: nameColumnX, y: rect.midY - nameSize.height / 2),
            withAttributes: [.font: nameFont, .foregroundColor: NSColor.labelColor]
        )
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
