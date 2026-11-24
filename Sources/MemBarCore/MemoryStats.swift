import Darwin
import Foundation

/// One immutable memory reading. Plain value type so the maths can be unit-tested without syscalls.
public struct MemorySnapshot: Equatable, Sendable {
    public let total: UInt64
    public let used: UInt64
    public let cache: UInt64
    public let free: UInt64
    public let reclaimable: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let swapTotal: UInt64
    public let swapUsed: UInt64
    public let pageSize: UInt64

    /// `used / total`, 0…100.
    public var percent: Double {
        guard total > 0 else { return 0 }
        return min(100, Double(used) / Double(total) * 100)
    }

    /// Rounded up: 63.2% reads as 64%, and 0.1% never reads as 0%.
    public var percentRoundedUp: Int { Int(percent.rounded(.up)) }

    /// Share of physical memory the kernel can hand back without swapping: free + inactive + purgeable.
    public var availableRatio: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(reclaimable) / Double(total))
    }

    public var swapRatio: Double {
        guard swapTotal > 0 else { return 0 }
        return min(1, Double(swapUsed) / Double(swapTotal))
    }

    public var pressure: MemoryPressure { MemoryPressure.evaluate(snapshot: self) }
}

/// Raw page counters, mirrored from `vm_statistics64` for testability.
public struct VMPageCounts: Equatable, Sendable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var speculative: UInt64
    public var purgeable: UInt64
    public var compressed: UInt64

    public init(
        free: UInt64,
        active: UInt64,
        inactive: UInt64,
        wired: UInt64,
        speculative: UInt64,
        purgeable: UInt64,
        compressed: UInt64
    ) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.speculative = speculative
        self.purgeable = purgeable
        self.compressed = compressed
    }
}

/// Pure conversion from page counters to a snapshot, matching Activity Monitor's vocabulary:
/// used = active + wired + compressed; cache = inactive + speculative + purgeable.
public enum MemoryMath {
    public static func snapshot(
        pages: VMPageCounts,
        pageSize: UInt64,
        total: UInt64,
        swapTotal: UInt64,
        swapUsed: UInt64
    ) -> MemorySnapshot {
        func bytes(_ count: UInt64) -> UInt64 {
            let (value, overflow) = count.multipliedReportingOverflow(by: pageSize)
            return overflow ? UInt64.max : value
        }

        var used = bytes(pages.active + pages.wired + pages.compressed)
        var free = bytes(pages.free + pages.speculative)
        var cache = bytes(pages.inactive + pages.speculative + pages.purgeable)
        var reclaimable = bytes(pages.free + pages.inactive + pages.speculative + pages.purgeable)

        if total > 0 {
            used = min(used, total)
            free = min(free, total)
            cache = min(cache, total)
            reclaimable = min(reclaimable, total)
        }

        return MemorySnapshot(
            total: total,
            used: used,
            cache: cache,
            free: free,
            reclaimable: reclaimable,
            wired: bytes(pages.wired),
            compressed: bytes(pages.compressed),
            swapTotal: swapTotal,
            swapUsed: swapUsed,
            pageSize: pageSize
        )
    }
}

/// Syscall wrapper: one `host_statistics64` + two small `sysctlbyname` calls per sample.
public enum MemoryStats {
    public static let defaultPageSize: UInt64 = 16384

    private static var cachedTotal: UInt64 = 0
    private static var cachedPageSize: UInt64 = 0

    public static var totalBytes: UInt64 {
        if cachedTotal == 0 { cachedTotal = readTotalBytes() }
        return cachedTotal
    }

    public static var pageSize: UInt64 {
        if cachedPageSize == 0 { cachedPageSize = readPageSize() }
        return cachedPageSize
    }

    public static func sample() -> MemorySnapshot {
        let swap = swapUsage()
        return MemoryMath.snapshot(
            pages: pageCounts(),
            pageSize: pageSize,
            total: totalBytes,
            swapTotal: swap.total,
            swapUsed: swap.used
        )
    }

    public static func pageCounts() -> VMPageCounts {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return VMPageCounts(
                free: 0, active: 0, inactive: 0, wired: 0,
                speculative: 0, purgeable: 0, compressed: 0
            )
        }
        return VMPageCounts(
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            wired: UInt64(stats.wire_count),
            speculative: UInt64(stats.speculative_count),
            purgeable: UInt64(stats.purgeable_count),
            compressed: UInt64(stats.compressor_page_count)
        )
    }

    public static func swapUsage() -> (total: UInt64, used: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return (0, 0)
        }
        return (UInt64(usage.xsu_total), UInt64(usage.xsu_used))
    }

    private static func readTotalBytes() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 else { return 0 }
        return value
    }

    private static func readPageSize() -> UInt64 {
        var value: vm_size_t = 0
        guard host_page_size(mach_host_self(), &value) == KERN_SUCCESS, value > 0 else {
            return defaultPageSize
        }
        return UInt64(value)
    }
}