// Shared types for the three enumeration strategies benchmarked in Phase 0 (PLAN.md §6 Phase 0, §2.6.1).

import Darwin
import Foundation

/// Counters accumulated by a walk. Byte totals are naive sums over every entry (no hard-link or clone
/// deduplication) so the three strategies are directly comparable.
struct WalkStats: Sendable, Codable, Equatable {
    var entries = 0
    var directories = 0
    var files = 0
    var symlinks = 0
    var others = 0
    var bytesLogical: UInt64 = 0
    var bytesAllocated: UInt64 = 0
    /// Directories that could not be opened/read or entries that could not be stat'ed.
    var errors = 0

    mutating func merge(_ other: WalkStats) {
        entries += other.entries
        directories += other.directories
        files += other.files
        symlinks += other.symlinks
        others += other.others
        bytesLogical += other.bytesLogical
        bytesAllocated += other.bytesAllocated
        errors += other.errors
    }
}

enum WalkError: Error, CustomStringConvertible {
    case posix(call: String, path: String, errno: Int32)
    case notADirectory(String)

    var description: String {
        switch self {
        case let .posix(call, path, code):
            return "\(call)(\(path)): \(String(cString: strerror(code))) (errno \(code))"
        case let .notADirectory(path):
            return "\(path) is not a directory"
        }
    }
}

/// One enumeration strategy. Implementations count every entry *below* `root` (the root itself excluded).
protocol WalkStrategy: Sendable {
    var name: String { get }
    /// Number of concurrent workers the strategy actually uses (1 for inherently serial strategies).
    var workers: Int { get }
    /// Attribute set requested from the kernel, when the strategy has a choice (bulk only).
    var attributeSet: String? { get }
    func walk(root: String) async throws -> WalkStats
}

extension WalkStrategy {
    var attributeSet: String? { nil }
}

/// Process-wide peak physical footprint via `proc_pid_rusage` (PLAN.md Phase 0 "peak RSS (proc_pid_rusage)").
enum ResourceUsage {
    static func peakFootprintBytes() -> UInt64 {
        usage()?.ri_lifetime_max_phys_footprint ?? 0
    }

    static func currentFootprintBytes() -> UInt64 {
        usage()?.ri_phys_footprint ?? 0
    }

    /// `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)`. The C signature is `rusage_info_t *buffer` with
    /// `typedef void *rusage_info_t`, but the kernel writes the struct *at* `buffer` (C callers cast
    /// `(rusage_info_t *)&info`), so the struct pointer itself is rebound — not a pointer to a pointer.
    private static func usage() -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return rc == 0 ? info : nil
    }

    /// Raises the soft `RLIMIT_NOFILE` to `min(hard, 8192)` (PLAN.md §2.6.2).
    static func raiseFileDescriptorLimit(to desired: rlim_t = 8192) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, desired)
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }
}
