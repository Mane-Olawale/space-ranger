import Foundation

public struct ScanSummary: Sendable, Equatable {
    public enum Completeness: Sendable, Equatable {
        case complete
        case partial(reasons: [String])
    }

    public var roots: [String]
    public var entryCount: Int
    public var directoryCount: Int
    public var fileCount: Int
    public var symlinkCount: Int
    public var unreadableCount: Int
    public var boundaryCount: Int
    public var bytesLogical: UInt64
    public var bytesAllocated: UInt64
    public var bytesReclaimable: UInt64
    public var elapsed: Duration
    public var completeness: Completeness
    public var peakRSSBytes: UInt64
    public var maxOpenDirectoryFDs: Int
    public var openDirectoryFDs: Int

    public init(
        roots: [String],
        entryCount: Int,
        directoryCount: Int,
        fileCount: Int,
        symlinkCount: Int,
        unreadableCount: Int,
        boundaryCount: Int,
        bytesLogical: UInt64,
        bytesAllocated: UInt64,
        bytesReclaimable: UInt64,
        elapsed: Duration,
        completeness: Completeness,
        peakRSSBytes: UInt64,
        maxOpenDirectoryFDs: Int,
        openDirectoryFDs: Int = 0
    ) {
        self.roots = roots
        self.entryCount = entryCount
        self.directoryCount = directoryCount
        self.fileCount = fileCount
        self.symlinkCount = symlinkCount
        self.unreadableCount = unreadableCount
        self.boundaryCount = boundaryCount
        self.bytesLogical = bytesLogical
        self.bytesAllocated = bytesAllocated
        self.bytesReclaimable = bytesReclaimable
        self.elapsed = elapsed
        self.completeness = completeness
        self.peakRSSBytes = peakRSSBytes
        self.maxOpenDirectoryFDs = maxOpenDirectoryFDs
        self.openDirectoryFDs = openDirectoryFDs
    }
}
