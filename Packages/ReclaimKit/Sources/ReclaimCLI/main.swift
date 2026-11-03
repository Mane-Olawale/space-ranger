// `reclaim` command-line executable (PLAN.md §2.2). Phase 2 adds top/report/plan/clean/undo/doctor.
// `scan` is the Phase 1 read-only validation entry point (no deletion).

import ArgumentParser
import Foundation
import ReclaimCore

@main
struct Reclaim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclaim",
        abstract: "Reclaim — native macOS storage management.",
        version: ReclaimCoreModule.version,
        subcommands: [ScanCommand.self]
    )
}

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Read-only scan of one or more roots. Prints a summary. Deletes nothing."
    )

    @Option(name: .long, help: "Root to scan. Repeat for more than one. Default: /System/Volumes/Data.")
    var root: [String] = []

    @Flag(name: .long, help: "Print one JSON object instead of lines.")
    var json = false

    func run() async throws {
        let roots = root.isEmpty ? ["/System/Volumes/Data"] : root
        let engine = ScanEngine(topology: VolumeTopology())
        let options = ScanOptions(roots: roots)
        let stream = await engine.run(options)
        var summary: ScanSummary?
        for try await event in stream {
            if case let .finished(value) = event { summary = value }
        }
        guard let finished = summary else { throw ScanFailure.noSummary }
        let reader = try await engine.result()
        if json {
            let object: [String: String] = [
                "entries": String(reader.count),
                "directories": String(finished.directoryCount),
                "files": String(finished.fileCount),
                "unreadable": String(finished.unreadableCount),
                "boundaries": String(finished.boundaryCount),
                "wallSeconds": String(format: "%.6f", ScanCommand.seconds(finished.elapsed)),
                "peakRSSBytes": String(finished.peakRSSBytes),
                "completeness": ScanCommand.describe(finished.completeness),
                "allocated": String(finished.bytesAllocated),
                "reclaimable": String(finished.bytesReclaimable),
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print("entries \(reader.count)")
        print("directories \(finished.directoryCount)")
        print("files \(finished.fileCount)")
        print("unreadable \(finished.unreadableCount)")
        print("boundaries \(finished.boundaryCount)")
        print("wall_seconds \(String(format: "%.3f", ScanCommand.seconds(finished.elapsed)))")
        print("peak_rss_bytes \(finished.peakRSSBytes)")
        print("completeness \(ScanCommand.describe(finished.completeness))")
        print("allocated \(finished.bytesAllocated)")
        print("reclaimable \(finished.bytesReclaimable)")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func describe(_ completeness: ScanSummary.Completeness) -> String {
        switch completeness {
        case .complete:
            "complete"
        case let .partial(reasons):
            "partial(\(reasons.joined(separator: ",")))"
        }
    }
}

enum ScanFailure: Error {
    case noSummary
}
