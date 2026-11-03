// Strategy 1 — Foundation `FileManager.enumerator` (the approach PLAN.md §2.6.1 rejects for the scanner).
// One attribute fetch and several object allocations per entry; single-threaded by construction.

import Foundation
import os

struct FileManagerWalk: WalkStrategy {
    let name = "filemanager"
    let workers = 1

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
    ]

    func walk(root: String) async throws -> WalkStats {
        try walkSynchronously(root: root)
    }

    /// `NSEnumerator` iteration is unavailable from async contexts, hence the synchronous body.
    private func walkSynchronously(root: String) throws -> WalkStats {
        var stats = WalkStats()
        let errorCount = OSAllocatedUnfairLock(initialState: 0)
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: rootURL,
                  includingPropertiesForKeys: Array(Self.keys),
                  options: [],
                  errorHandler: { _, _ in
                      errorCount.withLock { $0 += 1 }
                      return true
                  }
              ) else {
            throw WalkError.notADirectory(root)
        }

        for case let url as URL in enumerator {
            stats.entries += 1
            guard let values = try? url.resourceValues(forKeys: Self.keys) else {
                stats.errors += 1
                continue
            }
            if values.isDirectory == true {
                stats.directories += 1
            } else if values.isSymbolicLink == true {
                stats.symlinks += 1
            } else if values.isRegularFile == true {
                stats.files += 1
            } else {
                stats.others += 1
            }
            if values.isDirectory != true {
                stats.bytesLogical += UInt64(values.fileSize ?? 0)
                stats.bytesAllocated += UInt64(values.totalFileAllocatedSize ?? 0)
            }
        }
        stats.errors += errorCount.withLock { $0 }
        return stats
    }
}
