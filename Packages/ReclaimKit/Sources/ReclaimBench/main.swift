// `reclaim-bench` — Phase 0 benchmark harness and fixture generator (PLAN.md §6 Phase 0).

import ArgumentParser

struct ReclaimBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclaim-bench",
        abstract: "Reclaim enumeration benchmarks: generate large fixtures and time filemanager/fts/bulk walks.",
        version: "0.1.0",
        subcommands: [FixtureCommand.self, WalkCommand.self]
    )

    /// Top-level code resolves `main()` to the synchronous `ParsableCommand` overload; this async hop makes
    /// the `AsyncParsableCommand` entry point unambiguous so `run() async` subcommands work.
    static func runAsync() async {
        await main()
    }
}

await ReclaimBench.runAsync()
