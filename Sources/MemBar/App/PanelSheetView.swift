import AppKit
import MemBarCore

/// The popup's content: one sheet, two sections.
///
/// This used to be an `NSMenu` with a second "page" that swapped menu items. Every interaction then
/// had to cancel menu tracking and re-open the popup (`cancelTracking` + `performClick`), which
/// flickered and could tear the menu down while its own view was still handling a click. Hosting
/// the same cards in a real view hierarchy makes a section switch a `hidden` flip and lets the
/// one-click action stay open while it reports its result.
@MainActor
final class PanelSheetView: NSView {
    enum Section {
        case main
        case processes
    }

    enum Layout {
        /// Outer margin between the popover edge and the cards.
        static let margin: CGFloat = 12
        static let gap: CGFloat = 10
        static let topPadding: CGFloat = 10
        static let bottomPadding: CGFloat = 12

        static var width: CGFloat { PanelCardView.Layout.width + margin * 2 }
    }

    private(set) var section: Section = .main

    let panelCard: PanelCardView
    let actionsCard: PanelActionsCard
    let processesCard: PanelProcessesCard

    /// Fired whenever the sheet's height changes, so the hosting popover can resize itself.
    var onPreferredSizeChange: ((NSSize) -> Void)?

    override var isFlipped: Bool { true }

    init(
        panelCard: PanelCardView,
        actionsCard: PanelActionsCard,
        processesCard: PanelProcessesCard
    ) {
        self.panelCard = panelCard
        self.actionsCard = actionsCard
        self.processesCard = processesCard
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Layout.width, height: 420)))
        addSubview(panelCard)
        addSubview(actionsCard)
        addSubview(processesCard)
        processesCard.isHidden = true
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Section

    /// Switches the lower half of the sheet. Deliberately instant: there is nothing to animate
    /// between two card stacks, and an instant swap never flashes.
    func setSection(_ newSection: Section) {
        guard newSection != section else { return }
        section = newSection
        actionsCard.isHidden = newSection != .main
        processesCard.isHidden = newSection != .processes
        needsLayout = true
        layoutSubtreeIfNeeded()
        publishSize()
    }

    var preferredSize: NSSize {
        NSSize(width: Layout.width, height: layoutHeight())
    }

    private func layoutHeight() -> CGFloat {
        let secondary = section == .main ? actionsCard : processesCard
        return Layout.topPadding
            + panelCard.frame.height
            + Layout.gap
            + secondary.frame.height
            + Layout.bottomPadding
    }

    /// Recomputes the frame and tells the popover about the new height. Called after a model
    /// update grew or shrank one of the cards.
    func refreshSize() {
        layoutSubtreeIfNeeded()
        publishSize()
    }

    private func publishSize() {
        let size = preferredSize
        if abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 {
            frame = NSRect(origin: frame.origin, size: size)
        }
        onPreferredSizeChange?(size)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = bounds.width - Layout.margin * 2
        panelCard.frame = NSRect(
            x: Layout.margin,
            y: Layout.topPadding,
            width: width,
            height: panelCard.frame.height
        )
        let secondaryY = panelCard.frame.maxY + Layout.gap
        let secondary = section == .main ? actionsCard : processesCard
        secondary.frame = NSRect(
            x: Layout.margin,
            y: secondaryY,
            width: width,
            height: secondary.frame.height
        )
        let other = section == .main ? processesCard : actionsCard
        other.frame.origin = NSPoint(x: Layout.margin, y: secondaryY)
        other.frame.size = NSSize(width: width, height: other.frame.height)
    }
}

/// Plain view controller wrapper: `NSPopover` needs one, the sheet does not need anything else.
@MainActor
final class PanelSheetViewController: NSViewController {
    let sheet: PanelSheetView

    init(sheet: PanelSheetView) {
        self.sheet = sheet
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = sheet
    }
}