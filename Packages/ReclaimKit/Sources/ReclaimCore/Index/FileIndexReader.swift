import Darwin

private struct ChildSortKey {
    var key: UInt64
    var id: UInt32
}

private func sortDescending(_ rows: inout ContiguousArray<ChildSortKey>) {
    rows.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress, buffer.count > 1 else { return }
        qsort_r(
            base,
            buffer.count,
            MemoryLayout<ChildSortKey>.stride,
            nil
        ) { _, leftPointer, rightPointer in
            guard let leftPointer, let rightPointer else { return 0 }
            let left = leftPointer.load(as: ChildSortKey.self).key
            let right = rightPointer.load(as: ChildSortKey.self).key
            if left > right { return -1 }
            if left < right { return 1 }
            return 0
        }
    }
}

/// Immutable, `Sendable` view of a finished index (PLAN.md §2.6.6). Arrays are copy-on-write with the
/// storage they were frozen from, so `finalize` does not memcpy the arena.
public struct FileIndexReader: Sendable {
    let columns: IndexColumns
    public let firmlinks: FirmlinkTable

    init(columns: IndexColumns, firmlinks: FirmlinkTable) {
        self.columns = columns
        self.firmlinks = firmlinks
    }

    public var count: Int { columns.count }
    public var roots: [EntryID] { columns.roots }

    public func root(_ index: Int) -> EntryID {
        columns.roots.indices.contains(index) ? columns.roots[index] : .none
    }

    public func parent(of id: EntryID) -> EntryID? {
        guard valid(id) else { return nil }
        let raw = columns.parent[Int(id.rawValue)]
        return raw == UInt32.max ? nil : EntryID(rawValue: raw)
    }

    public func summary(_ id: EntryID) -> EntrySummary {
        let index = Int(id.rawValue)
        let kind = columns.kind(at: index)
        let privateBytes = columns.privateBytes[index]
        let sizes = SizeTriple(
            logical: columns.logical[index],
            allocated: columns.allocated[index],
            privateBytes: privateBytes,
            privateReclaimable: privateBytes
        )
        return EntrySummary(
            id: id,
            name: name(of: id),
            kind: kind,
            sizes: sizes,
            flags: BSDFlags(rawValue: columns.bsdFlags[index]),
            extFlags: ExtFlags(rawValue: columns.extFlags[index]),
            mode: columns.mode[index],
            uid: columns.uid[index],
            mtime: columns.mtime[index],
            identity: FileIdentity(fsidA: columns.fsidA[index], fsidB: columns.fsidB[index], fileID: columns.fileID[index]),
            linkCount: columns.linkCount[index],
            errno: Int32(columns.errno[index]),
            volumeIndex: columns.volumeIndex[index],
            cloneID: columns.cloneID[index]
        )
    }

    public func name(of id: EntryID) -> String {
        guard valid(id) else { return "" }
        let bytes = nameBytes(id)
        return String(decoding: bytes, as: UTF8.self)
    }

    public func path(of id: EntryID) -> String {
        guard valid(id) else { return "" }
        var parts: [String] = []
        var current = id
        var steps = 0
        while valid(current), steps < 10_000 {
            steps += 1
            let parent = columns.parent[Int(current.rawValue)]
            if parent == UInt32.max {
                let root = name(of: current)
                if parts.isEmpty { return root }
                return root + "/" + parts.reversed().joined(separator: "/")
            }
            parts.append(name(of: current))
            current = EntryID(rawValue: parent)
        }
        return parts.reversed().joined(separator: "/")
    }

    public func displayPath(of id: EntryID) -> String {
        firmlinks.displayPath(for: path(of: id))
    }

    public func find(path: String) -> EntryID? {
        if let alias = columns.aliases[path] { return alias }
        let canonical = firmlinks.canonicalize(path)
        if canonical != path, let alias = columns.aliases[canonical] { return alias }
        let candidates = [path, canonical]
        for root in columns.roots {
            let rootPath = name(of: root)
            for candidate in candidates {
                if candidate == rootPath { return root }
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                if candidate.hasPrefix(prefix) {
                    let rest = candidate.dropFirst(prefix.count)
                    if let found = descend(from: root, remainder: rest) { return found }
                }
            }
        }
        return nil
    }

    public func children(of id: EntryID, sortedBy basis: SizeBasis, page: Range<Int>) -> [EntrySummary] {
        guard valid(id), page.lowerBound >= 0, !page.isEmpty else { return [] }
        var rows = ContiguousArray<ChildSortKey>()
        var child = columns.firstChild[Int(id.rawValue)]
        while child != UInt32.max {
            rows.append(ChildSortKey(key: key(Int(child), basis), id: child))
            child = columns.nextSibling[Int(child)]
        }
        guard page.lowerBound < rows.count else { return [] }
        sortDescending(&rows)
        let upper = min(page.upperBound, rows.count)
        return rows[page.lowerBound..<upper].map { summary(EntryID(rawValue: $0.id)) }
    }

    public func query(_ query: IndexQuery) -> [EntryID] {
        var matches: [EntryID] = []
        matches.reserveCapacity(64)
        for index in 0..<columns.count where matchesPredicate(query.predicate, index: index) {
            matches.append(EntryID(rawValue: UInt32(index)))
        }
        return matches
    }

    public func largest(kind: EntryKind, basis: SizeBasis, limit: Int) -> [EntryID] {
        guard limit > 0 else { return [] }
        var best: [(UInt64, UInt32)] = []
        best.reserveCapacity(limit)
        for index in 0..<columns.count where columns.kind(at: index) == kind {
            let value = key(index, basis)
            if best.count < limit {
                best.append((value, UInt32(index)))
                best.sort { $0.0 > $1.0 }
            } else if let last = best.last, value > last.0 {
                best[best.count - 1] = (value, UInt32(index))
                best.sort { $0.0 > $1.0 }
            }
        }
        return best.map { EntryID(rawValue: $0.1) }
    }

    public func entryID(for identity: FileIdentity) -> EntryID? {
        columns.directories[identity]
    }

    public func samePayload(as other: FileIndexReader) -> Bool {
        columns.nameArena == other.columns.nameArena
            && columns.nameOffset == other.columns.nameOffset
            && columns.nameLength == other.columns.nameLength
            && columns.parent == other.columns.parent
            && columns.firstChild == other.columns.firstChild
            && columns.nextSibling == other.columns.nextSibling
            && columns.kind == other.columns.kind
            && columns.bsdFlags == other.columns.bsdFlags
            && columns.extFlags == other.columns.extFlags
            && columns.mode == other.columns.mode
            && columns.uid == other.columns.uid
            && columns.mtime == other.columns.mtime
            && columns.fileID == other.columns.fileID
            && columns.cloneID == other.columns.cloneID
            && columns.linkCount == other.columns.linkCount
            && columns.logical == other.columns.logical
            && columns.allocated == other.columns.allocated
            && columns.privateBytes == other.columns.privateBytes
            && columns.errno == other.columns.errno
            && columns.volumeIndex == other.columns.volumeIndex
            && columns.roots == other.columns.roots
    }

    private func valid(_ id: EntryID) -> Bool {
        id != .none && Int(id.rawValue) < columns.count
    }

    private func nameBytes(_ id: EntryID) -> ArraySlice<UInt8> {
        let index = Int(id.rawValue)
        let start = Int(columns.nameOffset[index])
        let length = Int(columns.nameLength[index])
        let end = min(start + length, columns.nameArena.count)
        guard start >= 0, start <= end else { return [] }
        return columns.nameArena[start..<end]
    }

    private func descend(from id: EntryID, remainder: Substring) -> EntryID? {
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: true)
        var current = id
        for part in parts {
            let bytes = Array(part.utf8)
            guard let child = child(of: current, named: bytes) else { return nil }
            current = child
        }
        return current
    }

    private func child(of id: EntryID, named bytes: [UInt8]) -> EntryID? {
        var child = columns.firstChild[Int(id.rawValue)]
        while child != UInt32.max {
            let index = Int(child)
            let start = Int(columns.nameOffset[index])
            let length = Int(columns.nameLength[index])
            if length == bytes.count, start + length <= columns.nameArena.count {
                var same = true
                for offset in 0..<length where columns.nameArena[start + offset] != bytes[offset] {
                    same = false
                    break
                }
                if same { return EntryID(rawValue: child) }
            }
            child = columns.nextSibling[index]
        }
        return nil
    }

    private func key(_ index: Int, _ basis: SizeBasis) -> UInt64 {
        switch basis {
        case .logical: columns.logical[index]
        case .allocated: columns.allocated[index]
        case .privateBytes: columns.privateBytes[index]
        }
    }

    private func matchesPredicate(_ predicate: IndexQuery.Predicate, index: Int) -> Bool {
        switch predicate {
        case let .kind(kind):
            columns.kind(at: index) == kind
        case let .kinds(set):
            set.contains(columns.kind(at: index))
        case let .minimumAllocated(minimum):
            columns.allocated[index] >= minimum
        case let .nameEquals(name):
            self.name(of: EntryID(rawValue: UInt32(index))) == name
        case let .pathHasPrefix(prefix):
            path(of: EntryID(rawValue: UInt32(index))).hasPrefix(prefix)
        case let .all(list):
            list.allSatisfy { matchesPredicate($0, index: index) }
        case let .any(list):
            list.contains { matchesPredicate($0, index: index) }
        }
    }
}
