# ADR-006 — Decimal units everywhere

**Status:** Accepted (PLAN.md §2.14, §2.7, REQ-UX-3) · **Date:** 2026-11-02

All byte counts are stored as exact `UInt64` values and displayed with `ByteCountFormatter` in `.file` style, i.e. decimal GB/MB like Finder and System Settings → Storage; tooltips show the exact byte count and the binary (GiB) value for engineers. The audit repeatedly lost time reconciling `df -h`'s GiB against `diskutil`'s and Finder's GB (EC-07, EC-24), and the "freed" number must match what the user sees in Finder after a clean. **Alternatives rejected:** binary units (mismatch with every Apple UI) and a user-selectable unit system (two sets of numbers to explain; deferred to a tooltip instead).
