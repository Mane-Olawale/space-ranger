import Foundation

public struct ScanOptions: Sendable {
    public var roots: [String]
    public var excludes: [String]
    public var crossMountPoints: Bool
    public var includeOtherVolumes: Bool
    public var maxConcurrency: Int
    public var bufferBytes: Int
    public var forceFTS: Bool
    public var timeBudget: Duration?
    public var maxEntries: Int?
    /// When set, `/System`, `/dev` and `/Volumes` are excluded unless a root lives under that prefix.
    /// `/System/Volumes/Data` is a root, so `/System` is dropped for that root (it would otherwise match
    /// the Data volume's path prefix).
    public var useDefaultExcludes: Bool

    public init(
        roots: [String],
        excludes: [String] = [],
        crossMountPoints: Bool = false,
        includeOtherVolumes: Bool = false,
        maxConcurrency: Int = min(ProcessInfo.processInfo.activeProcessorCount, 12),
        bufferBytes: Int = 256 * 1024,
        forceFTS: Bool = false,
        timeBudget: Duration? = nil,
        maxEntries: Int? = nil,
        useDefaultExcludes: Bool = true
    ) {
        self.roots = roots
        self.excludes = excludes
        self.crossMountPoints = crossMountPoints
        self.includeOtherVolumes = includeOtherVolumes
        self.maxConcurrency = max(1, maxConcurrency)
        self.bufferBytes = bufferBytes
        self.forceFTS = forceFTS
        self.timeBudget = timeBudget
        self.maxEntries = maxEntries
        self.useDefaultExcludes = useDefaultExcludes
    }

    func resolvedExcludes(canonicalRoots: [String]) -> [String] {
        var list = excludes
        if useDefaultExcludes {
            list.append(contentsOf: ["/System", "/dev", "/Volumes"])
        }
        return list.filter { exclude in
            !canonicalRoots.contains { root in root == exclude || root.hasPrefix(exclude + "/") }
        }
    }

    func isExcluded(_ path: String, excludes list: [String]) -> Bool {
        list.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
