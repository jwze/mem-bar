import Foundation

/// Formatting helpers shared by the menu, the log lines and `--diagnostics`.
public enum Fmt {
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    /// `12582912` → `"12 MB"`, `10952166604` → `"10.2 GB"`.
    public static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "0 MB" }
        return memoryFormatter.string(fromByteCount: Int64(value))
    }

    /// Signed delta: `+480 MB` / `-1.2 GB`.
    public static func deltaBytes(_ value: Int64) -> String {
        let magnitude = UInt64(value.magnitude)
        return (value >= 0 ? "+" : "-") + bytes(magnitude)
    }

    /// `63.2` → `"64%"` (the menu bar rounds up so 0.1% never reads as 0%).
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded(.up)))%"
    }

    /// `"12 秒前"` / `"3 分钟前"` / `"2 小时前"`.
    public static func secondsAgo(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }

    public static func ratioPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}