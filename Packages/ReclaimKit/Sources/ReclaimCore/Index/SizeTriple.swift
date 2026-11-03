/// Logical / allocated / private sizes (PLAN.md §0.4, §2.7). `privateReclaimable` is the deletion
/// estimate from ADR-011 — for a directory it is the rolled-up figure, which is not always Σ kernel private.
public struct SizeTriple: Sendable, Equatable, Codable {
    public var logical: UInt64
    public var allocated: UInt64
    public var privateBytes: UInt64
    public var privateReclaimable: UInt64

    public init(logical: UInt64, allocated: UInt64, privateBytes: UInt64, privateReclaimable: UInt64? = nil) {
        self.logical = logical
        self.allocated = allocated
        self.privateBytes = privateBytes
        self.privateReclaimable = privateReclaimable ?? privateBytes
    }

    public static let zero = SizeTriple(logical: 0, allocated: 0, privateBytes: 0, privateReclaimable: 0)
}

public enum SizeBasis: Sendable, Equatable, Codable {
    case logical
    case allocated
    case privateBytes
}
