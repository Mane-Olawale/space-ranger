# ADR-013 — `HomeLayout`: the fixture root *is* the fake home directory

**Status:** Accepted (Phase 0, 2026-11-03) · **PLAN.md gap:** `FixtureBuilder.home(_ layout: HomeLayout) throws -> Fixture` is specified ("builds ~/Library-like tree") but `HomeLayout` is never defined.

## Decision

```swift
public struct HomeLayout: Sendable {
    public var library: [FixtureSpec.Node]   // created under <root>/Library
    public var home: [FixtureSpec.Node]      // created directly under <root>
}
```

`FixtureBuilder.home` creates `mkdtemp(/private/tmp/rcl-home-XXXXXX)`, materialises `home` nodes at the root and then `.dir(name: "Library", children: library)`. The returned `Fixture.root` is the home directory itself, so Phase 3 tests point `RuleEnvironment.home` (and `RECLAIM_HOME_OVERRIDE` in Phase 4) at `fixture.root` and `KnownPaths`-style templates (`~/Library/Caches/…`) resolve naturally. `ExpectedSizes.entryCount` includes the `Library` directory.

## Alternatives rejected

A `Users/<name>/` sub-tree inside the fixture root (forces every consumer to reconstruct the home path and adds two unneeded levels); named convenience fields per Library sub-folder (`caches`, `applicationSupport`, …) — premature until Phase 3 shows which ones rules actually need; they can be added as computed helpers that build `.dir` nodes without changing this shape.
