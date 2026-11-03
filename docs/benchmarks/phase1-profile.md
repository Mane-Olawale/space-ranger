# Phase 1 profile — `BulkAttrWalk` on the 2.2 M fixture

Recorded 2026-11-03 on the author's Mac15,6 (Apple M3 Pro, 11 cores, 18 GB, macOS 26.0.1) before `ScanEngine` was written. Tooling: release `reclaim-bench` (`Packages/ReclaimKit/.build/arm64-apple-macosx/release/reclaim-bench`), `/usr/bin/time -l`, and `/usr/bin/sample` (1 ms) attached to a second walk. `xctrace` System Trace / `fs_usage` need root to see per-syscall counts; the time-based sample plus the known call shape below is the syscall evidence. Fixture: `/private/tmp/rcl-fixture`, 200 000 directories / 2 000 000 files / 2 200 000 entries, inode-only, two-level (`d<i>/s<j>/f<k>`). `kern.maxvnodes` = 263 168. Load average during the timed walk was **10.8 / 12.8 / 9.1** (the machine was not idle; Phase 0's 12.1 s run was also loaded).

## Timed walk

`walk --strategy bulk --workers 11 --attrs full --repeat 1` (includes one warmup pass). `/usr/bin/time -l` covers warmup + measured pass:

| | |
|--|--|
| Wall (both passes) | 35.05 s |
| Measured pass median | **19.05 s**, 115 k entries/s, peak RSS 3.7 MiB |
| User CPU | **0.46 s** |
| System CPU | **95.34 s** |
| Voluntary context switches | 1 980 751 (≈ 990 k per pass) |
| Involuntary context switches | 668 803 |
| Instructions retired | 3.49×10¹¹ (process, both passes) |
| Max RSS (`time -l`) | 12 MiB |

Phase 0 on a similarly loaded boot measured 12.1 s median for the same shape (best 11.6 s). This run is slower because the machine was busier, not because the binary changed. A second pass is not meaningfully "warm": 2.2 M entries do not fit in 263 k vnodes, so each pass rebuilds the cache.

## Where the samples go

`sample` for 6 s of a no-warmup 11-worker walk (time-based, so a frame is "on CPU or in that syscall", not a count). The main thread is idle in `mach_msg` inside `CFRunLoop` (the Swift concurrency drain). Each worker thread's samples collapse to:

| Frame | Share of a worker's samples |
|-------|-----------------------------|
| `getattrlistbulk` | ~80 % |
| `openat` (`_fcntl_overlay_openat` → `__openat`) | ~19 % |
| `close` | < 1 % |
| `swift_task_switch` / allocator | a handful of samples across all threads |

User-space parsing, the LIFO actor queue, and buffer management do not show up. The 0.46 s of user CPU across two full passes is the same fact: **per-entry Swift work is noise next to vnode setup.**

## Syscall shape (from the code, checked against the switches)

`BulkAttrWalk` with `trustEntryCount` (the default) issues, per directory:

1. one `openat(parent, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`
2. one `getattrlistbulk` — a leaf holds 10 names and a top-level directory holds ~447, and a full attribute record is ~150–200 bytes, so a **256 KiB buffer holds the widest directory in this fixture in one call**
3. one `close`

That is ~200 k of each, ~600 k syscalls per pass. ~990 k voluntary switches per pass is ~1.6 wakes per syscall (block in `getattrlistbulk` / `openat`, plus the odd scheduler hop). It is not one syscall per file. The extra `getattrlistbulk` that would return 0 is skipped when the parent's `ATTR_DIR_ENTRYCOUNT` is trusted; Phase 0 showed that matches the real entry count on this fixture.

`openat` is a fifth of the samples because creating the directory vnode is expensive, not because the Swift wrapper is. `close` is cheap and almost never sampled. There is no per-file `fstat`.

## What Phase 1 should copy, and what it must not add

1. **Keep 256 KiB buffers and `trustEntryCount`.** The buffer is not the limit (one call already drains every directory here). Shrinking it would only add syscalls; growing it does not remove the one call we already make.
2. **Keep a deep LIFO worker pool sized to `min(active CPUs, 12)`.** Phase 0: 11 workers won at this scale, 4 won only when the tree fit in the vnode cache. Actor hops are invisible in the sample — a lock-based queue is there to avoid *adding* hops when the index is appended, not because the Phase 0 queue is the 12 s.
3. **Do not add a syscall per directory.** No `fstat`/`fstatat` on the hot path. Inherit `st_dev` / volume index from the parent. `fstat` the root once. Consult `ATTR_DIR_MOUNTSTATUS` (and `st_dev` only after a mount flag or an `openat` we already did) for boundaries.
4. **Do not allocate a `String` or `Data` per file.** 2.2 M small objects would finally show up in user time and in the 300 MB RSS budget. Copy name bytes into one arena per batch. Directory paths (200 k, not 2.2 M) are the only strings the walk needs.
5. **Cap queued directory fds at 2 048** by deferring a partially-opened parent under the LIFO stack (T1-FDLIMIT). That does not change the 2.2 M fixture (fan-out ≤ ~450, depth 2) but keeps the depth-300 tree off `EMFILE`.
6. **The 6.0 s ADR-016 gate is below this kernel floor on a loaded boot.** Phase 0's quiet-as-it-got number was 11.6–12.1 s for a walk that stores nothing. `ScanEngine` can match that shape; it cannot do the vnode work twice as fast. The stretch remains 3 s. RSS headroom is large (walk ≈ 4 MiB; the SoA index is the thing that has to stay ≤ 300 MiB).
