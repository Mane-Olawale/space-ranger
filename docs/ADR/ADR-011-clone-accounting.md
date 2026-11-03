# ADR-011 — APFS clone accounting

**Status:** Accepted (Phase 1, 2026-11-03) · **Settles:** Appendix G Q1, measured by T1-SIZE-CLONE on the author's Mac15,6 (macOS 26.0.1, APFS).

## Measurement

A 100 MiB file `A` and `clonefile(2)` of it named `B`, read back with the Phase 1 attribute set (`FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED`):

| Field | A | B |
|-------|--:|--:|
| `ATTR_FILE_ALLOCSIZE` | 104 857 600 | 104 857 600 |
| `ATTR_CMNEXT_PRIVATESIZE` | **0** | **0** |
| `ATTR_CMNEXT_CLONEID` | 290 436 343 | 290 436 343 (same, non-zero) |
| `ATTR_CMNEXT_EXT_FLAGS` | `0x41` | `0x41` |

`0x41` is `EF_MAY_SHARE_BLOCKS | EF_SHARES_ALL_BLOCKS`. The kernel attributes the shared blocks to **neither** side: both report their full allocated size (what `du` would sum to 200 MiB) and **zero** private bytes. This matches the Phase 0 fixture comment in `FixtureBuilder`. Deleting only one of the pair frees nothing; deleting both frees one copy, 100 MiB.

## Decision

`privateReclaimable` of a tree is the bytes a deletion of that whole tree is estimated to return:

1. Hard links (`linkCount > 1`) contribute logical, allocated, and private bytes once per `(volumeIndex, fileID)`. Later names contribute nothing to ancestors. Each name still stores the kernel sizes so the inspector can show "N links".
2. Entries that share a non-zero `cloneID` form a family. The family's contribution is Σ `ATTR_CMNEXT_PRIVATESIZE` when that sum is non-zero, and otherwise `max(ATTR_FILE_ALLOCSIZE)` — one copy of the shared blocks, which is what comes back when the last member in the tree is deleted. The contribution is attached to the first member; the others contribute 0. A family of one is left alone: a lone clone whose sibling lives outside the scan reports private 0 and must not be counted as if deleting it freed the shared blocks.
3. Directory `logical` / `allocated` / `privateBytes` after the post-pass are the rolled-up totals of those contributions, **excluding mount boundaries**. For a directory, `SizeTriple.privateBytes` and `privateReclaimable` are that rollup. For a file they stay the kernel private size (0 on both sides of a full clone).
4. `fts` has no private size. Those rows set `privateBytes = allocated` and `ExtFlags.allocatedOnly` (bit 7, not a kernel `EF_*` bit) so a fallback scan does not pretend to know sharing.

T1-SIZE-CLONE therefore sees `allocated(A)+allocated(B) == 200 MiB`, `private(A) == private(B) == 0`, and `privateReclaimable(directory) == 100 MiB`.

## Consequences

Findings and plans that estimate "space freed if this directory is deleted" must use `privateReclaimable`, not Σ `allocated` and not Σ kernel private (which is 0 for a clone family and would under-state a full-directory delete). "Reclaimable if this one file is deleted alone" stays the kernel private size, which is 0 for either member of a full clone. The duplicate finder should treat a shared `cloneID` as already deduplicated.
