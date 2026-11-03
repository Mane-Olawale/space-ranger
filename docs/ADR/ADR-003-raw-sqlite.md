# ADR-003 — Raw SQLite (system `libsqlite3`) instead of SwiftData or GRDB

**Status:** Accepted (PLAN.md §2.14, §2.11, Appendix C) · **Date:** 2026-11-02

The rollback ledger, settings and snapshot catalog live in a single `ledger.sqlite` opened in WAL mode (`foreign_keys=ON`, `synchronous=NORMAL`) through a thin `actor SQLiteDatabase` wrapper around the system `libsqlite3`, with the DDL in Appendix C versioned by an explicit `schema_version` table. The ledger must be readable by the `reclaim` CLI and by the app alike, survive crashes mid-operation (resumable `in_progress` rows), and never surprise us with implicit schema migrations. **Alternatives rejected:** SwiftData (schema migration risk, `@MainActor` coupling, no CLI story) and GRDB (excellent, but it would be the second external dependency in a project whose only dependency is `swift-argument-parser`).
