import XCTest
@testable import MemBarCore

final class ProcessFilterTests: XCTestCase {
    private let myUID: uid_t = 501
    private let otherUID: uid_t = 0

    private func sample(_ pid: pid_t, _ name: String, _ megabytes: UInt64, uid: uid_t? = nil) -> ProcessSample {
        ProcessSample(
            pid: pid,
            name: name,
            resident: megabytes * 1024 * 1024,
            uid: uid ?? myUID
        )
    }

    private func filtered(_ candidates: [ProcessSample], limit: Int = 8) -> [ProcessSample] {
        ProcessScanner.filter(
            candidates: candidates,
            ownUID: myUID,
            ownPID: 4242,
            limit: limit
        )
    }

    func testDropsOtherUsersAndSelf() {
        let candidates = [
            sample(101, "other", 900, uid: otherUID),
            sample(4242, "MemBar", 5),
            sample(102, "mine", 100),
        ]
        let result = filtered(candidates)
        XCTAssertEqual(result.map { $0.pid }, [102])
    }

    func testDropsBootProcesses() {
        let candidates = [
            sample(1, "launchd", 900),
            sample(42, "something", 800),
            sample(99, "edge", 700),
            sample(100, "edge", 600),
        ]
        XCTAssertEqual(filtered(candidates).map { $0.pid }, [100])
    }

    func testDropsSystemGuiAndDaemonsCaseInsensitively() {
        let candidates = [
            sample(200, "WindowServer", 900),
            sample(201, "dock", 800),
            sample(202, "Finder", 700),
            sample(203, "ControlCenter", 600),
            sample(204, "coreaudiod", 500),
            sample(205, "cfprefsd", 400),
            sample(206, "mds_stores", 300),
            sample(207, "MDS", 200),
            sample(208, "keep-me", 100),
        ]
        XCTAssertEqual(filtered(candidates).map { $0.pid }, [208])
    }

    func testDropsSelfByBundleName() {
        let candidates = [sample(300, "MemBar", 900), sample(301, "keep", 100)]
        XCTAssertEqual(filtered(candidates).map { $0.pid }, [301])
    }

    func testSortsByResidentDescendingAndTruncatesToLimit() {
        let candidates = (0..<12).map { index in
            sample(pid_t(500 + index), "p\(index)", UInt64(index * 10 + 1))
        }
        let result = filtered(candidates, limit: 8)
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.map { $0.pid }, [511, 510, 509, 508, 507, 506, 505, 504])
        XCTAssertEqual(result.map { $0.resident }, result.map { $0.resident }.sorted(by: >))
    }

    func testEqualResidentFallsBackToPIDAscending() {
        let candidates = [
            sample(700, "b", 50),
            sample(701, "a", 50),
        ]
        XCTAssertEqual(filtered(candidates).map { $0.pid }, [700, 701])
    }

    func testZeroLimitReturnsNothing() {
        XCTAssertTrue(filtered([sample(800, "x", 10)], limit: 0).isEmpty)
    }

    func testLiveTopIsSane() {
        let top = ProcessScanner.top(limit: 8)
        XCTAssertLessThanOrEqual(top.count, 8)
        for entry in top {
            XCTAssertGreaterThanOrEqual(entry.pid, ProcessScanner.minimumPID)
            XCTAssertNotEqual(entry.pid, getpid())
            XCTAssertFalse(entry.name.isEmpty)
        }
        XCTAssertEqual(top.map { $0.resident }, top.map { $0.resident }.sorted(by: >))
    }
}