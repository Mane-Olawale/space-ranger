// `reclaim-bench walk --strategy filemanager|fts|bulk --root PATH --workers N --repeat 3 --json`
// (PLAN.md §6 Phase 0 "Benchmark harness"). `--strategy` may be repeated to measure several in one process.

import ArgumentParser
import Darwin
import Foundation

enum Strategy: String, ExpressibleByArgument, CaseIterable, Sendable {
    case filemanager, fts, bulk
}

extension BulkAttributeSet: ExpressibleByArgument {}

struct WalkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "walk",
        abstract: "Time an enumeration strategy over a tree: wall time, entries/s, peak RSS."
    )

    @Option(name: .long, help: "Enumeration strategy (repeatable): filemanager, fts or bulk.")
    var strategy: [Strategy] = [.bulk]

    @Option(name: .long, help: "Root directory to walk.", transform: FixtureCommand.absolutePath)
    var root: String

    @Option(name: .long, help: "Worker tasks for the bulk strategy (default: min(active CPUs, 12)).")
    var workers: Int = min(ProcessInfo.processInfo.activeProcessorCount, 12)

    @Option(name: .long, help: "Measured passes per strategy.")
    var `repeat`: Int = 3

    @Flag(name: .long, inversion: .prefixedNo, help: "Run one unmeasured warm-up pass per strategy first.")
    var warmup = true

    @Option(name: .long, help: "getattrlistbulk buffer size in bytes (bulk strategy).")
    var bufferBytes: Int = 256 * 1024

    @Option(name: .long, help: "Attribute set requested by the bulk strategy: minimal, standard or full (PLAN.md §2.6.2).")
    var attrs: BulkAttributeSet = .full

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Bulk strategy: stop reading a directory once ATTR_DIR_ENTRYCOUNT entries were returned (skips the final empty call).")
    var trustEntryCount = true

    @Flag(name: .long, help: "Emit a JSON report instead of text.")
    var json = false

    func validate() throws {
        guard `repeat` >= 1 else { throw ValidationError("--repeat must be ≥ 1") }
        guard workers >= 1 else { throw ValidationError("--workers must be ≥ 1") }
        guard bufferBytes >= 4096 else { throw ValidationError("--buffer-bytes must be ≥ 4096") }
        guard !strategy.isEmpty else { throw ValidationError("at least one --strategy is required") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("--root \(root) is not a directory")
        }
    }

    func run() async throws {
        var results: [StrategyResult] = []
        var seen = Set<Strategy>()
        for choice in strategy where seen.insert(choice).inserted {
            let walker = makeStrategy(choice)
            if !json {
                let attrs = walker.attributeSet.map { ", attrs=\($0)" } ?? ""
                print("\(walker.name) (\(walker.workers) worker\(walker.workers == 1 ? "" : "s")\(attrs)) on \(root)")
            }
            var warmupSeconds: Double?
            if warmup {
                let measurement = try await measure(walker)
                warmupSeconds = measurement.wallSeconds
                if !json { print("  warm-up: \(Output.seconds(measurement.wallSeconds))") }
            }
            var runs: [RunMeasurement] = []
            for index in 0..<`repeat` {
                let measurement = try await measure(walker)
                runs.append(measurement)
                if !json {
                    print("  run \(index + 1): \(Output.seconds(measurement.wallSeconds))  \(measurement.entries) entries  "
                        + "\(Int(measurement.entriesPerSecond)) entries/s  peak RSS \(Output.bytes(measurement.peakRSSBytes))"
                        + (measurement.stats.errors > 0 ? "  errors \(measurement.stats.errors)" : ""))
                }
            }
            let result = StrategyResult(strategy: walker.name, workers: walker.workers, attributeSet: walker.attributeSet,
                                        warmupSeconds: warmupSeconds, runs: runs)
            results.append(result)
            if !json {
                let stats = result.median.stats
                print("  median \(Output.seconds(result.median.wallSeconds)), best \(Output.seconds(result.best.wallSeconds)); "
                    + "\(Output.bytes(stats.bytesAllocated)) allocated, \(Output.bytes(stats.bytesLogical)) logical")
            }
        }
        if json {
            let report = WalkReport(
                generatedAt: Output.timestamp(),
                host: HostInfo.current(),
                root: root,
                repeatCount: `repeat`,
                warmup: warmup,
                results: results
            )
            print(try Output.json(report))
        }
    }

    private func makeStrategy(_ choice: Strategy) -> any WalkStrategy {
        switch choice {
        case .filemanager: return FileManagerWalk()
        case .fts: return FTSWalk()
        case .bulk: return BulkAttrWalk(workers: workers, bufferBytes: bufferBytes, attributes: attrs, trustEntryCount: trustEntryCount)
        }
    }

    private func measure(_ walker: any WalkStrategy) async throws -> RunMeasurement {
        let clock = ContinuousClock()
        let start = clock.now
        let stats = try await walker.walk(root: root)
        let elapsed = (clock.now - start).seconds
        return RunMeasurement(wallSeconds: elapsed, stats: stats, peakRSSBytes: ResourceUsage.peakFootprintBytes())
    }
}
