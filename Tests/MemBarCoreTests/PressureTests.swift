import XCTest
@testable import MemBarCore

final class PressureTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private let total: UInt64 = 16 * 1024 * 1024 * 1024

    private func evaluate(freeRatio: Double, swapUsed: UInt64, compressed: UInt64 = 0) -> MemoryPressure {
        MemoryPressure.evaluate(
            freeRatio: freeRatio,
            swapUsed: swapUsed,
            swapTotal: 4 * gib,
            compressed: compressed,
            total: total
        )
    }

    func testComfortableMachineIsNormal() {
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: 0), .normal)
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: gib), .normal, "exactly 1 GB swap is still normal")
    }

    func testCriticalByAvailableRatio() {
        XCTAssertEqual(evaluate(freeRatio: 0.05, swapUsed: 0), .critical)
        XCTAssertEqual(evaluate(freeRatio: 0.0, swapUsed: 0), .critical)
    }

    func testAvailableRatioBoundaries() {
        // 0.08 is the critical threshold: equality is not "less than", so it falls one level down.
        XCTAssertEqual(evaluate(freeRatio: 0.08, swapUsed: 0), .elevated)
        XCTAssertEqual(evaluate(freeRatio: 0.0799, swapUsed: 0), .critical)
        // 0.18 is the elevated threshold: equality is normal.
        XCTAssertEqual(evaluate(freeRatio: 0.18, swapUsed: 0), .normal)
        XCTAssertEqual(evaluate(freeRatio: 0.1799, swapUsed: 0), .elevated)
    }

    func testSwapBoundaries() {
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: gib), .normal)
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: gib + 1), .elevated)
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: 4 * gib), .elevated, "equality is not critical")
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: 4 * gib + 1), .critical)
    }

    func testCompressorBoundary() {
        let quarter = total / 4
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: 0, compressed: quarter), .normal)
        XCTAssertEqual(evaluate(freeRatio: 0.5, swapUsed: 0, compressed: quarter + 1), .elevated)
    }

    func testSnapshotPressureUsesAvailableMemory() {
        // Half of physical memory is reclaimable → normal, even though "free" alone is tiny.
        let pages = VMPageCounts(
            free: 100,
            active: 1000,
            inactive: 1000,
            wired: 500,
            speculative: 0,
            purgeable: 100,
            compressed: 200
        )
        let snapshot = MemoryMath.snapshot(
            pages: pages,
            pageSize: 16384,
            total: 2400 * 16384,
            swapTotal: 4 * gib,
            swapUsed: 0
        )
        XCTAssertEqual(snapshot.availableRatio, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.pressure, .normal)
    }

    func testSnapshotPressureCriticalWhenAlmostNothingReclaimable() {
        let pages = VMPageCounts(
            free: 0,
            active: 9000,
            inactive: 500,
            wired: 500,
            speculative: 0,
            purgeable: 0,
            compressed: 0
        )
        let snapshot = MemoryMath.snapshot(
            pages: pages,
            pageSize: 16384,
            total: 10_000 * 16384,
            swapTotal: 4 * gib,
            swapUsed: 0
        )
        XCTAssertLessThan(snapshot.availableRatio, 0.08)
        XCTAssertEqual(snapshot.pressure, .critical)
    }

    func testLabelsAndRanks() {
        XCTAssertEqual(MemoryPressure.normal.label, "正常")
        XCTAssertEqual(MemoryPressure.elevated.label, "偏高")
        XCTAssertEqual(MemoryPressure.critical.label, "紧张")
        XCTAssertEqual(MemoryPressure.normal.dot, "🟢")
        XCTAssertEqual(MemoryPressure.elevated.dot, "🟡")
        XCTAssertEqual(MemoryPressure.critical.dot, "🔴")
        XCTAssertLessThan(MemoryPressure.normal.rank, MemoryPressure.elevated.rank)
        XCTAssertLessThan(MemoryPressure.elevated.rank, MemoryPressure.critical.rank)
    }
}