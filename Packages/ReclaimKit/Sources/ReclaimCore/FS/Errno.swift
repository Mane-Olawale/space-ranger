// Errno classification (PLAN.md §2.9.1, §2.13, §6 Phase 1). `EPERM` is a policy denial
// (TCC / SIP / data vault); `EACCES` is an ordinary POSIX permission check. The UI distinguishes them.

import Darwin

/// A POSIX failure captured at the call site. `errno` is copied immediately — it is not re-read later.
public struct ErrnoError: Error, Sendable, Equatable, CustomStringConvertible {
    public let call: String
    public let errno: Int32
    public let path: String?

    public init(call: String, errno: Int32, path: String? = nil) {
        self.call = call
        self.errno = errno
        self.path = path
    }

    /// `EPERM` (1): TCC, SIP, or a data-vault denial. Not a mode-bit check.
    public var isPolicyDenial: Bool { errno == EPERM }

    /// `EACCES` (13): the process failed a POSIX permission check.
    public var isPosixDenial: Bool { errno == EACCES }

    public var description: String {
        let where_ = path.map { " (\($0))" } ?? ""
        return "\(call) failed: \(String(cString: strerror(errno))) (\(errno))\(where_)"
    }
}

/// Typed filesystem error. Carries the same classification as `ErrnoError` (PLAN.md §2.13).
public enum FSError: Error, Sendable, Equatable {
    case posix(call: String, errno: Int32, path: String?)
    case cancelled
    case snapshot(String)
    case noResult

    public var errno: Int32? {
        if case let .posix(_, errno, _) = self { return errno }
        return nil
    }

    public var isPolicyDenial: Bool { errno == EPERM }
    public var isPosixDenial: Bool { errno == EACCES }

    public static func capture(_ call: String, path: String? = nil) -> FSError {
        let code = Darwin.errno
        return .posix(call: call, errno: code, path: path)
    }
}
