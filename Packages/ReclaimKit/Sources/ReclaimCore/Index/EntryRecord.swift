/// One index row as a value, used by `FileIndex.append` (PLAN.md §6 Phase 1). The scanner's hot path
/// does not build this type — it writes bytes into `FastBatch` so a 2.2 M walk does not allocate a
/// `String` per file (docs/benchmarks/phase1-profile.md).
public struct EntryRecord: Sendable, Equatable {
    public var name: String
    public var kind: EntryKind
    public var bsdFlags: UInt32
    public var extFlags: ExtFlags
    public var mode: UInt16
    public var uid: UInt32
    public var mtime: Int64
    public var fileID: UInt64
    public var cloneID: UInt64
    public var linkCount: UInt16
    public var logical: UInt64
    public var allocated: UInt64
    public var privateBytes: UInt64
    public var errno: Int32
    public var volumeIndex: UInt8
    public var identity: FileIdentity

    public init(
        name: String,
        kind: EntryKind,
        bsdFlags: UInt32 = 0,
        extFlags: ExtFlags = [],
        mode: UInt16 = 0,
        uid: UInt32 = 0,
        mtime: Int64 = 0,
        fileID: UInt64 = 0,
        cloneID: UInt64 = 0,
        linkCount: UInt16 = 1,
        logical: UInt64 = 0,
        allocated: UInt64 = 0,
        privateBytes: UInt64 = 0,
        errno: Int32 = 0,
        volumeIndex: UInt8 = 0,
        identity: FileIdentity = FileIdentity(fsidA: 0, fsidB: 0, fileID: 0)
    ) {
        self.name = name
        self.kind = kind
        self.bsdFlags = bsdFlags
        self.extFlags = extFlags
        self.mode = mode
        self.uid = uid
        self.mtime = mtime
        self.fileID = fileID
        self.cloneID = cloneID
        self.linkCount = linkCount
        self.logical = logical
        self.allocated = allocated
        self.privateBytes = privateBytes
        self.errno = errno
        self.volumeIndex = volumeIndex
        self.identity = identity
    }
}

public struct EntryBatch: Sendable {
    public var parent: EntryID
    public var records: [EntryRecord]

    public init(parent: EntryID, records: [EntryRecord]) {
        self.parent = parent
        self.records = records
    }
}

/// Read-side DTO. `sizes.privateReclaimable` on a directory is the ADR-011 rollup.
public struct EntrySummary: Sendable, Equatable {
    public var id: EntryID
    public var name: String
    public var kind: EntryKind
    public var sizes: SizeTriple
    public var flags: BSDFlags
    public var extFlags: ExtFlags
    public var mode: UInt16
    public var uid: UInt32
    public var mtime: Int64
    public var identity: FileIdentity
    public var linkCount: UInt16
    public var errno: Int32
    public var volumeIndex: UInt8
    public var cloneID: UInt64
}

/// Scanner-internal batch: one name arena plus fixed rows. Not part of the public append API.
struct FastBatch: Sendable {
    var parent: EntryID
    var names: [UInt8] = []
    var items: [FastItem] = []

    mutating func add(name: UnsafeRawBufferPointer, item: FastItem) {
        var stored = item
        stored.nameOffset = UInt32(names.count)
        stored.nameLength = UInt16(truncatingIfNeeded: min(name.count, Int(UInt16.max)))
        if stored.nameLength > 0, let base = name.baseAddress {
            names.append(contentsOf: UnsafeRawBufferPointer(start: base, count: Int(stored.nameLength)))
        }
        items.append(stored)
    }
}

struct FastItem: Sendable {
    var nameOffset: UInt32 = 0
    var nameLength: UInt16 = 0
    var kind: EntryKind = .file
    var bsdFlags: UInt32 = 0
    var extFlags: UInt8 = 0
    var mode: UInt16 = 0
    var uid: UInt32 = 0
    var mtime: Int64 = 0
    var fileID: UInt64 = 0
    var cloneID: UInt64 = 0
    var linkCount: UInt16 = 1
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    var privateBytes: UInt64 = 0
    var errno: UInt16 = 0
    var volumeIndex: UInt8 = 0
    var fsidA: Int32 = 0
    var fsidB: Int32 = 0
    var trackDirectory = false
}
