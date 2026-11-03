// `reclaim` command-line executable (PLAN.md §2.2, §6 Phase 2 defines the full command surface).
// Phase 0: root command only; subcommands (scan/top/report/plan/clean/undo/doctor) arrive in Phase 2.

import ArgumentParser
import ReclaimCore

struct Reclaim: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reclaim",
        abstract: "Reclaim — native macOS storage management (Phase 0 skeleton).",
        version: ReclaimCoreModule.version
    )

    func run() throws {
        print("reclaim \(ReclaimCoreModule.version) — Phase 0 skeleton. Commands arrive in Phase 2 (PLAN.md §6).")
    }
}

Reclaim.main()
