// Post-pass (PLAN.md §2.6.5). Children have higher ids than their parents, so a reverse scan rolls
// sizes up to the root in one O(n) pass.
//
// Hard links: the first `(volume, fileID)` with `linkCount > 1` contributes its bytes; later names contribute 0.
// The entry itself still stores the kernel sizes (the inspector shows the file, the parent counts it once).
//
// Clones: see ADR-011. Kernel `ATTR_CMNEXT_PRIVATESIZE` on a fully shared family is 0 on every member.
// Deleting the whole family frees one copy of the allocated size, so a family whose private sizes sum to 0
// contributes `max(allocated)` once. A family that does report private bytes contributes that sum once.

import Foundation

enum Rollup {
    static func apply(_ columns: inout IndexColumns) {
        let count = columns.count
        guard count > 0 else { return }
        var addLogical = [UInt64](repeating: 0, count: count)
        var addAllocated = [UInt64](repeating: 0, count: count)
        var addPrivate = [UInt64](repeating: 0, count: count)
        var seen = Set<LinkKey>()

        for index in 0..<count {
            let kind = columns.kind(at: index)
            if kind == .mountBoundary { continue }
            if isDuplicateLink(columns, index: index, seen: &seen) { continue }
            addLogical[index] = columns.logical[index]
            addAllocated[index] = columns.allocated[index]
            addPrivate[index] = columns.privateBytes[index]
        }
        attributeCloneFamilies(columns, addPrivate: &addPrivate, addAllocated: addAllocated)

        var rollLogical = addLogical
        var rollAllocated = addAllocated
        var rollPrivate = addPrivate
        var index = count - 1
        while true {
            let parent = columns.parent[index]
            if parent != UInt32.max, columns.kind(at: index) != .mountBoundary {
                let parentIndex = Int(parent)
                rollLogical[parentIndex] &+= rollLogical[index]
                rollAllocated[parentIndex] &+= rollAllocated[index]
                rollPrivate[parentIndex] &+= rollPrivate[index]
            }
            if index == 0 { break }
            index -= 1
        }

        for row in 0..<count where columns.kind(at: row) == .directory {
            columns.logical[row] = rollLogical[row]
            columns.allocated[row] = rollAllocated[row]
            columns.privateBytes[row] = rollPrivate[row]
        }
    }

    private static func isDuplicateLink(_ columns: IndexColumns, index: Int, seen: inout Set<LinkKey>) -> Bool {
        guard columns.linkCount[index] > 1 else { return false }
        let kind = columns.kind(at: index)
        guard kind == .file || kind == .symlink else { return false }
        let key = LinkKey(volume: columns.volumeIndex[index], file: columns.fileID[index])
        if seen.contains(key) { return true }
        seen.insert(key)
        return false
    }

    private static func attributeCloneFamilies(
        _ columns: IndexColumns,
        addPrivate: inout [UInt64],
        addAllocated: [UInt64]
    ) {
        struct Group {
            var members: [Int] = []
            var privateSum: UInt64 = 0
            var maxAllocated: UInt64 = 0
        }
        var groups: [UInt64: Group] = [:]
        for index in 0..<columns.count {
            let clone = columns.cloneID[index]
            guard clone != 0 else { continue }
            guard addAllocated[index] != 0 || columns.privateBytes[index] != 0 || columns.linkCount[index] <= 1 else {
                continue
            }
            var group = groups[clone] ?? Group()
            group.members.append(index)
            group.privateSum &+= columns.privateBytes[index]
            group.maxAllocated = max(group.maxAllocated, columns.allocated[index])
            groups[clone] = group
        }
        for group in groups.values where group.members.count >= 2 {
            let family = group.privateSum > 0 ? group.privateSum : group.maxAllocated
            guard let first = group.members.first else { continue }
            addPrivate[first] = family
            for member in group.members.dropFirst() {
                addPrivate[member] = 0
            }
        }
    }
}

private struct LinkKey: Hashable {
    var volume: UInt8
    var file: UInt64
}
