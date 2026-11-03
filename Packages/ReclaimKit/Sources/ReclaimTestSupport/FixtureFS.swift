// FixtureFS — thin POSIX helpers used by FixtureBuilder. Everything is fd-relative (`*at` calls) and
// never follows symlinks; no shell is involved anywhere (REQ-ENUM-1).

import Darwin
import Foundation

/// Errors thrown while materialising or removing fixtures.
public enum FixtureError: Error, CustomStringConvertible, Sendable {
    case posix(call: String, path: String, errno: Int32)
    case invalidSpec(String)
    case toolFailed(tool: String, arguments: [String], exitCode: Int32, stderr: String)
    case notAPFS(path: String, fsType: String)

    public var description: String {
        switch self {
        case let .posix(call, path, code):
            return "\(call)(\(path)) failed: \(String(cString: strerror(code))) (errno \(code))"
        case let .invalidSpec(message):
            return "invalid fixture spec: \(message)"
        case let .toolFailed(tool, arguments, exitCode, stderr):
            return "\(tool) \(arguments.joined(separator: " ")) exited \(exitCode): \(stderr)"
        case let .notAPFS(path, fsType):
            return "\(path) is on \(fsType), fixtures require APFS"
        }
    }
}

/// Low-level filesystem operations. Internal to the module; `FixtureBuilder` is the public API.
enum FixtureFS {
    /// Allocation block size reported by the volume hosting `path` (4096 on APFS).
    static func blockSize(at path: String) throws -> Int {
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else { throw FixtureError.posix(call: "statfs", path: path, errno: errno) }
        return Int(sfs.f_bsize)
    }

    static func fsType(at path: String) throws -> String {
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else { throw FixtureError.posix(call: "statfs", path: path, errno: errno) }
        return withUnsafePointer(to: &sfs.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
    }

    /// VM page size: APFS allocates sparse-file head data in page-sized units (16 KiB on Apple silicon).
    static var pageSize: Int { Int(sysconf(_SC_PAGESIZE)) }

    /// `mkdtemp` with `prefix` under `base` (default `/private/tmp`). Returns the created path.
    static func makeTempDir(prefix: String, under base: URL?) throws -> String {
        let baseDir = base?.path ?? "/private/tmp"
        var template = Array("\(baseDir)/\(prefix)-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            throw FixtureError.posix(call: "mkdtemp", path: "\(baseDir)/\(prefix)-XXXXXX", errno: errno)
        }
        return string(fromCString: template)
    }

    /// Decodes a NUL-terminated `[CChar]` buffer.
    static func string(fromCString buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureError.posix(call: "open", path: path, errno: errno) }
        return fd
    }

    static func openDirectory(parent: Int32, name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("openat", parent: parent, name: name) }
        return fd
    }

    static func makeDirectory(parent: Int32, name: String) throws {
        guard mkdirat(parent, name, 0o755) == 0 else {
            throw posixError("mkdirat", parent: parent, name: name)
        }
    }

    static func createFile(parent: Int32, name: String) throws -> Int32 {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError("openat(O_CREAT)", parent: parent, name: name) }
        return fd
    }

    /// Deterministic, non-zero payload so no layer can elide the data as zero blocks.
    static let pattern: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        var state: UInt32 = 0x9E37_79B9
        for i in bytes.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[i] = UInt8(truncatingIfNeeded: state >> 24) | 0x01
        }
        return bytes
    }()

    /// Writes exactly `count` pattern bytes at `offset`, handling short writes and `EINTR`.
    static func writePattern(fd: Int32, count: Int, offset: off_t = 0, path: String) throws {
        var remaining = count
        var position = offset
        while remaining > 0 {
            let chunk = min(remaining, pattern.count)
            let written = pattern.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk, position) }
            if written < 0 {
                if errno == EINTR { continue }
                throw FixtureError.posix(call: "pwrite", path: path, errno: errno)
            }
            remaining -= written
            position += off_t(written)
        }
    }

    private static let zeros = [UInt8](repeating: 0, count: 1 << 20)

    /// Writes exactly `count` zero bytes at `offset`.
    static func writeZeros(fd: Int32, count: Int, offset: off_t, path: String) throws {
        var remaining = count
        var position = offset
        while remaining > 0 {
            let chunk = min(remaining, zeros.count)
            let written = zeros.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk, position) }
            if written < 0 {
                if errno == EINTR { continue }
                throw FixtureError.posix(call: "pwrite", path: path, errno: errno)
            }
            remaining -= written
            position += off_t(written)
        }
    }

    static func truncate(fd: Int32, to length: Int, path: String) throws {
        guard ftruncate(fd, off_t(length)) == 0 else { throw FixtureError.posix(call: "ftruncate", path: path, errno: errno) }
    }

    static func setModificationTime(fd: Int32, daysAgo: Int, path: String) throws {
        guard daysAgo != 0 else { return }
        let seconds = time_t(Date().timeIntervalSince1970) - time_t(daysAgo) * 86400
        var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
        guard futimens(fd, &times) == 0 else { throw FixtureError.posix(call: "futimens", path: path, errno: errno) }
    }

    static func setMode(fd: Int32, mode: mode_t, path: String) throws {
        guard fchmod(fd, mode) == 0 else { throw FixtureError.posix(call: "fchmod", path: path, errno: errno) }
    }

    static func setMode(parent: Int32, name: String, mode: mode_t) throws {
        guard fchmodat(parent, name, mode, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixError("fchmodat", parent: parent, name: name)
        }
    }

    /// `lchflags` (there is no `*at` variant); `path` must be the full path of the entry.
    static func setFlags(path: String, flags: UInt32) throws {
        guard lchflags(path, flags) == 0 else { throw FixtureError.posix(call: "lchflags", path: path, errno: errno) }
    }

    static func clone(source: String, parent: Int32, name: String) throws {
        guard clonefileat(AT_FDCWD, source, parent, name, 0) == 0 else {
            throw posixError("clonefileat", parent: parent, name: name)
        }
    }

    static func hardlink(source: String, parent: Int32, name: String) throws {
        guard linkat(AT_FDCWD, source, parent, name, 0) == 0 else {
            throw posixError("linkat", parent: parent, name: name)
        }
    }

    static func symlink(target: String, parent: Int32, name: String) throws {
        guard symlinkat(target, parent, name) == 0 else {
            throw posixError("symlinkat", parent: parent, name: name)
        }
    }

    /// Creates a Unix domain socket at `path` via `bind(2)`. `sun_path` is limited to 103 bytes.
    static func bindSocket(at path: String) throws {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            throw FixtureError.invalidSpec("socket path exceeds \(capacity - 1) bytes: \(path)")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.posix(call: "socket", path: path, errno: errno) }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw FixtureError.posix(call: "bind", path: path, errno: errno) }
    }

    static func stat(parent: Int32, name: String) throws -> Darwin.stat {
        var st = Darwin.stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixError("fstatat", parent: parent, name: name)
        }
        return st
    }

    static func stat(path: String) throws -> Darwin.stat {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { throw FixtureError.posix(call: "lstat", path: path, errno: errno) }
        return st
    }

    /// Full path of an open directory descriptor (`fcntl(F_GETPATH)`).
    static func path(ofDirectory fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw FixtureError.posix(call: "fcntl(F_GETPATH)", path: "fd \(fd)", errno: errno) }
        return string(fromCString: buffer)
    }

    /// Builds a `.posix` error for `name` under `parent`, capturing `errno` *before* resolving the directory
    /// path (`fcntl(F_GETPATH)` could otherwise clobber it).
    private static func posixError(_ call: String, parent: Int32, name: String) -> FixtureError {
        let code = errno
        let directory = (try? path(ofDirectory: parent)) ?? "<fd \(parent)>"
        return .posix(call: call, path: directory + "/" + name, errno: code)
    }

    // MARK: - Removal

    /// Removes a whole tree. Clears `UF_IMMUTABLE`/`UF_APPEND`/`UF_NOUNLINK` flags and restores `u+rwx` on
    /// directories first, never follows symlinks, and never crosses into another device.
    static func removeTree(at path: String) throws {
        let st = try stat(path: path)
        try clearFlags(path: path, flags: st.st_flags)
        if (st.st_mode & S_IFMT) == S_IFDIR {
            if (st.st_mode & 0o700) != 0o700 {
                guard chmod(path, 0o700) == 0 else { throw FixtureError.posix(call: "chmod", path: path, errno: errno) }
            }
            let fd = try openDirectory(path)
            defer { close(fd) }
            try removeChildren(of: fd, directoryPath: path, device: st.st_dev)
            guard rmdir(path) == 0 else { throw FixtureError.posix(call: "rmdir", path: path, errno: errno) }
        } else {
            guard unlink(path) == 0 else { throw FixtureError.posix(call: "unlink", path: path, errno: errno) }
        }
    }

    /// User flags that block `unlink`/`rmdir`; `SF_*` flags need root and are left alone.
    private static let clearableFlags = UInt32(UF_IMMUTABLE | UF_APPEND)

    private static func clearFlags(path: String, flags: UInt32) throws {
        guard flags & clearableFlags != 0 else { return }
        try setFlags(path: path, flags: flags & ~clearableFlags)
    }

    private static func removeChildren(of dirfd: Int32, directoryPath: String, device: dev_t) throws {
        let names = try listNames(of: dirfd, path: directoryPath)
        for name in names {
            let childPath = directoryPath + "/" + name
            let st = try stat(parent: dirfd, name: name)
            try clearFlags(path: childPath, flags: st.st_flags)
            if (st.st_mode & S_IFMT) == S_IFDIR {
                guard st.st_dev == device else {
                    throw FixtureError.invalidSpec("refusing to remove across a mount point at \(childPath)")
                }
                if (st.st_mode & 0o700) != 0o700 {
                    try setMode(parent: dirfd, name: name, mode: 0o700)
                }
                let child = try openDirectory(parent: dirfd, name: name)
                do {
                    try removeChildren(of: child, directoryPath: childPath, device: device)
                } catch {
                    close(child)
                    throw error
                }
                close(child)
                guard unlinkat(dirfd, name, AT_REMOVEDIR) == 0 else {
                    throw FixtureError.posix(call: "unlinkat(AT_REMOVEDIR)", path: childPath, errno: errno)
                }
            } else {
                guard unlinkat(dirfd, name, 0) == 0 else {
                    throw FixtureError.posix(call: "unlinkat", path: childPath, errno: errno)
                }
            }
        }
    }

    /// Names of the entries in an open directory (excluding `.`/`..`), byte-exact.
    static func listNames(of dirfd: Int32, path: String) throws -> [String] {
        let duplicate = dup(dirfd)
        guard duplicate >= 0 else { throw FixtureError.posix(call: "dup", path: path, errno: errno) }
        guard let dir = fdopendir(duplicate) else {
            close(duplicate)
            throw FixtureError.posix(call: "fdopendir", path: path, errno: errno)
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }
}
