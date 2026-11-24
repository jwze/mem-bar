import AppKit
import Darwin
import MemBarCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var sampler: Sampler?
    private var snapshot: MemorySnapshot?

    private var lastClean: CleanOutcome?
    private var lastCleanAt: Date?
    private var lastKill: (text: String, at: Date)?

    /// Last rendered menu-bar state; the system only redraws the bar when these change, so a
    /// 5 s tick that lands on the same percent/pressure must not touch the title again.
    private var renderedPercent = -1
    private var renderedPressure: MemoryPressure?

    private var isCleaning = false
    private var candidates: [AppGroup] = []
    /// Checked rows, keyed by `AppGroup.key` (bundle path or executable name) — not by pid,
    /// because one row covers several processes.
    private var checkedKeys: Set<String> = []
    /// Tab stop shared by every process row so their sizes form one right-aligned column.
    private var processColumnWidth: CGFloat = 0

    private let placeholderImage = MenuBarBadge.image(text: "–%", pressure: .normal)

    private let headlineItem = NSMenuItem()
    private let gaugeItem = NSMenuItem()
    private let legendItem = NSMenuItem()
    private let usedItem = NSMenuItem()
    private let cacheItem = NSMenuItem()
    private let compressedItem = NSMenuItem()
    private let swapItem = NSMenuItem()
    private let cleanItem = NSMenuItem()
    private let resultItem = NSMenuItem()
    private let processesItem = NSMenuItem()
    private let processesMenu = NSMenu()
    private let killSelectedItem = NSMenuItem()
    private let intervalItem = NSMenuItem()
    private let intervalMenu = NSMenu()
    private let loginItemToggle = NSMenuItem()
    private let quitItem = NSMenuItem()

    override init() {
        // Fixed width: a variable-length item forces the window server to re-lay-out the whole
        // menu bar on every percentage change, which dominates the app's CPU time. The badge is
        // sized for the widest label ("100%") and every state reuses that width.
        self.statusItem = NSStatusBar.system.statusItem(withLength: MenuBarBadge.fixedWidth)
        super.init()
        configureButton()
        configureMenu()
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
        statusItem.menu = menu
    }

    private func apply(_ snapshot: MemorySnapshot) {
        self.snapshot = snapshot
        updateStatusButton(snapshot)
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

    // MARK: - Menu construction

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        for item in [headlineItem, gaugeItem, legendItem, usedItem, cacheItem,
                     compressedItem, swapItem, resultItem] {
            item.isEnabled = false
            // A brand-new NSMenuItem carries no title and NSMenu paints the class name in its
            // place; every row must have one, even the image-only gauge.
            item.title = ""
        }
        menu.addItem(headlineItem)
        menu.addItem(gaugeItem)
        menu.addItem(legendItem)
        menu.addItem(.separator())
        menu.addItem(usedItem)
        menu.addItem(cacheItem)
        menu.addItem(compressedItem)
        menu.addItem(swapItem)
        menu.addItem(.separator())

        cleanItem.title = "⚡ 一键清理"
        cleanItem.target = self
        cleanItem.action = #selector(cleanNow)
        cleanItem.keyEquivalent = "k"
        cleanItem.keyEquivalentModifierMask = [.command]
        menu.addItem(cleanItem)
        menu.addItem(resultItem)

        processesItem.title = "高占用进程"
        processesItem.submenu = processesMenu
        processesMenu.autoenablesItems = false
        killSelectedItem.title = "结束选中进程 (0)"
        killSelectedItem.target = self
        killSelectedItem.action = #selector(killSelected)
        menu.addItem(processesItem)
        menu.addItem(.separator())

        intervalItem.title = "刷新间隔"
        intervalItem.submenu = intervalMenu
        intervalMenu.autoenablesItems = false
        for seconds in Prefs.refreshOptions {
            let item = NSMenuItem(
                title: "\(seconds) 秒",
                action: #selector(selectInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = seconds
            intervalMenu.addItem(item)
        }
        menu.addItem(intervalItem)

        loginItemToggle.title = "登录时自动启动"
        loginItemToggle.target = self
        loginItemToggle.action = #selector(toggleLoginItem)
        menu.addItem(loginItemToggle)
        menu.addItem(.separator())

        quitItem.title = "退出 MemBar"
        quitItem.target = self
        quitItem.action = #selector(quit)
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
    }

    private func updateInfoItems(_ snapshot: MemorySnapshot) {
        let pressure = snapshot.pressure

        headlineItem.attributedTitle = MenuStyle.headline(
            percent: Fmt.percent(snapshot.percent),
            used: Fmt.bytes(snapshot.used),
            total: Fmt.bytes(snapshot.total),
            pressure: pressure
        )

        gaugeItem.image = MenuStyle.compositionBarImage(
            used: snapshot.used,
            cache: snapshot.cache,
            free: snapshot.free,
            total: snapshot.total
        )
        legendItem.attributedTitle = MenuStyle.compositionLegend(
            used: snapshot.used,
            cache: snapshot.cache,
            free: snapshot.free,
            total: snapshot.total
        )

        let usedLabel = "已用 · \(pressure.dot) \(pressure.label)"
        let swapLabel = "交换 · 已用 \(Fmt.ratioPercent(snapshot.swapRatio))"
        let column = MenuStyle.columnWidth(for: [
            (usedLabel, Fmt.bytes(snapshot.used)),
            ("缓存", Fmt.bytes(snapshot.cache)),
            ("压缩", Fmt.bytes(snapshot.compressed)),
            (swapLabel, Fmt.bytes(snapshot.swapUsed) + " / " + Fmt.bytes(snapshot.swapTotal)),
        ])

        usedItem.attributedTitle = MenuStyle.row(
            usedLabel,
            value: Fmt.bytes(snapshot.used),
            valueColor: MenuStyle.color(for: pressure),
            columnWidth: column
        )
        cacheItem.attributedTitle = MenuStyle.row(
            "缓存", value: Fmt.bytes(snapshot.cache), columnWidth: column
        )
        compressedItem.attributedTitle = MenuStyle.row(
            "压缩", value: Fmt.bytes(snapshot.compressed), columnWidth: column
        )

        let swapColor: NSColor = snapshot.swapRatio > 0.8 ? .systemRed : .labelColor
        swapItem.attributedTitle = MenuStyle.row(
            swapLabel,
            value: "\(Fmt.bytes(snapshot.swapUsed)) / \(Fmt.bytes(snapshot.swapTotal))",
            valueColor: swapColor,
            columnWidth: column
        )

        resultItem.attributedTitle = MenuStyle.caption(resultText())
    }

    private func resultText() -> String {
        if isCleaning { return "正在清理…" }

        let cleanEvent: (text: String, at: Date)?
        if let lastClean, let lastCleanAt {
            cleanEvent = ("上次清理：" + lastClean.detailText, lastCleanAt)
        } else {
            cleanEvent = nil
        }

        if let kill = lastKill, let clean = cleanEvent {
            return kill.at > clean.at
                ? "\(kill.text) · \(Fmt.secondsAgo(kill.at))"
                : "\(clean.text) · \(Fmt.secondsAgo(clean.at))"
        }
        if let clean = cleanEvent {
            return "\(clean.text) · \(Fmt.secondsAgo(clean.at))"
        }
        if let kill = lastKill {
            return "\(kill.text) · \(Fmt.secondsAgo(kill.at))"
        }
        return "上次清理：尚未清理"
    }

    private func updateSubmenuChecks() {
        for item in intervalMenu.items {
            item.state = item.tag == Prefs.refreshSeconds ? .on : .off
        }

        let status = LoginItem.status
        loginItemToggle.state = status == .enabled ? .on : .off
        switch status {
        case .requiresApproval:
            loginItemToggle.title = "登录时自动启动（需在系统设置允许）"
        case .notFound:
            loginItemToggle.title = "登录时自动启动（请先安装到 /Applications）"
        default:
            loginItemToggle.title = "登录时自动启动"
        }
    }

    // MARK: - Process submenu

    private func rebuildProcessMenu() {
        candidates = ProcessScanner.top(limit: 8)
        checkedKeys = checkedKeys.intersection(Set(candidates.map { $0.key }))
        renderProcessItems()
    }

    /// Renders the submenu from the current `candidates` (no rescan), used by the menu and the self test.
    ///
    /// One row per app: every helper of a browser is folded into a single entry, and checking that
    /// entry means "quit this app", not "kill one random renderer".
    private func renderProcessItems() {
        processesMenu.removeAllItems()

        if candidates.isEmpty {
            let empty = NSMenuItem(title: "暂无可结束的进程", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            processesMenu.addItem(empty)
        } else {
            let column = MenuStyle.columnWidth(
                for: candidates.map {
                    (rowLabel(name: $0.displayName, processCount: $0.processCount),
                     Fmt.bytes($0.totalResident))
                }
            )
            processColumnWidth = column
            for group in candidates {
                let item = NSMenuItem(
                    title: MenuStyle.processRow(
                        name: group.displayName,
                        bytes: Fmt.bytes(group.totalResident),
                        processCount: group.processCount
                    ),
                    action: #selector(toggleProcess(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = 0
                item.representedObject = group.key
                item.toolTip = group.processCount > 1
                    ? "\(group.processCount) 个进程 · pids \(group.pids.map(String.init).joined(separator: ", "))"
                    : "pid \(group.pids.first.map(String.init) ?? "?")"
                item.state = checkedKeys.contains(group.key) ? .on : .off
                item.attributedTitle = MenuStyle.processAttributedTitle(
                    name: group.displayName,
                    bytes: Fmt.bytes(group.totalResident),
                    processCount: group.processCount,
                    checked: item.state == .on,
                    columnWidth: column
                )
                processesMenu.addItem(item)
            }
        }

        processesMenu.addItem(.separator())
        updateKillItem()
        processesMenu.addItem(killSelectedItem)
    }

    /// The left-hand text of a process row, i.e. everything before the tab that starts the column.
    private func rowLabel(name: String, processCount: Int) -> String {
        let suffix = processCount > 1 ? "  ·\(processCount)" : ""
        return name + suffix
    }

    private func updateKillItem() {
        let selected = candidates.filter { checkedKeys.contains($0.key) }
        killSelectedItem.title = "结束选中应用 (\(selected.count))"
        killSelectedItem.isEnabled = !selected.isEmpty && !isCleaning
    }

    /// The GUI app for a group, if any: used so quitting shows the app's own save sheet.
    private func runningApplication(for group: AppGroup) -> NSRunningApplication? {
        for pid in group.pids {
            if let app = NSRunningApplication(processIdentifier: pid) {
                return app
            }
        }
        return nil
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

    /// Graceful quit for real apps (their save sheet can appear), `SIGTERM` for plain processes.
    nonisolated static func gracefulTerminate(_ pid: pid_t) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.terminate()
        }
        return kill(pid, SIGTERM) == 0
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildProcessMenu()
        updateSubmenuChecks()
        if let snapshot {
            updateInfoItems(snapshot)
        }
    }

    // MARK: - Actions

    @objc private func cleanNow() {
        guard !isCleaning else { return }
        isCleaning = true
        cleanItem.title = "正在清理…"
        cleanItem.isEnabled = false
        killSelectedItem.isEnabled = false
        resultItem.title = resultText()

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
                self.cleanItem.title = "⚡ 一键清理"
                self.cleanItem.isEnabled = true
                self.lastClean = outcome
                self.lastCleanAt = Date()
                self.checkedKeys.removeAll()
                self.rebuildProcessMenu()
                self.apply(MemoryStats.sample())
                if let snapshot = self.snapshot { self.updateInfoItems(snapshot) }
            }
        }
    }

    @objc private func killSelected() {
        let victims = victimsForChecked()
        guard !victims.isEmpty else { return }
        let names = victims.map { $0.name }.joined(separator: "、")

        killSelectedItem.isEnabled = false
        killSelectedItem.title = "正在结束…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Reclaimer.terminate(victims, graceful: StatusItemController.gracefulTerminate)
            guard let self else { return }
            DispatchQueue.main.async {
                self.checkedKeys.removeAll()
                if result.stuck.isEmpty {
                    self.lastKill = ("上次结束：\(names) · 已结束", Date())
                } else {
                    self.lastKill = (
                        "未能结束：\(result.stuck.joined(separator: "、"))",
                        Date()
                    )
                }
                Log.info("terminate selected ended=\(result.terminated) stuck=\(result.stuck)")
                self.rebuildProcessMenu()
                self.apply(MemoryStats.sample())
                if let snapshot = self.snapshot { self.updateInfoItems(snapshot) }
            }
        }
    }

    @objc private func toggleProcess(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let checked: Bool
        if checkedKeys.contains(key) {
            checkedKeys.remove(key)
            checked = false
        } else {
            checkedKeys.insert(key)
            checked = true
        }
        sender.state = checked ? .on : .off
        if let group = candidates.first(where: { $0.key == key }) {
            sender.attributedTitle = MenuStyle.processAttributedTitle(
                name: group.displayName,
                bytes: Fmt.bytes(group.totalResident),
                processCount: group.processCount,
                checked: checked,
                columnWidth: processColumnWidth
            )
        }
        updateKillItem()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        Prefs.refreshSeconds = sender.tag
        sampler?.setInterval(Prefs.refreshInterval)
        updateSubmenuChecks()
    }

    @objc private func toggleLoginItem() {
        let enable = !LoginItem.isEnabled
        LoginItem.apply(enabled: enable)
        if enable, LoginItem.status != .enabled {
            lastKill = ("登录项未生效：\(LoginItem.statusDescription)", Date())
        }
        updateSubmenuChecks()
        resultItem.attributedTitle = MenuStyle.caption(resultText())
        Log.info("login item toggle enable=\(enable) status=\(LoginItem.statusDescription)")
    }

    @objc private func quit() {
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
    private var selfTestOriginalInterval = Prefs.defaultRefreshSeconds
}
// MARK: - Self test (`MemBar --selftest`)

extension StatusItemController {
    /// Drives the very same actions the menu items call and prints a PASS/FAIL report.
    /// A timer walks the stages because the production actions finish on the main queue.
    func runSelfTest() {
        var failures: [String] = []
        selfTestOriginalInterval = Prefs.refreshSeconds
        apply(MemoryStats.sample())
        print("\(AppInfo.name) \(AppInfo.version) 自检")
        print("菜单栏徽章: \(statusItem.button?.image?.size.debugDescription ?? "无")"
            + " · 宽度 \(statusItem.length)"
            + " · 压力 \(snapshot?.pressure.label ?? "无")")
        print("菜单栏项可见: \(statusItem.isVisible) · 按钮帧: \(statusItem.button?.window?.frame.debugDescription ?? "无")")
        if !statusItem.isVisible { selfTestFail("状态栏项不可见") }
        if statusItem.button?.image == nil { failures.append("菜单栏图标缺失") }

        menuWillOpen(menu)
        print("菜单结构:")
        for item in menu.items {
            let label = (item.attributedTitle?.length ?? 0) > 0 ? item.attributedTitle!.string : item.title
            print("  - \(item.isSeparatorItem ? "──" : label) enabled=\(item.isEnabled) state=\(item.state.rawValue)")
        }
        let headlineText = headlineItem.attributedTitle?.string ?? ""
        let swapText = swapItem.attributedTitle?.string ?? ""
        let resultTextValue = resultItem.attributedTitle?.string ?? ""
        if !headlineText.contains("%") || !headlineText.contains("/") {
            failures.append("摘要行文案异常: \(headlineText)")
        }
        if !swapText.contains("交换") { failures.append("交换行文案异常: \(swapText)") }
        if !resultTextValue.contains("上次清理") {
            failures.append("结果行文案异常: \(resultTextValue)")
        }
        if gaugeItem.image == nil { failures.append("构成条图片缺失") }
        if (legendItem.attributedTitle?.string ?? "").isEmpty { failures.append("图例为空") }
        if cleanItem.action == nil { failures.append("一键清理没有绑定 action") }
        if cleanItem.keyEquivalent != "k" { failures.append("一键清理缺少 ⌘K") }
        if processesItem.submenu == nil { failures.append("高占用进程没有子菜单") }
        if intervalItem.submenu?.items.count != Prefs.refreshOptions.count { failures.append("刷新间隔选项数量异常") }
        if killSelectedItem.isEnabled { failures.append("未勾选时「结束选中进程」应为禁用") }

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

        // Refresh-interval menu wiring.
        if let twoSeconds = intervalMenu.items.first(where: { $0.tag == 2 }) {
            selectInterval(twoSeconds)
            if sampler?.interval != 2 { selfTestFail("刷新间隔未生效") }
            if intervalMenu.items.first(where: { $0.tag == 2 })?.state != .on {
                selfTestFail("刷新间隔勾选未更新")
            }
        }
        if let defaultInterval = intervalMenu.items.first(where: { $0.tag == selfTestOriginalInterval }) {
            selectInterval(defaultInterval)
        }
        print("偏好切换: 刷新→2s 再回到 \(selfTestOriginalInterval)s")
        if let quitMenu = menu.items.first(where: { $0 === quitItem }), quitMenu.keyEquivalent != "q" {
            selfTestFail("退出缺少 ⌘Q")
        }

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
        switch selfTestState {
        case .cleaning:
            if isCleaning {
                if Date() > selfTestDeadline { selfTestFail("一键清理超时（20s）") }
                return
            }
            if let outcome = lastClean {
                print("一键清理: \(outcome.detailText)")
                print("  之前 free=\(Fmt.bytes(outcome.before.free)) compressed=\(Fmt.bytes(outcome.before.compressed))")
                print("  之后 free=\(Fmt.bytes(outcome.after.free)) compressed=\(Fmt.bytes(outcome.after.compressed))")
                print("菜单栏徽章（清理后）: \(statusItem.button?.image?.size.debugDescription ?? "无")")
                if !outcome.balloonRan { selfTestFail("气球子进程未执行") }
                if !(resultItem.attributedTitle?.string ?? "").contains("上次清理") {
                    selfTestFail("结果行没有更新")
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
            rebuildProcessMenu()
            let sleeperGroup = AppGroup(
                key: "selftest-sleeper",
                displayName: "selftest-sleeper",
                totalResident: 1,
                pids: [child],
                isApplication: false
            )
            candidates.insert(sleeperGroup, at: 0)
            checkedKeys = [sleeperGroup.key]
            renderProcessItems()
            print("高占用进程子菜单:")
            for item in processesMenu.items {
                print("  - \(item.isSeparatorItem ? "──" : item.title) state=\(item.state.rawValue) enabled=\(item.isEnabled)")
            }
            if !killSelectedItem.isEnabled { selfTestFail("勾选后「结束选中进程」应为可用") }
            killSelected()
            selfTestState = .killing
            selfTestDeadline = Date().addingTimeInterval(10)

        case .killing:
            if lastKill == nil {
                if Date() > selfTestDeadline { selfTestFail("结束进程超时（10s）") }
                return
            }
            print("结束进程: \(lastKill?.text ?? "<无结果>")")
            if kill(selfTestChild, 0) == 0 {
                selfTestFail("测试进程仍在运行")
                kill(selfTestChild, SIGKILL)
            }
            if killSelectedItem.isEnabled { selfTestFail("结束后「结束选中进程」应回到禁用") }
            finishSelfTest()

        case .idle:
            return
        }
    }

    private func finishSelfTest() {
        selfTestTimer?.invalidate()
        selfTestTimer = nil
        selfTestState = .idle

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
