import Darwin
import Foundation
import ReclaimCore
import Testing

@Suite("Volume stats")
struct VolumeStatsTests {
    @Test func dataVolumeMatchesRootCapacity() throws {
        let stats = try VolumeStats.dataVolume()
        var root = statfs()
        #expect(statfs("/", &root) == 0)
        let rootTotal = UInt64(truncatingIfNeeded: root.f_blocks) * UInt64(truncatingIfNeeded: root.f_bsize)
        let delta = stats.total > rootTotal ? stats.total - rootTotal : rootTotal - stats.total
        #expect(rootTotal > 0)
        #expect(Double(delta) / Double(rootTotal) < 0.01)

        let df = try dfAvailableKilobytes()
        let bytes = df * 1024
        let drift = stats.available > bytes ? stats.available - bytes : bytes - stats.available
        // A live Data volume moves while tests run. 16 MiB is far tighter than a unit mistake
        // (f_bsize vs 1024) and wide enough for concurrent writes.
        #expect(drift < 16 << 20)
    }

    @Test func statfsPurgeableIsNonNegative() throws {
        let stats = try VolumeStats.dataVolume()
        #expect(stats.purgeableEstimate >= 0)
        #expect(stats.available <= stats.availableImportant)
    }

    private func dfAvailableKilobytes() throws -> UInt64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/df")
        process.arguments = ["-k", "/System/Volumes/Data"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        #expect(lines.count >= 2)
        let fields = lines[1].split(whereSeparator: \.isWhitespace)
        // Filesystem 1024-blocks Used Available Capacity ...
        #expect(fields.count >= 4)
        return UInt64(fields[3]) ?? 0
    }
}
