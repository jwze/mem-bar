import AppKit
import MemBarCore

// Internal helper modes run before AppKit is brought up, so they cost almost nothing.
setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--balloon"),
   index + 1 < arguments.count,
   let megabytes = Int(arguments[index + 1]) {
    exit(Balloon.run(megabytes: megabytes))
}

if let index = arguments.firstIndex(of: "--clean") {
    var megabytes = Prefs.balloonMB
    if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
        megabytes = value
    }
    print(Diagnostics.cleanReport(balloonMB: megabytes))
    exit(0)
}

if arguments.contains("--diagnostics") {
    Diagnostics.printReport()
    exit(0)
}

if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
    let directory = arguments[index + 1]
    MainActor.assumeIsolated {
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let snapshot = MemoryStats.sample()
        let panel = PanelCardView()
        panel.update(PanelCardView.Model(
            snapshot: snapshot,
            result: PanelCardView.ResultLine(
                prefix: "上次清理",
                value: "已释放 297 MB",
                tail: "31 秒前",
                tone: .good
            ),
            isCleaning: false
        ))
        let actions = PanelActionsCard()
        actions.update(PanelActionsCard.Model(
            processCount: 8,
            intervalSeconds: 5,
            login: .on
        ))
        let processes = PanelProcessesCard()
        let groups = ProcessScanner.top(limit: 8)
        let rows = groups.map {
            PanelProcessesCard.Row(
                key: $0.key,
                name: $0.displayName,
                bytes: Fmt.bytes($0.totalResident),
                size: $0.totalResident,
                processCount: $0.processCount,
                checked: false
            )
        }
        let total = groups.reduce(UInt64(0)) { $0 + $1.totalResident }
        processes.update(
            rows: rows.enumerated().map { index, row in
                var copy = row
                copy.checked = index == 1
                return copy
            },
            subtitle: "\(rows.count) 个应用 · 共 \(Fmt.bytes(total))",
            isBusy: false,
            selection: rows.count > 1 ? [rows[1].key] : []
        )

        let sheet = PanelSheetView(
            panelCard: panel,
            actionsCard: actions,
            processesCard: processes
        )

        func render(_ view: NSView, to name: String) {
            view.layoutSubtreeIfNeeded()
            let size = view.bounds.size
            guard size.width >= 1, size.height >= 1,
                  let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width) * 2,
                    pixelsHigh: Int(size.height) * 2,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                  ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            // The popover has a material background; the preview has to fake one, otherwise
            // `labelColor` text (white in dark mode) would be invisible on transparency.
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
            }
        }

        sheet.setSection(.main)
        render(sheet, to: "sheet-main")
        sheet.setSection(.processes)
        render(sheet, to: "sheet-processes")
        render(panel, to: "panel")
        render(actions, to: "actions")
        render(processes, to: "processes")
    }
    exit(0)
}

if arguments.contains("--selftest") {
    print("[selftest] starting")
    let testApplication = NSApplication.shared
    testApplication.setActivationPolicy(.accessory)
    let testController: StatusItemController = MainActor.assumeIsolated { StatusItemController() }
    // A timer (not a dispatch block) starts the test: main-queue completions cannot be drained
    // while a dispatch block is still on the stack.
    let kickoff = Timer(timeInterval: 0.3, repeats: false) { timer in
        print("[selftest] timer fired")
        MainActor.assumeIsolated {
            testController.start()
            testController.runSelfTest()
        }
    }
    RunLoop.main.add(kickoff, forMode: .common)
    // Absolute watchdog: a staged self test must never outlive its budget, even if a stage wedges
    // the run loop. Exiting with a failure is always better than leaving the caller waiting.
    let watchdog = Timer(timeInterval: 70, repeats: false) { _ in
        print("自检结果: FAIL（70 秒内未退出）")
        exit(1)
    }
    RunLoop.main.add(watchdog, forMode: .common)
    testApplication.run()
    exit(0)
}

let application = NSApplication.shared
let delegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()