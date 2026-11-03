// Decimal byte display (ADR-006, PLAN.md §2.7). Counts stay `UInt64` everywhere else.

import Foundation

public enum ByteFormatting {
    /// Finder / System Settings style (`ByteCountFormatter.CountStyle.file`, decimal).
    public static func file(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Exact byte count, no unit suffix.
    public static func exact(_ bytes: UInt64) -> String {
        String(bytes)
    }

    /// Binary units for the engineer tooltip (KiB / MiB / GiB / TiB), one fractional digit past 1024.
    public static func binary(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }
}
