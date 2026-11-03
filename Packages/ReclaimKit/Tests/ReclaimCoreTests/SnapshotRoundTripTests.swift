import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

@Suite("Snapshot", .tags(.requiresAPFS))
struct SnapshotRoundTripTests {
    @Test func roundTripPreservesArrays() async throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .dir(name: "d", children: [
                .file(name: "a", logicalBytes: 40),
                .file(name: "b", logicalBytes: 80),
            ]),
        ]))
        defer { fixture.cleanup() }
        let outcome = try await ScanHarness.scan([fixture.path])
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "rcl-snap-\(UUID().uuidString).rclsnap")
        defer { try? FileManager.default.removeItem(at: url) }
        try SnapshotWriter.write(outcome.reader, volumes: [], completeness: .complete, to: url)
        let clock = ContinuousClock()
        let started = clock.now
        let loaded = try SnapshotReader.load(from: url, firmlinks: outcome.reader.firmlinks)
        let elapsed = started.duration(to: clock.now)
        #expect(loaded.samePayload(as: outcome.reader))
        #expect(elapsed < .seconds(1))
        #expect(loaded.find(path: loaded.path(of: loaded.root(0))) == loaded.root(0))
    }
}
