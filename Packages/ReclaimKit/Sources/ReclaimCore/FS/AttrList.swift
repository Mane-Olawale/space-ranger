// `attrlist` for PLAN.md §2.6.2 and the record parser for §2.6.3.
//
// Record layout (getattrlistbulk):
//   u_int32 length | attribute_set_t returned (ATTR_CMN_RETURNED_ATTRS is always first)
//   | ATTR_CMN_ERROR, when requested, immediately after the returned set
//   | remaining attributes in ascending bit order within each group,
//     groups common → directory → file → common-extended (forkattr).
// Each present field is naturally aligned. `FSOPT_PACK_INVAL_ATTRS` still reserves space for a
// requested field whose returned bit is clear; the value is then ignored.
// Variable-length ATTR_CMN_NAME is an attrreference_t relative to the reference's own address.
// The name bytes live elsewhere in the record and are not consumed by the cursor.

import Darwin

enum AttrList {
    static let options = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED)

    static let common = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_CHGTIME)
        | attrgroup_t(ATTR_CMN_OWNERID)
        | attrgroup_t(ATTR_CMN_GRPID)
        | attrgroup_t(ATTR_CMN_ACCESSMASK)
        | attrgroup_t(ATTR_CMN_FLAGS)
        | attrgroup_t(ATTR_CMN_FILEID)

    static let directory = attrgroup_t(ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS)
    static let file = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
    /// Ascending bit order is private, link id, clone id, ext flags — not the order written in §2.6.2's literal.
    static let extended = attrgroup_t(
        ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_LINKID | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS
    )

    static func make() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = common
        list.dirattr = directory
        list.fileattr = file
        list.forkattr = extended
        return list
    }
}

/// Scalars parsed from one getattrlistbulk record. The name is returned separately (it aliases the record).
struct ParsedAttributes {
    var error: Int32 = 0
    var objType: UInt32 = 0
    var mtimeSeconds: Int64 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var mode: UInt32 = 0
    var flags: UInt32 = 0
    var fileID: UInt64 = 0
    var entryCount: UInt32 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 0
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    var privateSize: UInt64 = 0
    var linkID: UInt64 = 0
    var cloneID: UInt64 = 0
    var extFlags: UInt64 = 0
    var hasPrivateSize = false
}

struct ParsedName {
    var pointer: UnsafePointer<UInt8>?
    var length: Int
}

enum AttrRecordParser {
    /// Parse one record. `name` aliases `record` and is valid only until the buffer is reused.
    static func parse(record: UnsafeRawPointer, length: Int) -> (ParsedAttributes, ParsedName) {
        var cursor = record + MemoryLayout<UInt32>.size
        let end = record + length
        guard cursor + MemoryLayout<attribute_set_t>.size <= end else {
            return (ParsedAttributes(), ParsedName(pointer: nil, length: 0))
        }
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        var reader = FieldReader(
            cursor: cursor,
            recordStart: record,
            end: end,
            returned: returned,
            requested: AttrList.make()
        )
        reader.readAll()
        return (reader.attributes, reader.name)
    }
}

private struct FieldReader {
    var cursor: UnsafeRawPointer
    /// Start of the record, used to reject a name reference that points outside it.
    var recordStart: UnsafeRawPointer
    let end: UnsafeRawPointer
    let returned: attribute_set_t
    let requested: attrlist
    var attributes = ParsedAttributes()
    var name = ParsedName(pointer: nil, length: 0)
    var failed = false

    mutating func readAll() {
        readError()
        guard !failed else { return }
        readCommon()
        guard !failed else { return }
        readDirectory()
        readFile()
        readExtended()
    }

    mutating func readError() {
        guard bit(returned.commonattr, ATTR_CMN_ERROR) else { return }
        guard let value: UInt32 = consume(UInt32.self, alignment: 1) else { return }
        if value != 0 {
            attributes.error = Int32(bitPattern: value)
            failed = true
        }
    }

    mutating func readCommon() {
        if bit(requested.commonattr, ATTR_CMN_NAME) {
            let present = bit(returned.commonattr, ATTR_CMN_NAME)
            guard cursor + MemoryLayout<attrreference_t>.size <= end else { failed = true; return }
            let referenceAddress = cursor
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            cursor += MemoryLayout<attrreference_t>.size
            if present, reference.attr_length > 0 {
                let raw = referenceAddress + Int(reference.attr_dataoffset)
                let bytes = Int(reference.attr_length)
                if raw >= UnsafeRawPointer(recordStart) && raw + bytes <= end {
                    let lastIsNUL = bytes > 0 && raw.load(fromByteOffset: bytes - 1, as: UInt8.self) == 0
                    name.pointer = raw.assumingMemoryBound(to: UInt8.self)
                    name.length = lastIsNUL ? bytes - 1 : bytes
                }
            }
        }
        if let value = value(ATTR_CMN_OBJTYPE, group: \.commonattr, returned: returned.commonattr, as: UInt32.self, alignment: 4) {
            attributes.objType = value
        }
        if let time = value(ATTR_CMN_MODTIME, group: \.commonattr, returned: returned.commonattr, as: timespec.self, alignment: 8) {
            attributes.mtimeSeconds = Int64(time.tv_sec)
        }
        _ = value(ATTR_CMN_CHGTIME, group: \.commonattr, returned: returned.commonattr, as: timespec.self, alignment: 8)
        if let value = value(ATTR_CMN_OWNERID, group: \.commonattr, returned: returned.commonattr, as: UInt32.self, alignment: 4) {
            attributes.uid = value
        }
        if let value = value(ATTR_CMN_GRPID, group: \.commonattr, returned: returned.commonattr, as: UInt32.self, alignment: 4) {
            attributes.gid = value
        }
        if let value = value(ATTR_CMN_ACCESSMASK, group: \.commonattr, returned: returned.commonattr, as: UInt32.self, alignment: 4) {
            attributes.mode = value
        }
        if let value = value(ATTR_CMN_FLAGS, group: \.commonattr, returned: returned.commonattr, as: UInt32.self, alignment: 4) {
            attributes.flags = value
        }
        if let value = value(ATTR_CMN_FILEID, group: \.commonattr, returned: returned.commonattr, as: UInt64.self, alignment: 8) {
            attributes.fileID = value
        }
    }

    mutating func readDirectory() {
        if let value = value(ATTR_DIR_ENTRYCOUNT, group: \.dirattr, returned: returned.dirattr, as: UInt32.self, alignment: 4) {
            attributes.entryCount = value
        }
        if let value = value(ATTR_DIR_MOUNTSTATUS, group: \.dirattr, returned: returned.dirattr, as: UInt32.self, alignment: 4) {
            attributes.mountStatus = value
        }
    }

    mutating func readFile() {
        if let value = value(ATTR_FILE_LINKCOUNT, group: \.fileattr, returned: returned.fileattr, as: UInt32.self, alignment: 4) {
            attributes.linkCount = value
        }
        if let value = value(ATTR_FILE_TOTALSIZE, group: \.fileattr, returned: returned.fileattr, as: Int64.self, alignment: 8) {
            attributes.logical = UInt64(clamping: value)
        }
        if let value = value(ATTR_FILE_ALLOCSIZE, group: \.fileattr, returned: returned.fileattr, as: Int64.self, alignment: 8) {
            attributes.allocated = UInt64(clamping: value)
        }
    }

    mutating func readExtended() {
        if let value = value(ATTR_CMNEXT_PRIVATESIZE, group: \.forkattr, returned: returned.forkattr, as: Int64.self, alignment: 8) {
            attributes.privateSize = UInt64(clamping: value)
            attributes.hasPrivateSize = true
        }
        if let value = value(ATTR_CMNEXT_LINKID, group: \.forkattr, returned: returned.forkattr, as: UInt64.self, alignment: 8) {
            attributes.linkID = value
        }
        if let value = value(ATTR_CMNEXT_CLONEID, group: \.forkattr, returned: returned.forkattr, as: UInt64.self, alignment: 8) {
            attributes.cloneID = value
        }
        if let value = value(ATTR_CMNEXT_EXT_FLAGS, group: \.forkattr, returned: returned.forkattr, as: UInt64.self, alignment: 8) {
            attributes.extFlags = value
        }
    }

    mutating func value<T>(
        _ bitValue: Int32,
        group: KeyPath<attrlist, attrgroup_t>,
        returned returnedGroup: attrgroup_t,
        as type: T.Type,
        alignment: Int
    ) -> T? {
        guard bit(requested[keyPath: group], bitValue), bit(returnedGroup, bitValue) else { return nil }
        _ = alignment
        return consume(type, alignment: 1)
    }

    mutating func consume<T>(_ type: T.Type, alignment: Int) -> T? {
        align(alignment)
        guard cursor + MemoryLayout<T>.size <= end else {
            failed = true
            return nil
        }
        let value = cursor.loadUnaligned(as: type)
        cursor += MemoryLayout<T>.size
        return value
    }

    mutating func align(_ alignment: Int) {
        let mask = alignment - 1
        let bits = Int(bitPattern: cursor)
        let aligned = (bits + mask) & ~mask
        if aligned != bits, let moved = UnsafeRawPointer(bitPattern: aligned) {
            cursor = moved
        }
    }

    func bit(_ group: attrgroup_t, _ value: Int32) -> Bool {
        group & attrgroup_t(value) != 0
    }
}
