import Darwin
import Foundation

/// One process worth showing in the "high memory" submenu.
public struct ProcessSample: Equatable, Identifiable, Sendable {
    public let pid: pid_t
    public let name: String
    public let resident: UInt64
    public let uid: uid_t

    public var id: pid_t { pid }

    public init(pid: pid_t, name: String, resident: UInt64, uid: uid_t) {
        self.pid = pid
        self.name = name
        self.resident = resident
        self.uid = uid
    }
}

/// Enumerates the current user's processes by resident size. Called only when the menu opens.
public enum ProcessScanner {
    /// Never offered for termination: system daemons and window-server infrastructure.
    /// Matching is case-insensitive on the executable name.
    public static let defaultExclusions: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "dock", "finder",
        "systemuiserver", "controlcenter", "notificationcenter", "coreaudiod",
        "cfprefsd", "distnoted", "configd", "logd", "opendirectoryd",
        "securityd", "powerd", "thermald", "watchdogd", "mem", "membar",
    ]

    /// Prefix exclusions, e.g. every `mds*` Spotlight worker.
    public static let defaultExclusionPrefixes: [String] = ["mds", "spindump"]

    /// Processes below this pid are boot-time kernel/launchd children and are never listed.
    public static let minimumPID: pid_t = 100

    /// Pure filter used by the tests: drop other users' processes, ourselves, system daemons,
    /// then sort by resident size (pid as tie-breaker) and keep `limit` entries.
    public static func filter(
        candidates: [ProcessSample],
        ownUID: uid_t,
        ownPID: pid_t,
        exclusions: Set<String> = defaultExclusions,
        exclusionPrefixes: [String] = defaultExclusionPrefixes,
        limit: Int = 8
    ) -> [ProcessSample] {
        let filtered = candidates.filter { candidate in
            guard candidate.uid == ownUID else { return false }
            guard candidate.pid != ownPID, candidate.pid >= minimumPID else { return false }
            let name = candidate.name.lowercased()
            guard !exclusions.contains(name) else { return false }
            return !exclusionPrefixes.contains { name.hasPrefix($0) }
        }
        let sorted = filtered.sorted { lhs, rhs in
            if lhs.resident != rhs.resident { return lhs.resident > rhs.resident }
            return lhs.pid < rhs.pid
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Top memory consumers of the current user, largest first.
    public static func top(limit: Int = 8) -> [ProcessSample] {
        filter(
            candidates: enumerate(),
            ownUID: geteuid(),
            ownPID: getpid(),
            limit: limit
        )
    }

    /// Reads every pid with two cheap `proc_pidinfo` calls, ordered so the expensive one only
    /// runs for processes that survive the uid/name checks.
    public static func enumerate() -> [ProcessSample] {
        let capacity = max(64, Int(proc_listallpids(nil, 0)) * 2)
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }

        let count = Int(bytes) / MemoryLayout<pid_t>.size
        var samples: [ProcessSample] = []
        samples.reserveCapacity(count)

        let uid = geteuid()
        for index in 0..<min(count, capacity) {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            guard bsd.pbi_uid == uid else { continue }

            let name = Self.name(fromBSDInfo: &bsd)
            let lowered = name.lowercased()
            if lowered.isEmpty || defaultExclusions.contains(lowered) { continue }
            if defaultExclusionPrefixes.contains(where: { lowered.hasPrefix($0) }) { continue }

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }

            samples.append(
                ProcessSample(
                    pid: pid,
                    name: name,
                    resident: UInt64(task.pti_resident_size),
                    uid: uid
                )
            )
        }
        return samples
    }

    private static func name(fromBSDInfo info: inout proc_bsdinfo) -> String {
        let comm = withUnsafeBytes(of: &info.pbi_comm) { raw in
            String(validatingCString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if let comm, !comm.isEmpty { return comm }
        let name = withUnsafeBytes(of: &info.pbi_name) { raw in
            String(validatingCString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return name ?? ""
    }
}