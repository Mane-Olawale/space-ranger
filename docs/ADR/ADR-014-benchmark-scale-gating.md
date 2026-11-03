# ADR-014 — T0-BENCH-2M runs at full scale on demand and at 1/10 scale in every `swift test`

**Status:** Accepted (Phase 0, 2026-11-03) · **PLAN.md gap:** T0-BENCH-2M defines the fixture (200 k dirs / 2 M files), the ratios (`bulk` ≥ 3× `fts`, ≥ 10× `filemanager`) and the budget (`bulk` ≤ 3.0 s "on the CI runner class"), but not how a 2.2 M-entry fixture fits into the ordinary test run or where the baseline JSON comes from.

## Decision

- `Tests/ReclaimBenchTests/BenchmarkTests.testT0Bench2M` always runs. With `RECLAIM_BENCH_FULL=1` it generates the full `--dirs 200000 --files 2000000` fixture and asserts the ratios **and** the 3.0 s budget. Without it (`swift test` on a laptop or in the `build-test` CI job) it uses `--dirs 20000 --files 200000`, asserts entry/size agreement across all three strategies and the speed ratios, and skips the absolute budget (which PLAN.md defines for the full fixture only).
- `Scripts/bench.sh` builds in Release, generates the full fixture, runs each strategy in its own process (`--repeat 3`, warm-up on) and merges the three reports into `docs/benchmarks/phase0.json` with `jq`. That file, not the test, is the recorded baseline; it carries host info and load averages so numbers can be judged.
- CI (`.github/workflows/ci.yml`) runs the scaled test in the required `build-test` job and the full benchmark in a separate `bench` job on `workflow_dispatch`/`main` pushes whose artifact is uploaded; the `bench` job is informational (`continue-on-error`) until Phase 1 tightens thresholds, exactly as PLAN.md anticipates ("thresholds tightened in Phase 1").
- Fixtures are inode-only (`--bytes-per-file 0`) by default so the 2.2 M-entry tree costs a few hundred MB of metadata rather than 8 GB of data; walk time is unaffected because the strategies read metadata only.

## Consequences

`swift test` stays under a minute; the full benchmark (~2–4 min locally) is an explicit action; the baseline lives in git and is diffable. The measured ratios, not PLAN.md's assumed ones, are what Phase 1 inherits (see docs/benchmarks/phase0.json "notes").
