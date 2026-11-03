// DiskUsage — the `du`-equivalent oracle used by Phase 0 tests (PLAN.md T0-FIXTURE-SIZES: "fts + st_blocks")
// and by FixtureBuilder to measure tool-generated subtrees (`.git`).

import Darwin
import Foundation

/// Sizes measured by walking a tree with `fts(3)` (`FTS_PHYSICAL | FTS_XDEV`), summing `st_size` and
/// `st_blocks * 512` once per inode (hard links are deduplicated like `du`), plus `ATTR_CMNEXT_PRIVATESIZE`
/// for every regular file. The root entry itself is not counted in `entryCount`.
public struct DiskUsage: Sendable, Equatable {
    public var logical: UInt64 = 0
    public var allocated: UInt64 = 0
    public var privateBytes: UInt64 = 0
    public var entryCount: Int = 0
    public var directories: Int = 0
    public var files: Int = 0
    public var symlinks: Int = 0
    public var others: Int = 0
    /// Entries fts could not stat or descend into (e.g. `EACCES` directories).
    public var errors: Int = 0

    public init() {}

    /// Walks `path` physically (never following symlinks, never crossing devices).
    public static func measure(at path: String) throws -> DiskUsage {
        var usage = DiskUsage()
        var seen = Set<InodeKey>()
        let cPath = strdup(path)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let handle = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw FixtureError.posix(call: "fts_open", path: path, errno: errno)
        }
        defer { fts_close(handle) }

        while true {
            errno = 0
            guard let entry = fts_read(handle) else {
                if errno != 0 { throw FixtureError.posix(call: "fts_read", path: path, errno: errno) }
                break
            }
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }                 // post-order directory visit
            let isRoot = entry.pointee.fts_level == 0
            if !isRoot { usage.entryCount += 1 }

            switch info {
            case FTS_D:
                if !isRoot { usage.directories += 1 }
            case FTS_DNR, FTS_ERR, FTS_NS:
                usage.errors += 1
                if info == FTS_DNR, !isRoot { usage.directories += 1 }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_NSOK:
                guard let statp = entry.pointee.fts_statp else { continue }
                let st = statp.pointee
                let kind = st.st_mode & S_IFMT
                if info == FTS_F { usage.files += 1 } else if kind == S_IFLNK { usage.symlinks += 1 } else { usage.others += 1 }
                if st.st_nlink > 1 {
                    let key = InodeKey(device: st.st_dev, inode: st.st_ino)
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                usage.logical += UInt64(clamping: st.st_size)
                usage.allocated += UInt64(clamping: st.st_blocks) * 512
                if kind == S_IFREG {
                    usage.privateBytes += try privateSize(atPath: String(cString: entry.pointee.fts_path))
                }
            default:
                continue
            }
        }
        return usage
    }

    /// `ATTR_CMNEXT_PRIVATESIZE` for a single path (bytes not shared with any other file via APFS clones).
    public static func privateSize(atPath path: String) throws -> UInt64 {
        let attrs = try FileAttributes.read(atPath: path)
        return attrs.privateSize
    }

    private struct InodeKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }
}

/// Extended attributes for one path read with `getattrlist(2)` + `FSOPT_ATTR_CMN_EXTENDED`
/// (what Phase 1's `BulkAttrEnumerator` will read in bulk). Test-side verification only.
public struct FileAttributes: Sendable, Equatable {
    public let totalSize: UInt64
    public let allocatedSize: UInt64
    public let privateSize: UInt64
    public let cloneID: UInt64
    public let extFlags: UInt64

    public var isSparse: Bool { extFlags & UInt64(EF_IS_SPARSE) != 0 }
    public var mayShareBlocks: Bool { extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 }
    public var sharesAllBlocks: Bool { extFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 }

    public static func read(atPath path: String) throws -> FileAttributes {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
        var buffer = [UInt8](repeating: 0, count: 128)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard rc == 0 else { throw FixtureError.posix(call: "getattrlist", path: path, errno: errno) }
        return buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            func take<T>(_ group: attrgroup_t, _ bit: Int32, as type: T.Type) -> T? {
                guard group & attrgroup_t(bit) != 0 else { return nil }
                let value = raw.loadUnaligned(fromByteOffset: offset, as: type)
                offset += MemoryLayout<T>.size
                return value
            }
            let total = take(returned.fileattr, ATTR_FILE_TOTALSIZE, as: Int64.self) ?? 0
            let alloc = take(returned.fileattr, ATTR_FILE_ALLOCSIZE, as: Int64.self) ?? 0
            let priv = take(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE, as: Int64.self) ?? 0
            let clone = take(returned.forkattr, ATTR_CMNEXT_CLONEID, as: UInt64.self) ?? 0
            let ext = take(returned.forkattr, ATTR_CMNEXT_EXT_FLAGS, as: UInt64.self) ?? 0
            return FileAttributes(
                totalSize: UInt64(clamping: total),
                allocatedSize: UInt64(clamping: alloc),
                privateSize: UInt64(clamping: priv),
                cloneID: clone,
                extFlags: ext
            )
        }
    }
}
