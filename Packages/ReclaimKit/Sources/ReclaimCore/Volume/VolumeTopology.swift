// Mount table (PLAN.md §2.8). Built from `getmntinfo_r_np` + `statfs`. Disk names come from
// DiskArbitration when the framework can answer; a missing name does not drop the volume.

import Darwin
import DiskArbitration
import Foundation

public enum VolumeRole: String, Sendable, Equatable, Codable, Hashable {
    case system
    case data
    case preboot
    case vm
    case recovery
    case simulatorRuntime
    case diskImage
    case external
    case network
    case other
}

public struct VolumeInfo: Sendable, Hashable, Codable {
    public let id: UInt8
    public var fsidA: Int32
    public var fsidB: Int32
    public var device: UInt64
    public var mountPoint: String
    public var fsType: String
    public var flags: UInt32
    public var role: VolumeRole
    public var total: UInt64
    public var free: UInt64
    public var availableImportant: UInt64
    public var availableOpportunistic: UInt64
    public var diskName: String?
    public var isBootContainer: Bool

    public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }

    public var identityFSID: fsid_t {
        var value = fsid_t()
        value.val.0 = fsidA
        value.val.1 = fsidB
        return value
    }

    public init(
        id: UInt8,
        fsidA: Int32,
        fsidB: Int32,
        device: UInt64,
        mountPoint: String,
        fsType: String,
        flags: UInt32,
        role: VolumeRole,
        total: UInt64,
        free: UInt64,
        availableImportant: UInt64,
        availableOpportunistic: UInt64,
        diskName: String?,
        isBootContainer: Bool
    ) {
        self.id = id
        self.fsidA = fsidA
        self.fsidB = fsidB
        self.device = device
        self.mountPoint = mountPoint
        self.fsType = fsType
        self.flags = flags
        self.role = role
        self.total = total
        self.free = free
        self.availableImportant = availableImportant
        self.availableOpportunistic = availableOpportunistic
        self.diskName = diskName
        self.isBootContainer = isBootContainer
    }
}

public actor VolumeTopology {
    private var table: [VolumeInfo] = []

    public init() {}

    @discardableResult
    public func refresh() throws -> [VolumeInfo] {
        table = try Self.load()
        return table
    }

    public func volumes() -> [VolumeInfo] { table }

    public func volume(forDevice device: UInt64) -> VolumeInfo? {
        table.first { $0.device == device }
    }

    public func volume(mountedAt path: String) -> VolumeInfo? {
        table.first { $0.mountPoint == path }
    }

    public func fsType(forDevice device: UInt64) -> String {
        volume(forDevice: device)?.fsType ?? "apfs"
    }

    private static func load() throws -> [VolumeInfo] {
        let mounts = try mounted()
        var volumes: [VolumeInfo] = []
        volumes.reserveCapacity(mounts.count)
        for (index, info) in mounts.enumerated() {
            guard index < Int(UInt8.max) else { break }
            volumes.append(make(info, id: UInt8(index)))
        }
        return volumes
    }

    private static func mounted() throws -> [statfs] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count >= 0, let buffer else {
            throw FSError.capture("getmntinfo_r_np")
        }
        defer { free(buffer) }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
    }

    private static func make(_ info: statfs, id: UInt8) -> VolumeInfo {
        let mount = MountPoint.cString(info.f_mntonname)
        let fsType = MountPoint.cString(info.f_fstypename)
        let deviceName = MountPoint.cString(info.f_mntfromname)
        let described = DiskName.lookup(bsd: deviceName)
        let block = UInt64(truncatingIfNeeded: info.f_bsize)
        let total = UInt64(truncatingIfNeeded: info.f_blocks) &* block
        let free = UInt64(truncatingIfNeeded: info.f_bfree) &* block
        let flags = UInt32(truncatingIfNeeded: info.f_flags)
        let role = inferRole(mount: mount, flags: flags, model: described?.model, volumeName: described?.name)
        let boot = role == .system || role == .data || role == .preboot || role == .vm || role == .recovery
        var device = UInt64(0)
        var st = stat()
        if stat(mount, &st) == 0 { device = UInt64(truncatingIfNeeded: st.st_dev) }
        return VolumeInfo(
            id: id,
            fsidA: info.f_fsid.val.0,
            fsidB: info.f_fsid.val.1,
            device: device,
            mountPoint: mount,
            fsType: fsType,
            flags: flags,
            role: role,
            total: total,
            free: free,
            availableImportant: free,
            availableOpportunistic: free,
            diskName: described?.name,
            isBootContainer: boot
        )
    }

    /// `device` on `VolumeInfo` is not `st_dev` (statfs does not carry it). Callers match mounts by path
    /// or fsid. `st_dev` matching uses `deviceID` filled by `fstat` at the scan root.
    static func inferRole(mount: String, flags: UInt32, model: String?, volumeName: String?) -> VolumeRole {
        if flags & UInt32(MNT_LOCAL) == 0 { return .network }
        if mount == "/" || flags & UInt32(MNT_ROOTFS) != 0 { return .system }
        if mount == "/System/Volumes/Data" { return .data }
        if mount == "/System/Volumes/Preboot" { return .preboot }
        if mount == "/System/Volumes/VM" { return .vm }
        if mount.hasPrefix("/System/Volumes/Recovery") { return .recovery }
        if mount.hasPrefix("/Library/Developer/CoreSimulator/") { return .simulatorRuntime }
        let haystack = ((model ?? "") + " " + (volumeName ?? "")).lowercased()
        if haystack.contains("disk image") { return .diskImage }
        if mount.hasPrefix("/Volumes/") { return .external }
        return .other
    }
}

private enum DiskName {
    struct Described {
        var name: String?
        var model: String?
    }

    static func lookup(bsd: String) -> Described? {
        autoreleasepool { lookupInside(bsd: bsd) }
    }

    private static func lookupInside(bsd: String) -> Described? {
        let trimmed = bsd.hasPrefix("/dev/") ? String(bsd.dropFirst(5)) : bsd
        guard !trimmed.isEmpty else { return nil }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, trimmed) else { return nil }
        guard let raw = DADiskCopyDescription(disk) else { return nil }
        let description = raw as NSDictionary
        let name = description[kDADiskDescriptionVolumeNameKey] as? String
        let model = description[kDADiskDescriptionDeviceModelKey] as? String
        if name == nil, model == nil { return nil }
        return Described(name: name, model: model)
    }
}
