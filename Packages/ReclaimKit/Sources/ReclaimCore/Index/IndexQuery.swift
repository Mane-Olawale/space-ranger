/// Predicates compiled to a straight scan of the struct-of-arrays (PLAN.md §6 Phase 1 `IndexQuery`).
public struct IndexQuery: Sendable {
    public var predicate: Predicate

    public init(_ predicate: Predicate) {
        self.predicate = predicate
    }

    public enum Predicate: Sendable {
        case kind(EntryKind)
        case kinds(Set<EntryKind>)
        case minimumAllocated(UInt64)
        case nameEquals(String)
        case pathHasPrefix(String)
        case all([Predicate])
        case any([Predicate])
    }
}
