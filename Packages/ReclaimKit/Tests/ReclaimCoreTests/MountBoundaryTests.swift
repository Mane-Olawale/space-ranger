import Darwin
import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

@Suite("Mounts and firmlinks", .tags(.requiresAPFS))
struct MountBoundaryTests {
    @Test(.tags(.requiresAPFSMount)) func diskImageIsABoundary() async throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [.file(name: "keep", logicalBytes: 4)]))
        defer { fixture.cleanup() }
        let image = fixture.path + "/image.dmg"
        let mount = fixture.path + "/mnt"
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        try runTool("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "APFS", "-volname", "RCLTest", image, "-quiet"])
        try runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint", mount, image, "-quiet"])
        defer { try? runTool("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"]) }

        let parent = try FileDescriptor.openDirectory(atPath: fixture.path)
        defer { parent.close() }
        let listed = try BulkAttrEnumerator().readDirectory(dirfd: parent.fd, expectedCount: 0)
        let entry = try #require(listed.first { $0.nameText == "mnt" })
        #expect(entry.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0)

        let outcome = try await ScanHarness.scan([fixture.path])
        let id = try #require(outcome.reader.find(path: mount) ?? outcome.reader.find(path: outcome.reader.firmlinks.canonicalize(mount)))
        let summary = outcome.reader.summary(id)
        #expect(summary.kind == .mountBoundary)
        #expect(outcome.reader.children(of: id, sortedBy: .allocated, page: 0..<10).isEmpty)
        var info = statfs()
        if statfs(mount, &info) == 0 {
            let block = UInt64(truncatingIfNeeded: info.f_bsize)
            let total = UInt64(truncatingIfNeeded: info.f_blocks) * block
            let free = UInt64(truncatingIfNeeded: info.f_bfree) * block
            let used = total > free ? total - free : 0
            #expect(summary.sizes.allocated == used)
        }
        let boundaries = outcome.events.compactMap { event -> String? in
            if case let .boundary(path, _) = event { return path }
            return nil
        }
        #expect(!boundaries.isEmpty)
    }
}

@Suite("Firmlink dedupe", .tags(.requiresAPFS))
struct FirmlinkTests {
    @Test func sameInodeIsOneEntry() async throws {
        let resolved = PathCanonicalizer.realpath(FileManager.default.temporaryDirectory.path) ?? "/private/tmp"
        let leafName = "rcl-firmlink-\(getpid())"
        let systemSide = resolved + "/" + leafName
        try FileManager.default.createDirectory(atPath: systemSide, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: systemSide) }
        let canonical = PathCanonicalizer.system().canonicalize(systemSide)
        let dataSide: String
        if canonical.hasPrefix("/System/Volumes/Data/") {
            dataSide = canonical
        } else if systemSide.hasPrefix("/private/") {
            dataSide = "/System/Volumes/Data" + systemSide
        } else {
            dataSide = "/System/Volumes/Data/private" + systemSide
        }
        let outcome = try await ScanHarness.scan([systemSide, dataSide])
        #expect(outcome.reader.count == 1)
        #expect(outcome.reader.roots.count == 1)
        let single = try await ScanHarness.scan([systemSide])
        #expect(single.reader.count == outcome.reader.count)
    }
}
