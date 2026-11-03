# ADR-008 — No telemetry, no network

**Status:** Accepted (PLAN.md §2.14, §0.3) · **Date:** 2026-11-02

Reclaim never phones home: no analytics, crash upload, or remote configuration; scan snapshots, the ledger and settings stay in `~/Library/Application Support/Reclaim/`, logs are privacy-redacted by default, and "Export diagnostics" produces a local zip the user chooses to share. A disk cleaner sees every file name on the machine and asks for Full Disk Access plus a root helper; that trust is only defensible if nothing leaves the device. **Alternatives rejected:** opt-in anonymous telemetry (still requires network entitlements and a privacy policy, and offers little for a single-developer v1) and a hosted crash reporter (the same concerns; Sparkle update checks, if enabled in Phase 5, remain the only outbound connection and are user-controlled).
