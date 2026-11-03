# ADR-012 — `ReclaimTestSupport` links Swift Testing and is linked only by test targets

**Status:** Accepted (Phase 0, 2026-11-03) · **PLAN.md gap:** §2.3 lists `ReclaimTestSupport` (FixtureBuilder, tags, fakes) and `ReclaimBench` (fixture generator) without saying how they relate.

## Context

PLAN.md puts the shared Swift Testing tags (`Tags.swift`) in `ReclaimTestSupport`, which forces that module to `import Testing`. A Phase 0 probe showed that any *executable* linking such a module compiles but crashes at launch (`dyld: Library not loaded: @rpath/Testing.framework`), because `Testing.framework` only exists in the Xcode platform directory that SwiftPM adds to test bundles' rpaths. `reclaim-bench` needs a large-tree generator, and `FixtureBuilder.largeTree` needs one too.

## Decision

1. `ReclaimTestSupport` keeps `Tags.swift` (as PLAN.md specifies) and is therefore a **test-only** module: only `.testTarget`s may depend on it. `Package.swift` documents this next to the target.
2. `ReclaimBench` does **not** depend on `ReclaimTestSupport`. It carries its own small `LargeTreeGenerator` (`Sources/ReclaimBench/Fixture/`) with the same layout contract as `ReclaimTestSupport/LargeTreeGenerator.swift` (`top = ⌈√dirs⌉` top-level directories `d<i>`, leaf directories `s<j>`, files `f<k>` spread round-robin, entries = dirs + files). The two implementations are ~80 lines each and are kept identical by review; T0-BENCH-2M exercises the bench generator and `largeTreeSmall` the test-support one.
3. The benchmark test (`Tests/ReclaimBenchTests`) drives the built `reclaim-bench` binary as a subprocess (one process per strategy, so `proc_pid_rusage` peak RSS is attributable) rather than `@testable import`ing the executable.

## Consequences

Executables stay free of test frameworks; a future `FakeToolRunner`/errno-injection code in `ReclaimTestSupport` can import test-only APIs freely. If the generator ever grows, the shared part should move to a tiny `ReclaimFixtures` library without a Testing dependency.
