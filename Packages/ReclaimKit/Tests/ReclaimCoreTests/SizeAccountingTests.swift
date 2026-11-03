import Darwin
import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

@Suite("Sizes and names", .tags(.requiresAPFS))
struct SizeAccountingTests {
    @Test func namesRoundTrip() async throws {
        let nfd = "e\u{0301}"
        let long = String(repeating: "n", count: 255)
        let newline = "line\nbreak"
        let emoji = "📁"
        let group = "120363076093068126@g.us"
        let spaced = "a b.lid.status"
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .dir(name: "box", children: [
                .file(name: group, logicalBytes: 1),
                .file(name: spaced, logicalBytes: 1),
                .file(name: newline, logicalBytes: 1),
                .file(name: nfd, logicalBytes: 1),
                .file(name: long, logicalBytes: 1),
                .file(name: emoji, logicalBytes: 1),
            ]),
        ]))
        defer { fixture.cleanup() }
        let outcome = try await ScanHarness.scan([fixture.path])
        let box = fixture.path + "/box"
        for name in [group, spaced, newline, nfd, long, emoji] {
            let full = box + "/" + name
            let id = try #require(outcome.reader.find(path: full))
            #expect(outcome.reader.name(of: id) == name)
            #expect(outcome.reader.find(path: outcome.reader.path(of: id)) == id)
        }
    }

    @Test func sparseFile() async throws {
        let logical = 1_000_000_000
        let written = 8_000_000
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .sparse(name: "disk.raw", logicalBytes: logical, writtenBytes: written),
        ]))
        defer { fixture.cleanup() }
        let outcome = try await ScanHarness.scan([fixture.path])
        let id = try #require(outcome.reader.find(path: fixture.path + "/disk.raw"))
        let summary = outcome.reader.summary(id)
        #expect(summary.sizes.logical == UInt64(logical))
        #expect(summary.sizes.allocated <= 9_000_000)
        #expect(summary.extFlags.isSparse)
    }

    @Test func clonePair() async throws {
        let bytes = 100 * 1024 * 1024
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .dir(name: "d", children: [
                .file(name: "A", logicalBytes: bytes),
                .clone(name: "B", of: "A"),
            ]),
        ]))
        defer { fixture.cleanup() }
        let outcome = try await ScanHarness.scan([fixture.path])
        let reader = outcome.reader
        let dir = try #require(reader.find(path: fixture.path + "/d"))
        let a = reader.summary(try #require(reader.find(path: fixture.path + "/d/A")))
        let b = reader.summary(try #require(reader.find(path: fixture.path + "/d/B")))
        let directory = reader.summary(dir)
        #expect(a.sizes.allocated + b.sizes.allocated == UInt64(bytes * 2))
        #expect(a.sizes.privateBytes == 0 || b.sizes.privateBytes == 0)
        #expect(a.sizes.privateBytes + b.sizes.privateBytes <= UInt64(bytes))
        #expect(directory.sizes.privateReclaimable == UInt64(bytes))
        #expect(a.cloneID != 0)
        #expect(a.cloneID == b.cloneID)
    }

    @Test func hardLinksCountOnce() async throws {
        let bytes = 64 * 1024
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .dir(name: "d", children: [
                .file(name: "A", logicalBytes: bytes),
                .hardlink(name: "B", of: "A"),
                .hardlink(name: "C", of: "A"),
                .hardlink(name: "D", of: "A"),
            ]),
        ]))
        defer { fixture.cleanup() }
        let outcome = try await ScanHarness.scan([fixture.path])
        let reader = outcome.reader
        let directory = reader.summary(try #require(reader.find(path: fixture.path + "/d")))
        let file = reader.summary(try #require(reader.find(path: fixture.path + "/d/A")))
        #expect(file.linkCount == 4)
        #expect(reader.summary(try #require(reader.find(path: fixture.path + "/d/D"))).linkCount == 4)
        #expect(directory.sizes.allocated >= file.sizes.allocated)
        #expect(directory.sizes.allocated < file.sizes.allocated * 2)
        #expect(directory.sizes.logical == file.sizes.logical || directory.sizes.logical == file.sizes.logical + directory.sizes.logical)
    }
}
