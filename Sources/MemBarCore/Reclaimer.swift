import Darwin
import Foundation

/// A process the user explicitly ticked in the "high memory" submenu.
public struct VictimProcess: Equatable, Sendable {
    public let pid: pid_t
    public let name: String

    public init(pid: pid_t, name: String) {
        self.pid = pid
        self.name = name
    }

    public var display: String { "\(name)(\(pid))" }
}

/// Sends a polite "please quit" request. The app layer supplies an implementation backed by
/// `NSRunningApplication.terminate()` so document-based apps can show their save sheet;
/// plain processes fall back to `SIGTERM`.
public typealias GracefulTerminator = (pid_t) -> Bool

/// Before/after numbers for one clean cycle plus the human-readable verdict.
public struct CleanOutcome: Equatable, Sendable {
    public let before: MemorySnapshot
    public let after: MemorySnapshot
    public let duration: TimeInterval
    public let balloonMB: Int
    public let balloonRan: Bool
    public let selfReliefBytes: UInt64
    public let terminated: [String]
    public let stuck: [String]

    public var freeDelta: Int64 { Int64(after.free) - Int64(before.free) }
    public var cacheDelta: Int64 { Int64(after.cache) - Int64(before.cache) }
    public var reclaimed: Bool { freeDelta > 0 }
    public var pressureWorsened: Bool { after.pressure.rank > before.pressure.rank }

    /// One line for the menu, e.g.
    /// `空闲 1.2 GB → 2.6 GB（+480 MB），缓存 4.9 GB → 4.4 GB · 用时 0.7 秒`
    public var detailText: String {
        var parts: [String] = []
        if reclaimed {
            parts.append(
                "空闲 \(Fmt.bytes(before.free)) → \(Fmt.bytes(after.free))"
                    + "（\(Fmt.deltaBytes(freeDelta))）"
            )
        } else {
            parts.append("空闲 \(Fmt.bytes(before.free)) → \(Fmt.bytes(after.free))")
        }
        parts.append("缓存 \(Fmt.bytes(before.cache)) → \(Fmt.bytes(after.cache))")
        if !terminated.isEmpty {
            parts.append("结束 \(terminated.count) 个进程")
        }
        if !stuck.isEmpty {
            parts.append("\(stuck.count) 个进程未能结束")
        }
        if !balloonRan {
            parts.append("回收子进程未执行")
        }
        if !reclaimed {
            parts.append("未获得可回收缓存")
        }
        var text = parts.joined(separator: "，")
        text += " · 用时 " + Self.shortDuration(duration)
        return text
    }

    /// Longer line for the log file.
    public var logLine: String {
        let verdict = reclaimed ? "reclaimed=yes" : "reclaimed=no"
        return "clean balloon=\(balloonMB)MB ran=\(balloonRan)"
            + " free=\(before.free)→\(after.free) cache=\(before.cache)→\(after.cache)"
            + " compressed=\(before.compressed)→\(after.compressed)"
            + " stress=\(before.pressure.rawValue)→\(after.pressure.rawValue)"
            + " selfRelief=\(selfReliefBytes) terminated=\(terminated)"
            + " stuck=\(stuck) \(verdict) duration=\(String(format: "%.2f", duration))s"
    }

    private static func shortDuration(_ value: TimeInterval) -> String {
        value < 1 ? String(format: "%.0f 毫秒", value * 1000) : String(format: "%.1f 秒", value)
    }
}

/// The non-privileged clean pipeline: release our own pages, run a balloon child, then end
/// whatever the user ticked. No root, no `purge`, no prompts.
public enum Reclaimer {
    /// Hands memory back from our own allocator (and every zone, since `zone == nil`).
    @discardableResult
    public static func relieveSelf() -> UInt64 {
        UInt64(max(0, malloc_zone_pressure_relief(nil, 0)))
    }

    /// Spawns `self --balloon <MB>` and waits for it. A hung child is killed after `timeout`.
    public static func runBalloon(
        megabytes: Int,
        executablePath: String,
        timeout: TimeInterval = 3
    ) -> (ran: Bool, milliseconds: Int) {
        let start = Date()
        guard megabytes > 0 else { return (false, 0) }
        guard let pid = spawn(path: executablePath, arguments: ["MemBar", "--balloon", "\(megabytes)"]) else {
            Log.error("balloon spawn failed for \(executablePath)")
            return (false, 0)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while Date() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                let exited = (status & 0x7f) == 0 && (status >> 8) == 0
                return (exited, Int(Date().timeIntervalSince(start) * 1000))
            }
            usleep(20_000)
        }

        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
        Log.error("balloon \(megabytes)MB timed out after \(timeout)s; killed pid \(pid)")
        return (false, Int(Date().timeIntervalSince(start) * 1000))
    }

    /// Requests termination, waits up to `timeout` for each victim, and never escalates to `SIGKILL`.
    public static func terminate(
        _ victims: [VictimProcess],
        timeout: TimeInterval = 3,
        graceful: GracefulTerminator? = nil,
        isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 }
    ) -> (terminated: [String], stuck: [String]) {
        guard !victims.isEmpty else { return ([], []) }

        for victim in victims {
            if let graceful {
                _ = graceful(victim.pid)
            } else {
                _ = kill(victim.pid, SIGTERM)
            }
        }

        var alive = Set(victims.map { $0.pid })
        let deadline = Date().addingTimeInterval(timeout)
        while !alive.isEmpty && Date() < deadline {
            alive = Set(alive.filter { isAlive($0) })
            if !alive.isEmpty { usleep(50_000) }
        }

        let terminated = victims.filter { !alive.contains($0.pid) }.map { $0.display }
        let stuck = victims.filter { alive.contains($0.pid) }.map { $0.display }
        return (terminated, stuck)
    }

    public static func clean(
        balloonMB: Int,
        victims: [VictimProcess] = [],
        executablePath: String,
        graceful: GracefulTerminator? = nil
    ) -> CleanOutcome {
        let before = MemoryStats.sample()
        let start = Date()

        let relief = relieveSelf()
        let balloon = runBalloon(megabytes: balloonMB, executablePath: executablePath)
        let termination = terminate(victims, graceful: graceful)

        let after = MemoryStats.sample()
        let outcome = CleanOutcome(
            before: before,
            after: after,
            duration: Date().timeIntervalSince(start),
            balloonMB: balloonMB,
            balloonRan: balloon.ran,
            selfReliefBytes: relief,
            terminated: termination.terminated,
            stuck: termination.stuck
        )
        Log.info(outcome.logLine)
        return outcome
    }

    private static func spawn(path: String, arguments: [String]) -> pid_t? {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        let result = argv.withUnsafeMutableBufferPointer { buffer -> Int32 in
            posix_spawn(&pid, path, nil, nil, buffer.baseAddress, nil)
        }
        return result == 0 ? pid : nil
    }
}