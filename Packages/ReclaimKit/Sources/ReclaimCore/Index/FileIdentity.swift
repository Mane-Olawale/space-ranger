import Darwin

/// `(fsid, fileID)` identity (PLAN.md §2.6.5, §2.7). `fsid_t` is not `Hashable`; the two `val` words are stored plainly.
public struct FileIdentity: Hashable, Sendable, Equatable, Codable {
    public var fsidA: Int32
    public var fsidB: Int32
    public var fileID: UInt64

    public init(fsidA: Int32, fsidB: Int32, fileID: UInt64) {
        self.fsidA = fsidA
        self.fsidB = fsidB
        self.fileID = fileID
    }

    public init(fsid: fsid_t, fileID: UInt64) {
        fsidA = fsid.val.0
        fsidB = fsid.val.1
        self.fileID = fileID
    }

    public var fsid: fsid_t {
        var value = fsid_t()
        value.val.0 = fsidA
        value.val.1 = fsidB
        return value
    }
}
