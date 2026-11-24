import Foundation

/// Estimated memory pressure, derived from vm counters + swap usage.
/// This is an approximation of the Activity Monitor pressure chart, not the kernel's own signal.
public enum MemoryPressure: String, Sendable, CaseIterable {
    case normal
    case elevated
    case critical

    /// Below this share of *reclaimable* memory the system is considered critical.
    public static let criticalAvailableRatio = 0.08
    /// Below this share of *reclaimable* memory the system is considered elevated.
    public static let elevatedAvailableRatio = 0.18
    /// Absolute swap used that alone means "elevated" / "critical".
    public static let elevatedSwapBytes: UInt64 = 1 << 30
    public static let criticalSwapBytes: UInt64 = 4 << 30
    /// Compressor growth beyond this share of physical memory is treated as elevated.
    public static let elevatedCompressedRatio = 0.25

    public var label: String {
        switch self {
        case .normal: return "正常"
        case .elevated: return "偏高"
        case .critical: return "紧张"
        }
    }

    public var dot: String {
        switch self {
        case .normal: return "🟢"
        case .elevated: return "🟡"
        case .critical: return "🔴"
        }
    }

    public var rank: Int {
        switch self {
        case .normal: return 0
        case .elevated: return 1
        case .critical: return 2
        }
    }

    public var isCritical: Bool { self == .critical }

    /// Rules (strict `<` / `>` boundaries, so equality falls to the calmer level):
    /// - critical: available ratio < 8%, or swap used > 4 GB
    /// - elevated: available ratio < 18%, or swap used > 1 GB, or compressed > 25% of total
    /// - otherwise normal
    public static func evaluate(
        freeRatio: Double,
        swapUsed: UInt64,
        swapTotal: UInt64,
        compressed: UInt64,
        total: UInt64
    ) -> MemoryPressure {
        if freeRatio < criticalAvailableRatio || swapUsed > criticalSwapBytes {
            return .critical
        }
        let compressedRatio = total > 0 ? Double(compressed) / Double(total) : 0
        if freeRatio < elevatedAvailableRatio
            || swapUsed > elevatedSwapBytes
            || compressedRatio > elevatedCompressedRatio {
            return .elevated
        }
        return .normal
    }

    public static func evaluate(snapshot: MemorySnapshot) -> MemoryPressure {
        evaluate(
            freeRatio: snapshot.availableRatio,
            swapUsed: snapshot.swapUsed,
            swapTotal: snapshot.swapTotal,
            compressed: snapshot.compressed,
            total: snapshot.total
        )
    }
}