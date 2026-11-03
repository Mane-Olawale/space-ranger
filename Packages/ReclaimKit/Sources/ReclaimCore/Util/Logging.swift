// Unified logging (PLAN.md §2.2). Paths are private unless a call site opts into `.public`.

import os

extension Logger {
    /// Scanner, index, and volume topology.
    public static let scan = Logger(subsystem: "com.olawale.reclaim.scan", category: "scan")
    /// Rules engine (Phase 3). The subsystem exists so later modules share one naming scheme.
    public static let rules = Logger(subsystem: "com.olawale.reclaim.rules", category: "rules")
    /// Deletion, path guard, ledger.
    public static let safety = Logger(subsystem: "com.olawale.reclaim.safety", category: "safety")
    /// Privileged helper.
    public static let helper = Logger(subsystem: "com.olawale.reclaim.helper", category: "helper")
    /// SwiftUI / AppKit shell.
    public static let ui = Logger(subsystem: "com.olawale.reclaim.ui", category: "ui")
}

/// Marker and package version. Helper versioning (PLAN.md §2.9.4) reuses `version`.
public enum ReclaimCoreModule {
    public static let version = "0.1.0"
}
