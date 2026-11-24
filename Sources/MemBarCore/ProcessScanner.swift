import Darwin
import Foundation

/// One process worth showing in the "high memory" submenu.
public struct ProcessSample: Equatable, Identifiable, Sendable {
    public let pid: pid_t
    public let name: String
    public let resident: UInt64
    public let uid: uid_t
    /// Path of the enclosing `.app` bundle, when the executable lives inside one. Every Chrome
    /// helper resolves to the same `/Applications/Google Chrome.app`, so they fold into one row.
    public let appBundlePath: String?

    public var id: pid_t { pid }

    public init(
        pid: pid_t,
        name: String,
        resident: UInt64,
        uid: uid_t,
        appBundlePath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.resident = resident
        self.uid = uid
        self.appBundlePath = appBundlePath
    }
}

/// A user-facing app: one entry per application, with every helper process folded in.
public struct AppGroup: Equatable, Identifiable, Sendable {
    public let key: String
    public let displayName: String
    public let totalResident: UInt64
    public let pids: [pid_t]
    public let isApplication: Bool

    public var id: String { key }
    public var processCount: Int { pids.count }

    public init(key: String, displayName: String, totalResident: UInt64, pids: [pid_t], isApplication: Bool) {
        self.key = key
        self.displayName = displayName
        self.totalResident = totalResident
        self.pids = pids
        self.isApplication = isApplication
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

    /// Pure filter used by the self test: drop other users' processes, ourselves, system daemons,
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

    /// Folds helper processes into their owning app so one browser does not eat every slot.
    ///
    /// Grouping key, in order of preference:
    /// 1. `appBundlePath` — every Chrome helper resolves to the same `.app`, so they collapse
    ///    into one row instead of filling the list with `Google Chrome Helper (Renderer)` ×6.
    /// 2. executable name — plain processes such as `node` group by name.
    /// Grouped rows are named after the app; plain processes keep their executable name.
    public static func group(_ samples: [ProcessSample], limit: Int = 8) -> [AppGroup] {
        var buckets: [String: (name: String, total: UInt64, pids: [pid_t], isApp: Bool)] = [:]

        for sample in samples {
            let key: String
            let isApp: Bool
            if let appPath = sample.appBundlePath, !appPath.isEmpty {
                key = appPath
                isApp = true
            } else {
                key = "exe:" + sample.name.lowercased()
                isApp = false
            }

            let name = displayName(for: sample)
            if var existing = buckets[key] {
                existing.total += sample.resident
                existing.pids.append(sample.pid)
                buckets[key] = existing
            } else {
                buckets[key] = (name, sample.resident, [sample.pid], isApp)
            }
        }

        let groups = buckets.map { key, bucket in
            AppGroup(
                key: key,
                displayName: bucket.name,
                totalResident: bucket.total,
                pids: bucket.pids.sorted(),
                isApplication: bucket.isApp
            )
        }
        let sorted = groups.sorted { lhs, rhs in
            if lhs.totalResident != rhs.totalResident { return lhs.totalResident > rhs.totalResident }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Top memory consumers of the current user, one row per app, largest first.
    public static func top(limit: Int = 8) -> [AppGroup] {
        group(
            filter(
                candidates: enumerate(),
                ownUID: geteuid(),
                ownPID: getpid(),
                limit: Int.max
            ),
            limit: limit
        )
    }

    /// Reads every pid with two cheap `proc_pidinfo` calls, ordered so the expensive one only
    /// runs for processes that survive the uid/name checks.
    public static func enumerate() -> [ProcessSample] {
        // `proc_listallpids` returns the number of pids written, *not* a byte count — dividing it
        // by `sizeof(pid_t)` silently scanned only the first quarter of the process table, which
        // hid every process with a high pid (IntelliJ IDEA, for one).
        let needed = Int(proc_listallpids(nil, 0))
        guard needed > 0 else { return [] }
        // Headroom for processes spawned between the two calls.
        let capacity = needed + max(64, needed / 8)
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return [] }

        let count = min(Int(written), capacity)
        var samples: [ProcessSample] = []
        samples.reserveCapacity(count)

        let uid = geteuid()
        for index in 0..<count {
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
                    uid: uid,
                    appBundlePath: Self.appBundlePath(forPID: pid)
                )
            )
        }
        return samples
    }

    /// `pbi_name` is 32 bytes and holds the full executable name; `pbi_comm` is only 16 bytes and
    /// truncates ("Google Chrome H"), which made helpers indistinguishable from one another.
    private static func name(fromBSDInfo info: inout proc_bsdinfo) -> String {
        let name = withUnsafeBytes(of: &info.pbi_name) { raw in
            String(validatingCString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if let name, !name.isEmpty { return name }
        let comm = withUnsafeBytes(of: &info.pbi_comm) { raw in
            String(validatingCString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return comm ?? ""
    }

    /// Human-facing name: the `.app` bundle name when there is one (`IntelliJ IDEA` rather than
    /// `idea`, `Google Chrome` rather than `Google Chrome Helper (Renderer)`), else the executable.
    static func displayName(for sample: ProcessSample) -> String {
        if let appPath = sample.appBundlePath {
            let bundleName = (appPath as NSString).lastPathComponent
            let trimmed = bundleName.hasSuffix(".app")
                ? String(bundleName.dropLast(4))
                : bundleName
            if !trimmed.isEmpty { return trimmed }
        }
        return sample.name
    }

    /// Enclosing `.app` bundle path, or nil for plain command-line processes.
    ///
    /// `proc_pidpath` is a single cheap syscall (≈0.8 µs) and works for helpers that
    /// `NSRunningApplication` does not expose as an app.
    public static func appBundlePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }
}
