// Benchmark fixture generator for `reclaim-bench fixture` (PLAN.md §6 Phase 0 "Benchmark harness").
// Same layout as ReclaimTestSupport.LargeTreeGenerator (ADR-012 explains why it is duplicated here):
//   top = ceil(sqrt(dirs)) top-level directories `d<i>`, leaf directories `s<j>` below them so the total is
//   exactly `dirs`; `files` files `f<k>` spread round-robin over every directory. Entries = dirs + files.

import Darwin
import Foundation
import os

enum FixtureGeneratorError: Error, CustomStringConvertible {
    case posix(call: String, path: String, errno: Int32)
    case invalid(String)

    var description: String {
        switch self {
        case let .posix(call, path, code):
            return "\(call)(\(path)): \(String(cString: strerror(code))) (errno \(code))"
        case let .invalid(message):
            return message
        }
    }
}

struct LargeTreeGenerator: Sendable {
    let directories: Int
    let files: Int
    let bytesPerFile: Int
    let topCount: Int

    init(directories: Int, files: Int, bytesPerFile: Int) throws {
        guard directories > 0 else { throw FixtureGeneratorError.invalid("--dirs must be ≥ 1") }
        guard files >= 0, bytesPerFile >= 0 else { throw FixtureGeneratorError.invalid("counts must be ≥ 0") }
        self.directories = directories
        self.files = files
        self.bytesPerFile = bytesPerFile
        topCount = min(directories, Int(Double(directories).squareRoot().rounded(.up)))
    }

    func leaves(under i: Int) -> Int {
        let remaining = directories - topCount
        return remaining / topCount + (i < remaining % topCount ? 1 : 0)
    }

    func files(inDirectory d: Int) -> Int {
        files / directories + (d < files % directories ? 1 : 0)
    }

    func firstLeafIndex(under i: Int) -> Int {
        var index = topCount
        for j in 0..<i { index += leaves(under: j) }
        return index
    }

    /// Creates the tree inside `rootPath` (which must exist and be an empty directory).
    func generate(at rootPath: String, workers: Int) throws {
        let rootFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw FixtureGeneratorError.posix(call: "open", path: rootPath, errno: errno) }
        defer { close(rootFD) }

        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        let parallelism = max(1, min(workers, topCount))
        DispatchQueue.concurrentPerform(iterations: parallelism) { worker in
            var i = worker
            while i < topCount {
                if failure.withLock({ $0 != nil }) { return }
                do {
                    try generateTop(i, rootFD: rootFD, rootPath: rootPath)
                } catch {
                    failure.withLock { if $0 == nil { $0 = "\(error)" } }
                    return
                }
                i += parallelism
            }
        }
        if let message = failure.withLock({ $0 }) { throw FixtureGeneratorError.invalid(message) }
    }

    private func generateTop(_ i: Int, rootFD: Int32, rootPath: String) throws {
        let topName = "d\(i)"
        let topPath = rootPath + "/" + topName
        guard mkdirat(rootFD, topName, 0o755) == 0 else { throw FixtureGeneratorError.posix(call: "mkdirat", path: topPath, errno: errno) }
        let topFD = openat(rootFD, topName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard topFD >= 0 else { throw FixtureGeneratorError.posix(call: "openat", path: topPath, errno: errno) }
        defer { close(topFD) }
        try fill(directory: topFD, path: topPath, count: files(inDirectory: i))

        var leafIndex = firstLeafIndex(under: i)
        for j in 0..<leaves(under: i) {
            let leafName = "s\(j)"
            let leafPath = topPath + "/" + leafName
            guard mkdirat(topFD, leafName, 0o755) == 0 else { throw FixtureGeneratorError.posix(call: "mkdirat", path: leafPath, errno: errno) }
            let leafFD = openat(topFD, leafName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard leafFD >= 0 else { throw FixtureGeneratorError.posix(call: "openat", path: leafPath, errno: errno) }
            do {
                try fill(directory: leafFD, path: leafPath, count: files(inDirectory: leafIndex))
            } catch {
                close(leafFD)
                throw error
            }
            close(leafFD)
            leafIndex += 1
        }
    }

    private static let pattern: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        var state: UInt32 = 0x9E37_79B9
        for i in bytes.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[i] = UInt8(truncatingIfNeeded: state >> 24) | 0x01
        }
        return bytes
    }()

    private func fill(directory fd: Int32, path: String, count: Int) throws {
        for k in 0..<count {
            let name = "f\(k)"
            let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard file >= 0 else { throw FixtureGeneratorError.posix(call: "openat(O_CREAT)", path: path + "/" + name, errno: errno) }
            defer { close(file) }
            var remaining = bytesPerFile
            var offset: off_t = 0
            while remaining > 0 {
                let chunk = min(remaining, Self.pattern.count)
                let written = Self.pattern.withUnsafeBytes { pwrite(file, $0.baseAddress, chunk, offset) }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FixtureGeneratorError.posix(call: "pwrite", path: path + "/" + name, errno: errno)
                }
                remaining -= written
                offset += off_t(written)
            }
        }
    }
}
