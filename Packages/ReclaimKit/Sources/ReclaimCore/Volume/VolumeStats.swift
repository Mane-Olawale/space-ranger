// Free / used / purgeable for one mount (PLAN.md §2.7, §2.8, §6 Phase 1).
// `purgeableEstimate` is important-usage capacity minus the POSIX available capacity. It is never
// treated as reclaimable savings.

import Darwin
import Foundation

public struct VolumeStats: Sendable, Equatable {
    public let total: UInt64
    public let used: UInt64
    public let available: UInt64
    public let availableImportant: UInt64
    public let availableOpportunistic: UInt64

    public init(
        total: UInt64,
        used: UInt64,
        available: UInt64,
        availableImportant: UInt64,
        availableOpportunistic: UInt64
    ) {
        self.total = total
        self.used = used
        self.available = available
        self.availableImportant = availableImportant
        self.availableOpportunistic = availableOpportunistic
    }

    /// Space the OS can still purge. Zero when important-usage is not reported above `available`.
    public var purgeableEstimate: UInt64 {
        availableImportant > available ? availableImportant &- available : 0
    }

    public static func dataVolume() throws -> VolumeStats {
        try stats(atPath: "/System/Volumes/Data")
    }

    public static func stats(atPath path: String) throws -> VolumeStats {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw FSError.capture("statfs", path: path) }
        let block = UInt64(truncatingIfNeeded: info.f_bsize)
        let total = UInt64(truncatingIfNeeded: info.f_blocks) * block
        let free = UInt64(truncatingIfNeeded: info.f_bfree) * block
        let available = UInt64(truncatingIfNeeded: info.f_bavail) * block
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let important = UInt64(clamping: values?.volumeAvailableCapacityForImportantUsage ?? Int64(available))
        let opportunistic = UInt64(clamping: values?.volumeAvailableCapacityForOpportunisticUsage ?? Int64(available))
        return VolumeStats(
            total: total,
            used: total > free ? total &- free : 0,
            available: available,
            availableImportant: max(important, available),
            availableOpportunistic: max(opportunistic, available)
        )
    }
}

enum MountPoint {
    static func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }

    static func usedBytes(_ info: statfs) -> UInt64 {
        let block = UInt64(truncatingIfNeeded: info.f_bsize)
        let total = UInt64(truncatingIfNeeded: info.f_blocks) &* block
        let free = UInt64(truncatingIfNeeded: info.f_bfree) &* block
        return total > free ? total &- free : 0
    }

    static func read(atPath path: String) -> statfs? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return info
    }
}
