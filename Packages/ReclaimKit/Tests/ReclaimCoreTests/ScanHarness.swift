import Foundation
import ReclaimCore
import ReclaimTestSupport
import Testing

enum ScanHarness {
    struct Outcome: Sendable {
        var reader: FileIndexReader
        var events: [ScanEvent]
        var summary: ScanSummary?
    }

    static func scan(
        _ roots: [String],
        forceFTS: Bool = false,
        useDefaultExcludes: Bool = false,
        maxConcurrency: Int = min(ProcessInfo.processInfo.activeProcessorCount, 12)
    ) async throws -> Outcome {
        let engine = ScanEngine(topology: VolumeTopology())
        let options = ScanOptions(
            roots: roots,
            maxConcurrency: maxConcurrency,
            forceFTS: forceFTS,
            useDefaultExcludes: useDefaultExcludes
        )
        return try await run(engine, options: options)
    }

    static func run(_ engine: ScanEngine, options: ScanOptions) async throws -> Outcome {
        let stream = await engine.run(options)
        var events: [ScanEvent] = []
        var summary: ScanSummary?
        for try await event in stream {
            if case let .finished(value) = event { summary = value }
            events.append(event)
        }
        let reader = try await engine.result()
        return Outcome(reader: reader, events: events, summary: summary)
    }
}

func runTool(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        Issue.record("\(path) \(arguments) exited \(process.terminationStatus): \(text)")
        throw FixtureError.invalidSpec("\(path) exited \(process.terminationStatus)")
    }
}
