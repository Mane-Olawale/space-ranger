# ADR-005 — External tools run via `Process` with absolute paths and machine-readable output

**Status:** Accepted (PLAN.md §2.14, §2.10, REQ-ENUM-1, REQ-API-1) · **Date:** 2026-11-02

`simctl`, `tmutil`, `docker`, `brew`, `avdmanager`, `qlmanage`, `git` and friends are executed by `actor ToolRunner` through `Foundation.Process` with executables resolved from a fixed candidate list (never `$PATH`), arguments passed as arrays (never a shell string), a reduced environment, bounded output capture and timeouts, and only machine-readable modes (`-j`, `--format json`, plist) are parsed. The audit's two worst defects came from the opposite approach: zsh globbing silently matched nothing for 130 `*.lid.status` folders (EC-01) and a `sed`/`awk` pipeline concatenated every digit of `diskutil`'s output into a 76-quadrillion-GB free-space figure (EC-11). **Alternatives rejected:** `/bin/sh -c` interpolation and parsing human-readable text.
