// Strategy 2 — `fts(3)` (PLAN.md §2.6.4 fallback enumerator): no object allocation, but one `lstat` per entry.
// `FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV`; single-threaded.

import Darwin
import Foundation

struct FTSWalk: WalkStrategy {
    let name = "fts"
    let workers = 1

    func walk(root: String) async throws -> WalkStats {
        var stats = WalkStats()
        let cRoot = strdup(root)
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let handle = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw WalkError.posix(call: "fts_open", path: root, errno: errno)
        }
        defer { fts_close(handle) }

        var sawRoot = false
        while true {
            errno = 0
            guard let entry = fts_read(handle) else {
                if errno != 0 { throw WalkError.posix(call: "fts_read", path: root, errno: errno) }
                break
            }
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if entry.pointee.fts_level == 0 {
                sawRoot = true
                if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { throw WalkError.notADirectory(root) }
                if info != FTS_D { throw WalkError.notADirectory(root) }
                continue
            }
            stats.entries += 1
            switch info {
            case FTS_D:
                stats.directories += 1
            case FTS_DNR:
                stats.directories += 1
                stats.errors += 1
            case FTS_ERR, FTS_NS:
                stats.errors += 1
            default:
                guard let statp = entry.pointee.fts_statp else { continue }
                let st = statp.pointee
                switch st.st_mode & S_IFMT {
                case S_IFREG: stats.files += 1
                case S_IFLNK: stats.symlinks += 1
                default: stats.others += 1
                }
                stats.bytesLogical += UInt64(clamping: st.st_size)
                stats.bytesAllocated += UInt64(clamping: st.st_blocks) * 512
            }
        }
        guard sawRoot else { throw WalkError.notADirectory(root) }
        return stats
    }
}
