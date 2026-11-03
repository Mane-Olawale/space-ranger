# ADR-016 — Revised Phase 1 scan performance targets

**Status:** Accepted (Phase 1, 2026-11-03) · **Supersedes:** the numeric budgets in PLAN.md §0.2 G1, §2.12 and the Phase 1 `T1-BENCH-2M` row as originally written. PLAN.md has been edited to match. **Evidence:** [docs/benchmarks/phase0.json](../benchmarks/phase0.json) and [docs/benchmarks/README.md](../benchmarks/README.md).

## Context

PLAN.md G1 / §2.12 / T0-BENCH-2M asked for a warm 2,000,000-entry scan in ≤ 3.0 s, with `bulk` ≥ 10× `FileManager.enumerator` and ≥ 3× `fts`. Phase 0 measured the three strategies on a 2,200,000-entry inode-only fixture (200,000 directories, two levels, 10 files per leaf).

On the author's Mac15,6 (Apple M3 Pro, 11 performance cores, 18 GB, macOS 26.0.1), release build, `bulk` at 11 workers:

| Measurement | Result |
|-------------|--------|
| Median wall time | **12.1 s** (best run 11.6 s) |
| `bulk` / `fts` (77.0 s) | **6.35×** (met the 3× bar) |
| `bulk` / `FileManager` (89.5 s) | **7.38×** (missed 10×) |
| Single-worker `bulk` | **102 s**, slower than single-thread `fts` |
| Peak RSS | ~3 MiB for the walk alone (no index) |
| `kern.maxvnodes` | **263,168** — an order of magnitude below the entry count |
| Load average during the run | 8–20 (not a quiet machine) |

The same fixture on the GitHub `macos-15` runner (VirtualMac2,1, 3 cores, 7 GB, `kern.maxvnodes` 113,713) took **23.9 s** at the default worker count. Ratios there were 2.30× vs `fts` and 3.65× vs `FileManager`.

The 3.0 s budget assumed a warm vnode cache the kernel will not grant for this fixture, and the 10× `FileManager` margin assumed Foundation still does per-entry `stat`. It does not: modern `FileManager.enumerator` already calls `getattrlistbulk`.

## Decision

Phase 1 targets, measured by `T1-BENCH-2M` / `Scripts/bench.sh` on the warm 2.2 M-entry fixture:

| Target | Value |
|--------|--------|
| Author's M3 Pro, warm | **≤ 6.0 s** |
| Stretch goal (not a gate) | 3.0 s |
| `macos-15` CI runner class | **≤ 15 s** |
| `bulk` vs `FileManager` | **≥ 5×** |
| `bulk` vs `fts` | unchanged, ≥ 3× (Phase 0 met this; `fts` stays the fallback only, ADR-002) |
| Peak RSS, 2 M entries, including the in-memory index | **≤ 300 MB** (unchanged) |

Cold-scan (≤ 10 s) and full Data-volume (≤ 25 s cold / ≤ 8 s warm) budgets in §2.12 are unchanged. "Warm" means a preceding full walk of the same tree, not "every vnode is cached" — `kern.maxvnodes` makes the latter impossible at this scale.

## Consequences

- `T1-BENCH-2M` gates on 6.0 s / 5× / 300 MB on the author machine, and on 15 s when the host is the 3-core CI runner class. The 3.0 s figure remains a stretch recorded in the benchmark JSON, not a failure.
- The scheduler should size itself from per-directory latency (Phase 0: 4 workers won in-cache, 11 workers won at 2.2 M entries) rather than assuming the syscall boundary is the cost.
- Memory accounting for the gate includes `FileIndex`, not just the walk's scratch buffers. Phase 0's ~3 MiB RSS is not the Phase 1 number.
