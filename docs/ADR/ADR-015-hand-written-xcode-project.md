# ADR-015 — Hand-written `Reclaim.xcodeproj` driven entirely by xcconfig files

**Status:** Accepted (Phase 0, 2026-11-03) · **PLAN.md gap:** the file list names `Apps/Reclaim/Reclaim.xcodeproj` and `Config/*.xcconfig` but not how the project is produced or which settings live where.

## Decision

- The project file is written by hand (classic `objectVersion = 56` format, stable 24-hex object IDs prefixed `1C…`) and committed; no XcodeGen/Tuist dependency. Two native targets: `Reclaim` (application, `com.olawale.reclaim`) and `ReclaimHelper` (command-line tool, `com.olawale.reclaim.helper`). The app depends on the helper and embeds it at `Contents/MacOS/ReclaimHelper` plus `Config/LaunchDaemons/com.olawale.reclaim.helper.plist` at `Contents/Library/LaunchDaemons/` (PLAN.md §2.9.4 bundle layout) via two Copy Files phases.
- Every build setting that is not target identity lives in `Config/Base.xcconfig` (Swift 6, `SWIFT_STRICT_CONCURRENCY = complete`, macOS 14, hardened runtime, no sandbox, generated Info.plist), `Debug.xcconfig` (`-Onone`, `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, testability), `Release.xcconfig` (`-O`, dSYM, warnings visible but not fatal) and `Signing.xcconfig` (`CODE_SIGN_STYLE = Manual`; Debug ad-hoc `-`, Release `Developer ID Application` with `--timestamp --options runtime`; `DEVELOPMENT_TEAM = TEAMID` placeholder). The pbxproj's per-target `buildSettings` only hold `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`, `CODE_SIGN_ENTITLEMENTS`, `LD_RUNPATH_SEARCH_PATHS` and Info.plist keys.
- The shared scheme `Reclaim` is committed under `xcshareddata/xcschemes` so `xcodebuild -workspace Reclaim.xcworkspace -scheme Reclaim build` works on CI with `CODE_SIGNING_ALLOWED=NO`.
- `Reclaim.xcworkspace` references the project, the local `Packages/ReclaimKit` package and `PLAN.md`. The app target does not yet link ReclaimKit products (Phase 4 adds `ReclaimRules`/`ReclaimPersistence`/`ReclaimXPC`).

## Alternatives rejected

XcodeGen (available locally but adds a generator step and a third-party tool every contributor and CI must install); Xcode 16's folder-synchronised groups (`objectVersion 77`) — convenient, but opaque to review and not needed for two single-file targets; a static `Info.plist` (deferred until Phase 4 needs keys that `INFOPLIST_KEY_*` cannot express, e.g. `NSUserNotificationsUsageDescription`).
