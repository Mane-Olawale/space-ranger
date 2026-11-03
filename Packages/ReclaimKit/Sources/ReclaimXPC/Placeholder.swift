// ReclaimXPC — @objc HelperProtocol, shared request/response structs, code-signing requirement strings.
// Depends on nothing (PLAN.md §2.3). Phase 0 placeholder; real sources arrive in Phase 5.

/// Marker so the module has a stable, importable symbol during Phase 0.
public enum ReclaimXPCModule {
    /// Mach service / LaunchDaemon label (PLAN.md §2.2 identifiers).
    public static let helperLabel = "com.olawale.reclaim.helper"
}
