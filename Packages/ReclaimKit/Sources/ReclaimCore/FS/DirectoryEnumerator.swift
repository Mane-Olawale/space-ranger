// Per-directory enumeration (PLAN.md §2.6). `getattrlistbulk` is the primary reader. `fts` is selected
// for volumes that reject the bulk call (`ENOTSUP` / `EINVAL`) and when `ScanOptions.forceFTS` is set
// (ADR-002). The factory does not open paths; callers pass a directory fd they already own.

import Darwin

public protocol DirectoryEnumerator: AnyObject {
    func readDirectory(dirfd: Int32, expectedCount: UInt32) throws -> [BulkEntry]
}

public enum DirectoryEnumeratorFactory {
    /// Volumes known to implement `getattrlistbulk`. Anything else starts on `fts`. A bulk `ENOTSUP`
    /// during a scan still falls back even if this returns `false` (the kernel wins over the table).
    public static func needsFTS(fsType: String, forceFTS: Bool) -> Bool {
        if forceFTS { return true }
        switch fsType {
        case "apfs", "hfs", "exfat", "msdos", "devfs", "autofs":
            return false
        default:
            return true
        }
    }

    public static func makeBulk(bufferBytes: Int) -> BulkAttrEnumerator {
        BulkAttrEnumerator(bufferBytes: bufferBytes)
    }
}

extension BulkAttrEnumerator {
    /// `ENOTSUP` or `EINVAL` from `getattrlistbulk` means "this volume has no bulk attributes".
    public static func isUnsupported(_ error: Error) -> Bool {
        guard let fs = error as? FSError, let code = fs.errno else { return false }
        return code == ENOTSUP || code == EINVAL
    }
}
