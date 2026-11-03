import Darwin
import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

@Suite("Cancellation and fd cap", .tags(.requiresAPFS))
struct CancellationTests {
    @Test func cancelYieldsPartialAndReleasesDescriptors() async throws {
        let full = ProcessInfo.processInfo.environment["RECLAIM_BENCH_FULL"] == "1"
        let directories = full ? 200_000 : 15_000
        let fixture = try FixtureBuilder.largeTree(dirs: directories, filesPerDir: 10, bytesPerFile: 0)
        defer { fixture.cleanup() }
        let before = DirectoryOpen.openFileDescriptorCount()
        let engine = ScanEngine(topology: VolumeTopology())
        let options = ScanOptions(roots: [fixture.path], useDefaultExcludes: false)
        let stream = await engine.run(options)
        let clock = ContinuousClock()
        try await Task.sleep(for: .milliseconds(500))
        let cancelStarted = clock.now
        await engine.cancel()
        var summary: ScanSummary?
        for try await event in stream {
            if case let .finished(value) = event {
                summary = value
                break
            }
        }
        let finished = clock.now
        let finishedSummary = try #require(summary)
        #expect(finishedSummary.completeness == .partial(reasons: ["cancelled"]))
        let limit: Duration = ProcessInfo.processInfo.environment["RECLAIM_BENCH_RELEASE"] == "1" ? .milliseconds(200) : .seconds(3)
        #expect(cancelStarted.duration(to: finished) < limit)
        #expect(finishedSummary.openDirectoryFDs == 0)
        // proc_pidinfo is process-wide. Other tests in this process open fds too, so the baseline
        // check is only meaningful when this test runs alone (the phase report does that).
        if ProcessInfo.processInfo.environment["RECLAIM_FD_ISOLATED"] == "1" {
            let after = DirectoryOpen.openFileDescriptorCount()
            #expect(after <= before + 8, "fds \(before) -> \(after)")
        }
        _ = before
    }

    /// 50 k directories, a spine of depth 300, never more than 2 048 directory fds and no EMFILE.
    @Test func deepTreeDoesNotExhaustDescriptors() async throws {
        let root = try makeDeepTree(directories: 50_000, depth: 300)
        defer { try? FixtureBuilder.remove(at: URL(fileURLWithPath: root, isDirectory: true)) }
        let outcome = try await ScanHarness.scan([root])
        #expect(outcome.summary?.completeness == .complete)
        #expect((outcome.summary?.maxOpenDirectoryFDs ?? 9_999) <= DirectoryOpen.schedulerCap)
        let unreadable = outcome.events.compactMap { event -> Int32? in
            if case let .unreadable(_, errno) = event { return errno }
            return nil
        }
        #expect(!unreadable.contains(EMFILE))
        #expect(outcome.reader.count >= 50_000)
    }

    private func makeDeepTree(directories: Int, depth: Int) throws -> String {
        let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("rcl-deep-XXXXXX")
        var buffer = Array(template.utf8) + [0]
        let root: String = try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self), mkdtemp(base) != nil else {
                throw FSError.capture("mkdtemp", path: template)
            }
            return String(cString: base)
        }
        var parent = try FileDescriptor.openDirectory(atPath: root)
        var made = 1
        for _ in 1..<depth {
            let name = "s"
            let fd = name.withCString { openat(parent.fd, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            if fd < 0 {
                let created = name.withCString { mkdirat(parent.fd, $0, 0o755) }
                if created != 0 { throw FSError.capture("mkdirat", path: root) }
                let opened = name.withCString { openat(parent.fd, $0, DirectoryOpen.flags) }
                if opened < 0 { throw FSError.capture("openat", path: root) }
                parent.close()
                parent = FileDescriptor(adopting: opened)
            } else {
                parent.close()
                parent = FileDescriptor(adopting: fd)
            }
            made += 1
        }
        let anchor = parent.fd
        while made < directories {
            let name = "b\(made)"
            let rc = name.withCString { mkdirat(anchor, $0, 0o755) }
            if rc != 0 { throw FSError.capture("mkdirat", path: name) }
            made += 1
        }
        parent.close()
        return root
    }
}
