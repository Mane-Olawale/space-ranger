import Foundation

public struct ScanProgress: Sendable, Equatable {
    public var entries: Int
    public var bytesAllocated: UInt64
    public var directoriesDone: Int
    public var elapsed: Duration

    public init(entries: Int, bytesAllocated: UInt64, directoriesDone: Int, elapsed: Duration) {
        self.entries = entries
        self.bytesAllocated = bytesAllocated
        self.directoriesDone = directoriesDone
        self.elapsed = elapsed
    }
}

public enum ScanEvent: Sendable {
    case started(roots: [String])
    case progress(ScanProgress)
    case unreadable(path: String, errno: Int32)
    case boundary(path: String, volume: VolumeInfo)
    case finished(ScanSummary)
}
