# ADR-018 — `ATTR_DIR_MOUNTSTATUS` on firmlinks and disk images

**Status:** Accepted (Phase 1, 2026-11-03) · **Settles:** Appendix G Q2, measured by T1-VOL-MOUNTPOINT and a read of `/` on the author's Mac15,6 (macOS 26.0.1).

## Measurement

`getattrlistbulk` with the Phase 1 attribute set:

| Path | `ATTR_DIR_MOUNTSTATUS` | `DIR_MNTSTATUS_MNTPOINT` | `SF_FIRMLINK` |
|------|------------------------|--------------------------|---------------|
| APFS DMG mounted inside a fixture (`hdiutil attach -mountpoint`) | `1` | set | clear |
| `/Users`, `/private`, `/Applications` (firmlinks from `/usr/share/firmlinks`) | `0` | clear | set (`st_flags` `0x900000`, which includes `SF_FIRMLINK` `0x800000`) |

The mount-status bit is reliable for a real APFS mount (the disk image). It is **not** set on firmlinks. Firmlinks are distinguished by `SF_FIRMLINK`, not by mount status.

## Decision

- A directory with `DIR_MNTSTATUS_MNTPOINT` set and `SF_FIRMLINK` clear is a boundary. The scanner does not descend. The boundary entry's allocated size is the mounted volume's `statfs` used bytes (`(f_blocks - f_bfree) * f_bsize`), and a `.boundary` event carries that volume.
- A directory with `SF_FIRMLINK` set is descended. It is the same file tree as the Data-volume path. Identity dedupe `(fsid, fileID)` keeps a second root that names the same inode as one `EntryID` (T1-FIRMLINK-DEDUPE).
- `st_dev` is read once for the scan root (`fstat`) and inherited. It is not re-checked per directory: the Phase 1 profile showed an extra `fstat` per directory would add a syscall the mount-status bit already replaces for the cases above. A volume that reports neither the mount bit nor `SF_FIRMLINK` is still not crossed when `ScanOptions.crossMountPoints` is false only if the bit is set; that is the gap Q2 was worried about, and on this OS the bit is set for the disk-image case the product has to get right.

## Consequences

T1-VOL-MOUNTPOINT asserts the boundary kind, no children, the image's used-byte size, and a boundary event. Firmlink paths are not boundaries. `fts` remains the fallback only when `getattrlistbulk` returns `ENOTSUP`/`EINVAL` (ADR-002), not because mount status is missing.
