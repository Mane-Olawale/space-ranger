import Darwin
import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

@Suite("Scan behaviour", .tags(.requiresAPFS))
struct ScanEngineTests {
    @Test func symlinkLoopTerminates() async throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .dir(name: "d", children: [
                .symlink(name: "a", to: "b"),
                .symlink(name: "b", to: "a"),
                .symlink(name: "up", to: ".."),
                .file(name: "keep", logicalBytes: 32),
            ]),
        ]))
        defer { fixture.cleanup() }
        let outcome = try await ScanHarness.scan([fixture.path])
        let reader = outcome.reader
        for name in ["a", "b", "up"] {
            let id = try #require(reader.find(path: fixture.path + "/d/" + name))
            let summary = reader.summary(id)
            #expect(summary.kind == .symlink)
            #expect(summary.sizes.allocated < 64 * 1024)
        }
        #expect(outcome.summary?.completeness == .complete)
    }

    @Test func unreadableDirectoryContinues() async throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .dir(name: "locked", mode: 0, children: [.file(name: "secret", logicalBytes: 8)]),
            .file(name: "visible", logicalBytes: 8),
        ]))
        defer { fixture.cleanup() }
        let outcome = try await ScanHarness.scan([fixture.path])
        let locked = try #require(outcome.reader.find(path: fixture.path + "/locked"))
        let summary = outcome.reader.summary(locked)
        #expect(summary.kind == .unreadable)
        #expect(summary.errno == EACCES)
        let events = outcome.events.compactMap { event -> Int32? in
            if case let .unreadable(_, errno) = event { return errno }
            return nil
        }
        #expect(events.contains(EACCES))
        #expect(outcome.reader.find(path: fixture.path + "/visible") != nil)
    }

    @Test func forceFTSAgreesOnEntryCount() async throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .dir(name: "d", children: [
                .file(name: "a", logicalBytes: 100),
                .symlink(name: "s", to: "a"),
            ]),
        ]))
        defer { fixture.cleanup() }
        let bulk = try await ScanHarness.scan([fixture.path])
        let fts = try await ScanHarness.scan([fixture.path], forceFTS: true)
        #expect(bulk.reader.count == fts.reader.count)
        let path = fixture.path + "/d/a"
        let bulkFile = bulk.reader.summary(try #require(bulk.reader.find(path: path)))
        let ftsFile = fts.reader.summary(try #require(fts.reader.find(path: path)))
        #expect(bulkFile.sizes.logical == ftsFile.sizes.logical)
        #expect(ftsFile.extFlags.contains(.allocatedOnly))
    }
}
