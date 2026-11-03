// T1-BENCH-2M (ADR-016). `swift test` (debug) scans a small tree and checks the RSS cap.
// `RECLAIM_BENCH_FULL=1` scans the 2.2 M fixture (reusing /private/tmp/rcl-fixture when present).
// The ≤ 6 s budget is a release-build gate: debug is asserted only for RSS and entry count.
// Scripts/bench.sh records the release number in docs/benchmarks/phase1.json.

import Foundation
import ReclaimCore
import ReclaimTestSupport
import XCTest

final class Phase1BenchmarkTests: XCTestCase {
    func testT1Bench2M() async throws {
        let full = ProcessInfo.processInfo.environment["RECLAIM_BENCH_FULL"] == "1"
        let release = ProcessInfo.processInfo.environment["RECLAIM_BENCH_RELEASE"] == "1"
        let owned: Fixture?
        let root: String
        if full, FileManager.default.fileExists(atPath: "/private/tmp/rcl-fixture") {
            owned = nil
            root = "/private/tmp/rcl-fixture"
        } else if full {
            let fixture = try FixtureBuilder.largeTree(dirs: 200_000, filesPerDir: 10, bytesPerFile: 0)
            owned = fixture
            root = fixture.path
        } else {
            let fixture = try FixtureBuilder.largeTree(dirs: 200, filesPerDir: 10, bytesPerFile: 0)
            owned = fixture
            root = fixture.path
        }
        defer { owned?.cleanup() }

        let outcome = try await ScanHarness.scan([root], useDefaultExcludes: false)
        let summary = try XCTUnwrap(outcome.summary)
        if full {
            XCTAssertEqual(summary.entryCount, 2_200_001, "root plus 2.2 M entries")
            if release {
                XCTAssertLessThanOrEqual(summary.elapsed, .seconds(6))
            }
        } else {
            XCTAssertGreaterThan(summary.entryCount, 200)
        }
        XCTAssertLessThanOrEqual(summary.peakRSSBytes, 300 * 1024 * 1024)
        XCTAssertEqual(summary.openDirectoryFDs, 0)
    }
}
