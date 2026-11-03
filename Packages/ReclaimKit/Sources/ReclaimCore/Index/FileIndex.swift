// Struct-of-arrays index (PLAN.md §2.6.6). Ingestion takes a lock instead of an actor hop: the Phase 1
// profile showed actor switches are invisible next to `getattrlistbulk`, and a hop per directory would
// be the first user-space cost we actually added. `FileIndex` is still an actor — `finalize` and readers
// are isolated; `append` is `nonisolated` and only touches the lock.

import Darwin
import os

struct IndexColumns {
    var nameArena = ContiguousArray<UInt8>()
    var nameOffset = ContiguousArray<UInt32>()
    var nameLength = ContiguousArray<UInt16>()
    var parent = ContiguousArray<UInt32>()
    var firstChild = ContiguousArray<UInt32>()
    var nextSibling = ContiguousArray<UInt32>()
    var tailChild = ContiguousArray<UInt32>()
    var kind = ContiguousArray<UInt8>()
    var bsdFlags = ContiguousArray<UInt32>()
    var extFlags = ContiguousArray<UInt8>()
    var mode = ContiguousArray<UInt16>()
    var uid = ContiguousArray<UInt32>()
    var mtime = ContiguousArray<Int64>()
    var fileID = ContiguousArray<UInt64>()
    var cloneID = ContiguousArray<UInt64>()
    var linkCount = ContiguousArray<UInt16>()
    var logical = ContiguousArray<UInt64>()
    var allocated = ContiguousArray<UInt64>()
    var privateBytes = ContiguousArray<UInt64>()
    var errno = ContiguousArray<UInt16>()
    var volumeIndex = ContiguousArray<UInt8>()
    var fsidA = ContiguousArray<Int32>()
    var fsidB = ContiguousArray<Int32>()
    var roots: [EntryID] = []
    var aliases: [String: EntryID] = [:]
    var directories: [FileIdentity: EntryID] = [:]

    var count: Int { kind.count }

    func kind(at index: Int) -> EntryKind {
        EntryKind(rawValue: kind[index]) ?? .file
    }

    mutating func reserve(_ count: Int) {
        nameArena.reserveCapacity(count * 16)
        nameOffset.reserveCapacity(count)
        nameLength.reserveCapacity(count)
        parent.reserveCapacity(count)
        firstChild.reserveCapacity(count)
        nextSibling.reserveCapacity(count)
        tailChild.reserveCapacity(count)
        kind.reserveCapacity(count)
        bsdFlags.reserveCapacity(count)
        extFlags.reserveCapacity(count)
        mode.reserveCapacity(count)
        uid.reserveCapacity(count)
        mtime.reserveCapacity(count)
        fileID.reserveCapacity(count)
        cloneID.reserveCapacity(count)
        linkCount.reserveCapacity(count)
        logical.reserveCapacity(count)
        allocated.reserveCapacity(count)
        privateBytes.reserveCapacity(count)
        errno.reserveCapacity(count)
        volumeIndex.reserveCapacity(count)
        fsidA.reserveCapacity(count)
        fsidB.reserveCapacity(count)
    }
}

/// Lock-protected columns. `@unchecked Sendable` because every access takes `lock`.
final class IndexStorage: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var columns = IndexColumns()
    private var didRollup = false

    func reserve(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        columns.reserve(count)
    }

    func append(_ batch: EntryBatch) -> Range<EntryID> {
        var fast = FastBatch(parent: batch.parent)
        for record in batch.records {
            let bytes = Array(record.name.utf8)
            bytes.withUnsafeBytes { raw in
                var item = FastItem()
                item.kind = record.kind
                item.bsdFlags = record.bsdFlags
                item.extFlags = record.extFlags.rawValue
                item.mode = record.mode
                item.uid = record.uid
                item.mtime = record.mtime
                item.fileID = record.fileID
                item.cloneID = record.cloneID
                item.linkCount = record.linkCount
                item.logical = record.logical
                item.allocated = record.allocated
                item.privateBytes = record.privateBytes
                item.errno = UInt16(clamping: record.errno)
                item.volumeIndex = record.volumeIndex
                item.fsidA = record.identity.fsidA
                item.fsidB = record.identity.fsidB
                item.trackDirectory = record.kind == .directory || record.kind == .mountBoundary
                fast.add(name: raw, item: item)
            }
        }
        return ingest(fast)
    }

    func ingest(_ batch: FastBatch) -> Range<EntryID> {
        lock.lock()
        defer { lock.unlock() }
        let startRaw = UInt32(columns.count)
        let parent = batch.parent.rawValue
        for item in batch.items {
            let id = UInt32(columns.count)
            let arenaOffset = UInt32(columns.nameArena.count)
            let start = Int(item.nameOffset)
            let end = start + Int(item.nameLength)
            if item.nameLength > 0, start >= 0, end <= batch.names.count {
                columns.nameArena.append(contentsOf: batch.names[start..<end])
            }
            columns.nameOffset.append(arenaOffset)
            columns.nameLength.append(item.nameLength)
            columns.parent.append(parent)
            columns.firstChild.append(.max)
            columns.nextSibling.append(.max)
            columns.tailChild.append(.max)
            columns.kind.append(item.kind.rawValue)
            columns.bsdFlags.append(item.bsdFlags)
            columns.extFlags.append(item.extFlags)
            columns.mode.append(item.mode)
            columns.uid.append(item.uid)
            columns.mtime.append(item.mtime)
            columns.fileID.append(item.fileID)
            columns.cloneID.append(item.cloneID)
            columns.linkCount.append(item.linkCount)
            columns.logical.append(item.logical)
            columns.allocated.append(item.allocated)
            columns.privateBytes.append(item.privateBytes)
            columns.errno.append(item.errno)
            columns.volumeIndex.append(item.volumeIndex)
            columns.fsidA.append(item.fsidA)
            columns.fsidB.append(item.fsidB)
            if parent != UInt32.max {
                let parentIndex = Int(parent)
                if columns.firstChild[parentIndex] == .max {
                    columns.firstChild[parentIndex] = id
                } else {
                    let previous = columns.tailChild[parentIndex]
                    columns.nextSibling[Int(previous)] = id
                }
                columns.tailChild[parentIndex] = id
            }
            if item.trackDirectory {
                let identity = FileIdentity(fsidA: item.fsidA, fsidB: item.fsidB, fileID: item.fileID)
                if columns.directories[identity] == nil {
                    columns.directories[identity] = EntryID(rawValue: id)
                }
            }
        }
        return EntryID(rawValue: startRaw)..<EntryID(rawValue: UInt32(columns.count))
    }

    func addRoot(_ id: EntryID, path: String) {
        lock.lock()
        defer { lock.unlock() }
        columns.roots.append(id)
        columns.aliases[path] = id
    }

    func addAlias(path: String, id: EntryID) {
        lock.lock()
        defer { lock.unlock() }
        columns.aliases[path] = id
    }

    func existingDirectory(_ identity: FileIdentity) -> EntryID? {
        lock.lock()
        defer { lock.unlock() }
        return columns.directories[identity]
    }

    func update(id: EntryID, kind: EntryKind? = nil, allocated: UInt64? = nil, errno: Int32? = nil, volumeIndex: UInt8? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let index = Int(id.rawValue)
        guard columns.kind.indices.contains(index) else { return }
        if let kind { columns.kind[index] = kind.rawValue }
        if let allocated { columns.allocated[index] = allocated }
        if let errno { columns.errno[index] = UInt16(clamping: errno) }
        if let volumeIndex { columns.volumeIndex[index] = volumeIndex }
    }

    func freeze(firmlinks: FirmlinkTable) -> FileIndexReader {
        lock.lock()
        defer { lock.unlock() }
        if !didRollup {
            Rollup.apply(&columns)
            didRollup = true
        }
        return FileIndexReader(columns: columns, firmlinks: firmlinks)
    }
}

public actor FileIndex {
    nonisolated private let storage: IndexStorage
    private var firmlinks = FirmlinkTable(links: [])
    private var frozen: FileIndexReader?

    public init() {
        storage = IndexStorage()
    }

    nonisolated public func append(_ batch: EntryBatch) -> Range<EntryID> {
        storage.append(batch)
    }

    nonisolated func ingest(_ batch: FastBatch) -> Range<EntryID> {
        storage.ingest(batch)
    }

    nonisolated func reserve(_ count: Int) { storage.reserve(count) }

    nonisolated func addRoot(_ id: EntryID, path: String) { storage.addRoot(id, path: path) }

    nonisolated func addAlias(path: String, id: EntryID) { storage.addAlias(path: path, id: id) }

    nonisolated func existingDirectory(_ identity: FileIdentity) -> EntryID? {
        storage.existingDirectory(identity)
    }

    nonisolated func update(
        id: EntryID,
        kind: EntryKind? = nil,
        allocated: UInt64? = nil,
        errno: Int32? = nil,
        volumeIndex: UInt8? = nil
    ) {
        storage.update(id: id, kind: kind, allocated: allocated, errno: errno, volumeIndex: volumeIndex)
    }

    public func setFirmlinks(_ table: FirmlinkTable) {
        firmlinks = table
    }

    /// Synchronous freeze. Safe to call from a cancelled scan task — it does not hop to the actor.
    nonisolated func freeze(firmlinks table: FirmlinkTable) -> FileIndexReader {
        storage.freeze(firmlinks: table)
    }

    /// Roll sizes up and freeze a `Sendable` view. Further appends are not reflected.
    public func finalize() -> FileIndexReader {
        if let frozen { return frozen }
        let reader = freeze(firmlinks: firmlinks)
        frozen = reader
        return reader
    }
}
