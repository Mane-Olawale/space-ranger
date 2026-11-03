// T1-BULK-PARITY (PLAN.md §2.6.3): every parsed field equals `fstatat` on the same directory fd.

import Darwin
import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

@Suite("Bulk parity", .tags(.requiresAPFS))
struct ParityTests {
    @Test func bulkMatchesFstatat() throws {
        let fixture = try mixedFixture(files: 40_000, directories: 8_000)
        defer { fixture.cleanup() }
        let fd = try FileDescriptor.openDirectory(atPath: fixture.path)
        defer { fd.close() }
        // Walk one level of mixed names by scanning the whole tree's directories via the enumerator,
        // comparing each child with fstatat on its parent. The harness opens every directory with openat.
        var mismatches: [String] = []
        var compared = 0
        try compareTree(parentFD: fd.fd, path: fixture.path, mismatches: &mismatches, compared: &compared)
        #expect(compared >= 48_000, "compared \(compared) entries")
        #expect(mismatches.isEmpty, "\(mismatches.prefix(8).joined(separator: "\n"))")
    }

    private func compareTree(parentFD: Int32, path: String, mismatches: inout [String], compared: inout Int) throws {
        let reader = BulkAttrEnumerator()
        let entries = try reader.readDirectory(dirfd: parentFD, expectedCount: 0)
        for entry in entries {
            compared += 1
            var st = stat()
            let rc = entry.name.withUnsafeBytes { raw -> Int32 in
                var terminated = [UInt8](raw)
                terminated.append(0)
                return terminated.withUnsafeBytes { bytes in
                    guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
                    return fstatat(parentFD, pointer, &st, AT_SYMLINK_NOFOLLOW)
                }
            }
            if rc != 0 {
                mismatches.append("fstatat \(path)/\(entry.nameText) errno \(errno)")
                continue
            }
            check(entry, st, at: path, mismatches: &mismatches)
            if entry.isDirectory, !entry.isMountPoint {
                let child = entry.name.withUnsafeBytes { raw -> Int32 in
                    var terminated = [UInt8](raw)
                    terminated.append(0)
                    return terminated.withUnsafeBytes { bytes in
                        guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
                        return openat(parentFD, pointer, DirectoryOpen.flags)
                    }
                }
                if child >= 0 {
                    let childPath = path + "/" + entry.nameText
                    try compareTree(parentFD: child, path: childPath, mismatches: &mismatches, compared: &compared)
                    Darwin.close(child)
                }
            }
        }
    }

    private func check(_ entry: BulkEntry, _ st: stat, at path: String, mismatches: inout [String]) {
        let where_ = path + "/" + entry.nameText
        func fail(_ field: String, _ got: UInt64, _ want: UInt64) {
            if mismatches.count < 20 { mismatches.append("\(where_) \(field) bulk=\(got) stat=\(want)") }
        }
        let kind = st.st_mode & S_IFMT
        let expectedType: UInt32
        switch kind {
        case S_IFREG: expectedType = UInt32(VREG.rawValue)
        case S_IFDIR: expectedType = UInt32(VDIR.rawValue)
        case S_IFLNK: expectedType = UInt32(VLNK.rawValue)
        case S_IFSOCK: expectedType = UInt32(VSOCK.rawValue)
        case S_IFIFO: expectedType = UInt32(VFIFO.rawValue)
        default: expectedType = entry.objType
        }
        if entry.objType != expectedType { fail("objtype", UInt64(entry.objType), UInt64(expectedType)) }
        if entry.mtimeSeconds != Int64(st.st_mtimespec.tv_sec) {
            fail("mtime", UInt64(bitPattern: entry.mtimeSeconds), UInt64(bitPattern: Int64(st.st_mtimespec.tv_sec)))
        }
        if entry.uid != st.st_uid { fail("uid", UInt64(entry.uid), UInt64(st.st_uid)) }
        if entry.mode != UInt32(st.st_mode & 0xFFFF) { fail("mode", UInt64(entry.mode), UInt64(st.st_mode & 0xFFFF)) }
        if entry.flags != st.st_flags { fail("flags", UInt64(entry.flags), UInt64(st.st_flags)) }
        if entry.fileID != UInt64(st.st_ino) { fail("fileid", entry.fileID, UInt64(st.st_ino)) }
        if kind != S_IFDIR, entry.linkCount != UInt32(st.st_nlink) {
            fail("nlink", UInt64(entry.linkCount), UInt64(st.st_nlink))
        }
        if kind == S_IFREG || kind == S_IFLNK {
            if entry.logicalSize != UInt64(clamping: st.st_size) { fail("size", entry.logicalSize, UInt64(clamping: st.st_size)) }
            let allocated = UInt64(clamping: st.st_blocks) * 512
            if entry.allocatedSize != allocated { fail("alloc", entry.allocatedSize, allocated) }
        }
    }
}

private func mixedFixture(files: Int, directories: Int) throws -> Fixture {
    var children: [FixtureSpec.Node] = [
        .symlink(name: "link", to: "f0"),
        .socket(name: "sock"),
    ]
    children.reserveCapacity(files + directories + 2)
    for index in 0..<files {
        children.append(.file(name: "f\(index)", logicalBytes: index % 5 == 0 ? 128 : 0))
    }
    for index in 0..<directories {
        children.append(.dir(name: "d\(index)", children: [.file(name: "inner", logicalBytes: 16)]))
    }
    return try FixtureBuilder.make(FixtureSpec(root: children))
}

extension BulkEntry {
    var nameText: String { String(decoding: name, as: UTF8.self) }
}
