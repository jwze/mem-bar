import Foundation

/// `MemBar --diagnostics`: prints one reading plus our own footprint, then exits.
/// Used by the README/release checklist to compare against Activity Monitor.
public enum Diagnostics {
    public static func report(now: Date = Date()) -> String {
        let snapshot = MemoryStats.sample()
        let pressure = snapshot.pressure

        var lines: [String] = []
        lines.append("\(AppInfo.name) \(AppInfo.version) 诊断")
        lines.append(
            "自身: pid \(getpid()) · RSS \(Fmt.bytes(AppInfo.Process.residentBytes))"
                + " · 线程 \(threadCount())"
        )
        lines.append("物理内存: \(Fmt.bytes(snapshot.total)) · pageSize \(snapshot.pageSize)")
        lines.append(
            "已用 \(Fmt.bytes(snapshot.used))"
                + " (\(Fmt.ratioPercent(snapshot.percent / 100)))"
                + " · 缓存 \(Fmt.bytes(snapshot.cache))"
                + " · 空闲 \(Fmt.bytes(snapshot.free))"
        )
        lines.append(
            "可回收 \(Fmt.bytes(snapshot.reclaimable))"
                + " (\(Fmt.ratioPercent(snapshot.availableRatio)))"
                + " · 压缩 \(Fmt.bytes(snapshot.compressed))"
                + " · 有线 \(Fmt.bytes(snapshot.wired))"
        )
        lines.append(
            "交换 \(Fmt.bytes(snapshot.swapUsed)) / \(Fmt.bytes(snapshot.swapTotal))"
                + " (\(Fmt.ratioPercent(snapshot.swapRatio)))"
        )
        lines.append("压力: \(pressure.dot) \(pressure.label) (估算)")
        lines.append("采样时间: \(timestamp(now))")
        return lines.joined(separator: "\n")
    }

    public static func printReport() {
        print(report())
    }

    /// `MemBar --clean [MB]`: runs the exact one-click pipeline from the command line, without
    /// ending any process, so the effect can be measured and compared between builds.
    public static func cleanReport(balloonMB: Int) -> String {
        let outcome = Reclaimer.clean(balloonMB: balloonMB, executablePath: AppInfo.executablePath)
        func line(_ prefix: String, _ snapshot: MemorySnapshot) -> String {
            "\(prefix): 空闲 \(Fmt.bytes(snapshot.free))"
                + " · 缓存 \(Fmt.bytes(snapshot.cache))"
                + " · 已用 \(Fmt.bytes(snapshot.used))"
                + " · 压缩 \(Fmt.bytes(snapshot.compressed))"
                + " · 压力 \(snapshot.pressure.dot) \(snapshot.pressure.label)"
        }
        return [
            "\(AppInfo.name) \(AppInfo.version) 清理诊断（气球 \(balloonMB) MB，不结束进程）",
            line("清理前", outcome.before),
            line("清理后", outcome.after),
            "结果: \(outcome.detailText)",
            "自身释放: \(Fmt.bytes(outcome.selfReliefBytes)) · 气球子进程执行: \(outcome.balloonRan)",
            "日志: \(AppInfo.logFileURL.path)",
        ].joined(separator: "\n")
    }

    private static func threadCount() -> Int {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS else { return 0 }
        defer {
            if let threadList {
                let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
            }
        }
        return Int(threadCount)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}