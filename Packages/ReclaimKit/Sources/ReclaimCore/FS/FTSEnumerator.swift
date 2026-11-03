// `fts(3)` fallback (PLAN.md §2.6.4, ADR-002). `FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV`.
// Private size is not available: it is reported equal to allocated and `sizeConfidence` is `.allocatedOnly`.
// The `FTS*` handle is confined to the task that calls `walk`. The type is not `Sendable`.

import Darwin
import Foundation

public enum SizeConfidence: UInt8, Sendable, Equatable {
    case full
    case allocatedOnly
}

public struct FTSNode: Sendable {
    public var level: Int
    public var info: Int32
    public var path: String
    public var name: Data
    public var error: Int32
    public var objType: UInt32
    public var mtimeSeconds: Int64
    public var uid: UInt32
    public var mode: UInt32
    public var flags: UInt32
    public var fileID: UInt64
    public var linkCount: UInt32
    public var logicalSize: UInt64
    public var allocatedSize: UInt64
    public var device: UInt64
    public var sizeConfidence: SizeConfidence
    public var isMountBoundary: Bool
}

/// Tree walk used when `getattrlistbulk` is unavailable. One instance, one task.
public final class FTSEnumerator {
    public init() {}

    /// Physical walk. `onMount` / excluded directories are delivered once and not descended (`FTS_SKIP`).
    public func walk(
        path: String,
        shouldSkip: (FTSNode) -> Bool = { _ in false }
    ) throws -> [FTSNode] {
        var nodes: [FTSNode] = []
        try forEach(path: path, shouldSkip: shouldSkip) { nodes.append($0) }
        return nodes
    }

    func forEach(path: String, shouldSkip: (FTSNode) -> Bool, _ body: (FTSNode) -> Void) throws {
        let cPath = strdup(path)
        guard let cPath else { throw FSError.posix(call: "strdup", errno: ENOMEM, path: path) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let handle = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw FSError.capture("fts_open", path: path)
        }
        defer { fts_close(handle) }

        while true {
            errno = 0
            guard let entry = fts_read(handle) else {
                if errno != 0 { throw FSError.capture("fts_read", path: path) }
                return
            }
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            guard let node = Self.node(from: entry, root: path) else { continue }
            body(node)
            if info == FTS_D, shouldSkip(node) {
                fts_set(handle, entry, FTS_SKIP)
            }
        }
    }

    private static func node(from entry: UnsafeMutablePointer<FTSENT>, root: String) -> FTSNode? {
        let info = Int32(entry.pointee.fts_info)
        let nameLength = Int(entry.pointee.fts_namelen)
        let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name) ?? 0
        let name = Data(bytes: UnsafeRawPointer(entry).advanced(by: nameOffset), count: nameLength)
        let full = entry.pointee.fts_path.map { String(cString: $0) } ?? root
        let level = Int(entry.pointee.fts_level)

        if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
            let code = entry.pointee.fts_errno
            return FTSNode(
                level: level, info: info, path: full, name: name, error: code,
                objType: info == FTS_DNR ? UInt32(VDIR.rawValue) : 0,
                mtimeSeconds: 0, uid: 0, mode: 0, flags: 0, fileID: 0, linkCount: 0,
                logicalSize: 0, allocatedSize: 0, device: 0,
                sizeConfidence: SizeConfidence.allocatedOnly, isMountBoundary: false
            )
        }
        guard let statp = entry.pointee.fts_statp else { return nil }
        let st = statp.pointee
        let allocated = UInt64(clamping: st.st_blocks) * 512
        let kind = st.st_mode & S_IFMT
        let obj: UInt32
        switch kind {
        case S_IFREG: obj = UInt32(VREG.rawValue)
        case S_IFDIR: obj = UInt32(VDIR.rawValue)
        case S_IFLNK: obj = UInt32(VLNK.rawValue)
        case S_IFSOCK: obj = UInt32(VSOCK.rawValue)
        case S_IFIFO: obj = UInt32(VFIFO.rawValue)
        case S_IFBLK: obj = UInt32(VBLK.rawValue)
        case S_IFCHR: obj = UInt32(VCHR.rawValue)
        default: obj = 0
        }
        // `fts` was opened with `FTS_XDEV`, so a mount point is reported as `FTS_D` and then not descended
        // only when the caller skips it. `FTS_DC` is a cycle (symlink loop is already not followed).
        return FTSNode(
            level: level,
            info: info,
            path: full,
            name: level == 0 ? Data(root.utf8) : name,
            error: 0,
            objType: obj,
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
            uid: st.st_uid,
            mode: UInt32(st.st_mode & 0xFFFF),
            flags: st.st_flags,
            fileID: UInt64(st.st_ino),
            linkCount: UInt32(st.st_nlink),
            logicalSize: UInt64(clamping: st.st_size),
            allocatedSize: allocated,
            device: UInt64(truncatingIfNeeded: st.st_dev),
            sizeConfidence: SizeConfidence.allocatedOnly,
            isMountBoundary: false
        )
    }
}
