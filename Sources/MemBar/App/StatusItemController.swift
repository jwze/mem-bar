import AppKit
import Darwin
import MemBarCore

/// Owns the menu-bar badge and the popup.
///
/// The popup is an `NSPopover` hosting the cards directly, not an `NSMenu`. A menu lays itself out
/// once and cannot be re-flowed while it is tracking, so the old implementation had to cancel
/// tracking and re-open the popup for every page switch and every height change — that is what
/// flickered, and cancelling a menu from inside its own click handler is what crashed it.
///
/// With a popover: switching sections is a `hidden` flip, the one-click action keeps the popup open
/// while it reports progress and its result, and a rescan just repaints.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    private var sampler: Sampler?
    private var snapshot: MemorySnapshot?

    private let panelCard = PanelCardView()
    private let actionsCard = PanelActionsCard()
    private let processesCard = PanelProcessesCard()
    private let sheet: PanelSheetView
    private let sheetController: PanelSheetViewController

    private var keyMonitor: Any?

    private var lastClean: CleanOutcome?
    private var lastCleanAt: Date?
    private var lastKill: KillEvent?
    private var lastLoginIssue: (text: String, at: Date)?

    /// A short, self-contained description of the last "结束选中应用", so the panel can show it in
    /// one phrase instead of a report.
    private struct KillEvent {
        var value: String
        var tone: PanelCardView.ResultLine.Tone
        var at: Date
    }

    /// Last rendered menu-bar state; the system only redraws the bar when these change, so a
    /// 5 s tick that lands on the same percent/pressure must not touch the title again.
    private var renderedPercent = -1
    private var renderedPressure: MemoryPressure?

    private var isCleaning = false
    private var candidates: [AppGroup] = []
    /// Checked rows, keyed by `AppGroup.key` (bundle path or executable name) — not by pid,
    /// because one row covers several processes.
    private var checkedKeys: Set<String> = []

    private let placeholderImage = MenuBarBadge.image(text: "–%", pressure: .normal)

    override init() {
        // Fixed width: a variable-length item forces the window server to re-lay-out the whole
        // menu bar on every percentage change, which dominates the app's CPU time. The badge is
        // sized for the widest label ("100%") and every state reuses that width.
        self.statusItem = NSStatusBar.system.statusItem(withLength: MenuBarBadge.fixedWidth)
        self.sheet = PanelSheetView(
            panelCard: panelCard,
            actionsCard: actionsCard,
            processesCard: processesCard
        )
        self.sheetController = PanelSheetViewController(sheet: sheet)
        super.init()
        configureButton()
        configurePopover()
        wireCards()
    }

    /// Whether the item is actually in the menu bar (a third-party menu-bar manager can hide it).
    var statusItemIsVisible: Bool { statusItem.isVisible }

    func start() {
        let sampler = Sampler(interval: Prefs.refreshInterval)
        sampler.onSample = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        sampler.start()
        self.sampler = sampler
        apply(MemoryStats.sample())
    }

    // MARK: - Status button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = placeholderImage
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "MemBar 内存监控"
        // No `statusItem.menu`: one click opens the popover, one click closes it again.
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
    }

    private func configurePopover() {
        popover.contentViewController = sheetController
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = sheet.preferredSize
        sheet.onPreferredSizeChange = { [weak self] size in
            guard let self else { return }
            // The popover only resizes itself while it is on screen; the size is also the next
            // opening size, so it must be stored either way.
            self.popover.contentSize = size
        }
    }

    private func wireCards() {
        panelCard.onClean = { [weak self] in self?.cleanNow() }
        actionsCard.onOpenProcesses = { [weak self] in self?.showProcesses() }
        actionsCard.onSelectInterval = { [weak self] seconds in self?.applyInterval(seconds) }
        actionsCard.onToggleLogin = { [weak self] in self?.toggleLoginItem() }
        actionsCard.onQuit = { [weak self] in self?.quit() }
        processesCard.onBack = { [weak self] in self?.showMain() }
        processesCard.onToggle = { [weak self] key in self?.toggleProcess(key) }
        processesCard.onKill = { [weak self] in self?.killSelected() }
    }

    private func apply(_ snapshot: MemorySnapshot) {
        self.snapshot = snapshot
        updateStatusButton(snapshot)
        refreshPanel()
        // The summary card can change height only with the swap row; keep the popover honest.
        if popover.isShown { sheet.refreshSize() }
    }

    private func updateStatusButton(_ snapshot: MemorySnapshot) {
        guard let button = statusItem.button else { return }
        let pressure = snapshot.pressure
        let percent = snapshot.percentRoundedUp
        if percent != renderedPercent || pressure != renderedPressure {
            renderedPercent = percent
            renderedPressure = pressure
            let text = Fmt.percent(snapshot.percent)
            button.image = MenuBarBadge.image(text: text, pressure: pressure)
            button.setAccessibilityLabel(
                MenuBarBadge.accessibilityDescription(text: text, pressure: pressure)
            )
            // Tooltip text costs a handful of ByteCountFormatter calls; only rebuild it together
            // with the badge, not on every sampling tick.
            button.toolTip = "内存 \(text)"
                + " · 已用 \(Fmt.bytes(snapshot.used)) / \(Fmt.bytes(snapshot.total))"
                + " · 交换 \(Fmt.bytes(snapshot.swapUsed))"
                + " · \(pressure.dot) \(pressure.label)"
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // A fresh scan per opening: the list is only valid for the moment the user looks at it.
        rescan()
        setSection(.main)
        refreshEverything()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installKeyMonitor()
    }

    private func closePopover() {
        removeKeyMonitor()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
        // Leaving the section open would show a stale list on the next opening; the main page is
        // also where the last verdict line lives.
        setSection(.main)
    }

    // MARK: - Sections

    private func setSection(_ section: PanelSheetView.Section) {
        sheet.setSection(section)
        popover.contentSize = sheet.preferredSize
    }

    private func showProcesses() {
        rescan()
        checkedKeys.removeAll()
        refreshProcessesCard()
        setSection(.processes)
        sheet.refreshSize()
    }

    private func showMain() {
        setSection(.main)
        refreshActionsCard()
        sheet.refreshSize()
    }

    // MARK: - Key handling

    /// Popover instead of menu means there is no `performKeyEquivalent` pass left for ⌘K / ⌘Q;
    /// a local monitor covers them while the popup is open.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:  // esc
            closePopover()
            return true
        case 40 where flags.contains(.command):  // ⌘K
            cleanNow()
            return true
        case 12 where flags.contains(.command):  // ⌘Q
            quit()
            return true
        default:
            return false
        }
    }

    // MARK: - Card state

    /// Pushes the current snapshot + state into the summary card. Cheap enough to call on every
    /// sampling tick.
    private func refreshPanel() {
        guard let snapshot else { return }
        panelCard.update(
            PanelCardView.Model(
                snapshot: snapshot,
                result: resultLine(),
                isCleaning: isCleaning
            )
        )
    }

    private func refreshEverything() {
        refreshPanel()
        refreshActionsCard()
        refreshProcessesCard()
        sheet.refreshSize()
    }

    private func refreshActionsCard() {
        let login: PanelActionsCard.LoginState
        switch LoginItem.status {
        case .enabled: login = .on
        case .requiresApproval: login = .requiresApproval
        case .notFound: login = .notFound
        default: login = .off
        }
        actionsCard.update(
            PanelActionsCard.Model(
                processCount: candidates.count,
                intervalSeconds: Prefs.refreshSeconds,
                login: login
            )
        )
    }

    private func rescan() {
        candidates = ProcessScanner.top(limit: 8)
        checkedKeys = checkedKeys.intersection(Set(candidates.map(\.key)))
    }

    private func refreshProcessesCard() {
        let total = candidates.reduce(UInt64(0)) { $0 + $1.totalResident }
        var rows: [PanelProcessesCard.Row] = []
        rows.reserveCapacity(candidates.count)
        for group in candidates {
            rows.append(
                PanelProcessesCard.Row(
                    key: group.key,
                    name: group.displayName,
                    bytes: Fmt.bytes(group.totalResident),
                    size: group.totalResident,
                    processCount: group.processCount,
                    checked: checkedKeys.contains(group.key)
                )
            )
        }
        processesCard.update(
            rows: rows,
            subtitle: candidates.isEmpty
                ? "暂无可结束的进程"
                : "\(candidates.count) 个应用 · 共 \(Fmt.bytes(total))",
            isBusy: isCleaning,
            selection: checkedKeys
        )
    }

    /// The one line under the button: `上次清理  已释放 297 MB      31 秒前`.
    ///
    /// Only the newest event is shown, and only its human-sized number — the full before/after
    /// report stays in the log (`CleanOutcome.detailText`) instead of the popup.
    private func resultLine() -> PanelCardView.ResultLine {
        if isCleaning {
            return PanelCardView.ResultLine(
                prefix: "上次清理",
                value: "正在清理…",
                tail: "",
                tone: .busy
            )
        }

        var events: [(line: PanelCardView.ResultLine, at: Date)] = []

        if let lastClean, let lastCleanAt {
            events.append((
                PanelCardView.ResultLine(
                    prefix: "上次清理",
                    value: lastClean.releaseSummary,
                    tail: Fmt.secondsAgo(lastCleanAt),
                    tone: lastClean.reclaimed ? .good : .idle
                ),
                lastCleanAt
            ))
        }

        if let lastKill {
            events.append((
                PanelCardView.ResultLine(
                    prefix: "已结束",
                    value: lastKill.value,
                    tail: Fmt.secondsAgo(lastKill.at),
                    tone: lastKill.tone
                ),
                lastKill.at
            ))
        }

        if let lastLoginIssue {
            events.append((
                PanelCardView.ResultLine(
                    prefix: "登录项",
                    value: lastLoginIssue.text,
                    tail: Fmt.secondsAgo(lastLoginIssue.at),
                    tone: .warn
                ),
                lastLoginIssue.at
            ))
        }

        guard let latest = events.max(by: { $0.at < $1.at }) else {
            return .placeholder
        }
        return latest.line
    }

    // MARK: - Processes

    private func toggleProcess(_ key: String) {
        if checkedKeys.contains(key) {
            checkedKeys.remove(key)
        } else {
            checkedKeys.insert(key)
        }
        refreshProcessesCard()
        sheet.refreshSize()
    }

    /// Every process of every checked app. Helpers are terminated one by one after the main
    /// process, so a browser cannot respawn a renderer while we are still walking the list.
    private func victimsForChecked() -> [VictimProcess] {
        candidates
            .filter { checkedKeys.contains($0.key) }
            .flatMap { group in
                group.pids.map { VictimProcess(pid: $0, name: group.displayName) }
            }
    }

    private func checkedDisplayNames() -> [String] {
        candidates.filter { checkedKeys.contains($0.key) }.map { $0.displayName }
    }

    /// Graceful quit for real apps (their save sheet can appear), `SIGTERM` for plain processes.
    nonisolated static func gracefulTerminate(_ pid: pid_t) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.terminate()
        }
        return kill(pid, SIGTERM) == 0
    }

    // MARK: - Actions

    /// The one-click action keeps the popup open: the button shows "正在清理…" and the result line
    /// underneath is replaced in place when the pipeline finishes.
    private func cleanNow() {
        guard !isCleaning else { return }
        isCleaning = true
        refreshPanel()
        refreshProcessesCard()
        sheet.refreshSize()

        let victims = victimsForChecked()
        let balloonMB = Prefs.balloonMB
        let executablePath = AppInfo.executablePath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Reclaimer.clean(
                balloonMB: balloonMB,
                victims: victims,
                executablePath: executablePath,
                graceful: StatusItemController.gracefulTerminate
            )
            guard let self else { return }
            DispatchQueue.main.async {
                self.isCleaning = false
                self.lastClean = outcome
                self.lastCleanAt = Date()
                self.checkedKeys.removeAll()
                self.rescan()
                self.refreshActionsCard()
                self.refreshProcessesCard()
                self.apply(MemoryStats.sample())
                self.sheet.refreshSize()
            }
        }
    }

    private func killSelected() {
        let victims = victimsForChecked()
        guard !victims.isEmpty else { return }
        let labels = checkedDisplayNames()

        // Stay in the popup: the verdict line on the main page replaces whatever it showed before,
        // so the user sees the outcome without re-opening anything.
        setSection(.main)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Reclaimer.terminate(victims, graceful: StatusItemController.gracefulTerminate)
            guard let self else { return }
            DispatchQueue.main.async {
                self.checkedKeys.removeAll()
                if result.stuck.isEmpty {
                    self.lastKill = KillEvent(
                        value: Self.summary(for: labels, fallbackCount: victims.count, succeeded: true),
                        tone: .good,
                        at: Date()
                    )
                } else {
                    self.lastKill = KillEvent(
                        value: Self.summary(for: result.stuck, fallbackCount: result.stuck.count, succeeded: false),
                        tone: .warn,
                        at: Date()
                    )
                }
                Log.info("terminate selected ended=\(result.terminated) stuck=\(result.stuck)")
                self.rescan()
                self.refreshActionsCard()
                self.refreshProcessesCard()
                self.apply(MemoryStats.sample())
                self.sheet.refreshSize()
            }
        }
    }

    /// One short phrase for the verdict line: a single name, otherwise the number of apps.
    private static func summary(
        for names: [String],
        fallbackCount: Int,
        succeeded: Bool
    ) -> String {
        let verb = succeeded ? "已结束" : "未能结束"
        guard let first = names.first else { return "\(verb) \(fallbackCount) 个" }
        let short = first.count > 10 ? String(first.prefix(10)) + "…" : first
        return names.count > 1 ? "\(verb) \(names.count) 个应用" : "\(verb) \(short)"
    }

    private func applyInterval(_ seconds: Int) {
        Prefs.refreshSeconds = seconds
        sampler?.setInterval(Prefs.refreshInterval)
        refreshActionsCard()
        sheet.refreshSize()
    }

    private func toggleLoginItem() {
        let enable = !LoginItem.isEnabled
        LoginItem.apply(enabled: enable)
        if enable, LoginItem.status != .enabled {
            lastLoginIssue = ("未能开启：\(LoginItem.statusDescription)", Date())
        } else {
            lastLoginIssue = nil
        }
        refreshActionsCard()
        refreshPanel()
        Log.info("login item toggle enable=\(enable) status=\(LoginItem.statusDescription)")
        sheet.refreshSize()
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Self test state

    private enum SelfTestState {
        case idle, cleaning, killing
    }

    private var selfTestState: SelfTestState = .idle
    private var selfTestTimer: Timer?
    private var selfTestFailures: [String] = []
    private var selfTestBefore: MemorySnapshot?
    private var selfTestChild: pid_t = 0
    private var selfTestDeadline = Date()
    /// Absolute cap for the whole self test. A stage that never produces its result must fail the
    /// run instead of leaving `--selftest` spinning forever (and the terminal waiting on it).
    private var selfTestHardDeadline = Date()
    private var selfTestOriginalInterval = Prefs.defaultRefreshSeconds
}

// MARK: - Self test (`MemBar --selftest`)

extension StatusItemController {
    /// Upper bound for the whole self test, comfortably below the 60 s build budget. A staged test
    /// must always terminate; hanging is worse than failing.
    static let selfTestLimit: TimeInterval = 55

    /// Drives the very same actions the popup calls and prints a PASS/FAIL report.
    /// A timer walks the stages because the production actions finish on the main queue.
    func runSelfTest() {
        var failures: [String] = []
        selfTestOriginalInterval = Prefs.refreshSeconds
        selfTestHardDeadline = Date().addingTimeInterval(Self.selfTestLimit)
        apply(MemoryStats.sample())
        print("\(AppInfo.name) \(AppInfo.version) 自检")
        print("菜单栏徽章: \(statusItem.button?.image?.size.debugDescription ?? "无")"
            + " · 宽度 \(statusItem.length)"
            + " · 压力 \(snapshot?.pressure.label ?? "无")")
        print("菜单栏项可见: \(statusItem.isVisible) · 按钮帧: \(statusItem.button?.window?.frame.debugDescription ?? "无")")
        if !statusItem.isVisible { selfTestFail("状态栏项不可见") }
        if statusItem.button?.image == nil { failures.append("菜单栏图标缺失") }
        if statusItem.menu != nil { selfTestFail("状态栏项仍然挂着菜单，点击会被菜单吃掉") }

        // The popup is a popover with a real view hierarchy: no menu items to inspect, and no
        // cancelTracking / re-open dance to get wrong.
        refreshEverything()
        print("弹窗结构: \(Int(sheet.frame.width))×\(Int(sheet.frame.height))"
            + " · 面板 \(Int(panelCard.frame.height))pt"
            + " · 动作 \(Int(actionsCard.frame.height))pt"
            + " · 高占用 \(Int(processesCard.frame.height))pt")
        if sheet.panelCard !== panelCard { selfTestFail("面板卡片没有挂到 sheet 上") }
        if popover.contentViewController?.view !== sheet {
            selfTestFail("sheet 不是 popover 的内容视图")
        }
        if popover.contentSize.width != sheet.preferredSize.width {
            selfTestFail("popover 宽度没有跟随 sheet：\(popover.contentSize) vs \(sheet.preferredSize)")
        }
        print("面板内容:")
        for line in panelCard.renderedText.split(separator: "\n") { print("  | \(line)") }
        print("动作卡片内容:")
        for line in actionsCard.renderedText.split(separator: "\n") { print("  | \(line)") }

        sheet.layoutSubtreeIfNeeded()
        panelCard.layoutSubtreeIfNeeded()
        actionsCard.layoutSubtreeIfNeeded()
        if drawProbe(sheet) { print("离屏绘制: 整张 sheet OK") }
        if drawProbe(panelCard) { print("离屏绘制: 内存面板 OK") }
        if drawProbe(actionsCard) { print("离屏绘制: 动作卡片 OK") }

        if panelCard.model == nil { selfTestFail("面板卡片没有模型") }
        if panelCard.frame.width != PanelCardView.Layout.width { selfTestFail("面板宽度异常") }
        if panelCard.frame.height < 200 { selfTestFail("面板高度异常: \(panelCard.frame.height)") }
        if panelCard.cleanButton.frame.height != PanelCardView.Layout.button {
            selfTestFail("一键清理按钮高度异常")
        }
        let rendered = panelCard.renderedText
        if !rendered.contains("%") || !rendered.contains("/") {
            failures.append("摘要行文案异常: \(rendered)")
        }
        if !rendered.contains("交换") { failures.append("交换行缺失") }
        if !rendered.contains("上次清理") { failures.append("结果行文案异常") }
        // The verdict line must be one short phrase, not the old before/after report.
        if rendered.contains("→") || rendered.contains("用时") {
            selfTestFail("结果行仍然是啰嗦的前后对比")
        }
        if panelCard.cleanButton.title != "⚡ 一键清理" {
            selfTestFail("一键清理按钮标题异常: \(panelCard.cleanButton.title)")
        }
        if !actionsCard.renderedText.contains("高占用应用") {
            selfTestFail("动作卡片缺少高占用应用行")
        }
        for seconds in Prefs.refreshOptions where !actionsCard.renderedText.contains("\(seconds) 秒") {
            selfTestFail("刷新间隔缺少 \(seconds) 秒档")
        }
        if actionsCard.model?.intervalSeconds != Prefs.refreshSeconds {
            selfTestFail("动作卡片没有反映当前刷新间隔")
        }
        if actionsCard.model?.processCount != candidates.count {
            selfTestFail("动作卡片的进程数异常")
        }

        // ⌘K must still reach the clean action without a menu in the middle.
        if !handleKey(keyEvent(40, flags: .command)) {
            selfTestFail("⌘K 没有被处理")
        }
        // Esc closes the popup; with the popover closed that is a no-op, so only the routing matters.
        if !handleKey(keyEvent(53, flags: [])) {
            selfTestFail("esc 没有被处理")
        }

        // Section switching: the process list replaces the action rows, and back restores them.
        showProcesses()
        print("高占用应用内容:")
        for line in processesCard.renderedText.split(separator: "\n") { print("  | \(line)") }
        if sheet.section != .processes { selfTestFail("没有切换到高占用应用") }
        if actionsCard.isHidden == false { selfTestFail("高占用应用下动作卡片仍然可见") }
        if processesCard.isHidden { selfTestFail("高占用应用下进程列表不可见") }
        if processesCard.frame.width != PanelCardView.Layout.width {
            selfTestFail("高占用列表宽度异常: \(processesCard.frame.width)")
        }
        if processesCard.rows.isEmpty { selfTestFail("高占用列表为空") }
        // Ranked list, one column grid: sizes are non-increasing and every row sits inside the card.
        let sizes = processesCard.rows.map(\.size)
        if sizes != sizes.sorted(by: >) { selfTestFail("高占用列表没有按占用从大到小排序") }
        for row in processesCard.rows {
            if row.size == 0 { selfTestFail("\(row.name) 的占用为 0") }
        }
        sheet.layoutSubtreeIfNeeded()
        processesCard.layoutSubtreeIfNeeded()
        if processesCard.isKillAvailable { selfTestFail("未勾选时不应出现结束按钮") }
        if !processesCard.killButton.isHidden { selfTestFail("未勾选时结束按钮应隐藏") }
        // Dynamic window: no footer at all until something is checked, so the card is shorter and
        // the button has no frame to draw into.
        if processesCard.killButton.frame != .zero {
            selfTestFail("未勾选时结束按钮仍有布局帧: \(processesCard.killButton.frame)")
        }
        if drawProbe(processesCard) { print("离屏绘制: 高占用列表 OK") }
        showMain()
        if sheet.section != .main { selfTestFail("没有返回主面板") }
        if !processesCard.isHidden { selfTestFail("返回后高占用列表仍然可见") }
        if actionsCard.isHidden { selfTestFail("返回后动作卡片没有恢复") }

        // Pressure rendering: a synthetic "almost nothing reclaimable" snapshot must repaint the
        // badge with the critical colour, and going back must restore the calm colour.
        let criticalSnapshot = MemoryMath.snapshot(
            pages: VMPageCounts(
                free: 0, active: 9_000, inactive: 500, wired: 500,
                speculative: 0, purgeable: 0, compressed: 0
            ),
            pageSize: 16_384,
            total: 10_000 * 16_384,
            swapTotal: 0,
            swapUsed: 0
        )
        apply(criticalSnapshot)
        print("紧张渲染: \(criticalSnapshot.pressure.dot) \(criticalSnapshot.pressure.label)"
            + " 徽章=\(statusItem.button?.image?.size.debugDescription ?? "无")"
            + " 宽度=\(statusItem.length)")
        if criticalSnapshot.pressure != .critical { selfTestFail("合成快照未判为紧张") }
        if statusItem.button?.image !== MenuBarBadge.image(
            text: Fmt.percent(criticalSnapshot.percent),
            pressure: .critical
        ) {
            selfTestFail("紧张状态未使用红色徽章")
        }
        if abs(statusItem.length - MenuBarBadge.fixedWidth) > 0.5 {
            selfTestFail("状态栏项宽度不是固定值: \(statusItem.length)")
        }
        apply(MemoryStats.sample())
        print("恢复正常: 徽章=\(statusItem.button?.image?.size.debugDescription ?? "无")"
            + " 压力=\(snapshot?.pressure.label ?? "无")")
        if statusItem.button?.image === MenuBarBadge.image(
            text: Fmt.percent(snapshot?.percent ?? 0),
            pressure: .critical
        ) {
            selfTestFail("恢复正常后徽章仍为紧张配色")
        }

        // Refresh-interval switching.
        applyInterval(2)
        if sampler?.interval != 2 { selfTestFail("刷新间隔未生效") }
        if actionsCard.model?.intervalSeconds != 2 {
            selfTestFail("动作卡片未跟随刷新间隔")
        }
        applyInterval(selfTestOriginalInterval)
        print("偏好切换: 刷新→2s 再回到 \(selfTestOriginalInterval)s")

        // Badge rendering: one cached image per (text, pressure) pair, identical objects for the
        // same pair, and a distinct image per level so the colour really changes.
        let sampleText = "42%"
        let normalBadge = MenuBarBadge.image(text: sampleText, pressure: .normal)
        let elevatedBadge = MenuBarBadge.image(text: sampleText, pressure: .elevated)
        let criticalBadge = MenuBarBadge.image(text: sampleText, pressure: .critical)
        print("徽章缓存: 相同入参同一对象=\(normalBadge === MenuBarBadge.image(text: sampleText, pressure: .normal))"
            + " · 三种等级互不相同=\(normalBadge !== elevatedBadge && elevatedBadge !== criticalBadge)"
            + " · 尺寸=\(normalBadge.size.debugDescription)")
        if normalBadge !== MenuBarBadge.image(text: sampleText, pressure: .normal) {
            selfTestFail("徽章未按 (文字, 等级) 缓存")
        }
        if normalBadge === elevatedBadge || elevatedBadge === criticalBadge || normalBadge === criticalBadge {
            selfTestFail("不同压力等级共用了同一徽章图片")
        }
        for pressure in MemoryPressure.allCases {
            let badge = MenuBarBadge.image(text: "100%", pressure: pressure)
            if abs(badge.size.width - MenuBarBadge.fixedWidth) > 0.5
                || abs(badge.size.height - MenuBarBadge.height) > 0.5 {
                selfTestFail("徽章尺寸不固定: \(badge.size) @\(pressure.label)")
            }
        }

        selfTestFailures = failures
        selfTestBefore = MemoryStats.sample()

        // Stage 1: the production one-click action.
        cleanNow()
        selfTestState = .cleaning
        selfTestDeadline = Date().addingTimeInterval(20)

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.selfTestTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        selfTestTimer = timer
    }

    private func selfTestTick() {
        if Date() > selfTestHardDeadline {
            selfTestFail("自检整体超时（\(Int(Self.selfTestLimit))s）")
            if selfTestChild != 0, kill(selfTestChild, 0) == 0 { kill(selfTestChild, SIGKILL) }
            finishSelfTest()
            return
        }
        switch selfTestState {
        case .cleaning:
            if isCleaning {
                if Date() > selfTestDeadline {
                    selfTestFail("一键清理超时（20s）")
                    finishSelfTest()
                }
                return
            }
            if let outcome = lastClean {
                print("一键清理: \(outcome.detailText)")
                print("  结果行文案: \(outcome.releaseSummary)")
                print("  之前 free=\(Fmt.bytes(outcome.before.free)) compressed=\(Fmt.bytes(outcome.before.compressed))")
                print("  之后 free=\(Fmt.bytes(outcome.after.free)) compressed=\(Fmt.bytes(outcome.after.compressed))")
                print("面板结果行（清理后）:")
                for line in panelCard.renderedText.split(separator: "\n").suffix(1) {
                    print("  | \(line)")
                }
                if !outcome.balloonRan { selfTestFail("气球子进程未执行") }
                if !panelCard.renderedText.contains(outcome.releaseSummary) {
                    selfTestFail("结果行没有显示释放量")
                }
                if panelCard.cleanButton.title != "⚡ 一键清理" {
                    selfTestFail("清理后按钮标题未恢复")
                }
                if let before = selfTestBefore {
                    let delta = Int64(outcome.after.free) - Int64(before.free)
                    print("清理前后空闲变化: \(Fmt.deltaBytes(delta))")
                }
            } else {
                selfTestFail("一键清理没有产出结果")
            }

            guard let child = spawnSleeper() else {
                selfTestFail("无法启动测试进程")
                finishSelfTest()
                return
            }
            selfTestChild = child
            let sleeperGroup = AppGroup(
                key: "selftest-sleeper",
                displayName: "selftest-sleeper",
                totalResident: 1,
                pids: [child],
                isApplication: false
            )
            // `showProcesses()` rescans, and a rescan would throw the injected test process away —
            // switch section first, then inject, so the row survives into the rendered list.
            showProcesses()
            candidates.insert(sleeperGroup, at: 0)
            // Measure with the injected row present but unchecked, so the only difference between
            // the two heights is the footer block itself.
            checkedKeys = []
            refreshProcessesCard()
            sheet.refreshSize()
            processesCard.layoutSubtreeIfNeeded()
            let heightWithoutButton = processesCard.frame.height
            checkedKeys = [sleeperGroup.key]
            refreshProcessesCard()
            sheet.refreshSize()
            // Not on screen, so nothing layouts the card on its own; do it before measuring.
            processesCard.layoutSubtreeIfNeeded()
            print("高占用列表（勾选后）:")
            for line in processesCard.renderedText.split(separator: "\n") { print("  | \(line)") }
            if !processesCard.isKillAvailable || processesCard.killButton.isHidden {
                selfTestFail("勾选后应出现可用的结束按钮")
            }
            if processesCard.killButton.frame.height != PanelProcessesCard.Layout.footer {
                selfTestFail("结束按钮高度异常")
            }
            // Dynamic window: the same list must be exactly one footer block taller once the button
            // exists, and the button must sit inside the card.
            let expectedGrowth = PanelProcessesCard.Layout.footerGap
                + PanelProcessesCard.Layout.footer
            if abs(processesCard.frame.height - heightWithoutButton - expectedGrowth) > 0.5 {
                selfTestFail(
                    "勾选后卡片高度没有随按钮变化："
                        + "\(heightWithoutButton) → \(processesCard.frame.height)，"
                        + "期望 +\(expectedGrowth)"
                )
            }
            if processesCard.killButton.frame.maxY > processesCard.bounds.maxY {
                selfTestFail("结束按钮超出卡片范围")
            }
            killSelected()
            selfTestState = .killing
            selfTestDeadline = Date().addingTimeInterval(10)

        case .killing:
            if lastKill == nil {
                if Date() > selfTestDeadline {
                    selfTestFail("结束进程超时（10s）")
                    if selfTestChild != 0 { kill(selfTestChild, SIGKILL) }
                    finishSelfTest()
                }
                return
            }
            print("结束进程: \(lastKill?.value ?? "<无结果>")")
            if kill(selfTestChild, 0) == 0 {
                selfTestFail("测试进程仍在运行")
                kill(selfTestChild, SIGKILL)
            }
            if processesCard.isKillAvailable { selfTestFail("结束后应回到提示行") }
            if sheet.section != .main { selfTestFail("结束后应回到主面板") }
            finishSelfTest()

        case .idle:
            return
        }
    }

    private func finishSelfTest() {
        selfTestTimer?.invalidate()
        selfTestTimer = nil
        selfTestState = .idle
        // The test spawns `/bin/sleep 60`; a FAIL path must still reap it, otherwise an orphan
        // survives the run.
        if selfTestChild != 0 {
            if kill(selfTestChild, 0) == 0 { kill(selfTestChild, SIGKILL) }
            selfTestChild = 0
        }

        // Login item round trip (only meaningful for the installed copy, which is the one
        // Background Task Management tracks; the pref is restored afterwards).
        if Bundle.main.bundleURL.path.hasPrefix("/Applications") {
            let wasEnabled = LoginItem.isEnabled
            _ = LoginItem.apply(enabled: false)
            usleep(400_000)
            let offStatus = LoginItem.status
            _ = LoginItem.apply(enabled: wasEnabled)
            usleep(400_000)
            print("登录项往返: 初始=\(wasEnabled) 关闭后=\(offStatus.rawValue) 恢复=\(LoginItem.isEnabled)")
            if wasEnabled, offStatus == .enabled { selfTestFail("登录项无法关闭") }
            if LoginItem.isEnabled != wasEnabled { selfTestFail("登录项状态未能恢复") }
            refreshActionsCard()
            if actionsCard.model?.login.isOn != LoginItem.isEnabled {
                selfTestFail("动作卡片未反映登录项状态")
            }
        } else {
            print("登录项往返: 跳过（未安装在 /Applications）")
        }

        Prefs.refreshSeconds = selfTestOriginalInterval
        if Prefs.refreshSeconds != selfTestOriginalInterval {
            selfTestFail("偏好设置未能恢复")
        }
        print("偏好: 刷新 \(Prefs.refreshSeconds)s · 登录项 \(LoginItem.statusDescription)")

        if selfTestFailures.isEmpty {
            print("自检结果: OK（0 项失败）")
            exit(0)
        }
        print("自检结果: FAIL（\(selfTestFailures.count) 项失败）")
        for failure in selfTestFailures { print("  ✗ \(failure)") }
        exit(1)
    }

    private func selfTestFail(_ message: String) {
        selfTestFailures.append(message)
    }

    private func keyEvent(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) ?? NSEvent()
    }

    /// Renders one card into an off-screen bitmap (selftest only, never on the user's screen).
    @discardableResult
    private func drawProbe(_ view: NSView) -> Bool {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width.rounded(.up)),
                pixelsHigh: Int(size.height.rounded(.up)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            selfTestFail("无法离屏绘制 \(type(of: view))")
            return false
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }

    private func spawnSleeper() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        do {
            try process.run()
        } catch {
            Log.error("selftest spawn failed: \(error.localizedDescription)")
            return nil
        }
        return process.processIdentifier
    }
}