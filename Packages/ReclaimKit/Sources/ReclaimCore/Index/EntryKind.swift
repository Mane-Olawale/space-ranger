import Darwin

/// On-disk object class stored as `UInt8` in the index (PLAN.md §2.6.6).
public enum EntryKind: UInt8, Sendable, Equatable, Codable, CaseIterable {
    case file = 1
    case directory = 2
    case symlink = 3
    case socket = 4
    case fifo = 5
    case device = 6
    case mountBoundary = 7
    case unreadable = 8

    public static func from(objType: UInt32) -> EntryKind {
        switch objType {
        case UInt32(VREG.rawValue): .file
        case UInt32(VDIR.rawValue): .directory
        case UInt32(VLNK.rawValue): .symlink
        case UInt32(VSOCK.rawValue): .socket
        case UInt32(VFIFO.rawValue): .fifo
        case UInt32(VBLK.rawValue), UInt32(VCHR.rawValue): .device
        default: .file
        }
    }

    public var objType: UInt32 {
        switch self {
        case .file: UInt32(VREG.rawValue)
        case .directory, .mountBoundary, .unreadable: UInt32(VDIR.rawValue)
        case .symlink: UInt32(VLNK.rawValue)
        case .socket: UInt32(VSOCK.rawValue)
        case .fifo: UInt32(VFIFO.rawValue)
        case .device: UInt32(VCHR.rawValue)
        }
    }
}

/// BSD flags we branch on (PLAN.md §2.6.3, §2.9.2). The raw `st_flags` value is what the index stores.
public struct BSDFlags: OptionSet, Sendable, Equatable, Codable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let userImmutable = BSDFlags(rawValue: UInt32(UF_IMMUTABLE))
    public static let hidden = BSDFlags(rawValue: UInt32(UF_HIDDEN))
    public static let compressed = BSDFlags(rawValue: UInt32(UF_COMPRESSED))
    public static let dataVault = BSDFlags(rawValue: UInt32(UF_DATAVAULT))
    public static let tracked = BSDFlags(rawValue: UInt32(UF_TRACKED))
    public static let systemImmutable = BSDFlags(rawValue: UInt32(SF_IMMUTABLE))
    public static let restricted = BSDFlags(rawValue: UInt32(SF_RESTRICTED))
    public static let firmlink = BSDFlags(rawValue: UInt32(SF_FIRMLINK))
}

/// Packed `EF_*` bits (low 7). Bit 7 is Reclaim's `allocatedOnly` marker for `fts` rows, not a kernel flag.
public struct ExtFlags: OptionSet, Sendable, Equatable, Codable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let mayShareBlocks = ExtFlags(rawValue: 1 << 0)
    public static let noXattrs = ExtFlags(rawValue: 1 << 1)
    public static let syncRoot = ExtFlags(rawValue: 1 << 2)
    public static let purgeable = ExtFlags(rawValue: 1 << 3)
    public static let sparse = ExtFlags(rawValue: 1 << 4)
    public static let synthetic = ExtFlags(rawValue: 1 << 5)
    public static let sharesAllBlocks = ExtFlags(rawValue: 1 << 6)
    /// Set when private size was not provided (`fts`). Not an `EF_*` bit.
    public static let allocatedOnly = ExtFlags(rawValue: 1 << 7)

    public var isSparse: Bool { contains(.sparse) }

    public init(kernel: UInt64, confidence: SizeConfidence = .full) {
        var packed = ExtFlags(rawValue: UInt8(truncatingIfNeeded: kernel & 0x7F))
        if confidence == .allocatedOnly { packed.insert(.allocatedOnly) }
        self = packed
    }
}
