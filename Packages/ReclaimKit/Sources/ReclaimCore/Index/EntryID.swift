/// Index of one row in `FileIndex` (PLAN.md §2.6.6). `UInt32.max` is "none" (no parent, no sibling, no child).
public struct EntryID: Hashable, Sendable, Comparable, Strideable, Codable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let none = EntryID(rawValue: .max)

    public static func < (lhs: EntryID, rhs: EntryID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func distance(to other: EntryID) -> Int {
        Int(other.rawValue) &- Int(rawValue)
    }

    public func advanced(by amount: Int) -> EntryID {
        EntryID(rawValue: UInt32(truncatingIfNeeded: Int(rawValue) &+ amount))
    }
}
