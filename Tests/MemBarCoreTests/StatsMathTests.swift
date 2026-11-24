import XCTest
@testable import MemBarCore

final class StatsMathTests: XCTestCase {
    private let pageSize: UInt64 = 16384


    func testDerivedBytes() {
        let pages = VMPageCounts(
            free: 100,
            active: 200,
            inactive: 300,
            wired: 50,
            speculative: 10,
            purgeable: 20,
            compressed: 40
        )
        let snapshot = MemoryMath.snapshot(
            pages: pages,
            pageSize: pageSize,
            total: 8 * 1024 * 1024 * 1024,
            swapTotal: 4 * 1024 * 1024 * 1024,
            swapUsed: 1 * 1024 * 1024 * 1024
        )

        XCTAssertEqual(snapshot.used, (200 + 50 + 40) * pageSize)
        XCTAssertEqual(snapshot.cache, (300 + 10 + 20) * pageSize)
        XCTAssertEqual(snapshot.free, (100 + 10) * pageSize)
        XCTAssertEqual(snapshot.reclaimable, (100 + 300 + 10 + 20) * pageSize)
        XCTAssertEqual(snapshot.wired, 50 * pageSize)
        XCTAssertEqual(snapshot.compressed, 40 * pageSize)
        XCTAssertEqual(snapshot.swapTotal, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(snapshot.swapUsed, 1 * 1024 * 1024 * 1024)
    }

    func testPercentRoundsUp() {
        let snapshot = MemoryMath.snapshot(
            pages: VMPageCounts(free: 0, active: 5_242, inactive: 0, wired: 0, speculative: 0, purgeable: 0, compressed: 0),
            pageSize: pageSize,
            total: 16 * 1024 * 1024 * 1024,
            swapTotal: 0,
            swapUsed: 0
        )
        XCTAssertGreaterThan(snapshot.percent, 0)
        XCTAssertLessThan(snapshot.percent, 1)
        XCTAssertEqual(snapshot.percentRoundedUp, 1, "0.5% must not read as 0%")
    }

    func testPercentHalf() {
        let total: UInt64 = 1000
        let snapshot = MemoryMath.snapshot(
            pages: VMPageCounts(free: 0, active: 500, inactive: 0, wired: 0, speculative: 0, purgeable: 0, compressed: 0),
            pageSize: 1,
            total: total,
            swapTotal: 0,
            swapUsed: 0
        )
        XCTAssertEqual(snapshot.percent, 50)
        XCTAssertEqual(snapshot.percentRoundedUp, 50)
    }

    func testUsedIsClampedToTotal() {
        let snapshot = MemoryMath.snapshot(
            pages: VMPageCounts(free: 0, active: 10_000, inactive: 0, wired: 10_000, speculative: 0, purgeable: 0, compressed: 10_000),
            pageSize: pageSize,
            total: 1024,
            swapTotal: 0,
            swapUsed: 0
        )
        XCTAssertEqual(snapshot.used, 1024)
        XCTAssertEqual(snapshot.percent, 100)
        XCTAssertEqual(snapshot.percentRoundedUp, 100)
        XCTAssertLessThanOrEqual(snapshot.cache, snapshot.total)
        XCTAssertLessThanOrEqual(snapshot.reclaimable, snapshot.total)
    }

    func testZeroSwapDoesNotDivideByZero() {
        let snapshot = MemoryMath.snapshot(
            pages: VMPageCounts(free: 100, active: 10, inactive: 100, wired: 10, speculative: 0, purgeable: 0, compressed: 0),
            pageSize: pageSize,
            total: 300 * pageSize,
            swapTotal: 0,
            swapUsed: 0
        )
        XCTAssertEqual(snapshot.swapRatio, 0)
        XCTAssertTrue(snapshot.availableRatio.isFinite)
        XCTAssertNotEqual(snapshot.pressure, .critical)
    }

    func testZeroTotalDoesNotDivideByZero() {
        let snapshot = MemoryMath.snapshot(
            pages: VMPageCounts(free: 0, active: 0, inactive: 0, wired: 0, speculative: 0, purgeable: 0, compressed: 0),
            pageSize: pageSize,
            total: 0,
            swapTotal: 0,
            swapUsed: 0
        )
        XCTAssertEqual(snapshot.percent, 0)
        XCTAssertEqual(snapshot.availableRatio, 0)
        XCTAssertEqual(snapshot.swapRatio, 0)
    }

    func testLiveSampleIsSelfConsistent() {
        let live = MemoryStats.sample()
        XCTAssertGreaterThan(live.total, 0, "hw.memsize should be readable")
        XCTAssertGreaterThan(live.pageSize, 0)
        XCTAssertLessThanOrEqual(live.used, live.total)
        XCTAssertLessThanOrEqual(live.reclaimable, live.total)
        XCTAssertGreaterThanOrEqual(live.percent, 0)
        XCTAssertLessThanOrEqual(live.percent, 100)
    }

}