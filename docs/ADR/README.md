# Architecture Decision Records

ADR-001 … ADR-010 summarise the decisions already made in PLAN.md §2.14 (PLAN.md remains authoritative).
ADR-011 is reserved for APFS clone accounting (Appendix G Q1) and is written when T1-SIZE-CLONE settles it in Phase 1.
ADR-012 onwards record decisions PLAN.md was silent on, in the order they were needed.

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-001](ADR-001-non-sandboxed-developer-id.md) | Non-sandboxed Developer ID app | Accepted |
| [ADR-002](ADR-002-getattrlistbulk-primary-fts-fallback.md) | `getattrlistbulk` primary, `fts` fallback | Accepted |
| [ADR-003](ADR-003-raw-sqlite.md) | Raw SQLite over SwiftData/GRDB | Accepted |
| [ADR-004](ADR-004-swift-testing-plus-xctest-perf.md) | Swift Testing + XCTest performance tests | Accepted |
| [ADR-005](ADR-005-tools-via-process-json.md) | Tools via `Process` with absolute paths and JSON | Accepted |
| [ADR-006](ADR-006-decimal-units.md) | Decimal units everywhere | Accepted |
| [ADR-007](ADR-007-macos-14-minimum.md) | macOS 14 minimum | Accepted |
| [ADR-008](ADR-008-no-telemetry.md) | No telemetry | Accepted |
| [ADR-009](ADR-009-trash-tier-default.md) | Trash tier default, permanent opt-in | Accepted |
| [ADR-010](ADR-010-menu-bar-in-main-app.md) | Main app hosts the menu bar monitor | Accepted |
| [ADR-011](ADR-011-clone-accounting.md) | APFS clone accounting (`privateReclaimable`) | Accepted (Phase 1) |
| [ADR-012](ADR-012-test-support-isolation.md) | `ReclaimTestSupport` links Swift Testing and is test-only | Accepted (Phase 0) |
| [ADR-013](ADR-013-home-layout.md) | `HomeLayout` shape for `FixtureBuilder.home` | Accepted (Phase 0) |
| [ADR-014](ADR-014-benchmark-scale-gating.md) | T0-BENCH-2M scale gating and CI policy | Accepted (Phase 0) |
| [ADR-015](ADR-015-hand-written-xcode-project.md) | Hand-written Xcode project driven by xcconfig | Accepted (Phase 0) |
| [ADR-016](ADR-016-phase1-performance-targets.md) | Phase 1 scan budgets revised from the Phase 0 baseline | Accepted (Phase 1) |
| [ADR-017](ADR-017-phase1-heavy-test-scale.md) | Phase 1 heavy tests scale like T0-BENCH-2M | Accepted (Phase 1) |
| [ADR-018](ADR-018-mount-status-firmlinks.md) | Mount-status bit vs firmlinks | Accepted (Phase 1) |
