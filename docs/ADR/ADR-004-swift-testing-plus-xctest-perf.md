# ADR-004 — Swift Testing for unit/integration tests, XCTest for performance tests

**Status:** Accepted (PLAN.md §2.14, §2.2) · **Date:** 2026-11-02

Unit and integration tests use Swift Testing (`import Testing`): parameterised tests, parallel execution by default, and trait-based gating with shared tags (`.requiresAPFS`, `.requiresAdmin`, `.requiresAPFSMount`, `.requiresDocker`, declared in `ReclaimTestSupport/Tags.swift`). XCTest is kept for what Swift Testing lacks — `measure`-style performance tests and XCUITest smoke flows — so benchmark assertions such as T0-BENCH-2M and T1-BENCH-2M live in XCTest targets. **Alternatives rejected:** XCTest only (no parameterised tests, no traits, serial by default) and Swift Testing only (no `measure`, no UI testing).
