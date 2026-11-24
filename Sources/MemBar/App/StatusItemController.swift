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
    private var candidates: [ProcessSample] = []
    private var checkedPIDs: Set<pid_t> = []

    private let idleImage: NSImage? = StatusItemController.symbol("memorychip")
    private let criticalImage: NSImage? = StatusItemController.symbol("memorychip.fill")

    private let headlineItem = NSMenuItem()
    private let infoItem = NSMenuItem()
    private let swapItem = NSMenuItem()
    private let cleanItem = NSMenuItem()
    private let resultItem = NSMenuItem()
    private let processesItem = NSMenuItem()
    private let processesMenu = NSMenu()
    private let killSelectedItem = NSMenuItem()
    private let intervalItem = NSMenuItem()
    private let intervalMenu = NSMenu()
    private let balloonItem = NSMenuItem()
    private let balloonMenu = NSMenu()
    private let loginItemToggle = NSMenuItem()
    private let quitItem = NSMenuItem()

    override init() {
        // Fixed width: a variable-length item forces the window server to re-lay-out the whole
        // menu bar on every percentage change, which dominates the app's CPU time.
        self.statusItem = NSStatusBar.system.statusItem(withLength: 64)
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

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MemBar 内存监控")
        image?.isTemplate = true
        return image
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = idleImage
        button.imagePosition = .imageLeading
        button.title = " –%"
        button.toolTip = "MemBar 内存监控"
        statusItem.menu = menu
    }

    private func statusTitle(_ text: String, pressure: MemoryPressure) -> NSAttributedString {
        let weight: NSFont.Weight = pressure.isCritical ? .semibold : .regular
        let color: NSColor = pressure.isCritical ? .systemRed : .labelColor
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight),
                .foregroundColor: color,
                .baselineOffset: 0.5,
            ]
        )
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
            button.image = pressure.isCritical ? criticalImage : idleImage
            if pressure.isCritical {
                button.attributedTitle = statusTitle(" \(Fmt.percent(snapshot.percent))", pressure: pressure)
            } else {
                // A plain title is far cheaper to re-lay-out than an attributed one, and the menu
                // bar already renders it with the system font.
                button.title = " \(Fmt.percent(snapshot.percent))"
            }
            // Tooltip text costs a handful of ByteCountFormatter calls; only rebuild it together
            // with the title, not on every sampling tick.
            button.toolTip = "内存 \(Fmt.percent(snapshot.percent))"
                + " · 已用 \(Fmt.bytes(snapshot.used)) / \(Fmt.bytes(snapshot.total))"
                + " · 交换 \(Fmt.bytes(snapshot.swapUsed))"
                + " · \(pressure.dot) \(pressure.label)"
        }
    }

    // MARK: - Menu construction

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        for item in [headlineItem, infoItem, swapItem, resultItem] {
            item.isEnabled = false
        }
        menu.addItem(headlineItem)
        menu.addItem(infoItem)
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

        balloonItem.title = "回收强度"
        balloonItem.submenu = balloonMenu
        balloonMenu.autoenablesItems = false
        for megabytes in Prefs.balloonOptions {
            let item = NSMenuItem(
                title: "\(megabytes) MB",
                action: #selector(selectBalloon(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = megabytes
            balloonMenu.addItem(item)
        }
        menu.addItem(balloonItem)

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
        headlineItem.title = "内存 \(Fmt.percent(snapshot.percent))"
            + " · 已用 \(Fmt.bytes(snapshot.used)) / \(Fmt.bytes(snapshot.total))"
        infoItem.title = "空闲 \(Fmt.bytes(snapshot.free))"
            + " · 缓存 \(Fmt.bytes(snapshot.cache))"
            + " · 压缩 \(Fmt.bytes(snapshot.compressed))"
        swapItem.title = "交换 \(Fmt.bytes(snapshot.swapUsed)) / \(Fmt.bytes(snapshot.swapTotal))"
            + " · \(pressure.dot) \(pressure.label)"
        resultItem.title = resultText()
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
        for item in balloonMenu.items {
            item.state = item.tag == Prefs.balloonMB ? .on : .off
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
        checkedPIDs = checkedPIDs.intersection(Set(candidates.map { $0.pid }))
        renderProcessItems()
    }

    /// Renders the submenu from the current `candidates` (no rescan), used by the menu and the self test.
    private func renderProcessItems() {
        processesMenu.removeAllItems()

        if candidates.isEmpty {
            let empty = NSMenuItem(title: "暂无可结束的进程", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            processesMenu.addItem(empty)
        } else {
            for sample in candidates {
                let item = NSMenuItem(
                    title: "\(displayName(for: sample))  \(Fmt.bytes(sample.resident))",
                    action: #selector(toggleProcess(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = Int(sample.pid)
                item.toolTip = "pid \(sample.pid)"
                item.state = checkedPIDs.contains(sample.pid) ? .on : .off
                processesMenu.addItem(item)
            }
        }

        processesMenu.addItem(.separator())
        updateKillItem()
        processesMenu.addItem(killSelectedItem)
    }

    private func updateKillItem() {
        killSelectedItem.title = "结束选中进程 (\(checkedPIDs.count))"
        killSelectedItem.isEnabled = !checkedPIDs.isEmpty && !isCleaning
    }

    private func displayName(for sample: ProcessSample) -> String {
        if let app = NSRunningApplication(processIdentifier: sample.pid),
           let name = app.localizedName,
           !name.isEmpty {
            return name
        }
        return sample.name
    }

    private func victimsForChecked() -> [VictimProcess] {
        candidates
            .filter { checkedPIDs.contains($0.pid) }
            .map { VictimProcess(pid: $0.pid, name: displayName(for: $0)) }
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
                self.checkedPIDs.removeAll()
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
                self.checkedPIDs.removeAll()
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
        let pid = pid_t(sender.tag)
        if sender.state == .on {
            sender.state = .off
            checkedPIDs.remove(pid)
        } else {
            sender.state = .on
            checkedPIDs.insert(pid)
        }
        updateKillItem()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        Prefs.refreshSeconds = sender.tag
        sampler?.setInterval(Prefs.refreshInterval)
        updateSubmenuChecks()
    }

    @objc private func selectBalloon(_ sender: NSMenuItem) {
        Prefs.balloonMB = sender.tag
        updateSubmenuChecks()
    }

    @objc private func toggleLoginItem() {
        let enable = !LoginItem.isEnabled
        LoginItem.apply(enabled: enable)
        if enable, LoginItem.status != .enabled {
            lastKill = ("登录项未生效：\(LoginItem.statusDescription)", Date())
        }
        updateSubmenuChecks()
        resultItem.title = resultText()
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
    private var selfTestOriginalBalloon = Prefs.defaultBalloonMB
}
// MARK: - Self test (`MemBar --selftest`)

extension StatusItemController {
    /// Drives the very same actions the menu items call and prints a PASS/FAIL report.
    /// A timer walks the stages because the production actions finish on the main queue.
    func runSelfTest() {
        var failures: [String] = []
        selfTestOriginalInterval = Prefs.refreshSeconds
        selfTestOriginalBalloon = Prefs.balloonMB
        apply(MemoryStats.sample())
        print("\(AppInfo.name) \(AppInfo.version) 自检")
        print("菜单栏文字: \(statusItem.button?.attributedTitle.string ?? "<空>")")
        print("菜单栏项可见: \(statusItem.isVisible) · 按钮帧: \(statusItem.button?.window?.frame.debugDescription ?? "无")")
        if !statusItem.isVisible { selfTestFail("状态栏项不可见") }
        if statusItem.button?.image == nil { failures.append("菜单栏图标缺失") }

        menuWillOpen(menu)
        print("菜单结构:")
        for item in menu.items {
            print("  - \(item.isSeparatorItem ? "──" : item.title) enabled=\(item.isEnabled) state=\(item.state.rawValue)")
        }
        if !headlineItem.title.contains("内存") { failures.append("摘要行文案异常: \(headlineItem.title)") }
        if !swapItem.title.contains("交换") { failures.append("交换行文案异常: \(swapItem.title)") }
        if !resultItem.title.contains("上次清理") { failures.append("结果行文案异常: \(resultItem.title)") }
        if cleanItem.action == nil { failures.append("一键清理没有绑定 action") }
        if cleanItem.keyEquivalent != "k" { failures.append("一键清理缺少 ⌘K") }
        if processesItem.submenu == nil { failures.append("高占用进程没有子菜单") }
        if intervalItem.submenu?.items.count != Prefs.refreshOptions.count { failures.append("刷新间隔选项数量异常") }
        if balloonItem.submenu?.items.count != Prefs.balloonOptions.count { failures.append("回收强度选项数量异常") }
        if killSelectedItem.isEnabled { failures.append("未勾选时「结束选中进程」应为禁用") }

        // Pressure rendering: a synthetic "almost nothing reclaimable" snapshot must turn the
        // menu-bar title red and switch to the filled icon.
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
        let titleColor = statusItem.button?.attributedTitle.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        print("紧张渲染: \(criticalSnapshot.pressure.dot) \(criticalSnapshot.pressure.label)"
            + " 文字=\(statusItem.button?.attributedTitle.string ?? "")"
            + " 颜色=\(titleColor.map { $0 == .systemRed ? "红" : "\($0)" } ?? "无")")
        if criticalSnapshot.pressure != .critical { selfTestFail("合成快照未判为紧张") }
        if titleColor != .systemRed { selfTestFail("紧张状态未使用红色文字") }
        if statusItem.button?.image !== criticalImage { selfTestFail("紧张状态未使用实心图标") }
        apply(MemoryStats.sample())
        let restoredColor = statusItem.button?.attributedTitle.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        print("恢复正常: 文字=\(statusItem.button?.title ?? "") 颜色=\(restoredColor == .systemRed ? "红" : "默认")")
        if restoredColor == .systemRed { selfTestFail("恢复正常后文字仍为红色") }

        // Interval / balloon menu wiring.
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
        if let bigBalloonItem = balloonMenu.items.first(where: { $0.tag == 128 }) {
            selectBalloon(bigBalloonItem)
            if Prefs.balloonMB != 128 { selfTestFail("回收强度未持久化") }
        }
        if let defaultBalloon = balloonMenu.items.first(where: { $0.tag == selfTestOriginalBalloon }) {
            selectBalloon(defaultBalloon)
        }
        print("偏好切换: 刷新→2s 再回到 \(selfTestOriginalInterval)s · 气球→128MB 再回到 \(selfTestOriginalBalloon)MB")
        if let quitMenu = menu.items.first(where: { $0 === quitItem }), quitMenu.keyEquivalent != "q" {
            selfTestFail("退出缺少 ⌘Q")
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
                print("菜单栏文字（清理后）: \(statusItem.button?.attributedTitle.string ?? "<空>")")
                if !outcome.balloonRan { selfTestFail("气球子进程未执行") }
                if !resultItem.title.contains("上次清理") { selfTestFail("结果行没有更新") }
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
            candidates.insert(
                ProcessSample(pid: child, name: "selftest-sleeper", resident: 1, uid: geteuid()),
                at: 0
            )
            checkedPIDs = [child]
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
        Prefs.balloonMB = selfTestOriginalBalloon
        if Prefs.refreshSeconds != selfTestOriginalInterval || Prefs.balloonMB != selfTestOriginalBalloon {
            selfTestFail("偏好设置未能恢复")
        }
        print("偏好: 刷新 \(Prefs.refreshSeconds)s · 气球 \(Prefs.balloonMB)MB · 登录项 \(LoginItem.statusDescription)")

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
