// JSON report types for `reclaim-bench` (consumed by Tests/ReclaimBenchTests and Scripts/bench.sh).

import Darwin
import Foundation

struct HostInfo: Codable, Sendable {
    let model: String
    let cpu: String
    let activeProcessors: Int
    let memoryBytes: UInt64
    let osVersion: String
    let pageSize: Int
    let buildConfiguration: String
    /// 1/5/15-minute load averages at report time — benchmark numbers are only comparable on a quiet machine.
    let loadAverage: [Double]
    /// `kern.memorystatus_level`: percentage of memory the kernel considers available (low = memory pressure).
    let memoryStatusLevel: Int?
    /// `kern.maxvnodes`: size of the vnode cache. Trees larger than this can never be "warm" in the vnode sense.
    let maxVnodes: Int?

    static func current() -> HostInfo {
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) != 3 { loads = [] }
        return HostInfo(
            model: sysctlString("hw.model") ?? "unknown",
            cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            activeProcessors: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            pageSize: Int(sysconf(_SC_PAGESIZE)),
            buildConfiguration: buildConfiguration,
            loadAverage: loads.map { ($0 * 100).rounded() / 100 },
            memoryStatusLevel: sysctlInt("kern.memorystatus_level"),
            maxVnodes: sysctlInt("kern.maxvnodes")
        )
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = buffer.withUnsafeBufferPointer { pointer -> String in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

/// One measured pass of a strategy over the root.
struct RunMeasurement: Codable, Sendable {
    let wallSeconds: Double
    let entries: Int
    let entriesPerSecond: Double
    /// Lifetime peak physical footprint of the process after this run (`ri_lifetime_max_phys_footprint`).
    let peakRSSBytes: UInt64
    let stats: WalkStats

    init(wallSeconds: Double, stats: WalkStats, peakRSSBytes: UInt64) {
        self.wallSeconds = wallSeconds
        entries = stats.entries
        entriesPerSecond = wallSeconds > 0 ? Double(stats.entries) / wallSeconds : 0
        self.peakRSSBytes = peakRSSBytes
        self.stats = stats
    }
}

struct StrategyResult: Codable, Sendable {
    let strategy: String
    let workers: Int
    /// Bulk attribute set (`minimal`/`standard`/`full`); nil for the other strategies.
    let attributeSet: String?
    let warmupSeconds: Double?
    let runs: [RunMeasurement]
    /// Fastest measured run.
    let best: RunMeasurement
    /// Median by wall time (upper median for even counts).
    let median: RunMeasurement

    init(strategy: String, workers: Int, attributeSet: String?, warmupSeconds: Double?, runs: [RunMeasurement]) {
        precondition(!runs.isEmpty)
        self.strategy = strategy
        self.workers = workers
        self.attributeSet = attributeSet
        self.warmupSeconds = warmupSeconds
        self.runs = runs
        let sorted = runs.sorted { $0.wallSeconds < $1.wallSeconds }
        best = sorted[0]
        median = sorted[sorted.count / 2]
    }
}

struct WalkReport: Codable, Sendable {
    var schema = "reclaim-bench/walk/v1"
    let generatedAt: String
    let host: HostInfo
    let root: String
    let repeatCount: Int
    let warmup: Bool
    let results: [StrategyResult]

    private enum CodingKeys: String, CodingKey {
        case schema, generatedAt, host, root, warmup, results
        case repeatCount = "repeat"
    }
}

struct FixtureReport: Codable, Sendable {
    var schema = "reclaim-bench/fixture/v1"
    let generatedAt: String
    let host: HostInfo
    let root: String
    let directories: Int
    let files: Int
    let entries: Int
    let bytesPerFile: Int
    let workers: Int
    let wallSeconds: Double
    let entriesPerSecond: Double

    private enum CodingKeys: String, CodingKey {
        case schema, generatedAt, host, root, directories, files, entries, bytesPerFile, workers, wallSeconds, entriesPerSecond
    }
}

enum Output {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.3f s", value)
    }
}
