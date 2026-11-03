// Swift Testing tags shared by every test target (PLAN.md §2.2 "Tests", §6 phase exit criteria).
// Because this file imports `Testing`, ReclaimTestSupport must only be linked into test bundles (ADR-012).

import Testing

public extension Tag {
    /// Needs a real APFS volume (sparse files, clones, private sizes). All fixture tests carry this tag.
    @Tag static var requiresAPFS: Tag
    /// Needs root (privileged helper, `purge`, snapshot deletion); never runs on CI.
    @Tag static var requiresAdmin: Tag
    /// Needs `hdiutil attach` of a disk image inside the fixture tree (mount-boundary tests).
    @Tag static var requiresAPFSMount: Tag
    /// Needs a reachable Docker daemon.
    @Tag static var requiresDocker: Tag
}
