# Benchmarks

`phase0.json` is the Phase 0 baseline required by PLAN.md T0-BENCH-2M, produced by `Scripts/bench.sh`
(schema `reclaim-bench/baseline/v1`): host description (incl. load averages, `kern.memorystatus_level`,
`kern.maxvnodes`), fixture generation stats, one entry per walk (`median`/`best` run, all runs, peak RSS via
`proc_pid_rusage`) and the derived ratios against PLAN.md's thresholds.

## Phase 0 baseline (2026-11-03, Apple M3 Pro, 18 GB, macOS 26.0.1, release build)

Fixture: 200 000 directories / 2 000 000 inode-only files (2 200 000 entries, two-level tree, 10 files per
directory), generated in 49.9 s. Conditions were **not** quiet: load average 8–20 from unrelated processes
(a Virtualization VM, System Settings' Storage scanners), memory level 32–39 %.

| Strategy | Workers | Attributes | Median | Entries/s | Peak RSS |
|----------|---------|------------|-------:|----------:|---------:|
| filemanager | 1 | — | 89.5 s | 24.6 k | 2 MiB |
| fts | 1 | — | 77.0 s | 28.6 k | 2 MiB |
| bulk | 1 | full | 102.0 s | 21.6 k | 2 MiB |
| bulk | 2 | full | 38.3 s | 57.4 k | 2 MiB |
| bulk | 4 | full | 19.3 s | 114 k | 2 MiB |
| bulk | 8 | full | 12.8 s | 172 k | 3 MiB |
| bulk | 11 | full | **12.1 s** | 181 k | 3 MiB |
| bulk | 11 | standard | 11.5 s | 191 k | 3 MiB |
| bulk | 11 | minimal | 12.0 s | 183 k | 3 MiB |

PLAN.md thresholds: `bulk ≥ 3× fts` → **6.35× (met)**; `bulk ≥ 10× filemanager` → **7.38× (not met)**;
`bulk ≤ 3.0 s` → **12.1 s (not met)**.

## What the data says (input to Phase 1)

1. **Parallelism, not the syscall, is the win.** Single-threaded `getattrlistbulk` (102 s) is *slower* than
   `fts` (77 s) at this scale and roughly equal at 220 k entries. The per-entry cost is inside APFS/VFS
   (vnode creation, B-tree lookups), not the syscall boundary; bulk scales to 8–11 workers because many
   lookups are in flight at once.
2. **`FileManager.enumerator` is not 10–50× slower.** Modern Foundation already uses `getattrlistbulk`;
   it is 1.2–2.3× slower than `fts`. A 10× margin over it is unreachable for any single-process strategy.
3. **A 2.2 M-entry tree is never "warm".** `kern.maxvnodes` is 263 168 on this 18 GB machine, so each
   full walk re-creates every vnode; throughput collapses from ~200–600 k entries/s (220 k-entry fixture, in
   cache) to ~20–30 k entries/s per thread. The ≤ 3.0 s budget assumes a cache the kernel does not have.
4. **Attribute set cost is small at scale:** `minimal`/`standard`/`full` differ by < 10 % when I/O-bound;
   in-cache, `full` (with `ATTR_CMNEXT_*`) costs ~20–50 % more than `minimal`.
5. **Worker count should adapt:** in-cache (220 k entries) 4 workers were fastest and 11 were slower;
   I/O-bound (2.2 M) 11 workers were fastest. Phase 1's scheduler should size the pool from observed
   per-directory latency rather than a fixed `min(cpu, 12)`.

Re-run with `Scripts/bench.sh` (full scale, ~30 min including fixture generation and removal) or
`RECLAIM_BENCH_FULL=1 swift test -c release --filter BenchmarkTests` for the assertion form.
