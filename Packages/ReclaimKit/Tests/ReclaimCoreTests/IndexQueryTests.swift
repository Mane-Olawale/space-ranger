import Darwin
import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

@Suite("Index", .tags(.requiresAPFS))
struct IndexQueryTests {
    @Test func queryByKind() async throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .file(name: "a", logicalBytes: 10),
            .symlink(name: "s", to: "a"),
        ]))
        defer { fixture.cleanup() }
        let reader = try await ScanHarness.scan([fixture.path]).reader
        let files = reader.query(IndexQuery(.kind(.file)))
        #expect(files.contains { reader.name(of: $0) == "a" })
        #expect(!files.contains { reader.name(of: $0) == "s" })
    }

    /// T1-INDEX-SORT: 200 k children, first page sorted by allocated size in ≤ 50 ms.
    @Test func sortTwoHundredThousandChildren() async throws {
        let root = try temporaryRoot()
        defer { try? FixtureBuilder.remove(at: URL(fileURLWithPath: root, isDirectory: true)) }
        let wide = root + "/wide"
        try mkdir(wide)
        for index in 0..<200_000 {
            let path = wide + "/f\(index)"
            let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644) }
            if fd >= 0 { Darwin.close(fd) }
        }
        let reader = try await ScanHarness.scan([root]).reader
        let rootID = try #require(reader.roots.first)
        let wideID = try #require(
            reader.children(of: rootID, sortedBy: .allocated, page: 0..<8).first { $0.name == "wide" }?.id
        )
        let clock = ContinuousClock()
        let started = clock.now
        let page = reader.children(of: wideID, sortedBy: .allocated, page: 0..<200)
        let elapsed = started.duration(to: clock.now)
        #expect(page.count == 200)
        // 50 ms is the release budget (PLAN.md T1-INDEX-SORT). Debug stdlib sort/walk overhead is
        // several times that; the debug ceiling still fails a broken O(n²) implementation.
        #if DEBUG
        let budget: Duration = .milliseconds(500)
        #else
        let budget: Duration = .milliseconds(50)
        #endif
        #expect(elapsed < budget, "sort took \(elapsed)")
        let keys = page.map(\.sizes.allocated)
        #expect(keys == keys.sorted(by: >))
    }

    private func temporaryRoot() throws -> String {
        let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("rcl-wide-XXXXXX")
        var buffer = Array(template.utf8) + [0]
        let created = buffer.withUnsafeMutableBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            guard mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let created else { throw FSError.posix(call: "mkdtemp", errno: errno, path: template) }
        return created
    }

    private func mkdir(_ path: String) throws {
        let rc = path.withCString { Darwin.mkdir($0, 0o755) }
        if rc != 0 { throw FSError.capture("mkdir", path: path) }
    }
}
