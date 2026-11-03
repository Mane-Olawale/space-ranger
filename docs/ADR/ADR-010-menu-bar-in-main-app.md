# ADR-010 — The main app hosts the menu bar monitor (activation policy switch)

**Status:** Accepted (PLAN.md §2.14, §5.7) · **Date:** 2026-11-02

The background monitor is a `MenuBarExtra` scene inside `Reclaim.app`: when the last window closes with "Keep in menu bar" enabled the app switches `NSApp.setActivationPolicy(.accessory)` and a `ContinuousClock` task polls `statfs`, cheap `getattrlist` probes of watched roots and FSEvents, posting `UNUserNotificationCenter` alerts when thresholds are crossed. A single process means a single Full Disk Access grant, a single code-signing identity to validate, one settings store and one update to ship. **Alternatives rejected:** a separate LaunchAgent (a second TCC subject that would need its own FDA approval and its own update path) and a helper-based monitor running as root (far more privilege than a size probe warrants). To be revisited in v2 if the ≤ 30 MB / ≤ 0.1 % CPU idle budget (G6) cannot be met in-process.
