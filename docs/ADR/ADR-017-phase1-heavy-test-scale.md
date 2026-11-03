# ADR-017 — Phase 1 heavy tests scale the same way as T0-BENCH-2M

**Status:** Accepted (Phase 1, 2026-11-03) · **Extends:** ADR-014. **PLAN.md gap:** T1-SCAN-CANCEL, T1-SNAP-ROUNDTRIP and T1-BENCH-2M name the 2 M-entry fixture, which takes about a minute to generate and makes every `swift test` a multi-minute run.

## Decision

- `swift test` always runs the correctness checks. T1-SCAN-CANCEL uses 15 000 directories × 10 files (large enough that a cancel 500 ms in is still partial) and asserts the partial summary, directory-fd balance, and — when `RECLAIM_FD_ISOLATED=1` — that `proc_pidinfo(PROC_PIDLISTFDS)` returns to the pre-scan count. The ≤ 200 ms stop budget is asserted when `RECLAIM_BENCH_RELEASE=1`; debug builds assert ≤ 3 s because the post-pass over a partial index dominates.
- T1-SNAP-ROUNDTRIP always round-trips a small tree and checks the load is under 1 s. The 2 M-entry load is what `reclaim scan` plus the snapshot writer are measured against in the phase report, not in every debug test.
- T1-INDEX-SORT (200 k children, ≤ 50 ms) and T1-FDLIMIT (50 k directories, depth 300, ≤ 2 048 fds, no `EMFILE`) run at the planned size every time. They are the budgets that are cheap enough to keep honest.
- T1-BENCH-2M in XCTest scans 200 directories unless `RECLAIM_BENCH_FULL=1`, in which case it uses `/private/tmp/rcl-fixture` when that tree exists. The ≤ 6 s check is release-only (`RECLAIM_BENCH_RELEASE=1`). RSS ≤ 300 MB is always checked. `Scripts/bench.sh` remains the recorded baseline (ADR-014), now also emitting `docs/benchmarks/phase1.json`.

## Consequences

A laptop `swift test` stays on the order of a minute. The numbers in `phase1.json` are the release measurement the 6 s / 5× / 300 MB gate refers to.
