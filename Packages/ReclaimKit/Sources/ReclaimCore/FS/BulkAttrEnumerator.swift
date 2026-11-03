// `getattrlistbulk(2)` loop (PLAN.md §2.6.2–2.6.3). One buffer per instance, confined to the task
// that created it. The fast path (`forEach`) hands the parser's name pointer to the caller for the
// duration of the callback so the scanner can memcpy into an arena — no per-entry `String` (phase1-profile).

import Darwin
import Foundation

/// One directory entry with its name copied out of the kernel buffer. For tests and the public
/// `DirectoryEnumerator` API. The scanner uses `forEach` instead.
public struct BulkEntry: Sendable, Equatable {
    public var name: Data
    public var error: Int32
    public var objType: UInt32
    public var mtimeSeconds: Int64
    public var uid: UInt32
    public var gid: UInt32
    public var mode: UInt32
    public var flags: UInt32
    public var fileID: UInt64
    public var entryCount: UInt32
    public var mountStatus: UInt32
    public var linkCount: UInt32
    public var logicalSize: UInt64
    public var allocatedSize: UInt64
    public var privateSize: UInt64
    public var cloneID: UInt64
    public var linkID: UInt64
    public var extFlags: UInt64

    public var isDirectory: Bool { objType == UInt32(VDIR.rawValue) }
    public var isRegularFile: Bool { objType == UInt32(VREG.rawValue) }
    public var isSymlink: Bool { objType == UInt32(VLNK.rawValue) }
    public var isMountPoint: Bool { mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 }
    public var isFirmlink: Bool { flags & UInt32(SF_FIRMLINK) != 0 }

    init(attributes: ParsedAttributes, name: Data) {
        self.name = name
        error = attributes.error
        objType = attributes.objType
        mtimeSeconds = attributes.mtimeSeconds
        uid = attributes.uid
        gid = attributes.gid
        mode = attributes.mode
        flags = attributes.flags
        fileID = attributes.fileID
        entryCount = attributes.entryCount
        mountStatus = attributes.mountStatus
        linkCount = attributes.linkCount
        logicalSize = attributes.logical
        allocatedSize = attributes.allocated
        privateSize = attributes.privateSize
        cloneID = attributes.cloneID
        linkID = attributes.linkID
        extFlags = attributes.extFlags
    }
}

/// Reads one directory fd. Not `Sendable`: the attribute buffer is confined to one task (PLAN.md §2.5).
public final class BulkAttrEnumerator: DirectoryEnumerator {
    private let storage: UnsafeMutableRawBufferPointer
    private var list: attrlist

    /// `bufferBytes` defaults to 256 KiB (PLAN.md §2.5). Smaller than one record is rejected by the kernel;
    /// the Phase 1 profile shows 256 KiB already drains every directory of the 2.2 M fixture in one call.
    public init(bufferBytes: Int = 256 * 1024) {
        let bytes = max(bufferBytes, 4096)
        storage = .allocate(byteCount: bytes, alignment: 8)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
        list = AttrList.make()
    }

    deinit { storage.deallocate() }

    public func readDirectory(dirfd: Int32, expectedCount: UInt32) throws -> [BulkEntry] {
        var entries: [BulkEntry] = []
        if expectedCount > 0 { entries.reserveCapacity(Int(expectedCount)) }
        try forEach(dirfd: dirfd, expectedCount: expectedCount) { attributes, name in
            entries.append(BulkEntry(attributes: attributes, name: Data(name)))
        }
        return entries
    }

    /// `body` must not store `name`; it aliases the attribute buffer until `body` returns.
    func forEach(
        dirfd: Int32,
        expectedCount: UInt32,
        _ body: (ParsedAttributes, UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard let base = storage.baseAddress else {
            throw FSError.posix(call: "getattrlistbulk", errno: EINVAL, path: nil)
        }
        var returned: UInt32 = 0
        while true {
            if expectedCount > 0, returned >= expectedCount { return }
            let count = getattrlistbulk(dirfd, &list, base, storage.count, AttrList.options)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw FSError.capture("getattrlistbulk")
            }
            var record = UnsafeRawPointer(base)
            let limit = record + storage.count
            for _ in 0..<Int(count) {
                guard record + MemoryLayout<UInt32>.size <= limit else { break }
                let length = Int(record.loadUnaligned(as: UInt32.self))
                guard length >= MemoryLayout<UInt32>.size, record + length <= limit else {
                    throw FSError.posix(call: "getattrlistbulk", errno: EIO, path: nil)
                }
                let (attributes, parsedName) = AttrRecordParser.parse(record: record, length: length)
                let view: UnsafeRawBufferPointer
                if let pointer = parsedName.pointer, parsedName.length > 0 {
                    view = UnsafeRawBufferPointer(start: pointer, count: parsedName.length)
                } else {
                    view = UnsafeRawBufferPointer(start: nil, count: 0)
                }
                if attributes.error == 0 {
                    try body(attributes, view)
                } else {
                    try body(attributes, view)
                }
                record += length
            }
            returned += UInt32(count)
        }
    }
}
