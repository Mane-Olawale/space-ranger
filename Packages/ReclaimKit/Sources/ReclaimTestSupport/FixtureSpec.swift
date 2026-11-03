// FixtureSpec — declarative description of a real-APFS fixture tree (PLAN.md §6 Phase 0 "Core types introduced").

import Darwin

/// A declarative description of a filesystem tree that `FixtureBuilder` materialises on a real APFS
/// volume (under `/private/tmp`). Every node maps to one or more POSIX calls; nothing is created via a
/// shell (REQ-ENUM-1).
public struct FixtureSpec: Sendable {
    public enum Node: Sendable {
        /// Regular file. When `allocatedBytes` is nil the whole `logicalBytes` payload is written; when it is
        /// set, the file is `ftruncate`d to `logicalBytes` and only `allocatedBytes` bytes are written at the
        /// head (a sparse file). `mode` and `flags` (`UF_IMMUTABLE`, `UF_HIDDEN`, …) are applied after the data
        /// is written and `mtimeDaysAgo` is applied before `flags` so immutable files keep their timestamp.
        case file(name: String, logicalBytes: Int, allocatedBytes: Int? = nil, mtimeDaysAgo: Int = 0,
                  mode: mode_t = 0o644, flags: UInt32 = 0)
        /// `ftruncate(logicalBytes)` followed by writing `writtenBytes` at offset 0. APFS only keeps holes of
        /// ≥ 16 MiB, so use `logicalBytes - writtenBytes ≥ 16 MiB` (and page-aligned sizes) to get a genuinely
        /// sparse file — see `ExpectedSizes.sparseAllocation(logical:written:blockSize:pageSize:)`.
        case sparse(name: String, logicalBytes: Int, writtenBytes: Int)
        /// `clonefile(2)` of `of`. `of` is resolved relative to the node's parent directory unless absolute.
        case clone(name: String, of: String)
        /// `link(2)` to `of` (same resolution rule as `clone`).
        case hardlink(name: String, of: String)
        /// `symlink(2)`; `to` is stored verbatim, so loops (`a → b`, `b → a`) and links to parents are allowed.
        case symlink(name: String, to: String)
        /// Directory; `mode` is applied after the children exist (so `0o000` directories can be populated).
        case dir(name: String, mode: mode_t = 0o755, children: [Node])
        /// Unix domain socket created with `bind(AF_UNIX)`.
        case socket(name: String)
        /// A git repository: `git init`, one commit of `children`; when `dirty` an uncommitted file is added.
        case gitRepo(name: String, dirty: Bool, children: [Node])
        /// `packages` directories named `pkg-<i>` each holding `package.json` + `index.js`, totalling `bytesEach`.
        case nodeModules(name: String = "node_modules", packages: Int, bytesEach: Int)
    }

    public let root: [Node]

    public init(root: [Node]) {
        self.root = root
    }

    public init(_ root: Node...) {
        self.root = root
    }
}

/// Layout for `FixtureBuilder.home(_:)`: a fake user home directory. The fixture `root` *is* the home
/// directory (so later phases point `HOME`/`RuleEnvironment` at `fixture.root`); `library` nodes are created
/// under `<root>/Library`, `home` nodes directly under `<root>`.
/// PLAN.md leaves this type undefined; see docs/ADR/ADR-013-home-layout.md.
public struct HomeLayout: Sendable {
    public var library: [FixtureSpec.Node]
    public var home: [FixtureSpec.Node]

    public init(library: [FixtureSpec.Node] = [], home: [FixtureSpec.Node] = []) {
        self.library = library
        self.home = home
    }
}
