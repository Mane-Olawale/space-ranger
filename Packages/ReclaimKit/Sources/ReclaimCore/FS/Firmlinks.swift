// `/usr/share/firmlinks` (PLAN.md §2.7). Each line is `<system path>\\t<data-volume relative path>`.
// `/Users` → `/System/Volumes/Data/Users`. The Data volume root itself is not a firmlink row.

import Foundation

public struct Firmlink: Sendable, Equatable, Hashable {
    /// Path on the system volume, e.g. `/Users`.
    public let systemPath: String
    /// Corresponding path on the Data volume, e.g. `/System/Volumes/Data/Users`.
    public let dataPath: String

    public init(systemPath: String, dataPath: String) {
        self.systemPath = systemPath
        self.dataPath = dataPath
    }
}

public struct FirmlinkTable: Sendable, Equatable {
    public static let dataVolumeRoot = "/System/Volumes/Data"
    public let links: [Firmlink]

    public init(links: [Firmlink]) {
        // Longest prefix first so `/System/Library/Caches` wins over a shorter row.
        self.links = links.sorted { $0.systemPath.count > $1.systemPath.count }
    }

    public static func load(from path: String = "/usr/share/firmlinks") throws -> FirmlinkTable {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var links: [Firmlink] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard columns.count >= 2 else { continue }
            let system = String(columns[0])
            let relative = String(columns[1])
            let data = relative.hasPrefix("/")
                ? relative
                : dataVolumeRoot + "/" + relative
            links.append(Firmlink(systemPath: system, dataPath: data))
        }
        return FirmlinkTable(links: links)
    }

    /// Rewrite a firmlink source path onto the Data volume. Already-canonical paths are unchanged.
    public func canonicalize(_ path: String) -> String {
        if path == Self.dataVolumeRoot || path.hasPrefix(Self.dataVolumeRoot + "/") { return path }
        for link in links {
            if path == link.systemPath { return link.dataPath }
            let prefix = link.systemPath.hasSuffix("/") ? link.systemPath : link.systemPath + "/"
            if path.hasPrefix(prefix) {
                return link.dataPath + "/" + path.dropFirst(prefix.count)
            }
        }
        return path
    }

    /// User-facing path. `/System/Volumes/Data/Users/a` → `/Users/a`.
    public func displayPath(for canonical: String) -> String {
        let ranked = links.sorted { $0.dataPath.count > $1.dataPath.count }
        for link in ranked {
            if canonical == link.dataPath { return link.systemPath }
            let prefix = link.dataPath.hasSuffix("/") ? link.dataPath : link.dataPath + "/"
            if canonical.hasPrefix(prefix) {
                return link.systemPath + "/" + canonical.dropFirst(prefix.count)
            }
        }
        return canonical
    }
}
