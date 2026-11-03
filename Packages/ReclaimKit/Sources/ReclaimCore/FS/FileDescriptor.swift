// RAII directory/file descriptor (PLAN.md §2.6.2, §6 Phase 1).
// Directory traversal opens with `openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`
// and never with a path string, so a symlink cannot redirect the walk and `PATH_MAX` is irrelevant.
//
// The raw fd inside `FileDescriptor` is confined to the task that created the instance. The type is
// intentionally not `Sendable`. `nonisolated(unsafe)` is not used here.

import Darwin
import Foundation

public enum DirectoryOpen {
    /// Flags required for every directory the scanner descends into (PLAN.md §2.6.2).
    public static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Soft cap on directory fds held by the scheduler (queued + in a worker). `RLIMIT_NOFILE` is raised
    /// above this so the cap, not `EMFILE`, is what binds.
    public static let schedulerCap = 2048

    /// Raises the soft `RLIMIT_NOFILE` to `min(hard, 8192)` (PLAN.md §2.6.2).
    public static func raiseSoftLimit(to desired: rlim_t = 8192) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, desired)
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    /// Process-wide open-fd count. A `NULL` buffer makes `proc_pidinfo` return a size that is not the
    /// live list (it over-reports), so the count is the number of records the kernel actually writes.
    public static func openFileDescriptorCount() -> Int {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var infos = [proc_fdinfo](repeating: proc_fdinfo(), count: 8192)
        let got = infos.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, base, Int32(raw.count))
        }
        guard got > 0 else { return 0 }
        return Int(got) / stride
    }
}

/// Owns one file descriptor and closes it on `close()` or `deinit`, whichever comes first.
public final class FileDescriptor {
    private var raw: Int32

    public var fd: Int32 { raw }
    public var isOpen: Bool { raw >= 0 }

    public init(adopting fd: Int32) {
        raw = fd
    }

    /// `openat`. `name` is a single path component (no slashes); it is not a path the caller built for `open`.
    public static func openAt(parent: Int32, name: UnsafePointer<CChar>) throws -> FileDescriptor {
        let fd = openat(parent, name, DirectoryOpen.flags)
        guard fd >= 0 else { throw FSError.capture("openat") }
        return FileDescriptor(adopting: fd)
    }

    public static func openDirectory(atPath path: String) throws -> FileDescriptor {
        let fd = open(path, DirectoryOpen.flags)
        guard fd >= 0 else { throw FSError.capture("open", path: path) }
        return FileDescriptor(adopting: fd)
    }

    /// `fcntl(F_GETPATH)`. Only valid while the descriptor is open.
    public func path() throws -> String {
        guard raw >= 0 else { throw FSError.posix(call: "fcntl", errno: EBADF, path: nil) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let rc = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return fcntl(raw, F_GETPATH, base)
        }
        guard rc >= 0 else { throw FSError.capture("fcntl(F_GETPATH)") }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    public func close() {
        if raw >= 0 {
            Darwin.close(raw)
            raw = -1
        }
    }

    /// Transfer ownership of the descriptor without closing it. The caller must close `fd`.
    public func relinquish() -> Int32 {
        let value = raw
        raw = -1
        return value
    }

    deinit { close() }
}
