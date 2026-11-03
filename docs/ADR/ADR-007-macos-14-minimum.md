# ADR-007 — macOS 14 (Sonoma) minimum deployment target

**Status:** Accepted (PLAN.md §2.14, §2.2) · **Date:** 2026-11-02

The app, helper and ReclaimKit package target macOS 14.0. It gives us `@Observable` for `AppModel`, the mature `SMAppService` daemon registration and status behaviours, `MenuBarExtra`, `NSXPCConnection.setCodeSigningRequirement`, `OSAllocatedUnfairLock`, and Swift 6 language mode with complete concurrency checking on a toolchain whose SDK supports the OS. **Alternatives rejected:** macOS 13 (loses `@Observable` and ships `SMAppService` edge cases we would have to work around) and macOS 15 (would unlock the `Synchronization` module but excludes the Sonoma machines the product is meant to rescue).
