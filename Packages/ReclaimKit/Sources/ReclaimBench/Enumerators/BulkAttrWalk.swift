// Strategy 3 — `getattrlistbulk(2)` with the exact attribute set of PLAN.md §2.6.2, parallel workers pulling
// directory descriptors from a LIFO work queue (§2.6.5). Directories are opened with
// `openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` straight from the kernel buffer —
// no path strings are built at all.
//
// Parsing is bitmap-driven: each field is read only if its bit is set in the returned `attribute_set_t`,
// in ascending bit order within group, groups common → dir → file → common-extended. Validated against
// `fstatat` in the Phase 0 probe (see docs/benchmarks/phase0.json "notes"); T1-BULK-PARITY makes it a test.

import Darwin
import Foundation

/// Which attributes the bulk walk requests. `full` is the PLAN.md §2.6.2 set; the smaller sets exist so the
/// per-attribute kernel cost (notably the common-extended clone/private-size attributes) can be measured.
enum BulkAttributeSet: String, CaseIterable, Sendable {
    /// RETURNED_ATTRS, NAME, ERROR, OBJTYPE + FILE_TOTALSIZE/ALLOCSIZE + DIR_ENTRYCOUNT/MOUNTSTATUS: the minimum a sizing walk needs.
    case minimal
    /// `full` minus the common-extended group (PRIVATESIZE, LINKID, CLONEID, EXT_FLAGS).
    case standard
    /// The complete PLAN.md §2.6.2 attribute set, including FSOPT_ATTR_CMN_EXTENDED attributes.
    case full
}

struct BulkAttrWalk: WalkStrategy {
    let name = "bulk"
    let workers: Int
    let bufferBytes: Int
    let attributes: BulkAttributeSet
    /// Stop reading a directory as soon as `ATTR_DIR_ENTRYCOUNT` entries (reported by its parent) have been
    /// returned, saving the final zero-length `getattrlistbulk` call per directory.
    let trustEntryCount: Bool
    var attributeSet: String? { attributes.rawValue }

    init(workers: Int, bufferBytes: Int = 256 * 1024, attributes: BulkAttributeSet = .full, trustEntryCount: Bool = true) {
        self.workers = max(1, workers)
        self.bufferBytes = bufferBytes
        self.attributes = attributes
        self.trustEntryCount = trustEntryCount
    }

    func walk(root: String) async throws -> WalkStats {
        ResourceUsage.raiseFileDescriptorLimit()
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw WalkError.posix(call: "open", path: root, errno: errno) }

        let queue = DirectoryWorkQueue()
        await queue.push([DirectoryItem(fd: rootFD, entryCount: 0)])
        let configuration = BulkWorker.Configuration(bufferBytes: bufferBytes, attributes: attributes, trustEntryCount: trustEntryCount)
        return await withTaskGroup(of: WalkStats.self, returning: WalkStats.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    let worker = BulkWorker(queue: queue, configuration: configuration)
                    return await worker.run()
                }
            }
            var total = WalkStats()
            for await partial in group { total.merge(partial) }
            return total
        }
    }
}

/// An open directory descriptor plus the entry count its parent reported (0 when unknown).
struct DirectoryItem: Sendable {
    let fd: Int32
    let entryCount: UInt32
}

/// LIFO queue of open directory descriptors. Ownership of an fd moves to the worker that pops it.
/// `pending` counts pushed-but-unfinished directories; when it drops to zero every waiter receives `nil`.
actor DirectoryWorkQueue {
    private var stack: [DirectoryItem] = []
    private var pending = 0
    private var waiters: [CheckedContinuation<DirectoryItem?, Never>] = []

    func push(_ items: [DirectoryItem]) {
        pending += items.count
        for item in items {
            if let waiter = waiters.popLast() {
                waiter.resume(returning: item)
            } else {
                stack.append(item)
            }
        }
    }

    func next() async -> DirectoryItem? {
        if let item = stack.popLast() { return item }
        if pending == 0 { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Marks one popped directory as fully processed (its children have already been pushed).
    func finished() {
        pending -= 1
        if pending == 0 {
            let idle = waiters
            waiters.removeAll()
            for waiter in idle { waiter.resume(returning: nil) }
        }
    }
}

/// Requested attribute set (PLAN.md §2.6.2) and the matching bitmap-driven record parser.
enum BulkAttributes {
    static let commonAttrs: attrgroup_t =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_CHGTIME)
            | attrgroup_t(ATTR_CMN_OWNERID) | attrgroup_t(ATTR_CMN_GRPID) | attrgroup_t(ATTR_CMN_ACCESSMASK)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
    static let dirAttrs = attrgroup_t(ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS)
    static let fileAttrs = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
    static let extendedAttrs = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_LINKID | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
    static let options = UInt64(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)

    static func makeList(_ set: BulkAttributeSet) -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        switch set {
        case .minimal:
            list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
                | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
            list.dirattr = dirAttrs
            list.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        case .standard:
            list.commonattr = commonAttrs
            list.dirattr = dirAttrs
            list.fileattr = fileAttrs
        case .full:
            list.commonattr = commonAttrs
            list.dirattr = dirAttrs
            list.fileattr = fileAttrs
            list.forkattr = extendedAttrs
        }
        return list
    }

    static let objTypeDirectory = UInt32(VDIR.rawValue)
    static let objTypeRegular = UInt32(VREG.rawValue)
    static let objTypeSymlink = UInt32(VLNK.rawValue)
}

/// One worker task: owns one attribute buffer, pops directories until the queue drains.
struct BulkWorker {
    struct Configuration: Sendable {
        let bufferBytes: Int
        let attributes: BulkAttributeSet
        let trustEntryCount: Bool
    }

    let queue: DirectoryWorkQueue
    let configuration: Configuration

    func run() async -> WalkStats {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: configuration.bufferBytes, alignment: 8)
        defer { buffer.deallocate() }
        var list = BulkAttributes.makeList(configuration.attributes)
        var stats = WalkStats()
        var children: [DirectoryItem] = []
        children.reserveCapacity(64)

        while let item = await queue.next() {
            children.removeAll(keepingCapacity: true)
            readDirectory(item, list: &list, buffer: buffer, stats: &stats, children: &children)
            close(item.fd)
            if !children.isEmpty { await queue.push(children) }
            await queue.finished()
        }
        return stats
    }

    private func readDirectory(
        _ item: DirectoryItem,
        list: inout attrlist,
        buffer: UnsafeMutableRawBufferPointer,
        stats: inout WalkStats,
        children: inout [DirectoryItem]
    ) {
        guard let base = buffer.baseAddress else { stats.errors += 1; return }
        var returned: UInt32 = 0
        while true {
            let count = getattrlistbulk(item.fd, &list, base, buffer.count, BulkAttributes.options)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                stats.errors += 1
                return
            }
            var record = UnsafeRawPointer(base)
            for _ in 0..<Int(count) {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                parse(record: record, dirfd: item.fd, stats: &stats, children: &children)
                record += length
            }
            returned += UInt32(count)
            if configuration.trustEntryCount, item.entryCount != 0, returned >= item.entryCount { return }
        }
    }

    private func parse(record: UnsafeRawPointer, dirfd: Int32, stats: inout WalkStats, children: inout [DirectoryItem]) {
        var cursor = record + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        stats.entries += 1

        @inline(__always) func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }

        if has(returned.commonattr, ATTR_CMN_ERROR) {
            let error = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
            if error != 0 { stats.errors += 1; return }
        }
        var namePointer: UnsafePointer<CChar>?
        if has(returned.commonattr, ATTR_CMN_NAME) {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            namePointer = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            cursor += MemoryLayout<attrreference_t>.size
        }
        var objType: UInt32 = 0
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) { objType = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        if has(returned.commonattr, ATTR_CMN_MODTIME) { cursor += MemoryLayout<timespec>.size }
        if has(returned.commonattr, ATTR_CMN_CHGTIME) { cursor += MemoryLayout<timespec>.size }
        if has(returned.commonattr, ATTR_CMN_OWNERID) { cursor += 4 }
        if has(returned.commonattr, ATTR_CMN_GRPID) { cursor += 4 }
        if has(returned.commonattr, ATTR_CMN_ACCESSMASK) { cursor += 4 }
        if has(returned.commonattr, ATTR_CMN_FLAGS) { cursor += 4 }
        if has(returned.commonattr, ATTR_CMN_FILEID) { cursor += 8 }

        var entryCount: UInt32 = 0
        var mountStatus: UInt32 = 0
        if has(returned.dirattr, ATTR_DIR_ENTRYCOUNT) { entryCount = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) { mountStatus = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }

        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { cursor += 4 }
        if has(returned.fileattr, ATTR_FILE_TOTALSIZE) {
            stats.bytesLogical += UInt64(clamping: cursor.loadUnaligned(as: Int64.self)); cursor += 8
        }
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) {
            stats.bytesAllocated += UInt64(clamping: cursor.loadUnaligned(as: Int64.self)); cursor += 8
        }
        // Common-extended group (PRIVATESIZE, LINKID, CLONEID, EXT_FLAGS) is not needed for the walk.

        switch objType {
        case BulkAttributes.objTypeDirectory:
            stats.directories += 1
            if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 { return } // boundary: do not descend
            guard let name = namePointer else { stats.errors += 1; return }
            let child = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child >= 0 { children.append(DirectoryItem(fd: child, entryCount: entryCount)) } else { stats.errors += 1 }
        case BulkAttributes.objTypeRegular:
            stats.files += 1
        case BulkAttributes.objTypeSymlink:
            stats.symlinks += 1
        default:
            stats.others += 1
        }
    }
}
