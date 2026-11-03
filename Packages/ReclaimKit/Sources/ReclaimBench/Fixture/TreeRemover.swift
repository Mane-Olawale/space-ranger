// fd-relative removal of a benchmark fixture tree (`reclaim-bench fixture --remove`). Never follows symlinks,
// never crosses devices, and refuses anything that does not look like a generated fixture root.

import Darwin
import Foundation

enum TreeRemover {
    /// Removes `path` recursively. Only roots under `/private/tmp` or `$TMPDIR` are accepted, as a guard
    /// against pointing the benchmark tool at real data.
    static func remove(at path: String) throws {
        let allowedPrefixes = ["/private/tmp/", "/tmp/", NSTemporaryDirectory()]
        guard allowedPrefixes.contains(where: { path.hasPrefix($0) }) else {
            throw FixtureGeneratorError.invalid("refusing to remove \(path): not under /private/tmp or $TMPDIR")
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { throw FixtureGeneratorError.posix(call: "lstat", path: path, errno: errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw FixtureGeneratorError.invalid("\(path) is not a directory") }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureGeneratorError.posix(call: "open", path: path, errno: errno) }
        do {
            try removeChildren(of: fd, path: path, device: st.st_dev)
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        guard rmdir(path) == 0 else { throw FixtureGeneratorError.posix(call: "rmdir", path: path, errno: errno) }
    }

    private static func removeChildren(of dirfd: Int32, path: String, device: dev_t) throws {
        let duplicate = dup(dirfd)
        guard duplicate >= 0, let dir = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw FixtureGeneratorError.posix(call: "fdopendir", path: path, errno: errno)
        }
        var names: [String] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name != ".", name != ".." { names.append(name) }
        }
        closedir(dir)

        var st = stat()
        for name in names {
            guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw FixtureGeneratorError.posix(call: "fstatat", path: path + "/" + name, errno: errno)
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                guard st.st_dev == device else { throw FixtureGeneratorError.invalid("mount point inside fixture at \(path)/\(name)") }
                let child = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw FixtureGeneratorError.posix(call: "openat", path: path + "/" + name, errno: errno) }
                do {
                    try removeChildren(of: child, path: path + "/" + name, device: device)
                } catch {
                    close(child)
                    throw error
                }
                close(child)
                guard unlinkat(dirfd, name, AT_REMOVEDIR) == 0 else {
                    throw FixtureGeneratorError.posix(call: "unlinkat(AT_REMOVEDIR)", path: path + "/" + name, errno: errno)
                }
            } else {
                guard unlinkat(dirfd, name, 0) == 0 else {
                    throw FixtureGeneratorError.posix(call: "unlinkat", path: path + "/" + name, errno: errno)
                }
            }
        }
    }
}
