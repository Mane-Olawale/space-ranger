// `realpath(3)` plus the firmlink table (PLAN.md §2.7). Canonical form is the Data-volume path.
// Display form is what the user typed (`/Users/…`).

import Darwin

public struct PathCanonicalizer: Sendable {
    public let firmlinks: FirmlinkTable

    public init(firmlinks: FirmlinkTable) {
        self.firmlinks = firmlinks
    }

    public static func system() -> PathCanonicalizer {
        let table = (try? FirmlinkTable.load()) ?? FirmlinkTable(links: [])
        return PathCanonicalizer(firmlinks: table)
    }

    /// `realpath` when the path exists, then firmlink rewrite onto the Data volume.
    public func canonicalize(_ path: String) -> String {
        let resolved = Self.realpath(path) ?? path
        return firmlinks.canonicalize(resolved)
    }

    public func displayPath(_ canonical: String) -> String {
        firmlinks.displayPath(for: canonical)
    }

    public static func realpath(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
