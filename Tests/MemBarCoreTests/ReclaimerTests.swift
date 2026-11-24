import XCTest
@testable import MemBarCore

final class ReclaimerTests: XCTestCase {
    private let pageSize: UInt64 = 16384

    private func snapshot(freeGiB: UInt64, cacheGiB: UInt64) -> MemorySnapshot {
        let gib: UInt64 = 1024 * 1024 * 1024
        let freePages = freeGiB * gib / pageSize
        let inactivePages = cacheGiB * gib / pageSize
        return MemoryMath.snapshot(
            pages: VMPageCounts(
                free: freePages,
                active: 1_000,
                inactive: inactivePages,
                wired: 1_000,
                speculative: 0,
                purgeable: 0,
                compressed: 0
            ),
            pageSize: pageSize,
            total: 16 * gib,
            swapTotal: 0,
            swapUsed: 0
        )
    }

    private func spawnSleep() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        XCTAssertGreaterThan(pid, 0)
        return pid
    }

    // MARK: - Termination

    func testTerminateEndsPlainProcess() throws {
        let pid = try spawnSleep()
        defer { kill(pid, SIGKILL) }

        let result = Reclaimer.terminate(
            [VictimProcess(pid: pid, name: "sleep")],
            timeout: 2
        )
        XCTAssertEqual(result.stuck, [])
        XCTAssertEqual(result.terminated, ["sleep(\(pid))"])
    }

    func testTerminateReportsStuckProcessAndNeverEscalates() throws {
        // bash with an ignored SIGTERM is the "app refuses to quit" case.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        try process.run()
        let pid = process.processIdentifier
        defer {
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }
        // Give bash time to install the trap before the first SIGTERM arrives.
        Thread.sleep(forTimeInterval: 0.3)

        let result = Reclaimer.terminate(
            [VictimProcess(pid: pid, name: "stubborn")],
            timeout: 0.6
        )
        XCTAssertEqual(result.terminated, [])
        XCTAssertEqual(result.stuck, ["stubborn(\(pid))"])
        XCTAssertEqual(kill(pid, 0), 0, "a stuck process must survive: no SIGKILL escalation")
    }

    func testTerminateUsesProbeToDetectExit() throws {
        let pid = try spawnSleep()
        defer { kill(pid, SIGKILL) }

        var probes = 0
        let result = Reclaimer.terminate(
            [VictimProcess(pid: pid, name: "probe")],
            timeout: 2,
            isAlive: { _ in
                probes += 1
                return probes < 3
            }
        )
        XCTAssertEqual(result.stuck, [])
        XCTAssertEqual(result.terminated, ["probe(\(pid))"])
        XCTAssertGreaterThanOrEqual(probes, 3, "the poll loop must keep asking before giving up")
    }

    func testTerminateWithNoVictimsIsNoop() {
        let result = Reclaimer.terminate([])
        XCTAssertTrue(result.terminated.isEmpty)
        XCTAssertTrue(result.stuck.isEmpty)
    }

    // MARK: - Balloon

    func testBalloonAllocatesAndReleases() {
        XCTAssertEqual(Balloon.run(megabytes: 16), 0)
        XCTAssertEqual(Balloon.run(megabytes: 0), 0)
    }

    func testBalloonChildFromBuiltApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binary = root.appendingPathComponent("build/MemBar.app/Contents/MacOS/MemBar").path
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: binary),
            "run Scripts/build-app.sh first"
        )

        let result = Reclaimer.runBalloon(megabytes: 32, executablePath: binary, timeout: 5)
        XCTAssertTrue(result.ran, "balloon child should exit cleanly")
        XCTAssertGreaterThan(result.milliseconds, 0)
    }

    // MARK: - Pipeline

    func testCleanWithoutBalloonStillReportsBeforeAndAfter() {
        let outcome = Reclaimer.clean(balloonMB: 0, executablePath: AppInfo.executablePath)
        XCTAssertFalse(outcome.balloonRan)
        XCTAssertGreaterThanOrEqual(outcome.duration, 0)
        XCTAssertTrue(outcome.detailText.contains("空闲"))
        XCTAssertTrue(outcome.detailText.contains("用时"))
        XCTAssertTrue(outcome.logLine.contains("clean balloon=0MB"))
    }

    // MARK: - Text

    func testDetailTextReportsGainHonestly() {
        let outcome = CleanOutcome(
            before: snapshot(freeGiB: 1, cacheGiB: 4),
            after: snapshot(freeGiB: 2, cacheGiB: 3),
            duration: 0.75,
            balloonMB: 256,
            balloonRan: true,
            selfReliefBytes: 0,
            terminated: [],
            stuck: []
        )
        XCTAssertTrue(outcome.reclaimed)
        XCTAssertTrue(outcome.detailText.contains("（+1 GB）"), outcome.detailText)
        XCTAssertFalse(outcome.detailText.contains("未获得可回收缓存"))
        XCTAssertTrue(outcome.detailText.contains("用时"))
    }

    func testDetailTextDoesNotFakeGain() {
        let outcome = CleanOutcome(
            before: snapshot(freeGiB: 2, cacheGiB: 4),
            after: snapshot(freeGiB: 1, cacheGiB: 5),
            duration: 0.5,
            balloonMB: 256,
            balloonRan: true,
            selfReliefBytes: 0,
            terminated: [],
            stuck: []
        )
        XCTAssertFalse(outcome.reclaimed)
        XCTAssertTrue(outcome.detailText.contains("未获得可回收缓存"), outcome.detailText)
        XCTAssertFalse(outcome.detailText.contains("（+"))
    }

    func testDetailTextMentionsTerminationsAndStuck() {
        let outcome = CleanOutcome(
            before: snapshot(freeGiB: 1, cacheGiB: 2),
            after: snapshot(freeGiB: 2, cacheGiB: 2),
            duration: 1.2,
            balloonMB: 64,
            balloonRan: true,
            selfReliefBytes: 1024,
            terminated: ["a(1)", "b(2)"],
            stuck: ["c(3)"]
        )
        XCTAssertTrue(outcome.detailText.contains("结束 2 个进程"), outcome.detailText)
        XCTAssertTrue(outcome.detailText.contains("1 个进程未能结束"), outcome.detailText)
    }
}