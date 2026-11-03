// RCL1 snapshot (PLAN.md §2.6.7). Header is a fixed 4096-byte page so the arrays that follow are
// mmap-aligned. The header's JSON names every section; the body is raw little-endian columns.
// Load validates bounds, then copies into `FileIndexReader` (the ≤ 1 s budget is this copy, not a parse).

import Darwin
import Foundation

public enum SnapshotFormat {
    public static let magic = Data("RCL1".utf8)
    public static let version: UInt32 = 1
    public static let headerBytes = 4096

    struct Section: Codable, Sendable {
        var name: String
        var offset: UInt64
        var length: UInt64
        var stride: UInt64
    }

    struct Header: Codable, Sendable {
        var version: UInt32
        var createdAt: Int64
        var partial: Bool
        var reasons: [String]
        var roots: [UInt32]
        var aliases: [String: UInt32]
        var volumes: [VolumeInfo]
        var sections: [Section]
    }
}

public enum SnapshotWriter {
    public static func write(_ reader: FileIndexReader, volumes: [VolumeInfo], completeness: ScanSummary.Completeness, to url: URL) throws {
        let header = SnapshotFormat.Header(
            version: SnapshotFormat.version,
            createdAt: Int64(Date().timeIntervalSince1970),
            partial: {
                if case .partial = completeness { return true }
                return false
            }(),
            reasons: {
                if case let .partial(reasons) = completeness { return reasons }
                return []
            }(),
            roots: reader.columns.roots.map(\.rawValue),
            aliases: Dictionary(uniqueKeysWithValues: reader.columns.aliases.map { ($0.key, $0.value.rawValue) }),
            volumes: volumes,
            sections: []
        )
        let columns = reader.columns
        let pieces: [(String, Data, Int)] = [
            ("nameArena", Data(columns.nameArena), 1),
            ("nameOffset", pack(columns.nameOffset), 4),
            ("nameLength", pack(columns.nameLength), 2),
            ("parent", pack(columns.parent), 4),
            ("firstChild", pack(columns.firstChild), 4),
            ("nextSibling", pack(columns.nextSibling), 4),
            ("kind", Data(columns.kind), 1),
            ("bsdFlags", pack(columns.bsdFlags), 4),
            ("extFlags", Data(columns.extFlags), 1),
            ("mode", pack(columns.mode), 2),
            ("uid", pack(columns.uid), 4),
            ("mtime", pack(columns.mtime), 8),
            ("fileID", pack(columns.fileID), 8),
            ("cloneID", pack(columns.cloneID), 8),
            ("linkCount", pack(columns.linkCount), 2),
            ("logical", pack(columns.logical), 8),
            ("allocated", pack(columns.allocated), 8),
            ("privateBytes", pack(columns.privateBytes), 8),
            ("errno", pack(columns.errno), 2),
            ("volumeIndex", Data(columns.volumeIndex), 1),
            ("fsidA", pack(columns.fsidA), 4),
            ("fsidB", pack(columns.fsidB), 4),
        ]
        var body = Data()
        var sections: [SnapshotFormat.Section] = []
        for (name, data, stride) in pieces {
            let aligned = (body.count + 7) & ~7
            if aligned > body.count { body.append(Data(count: aligned - body.count)) }
            let offset = UInt64(SnapshotFormat.headerBytes + body.count)
            sections.append(SnapshotFormat.Section(name: name, offset: offset, length: UInt64(data.count), stride: UInt64(stride)))
            body.append(data)
        }
        var encoded = header
        encoded.sections = sections
        let json = try JSONEncoder().encode(encoded)
        guard json.count + 16 <= SnapshotFormat.headerBytes else {
            throw FSError.snapshot("snapshot header exceeds \(SnapshotFormat.headerBytes) bytes")
        }
        var page = Data(count: SnapshotFormat.headerBytes)
        page.replaceSubrange(0..<4, with: SnapshotFormat.magic)
        page.replaceSubrange(4..<8, with: pack(UInt32(json.count)))
        page.replaceSubrange(8..<(8 + json.count), with: json)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var file = page
        file.append(body)
        try file.write(to: url, options: .atomic)
    }

    private static func pack<T: FixedWidthInteger>(_ value: T) -> Data {
        var copy = value.littleEndian
        return Data(bytes: &copy, count: MemoryLayout<T>.size)
    }

    private static func pack<T: FixedWidthInteger>(_ values: ContiguousArray<T>) -> Data {
        var data = Data(count: values.count * MemoryLayout<T>.size)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (index, value) in values.enumerated() {
                var copy = value.littleEndian
                memcpy(base.advanced(by: index * MemoryLayout<T>.size), &copy, MemoryLayout<T>.size)
            }
        }
        return data
    }
}

public enum SnapshotReader {
    public static func load(from url: URL, firmlinks: FirmlinkTable = FirmlinkTable(links: [])) throws -> FileIndexReader {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FSError.capture("open", path: url.path) }
        defer { Darwin.close(fd) }
        let size = Int(lseek(fd, 0, SEEK_END))
        guard size >= SnapshotFormat.headerBytes else { throw FSError.snapshot("snapshot is shorter than the header") }
        _ = lseek(fd, 0, SEEK_SET)
        let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        if mapped == MAP_FAILED { throw FSError.capture("mmap", path: url.path) }
        defer { munmap(mapped, size) }
        guard let base = mapped else { throw FSError.snapshot("mmap returned nil") }
        let start = UnsafeRawPointer(base)
        let magic = Data(bytes: start, count: 4)
        guard magic == SnapshotFormat.magic else { throw FSError.snapshot("bad magic") }
        let jsonCount = Int(start.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        guard jsonCount > 0, 8 + jsonCount <= SnapshotFormat.headerBytes else {
            throw FSError.snapshot("header JSON is out of range")
        }
        let json = Data(bytes: start.advanced(by: 8), count: jsonCount)
        let header = try JSONDecoder().decode(SnapshotFormat.Header.self, from: json)
        guard header.version == SnapshotFormat.version else { throw FSError.snapshot("unsupported version \(header.version)") }
        var columns = IndexColumns()
        for section in header.sections {
            let offset = Int(section.offset)
            let length = Int(section.length)
            guard offset >= SnapshotFormat.headerBytes, offset + length <= size, section.stride > 0 else {
                throw FSError.snapshot("section \(section.name) is outside the file")
            }
            let pointer = start.advanced(by: offset)
            try fill(&columns, name: section.name, pointer: pointer, length: length, stride: Int(section.stride))
        }
        let count = columns.kind.count
        guard columns.nameOffset.count == count, columns.fileID.count == count, columns.parent.count == count else {
            throw FSError.snapshot("column lengths differ")
        }
        for index in 0..<count {
            let startByte = Int(columns.nameOffset[index])
            let length = Int(columns.nameLength[index])
            guard startByte >= 0, startByte + length <= columns.nameArena.count else {
                throw FSError.snapshot("name reference \(index) is outside the arena")
            }
        }
        columns.roots = header.roots.map { EntryID(rawValue: $0) }
        columns.aliases = Dictionary(uniqueKeysWithValues: header.aliases.map { ($0.key, EntryID(rawValue: $0.value)) })
        columns.tailChild = ContiguousArray(repeating: .max, count: count)
        return FileIndexReader(columns: columns, firmlinks: firmlinks)
    }

    private static func fill(_ columns: inout IndexColumns, name: String, pointer: UnsafeRawPointer, length: Int, stride: Int) throws {
        guard length % stride == 0 else { throw FSError.snapshot("section \(name) is not a multiple of its stride") }
        let count = length / stride
        switch name {
        case "nameArena": columns.nameArena = copyBytes(pointer, count: length)
        case "nameOffset": columns.nameOffset = unpack(pointer, count: count)
        case "nameLength": columns.nameLength = unpack(pointer, count: count)
        case "parent": columns.parent = unpack(pointer, count: count)
        case "firstChild": columns.firstChild = unpack(pointer, count: count)
        case "nextSibling": columns.nextSibling = unpack(pointer, count: count)
        case "kind": columns.kind = copyBytes(pointer, count: length)
        case "bsdFlags": columns.bsdFlags = unpack(pointer, count: count)
        case "extFlags": columns.extFlags = copyBytes(pointer, count: length)
        case "mode": columns.mode = unpack(pointer, count: count)
        case "uid": columns.uid = unpack(pointer, count: count)
        case "mtime": columns.mtime = unpack(pointer, count: count)
        case "fileID": columns.fileID = unpack(pointer, count: count)
        case "cloneID": columns.cloneID = unpack(pointer, count: count)
        case "linkCount": columns.linkCount = unpack(pointer, count: count)
        case "logical": columns.logical = unpack(pointer, count: count)
        case "allocated": columns.allocated = unpack(pointer, count: count)
        case "privateBytes": columns.privateBytes = unpack(pointer, count: count)
        case "errno": columns.errno = unpack(pointer, count: count)
        case "volumeIndex": columns.volumeIndex = copyBytes(pointer, count: length)
        case "fsidA": columns.fsidA = unpack(pointer, count: count)
        case "fsidB": columns.fsidB = unpack(pointer, count: count)
        default: break
        }
    }

    private static func copyBytes(_ pointer: UnsafeRawPointer, count: Int) -> ContiguousArray<UInt8> {
        let buffer = UnsafeRawBufferPointer(start: pointer, count: count)
        return ContiguousArray(buffer)
    }

    private static func unpack<T: FixedWidthInteger>(_ pointer: UnsafeRawPointer, count: Int) -> ContiguousArray<T> {
        var array = ContiguousArray<T>()
        array.reserveCapacity(count)
        for index in 0..<count {
            let value = pointer.loadUnaligned(fromByteOffset: index * MemoryLayout<T>.size, as: T.self)
            array.append(T(littleEndian: value))
        }
        return array
    }
}
