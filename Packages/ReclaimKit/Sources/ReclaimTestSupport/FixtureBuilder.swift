// FixtureBuilder — materialises FixtureSpec trees on real APFS (PLAN.md §6 Phase 0 "Core types introduced").
// Signatures are literal from PLAN.md; see docs/ADR/ADR-013-home-layout.md for `HomeLayout`.

import Darwin
import Foundation

/// Sizes a fixture is expected to report, computed arithmetically while the tree is created (and measured
/// with `DiskUsage` for tool-generated subtrees such as `.git`). All three byte counts are per-inode: a hard
/// link adds a directory entry but no bytes; a clone adds its full `allocated` (like `du`) but moves the
/// clone family's `privateBytes` to zero (APFS attributes shared blocks to *neither* side — measured in Phase 0,
/// to be settled for rollups in ADR-011).
public struct ExpectedSizes: Sendable, Equatable {
    /// Σ `st_size` of files and symlinks (directories contribute nothing).
    public let logical: UInt64
    /// Σ `st_blocks * 512`, each inode once — the `du` number.
    public let allocated: UInt64
    /// Σ `ATTR_CMNEXT_PRIVATESIZE`, each inode once.
    public let privateBytes: UInt64
    /// Number of directory entries below the fixture root (the root itself is excluded).
    public let entryCount: Int

    public init(logical: UInt64, allocated: UInt64, privateBytes: UInt64, entryCount: Int) {
        self.logical = logical
        self.allocated = allocated
        self.privateBytes = privateBytes
        self.entryCount = entryCount
    }

    public static let zero = ExpectedSizes(logical: 0, allocated: 0, privateBytes: 0, entryCount: 0)

    public static func roundUp(_ bytes: Int, to unit: Int) -> Int {
        guard unit > 0, bytes > 0 else { return 0 }
        return (bytes + unit - 1) / unit * unit
    }

    /// Allocation of a fully written file: `logical` rounded up to the block size.
    public static func fullAllocation(logical: Int, blockSize: Int) -> Int {
        roundUp(logical, to: blockSize)
    }

    /// APFS keeps a hole only when it is at least this large; smaller holes are zero-filled (allocated) as
    /// soon as any data is written to the file. Measured on macOS 26 / Apple silicon in Phase 0.
    public static let minimumHoleBytes = 16 << 20

    /// Allocation of a file `ftruncate`d to `logical` with `written` bytes at its head, as observed on
    /// APFS (macOS 26, Apple silicon):
    /// 1. nothing is allocated until data is written (`written == 0` → 0);
    /// 2. the written head is allocated in VM-page units (16 KiB), never beyond the block-rounded size;
    /// 3. if the remaining hole is smaller than `minimumHoleBytes` the whole file is allocated.
    /// Consequently "sparse" accounting only matters for files with ≥ 16 MiB holes (`Docker.raw`-class files).
    public static func sparseAllocation(logical: Int, written: Int, blockSize: Int, pageSize: Int) -> Int {
        precondition(written <= logical, "written bytes exceed logical size")
        guard logical > 0, written > 0 else { return 0 }
        let full = fullAllocation(logical: logical, blockSize: blockSize)
        if written == logical { return full }
        let head = min(roundUp(written, to: pageSize), full)
        return full - head < minimumHoleBytes ? full : head
    }
}

/// A materialised fixture. `cleanup()` clears `uchg`-style flags first, restores directory permissions,
/// and removes the tree with fd-relative `unlinkat` — never via a shell.
public struct Fixture: Sendable {
    public let root: URL
    public let expected: ExpectedSizes

    public init(root: URL, expected: ExpectedSizes) {
        self.root = root
        self.expected = expected
    }

    /// `root` as a POSIX path.
    public var path: String { root.path(percentEncoded: false) }

    public func cleanup() {
        do {
            try FixtureBuilder.remove(at: root)
        } catch {
            FileHandle.standardError.write(Data("Fixture.cleanup failed for \(path): \(error)\n".utf8))
        }
    }
}

public struct FixtureBuilder {
    /// Default prefix of fixture temp directories under `/private/tmp`.
    public static let tempPrefix = "rcl-fixture"

    /// Creates `spec` inside a fresh `mkdtemp` directory (under `/private/tmp` unless `base` is given).
    public static func make(_ spec: FixtureSpec, at base: URL? = nil) throws -> Fixture {
        let rootPath = try FixtureFS.makeTempDir(prefix: tempPrefix, under: base)
        do {
            let materializer = try Materializer(rootPath: rootPath)
            try materializer.build(spec.root)
            return Fixture(root: URL(fileURLWithPath: rootPath, isDirectory: true), expected: materializer.expected)
        } catch {
            try? FixtureFS.removeTree(at: rootPath)
            throw error
        }
    }

    /// Builds a fake home directory: the fixture root is the home, `layout.library` lives in `<root>/Library`.
    public static func home(_ layout: HomeLayout) throws -> Fixture {
        let rootPath = try FixtureFS.makeTempDir(prefix: "rcl-home", under: nil)
        do {
            let materializer = try Materializer(rootPath: rootPath)
            try materializer.build(layout.home)
            try materializer.build([.dir(name: "Library", children: layout.library)])
            return Fixture(root: URL(fileURLWithPath: rootPath, isDirectory: true), expected: materializer.expected)
        } catch {
            try? FixtureFS.removeTree(at: rootPath)
            throw error
        }
    }

    /// Benchmark fixture: `dirs` directories (a two-level tree) with `filesPerDir` files each, every file
    /// holding `bytesPerFile` pattern bytes. Generated in parallel across top-level directories.
    public static func largeTree(dirs: Int, filesPerDir: Int, bytesPerFile: Int) throws -> Fixture {
        let rootPath = try FixtureFS.makeTempDir(prefix: "rcl-large", under: nil)
        do {
            let expected = try LargeTreeGenerator.generate(
                at: rootPath,
                directories: dirs,
                files: dirs * filesPerDir,
                bytesPerFile: bytesPerFile,
                workers: ProcessInfo.processInfo.activeProcessorCount
            )
            return Fixture(root: URL(fileURLWithPath: rootPath, isDirectory: true), expected: expected)
        } catch {
            try? FixtureFS.removeTree(at: rootPath)
            throw error
        }
    }

    /// Removes a fixture tree (flags cleared, permissions restored). Throws on the first failure.
    public static func remove(at root: URL) throws {
        try FixtureFS.removeTree(at: root.path(percentEncoded: false))
    }

    /// Allocation block size of the volume hosting `/private/tmp` (4096 on APFS).
    public static func blockSize() throws -> Int {
        try FixtureFS.blockSize(at: "/private/tmp")
    }

    /// VM page size used by APFS for sparse-head allocation (16 KiB on Apple silicon).
    public static var pageSize: Int { FixtureFS.pageSize }
}

// MARK: - Materializer

/// Walks a node list and performs the POSIX calls, accumulating `ExpectedSizes`. Single-threaded, used once.
final class Materializer {
    private struct FileState {
        var logical: Int
        var allocated: Int
        /// Bytes of this inode currently counted in `privateBytes` (zeroed for the whole clone family).
        var privateCounted: Int
    }

    private let rootPath: String
    private let blockSize: Int
    private let pageSize: Int
    private var logical = 0
    private var allocated = 0
    private var privateBytes = 0
    private var entryCount = 0
    private var states: [FileState] = []
    private var stateIndex: [String: Int] = [:]

    init(rootPath: String) throws {
        let fsType = try FixtureFS.fsType(at: rootPath)
        guard fsType == "apfs" else { throw FixtureError.notAPFS(path: rootPath, fsType: fsType) }
        self.rootPath = rootPath
        blockSize = try FixtureFS.blockSize(at: rootPath)
        pageSize = FixtureFS.pageSize
    }

    var expected: ExpectedSizes {
        ExpectedSizes(
            logical: UInt64(logical),
            allocated: UInt64(allocated),
            privateBytes: UInt64(privateBytes),
            entryCount: entryCount
        )
    }

    func build(_ nodes: [FixtureSpec.Node]) throws {
        let fd = try FixtureFS.openDirectory(rootPath)
        defer { close(fd) }
        for node in nodes {
            try build(node, in: fd, parentPath: rootPath)
        }
    }

    private func build(_ node: FixtureSpec.Node, in parentFD: Int32, parentPath: String) throws {
        switch node {
        case let .file(name, logicalBytes, allocatedBytes, mtimeDaysAgo, mode, flags):
            try validate(name: name)
            let written = allocatedBytes.map { min($0, logicalBytes) } ?? logicalBytes
            try createFile(name: name, in: parentFD, parentPath: parentPath, logical: logicalBytes,
                           written: written, mtimeDaysAgo: mtimeDaysAgo, mode: mode, flags: flags)

        case let .sparse(name, logicalBytes, writtenBytes):
            try validate(name: name)
            guard writtenBytes <= logicalBytes else {
                throw FixtureError.invalidSpec("sparse \(name): writtenBytes (\(writtenBytes)) > logicalBytes (\(logicalBytes))")
            }
            try createFile(name: name, in: parentFD, parentPath: parentPath, logical: logicalBytes,
                           written: writtenBytes, mtimeDaysAgo: 0, mode: 0o644, flags: 0)

        case let .clone(name, of):
            try validate(name: name)
            let source = resolve(of, relativeTo: parentPath)
            guard let index = stateIndex[source] else {
                throw FixtureError.invalidSpec("clone \(name): source \(of) is not a file created by this fixture")
            }
            try FixtureFS.clone(source: source, parent: parentFD, name: name)
            let state = states[index]
            // `du` counts the clone in full; the kernel reports zero private bytes for every member of an
            // identical clone family, so the source's private contribution is withdrawn.
            logical += state.logical
            allocated += state.allocated
            privateBytes -= state.privateCounted
            states[index].privateCounted = 0
            states.append(FileState(logical: state.logical, allocated: state.allocated, privateCounted: 0))
            stateIndex[parentPath + "/" + name] = states.count - 1
            entryCount += 1

        case let .hardlink(name, of):
            try validate(name: name)
            let source = resolve(of, relativeTo: parentPath)
            guard let index = stateIndex[source] else {
                throw FixtureError.invalidSpec("hardlink \(name): source \(of) is not a file created by this fixture")
            }
            try FixtureFS.hardlink(source: source, parent: parentFD, name: name)
            stateIndex[parentPath + "/" + name] = index          // same inode, no new bytes
            entryCount += 1

        case let .symlink(name, to):
            try validate(name: name)
            try FixtureFS.symlink(target: to, parent: parentFD, name: name)
            logical += to.utf8.count                               // st_size of a symlink; APFS allocates 0 blocks
            entryCount += 1

        case let .dir(name, mode, children):
            try validate(name: name)
            try FixtureFS.makeDirectory(parent: parentFD, name: name)
            entryCount += 1
            let fd = try FixtureFS.openDirectory(parent: parentFD, name: name)
            do {
                for child in children {
                    try build(child, in: fd, parentPath: parentPath + "/" + name)
                }
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            if mode != 0o755 {
                try FixtureFS.setMode(parent: parentFD, name: name, mode: mode)
            }

        case let .socket(name):
            try validate(name: name)
            try FixtureFS.bindSocket(at: parentPath + "/" + name)
            entryCount += 1

        case let .gitRepo(name, dirty, children):
            try validate(name: name)
            let repoPath = parentPath + "/" + name
            try build(.dir(name: name, children: children), in: parentFD, parentPath: parentPath)
            try GitRunner.run(["init", "-q", "-b", "main"], in: repoPath)
            try GitRunner.run(["add", "-A"], in: repoPath)
            try GitRunner.run(["commit", "-q", "--allow-empty", "-m", "fixture"], in: repoPath)
            if dirty {
                let fd = try FixtureFS.openDirectory(repoPath)
                defer { close(fd) }
                try build(.file(name: "UNCOMMITTED.txt", logicalBytes: 64), in: fd, parentPath: repoPath)
            }
            let git = try DiskUsage.measure(at: repoPath + "/.git")
            logical += Int(git.logical)
            allocated += Int(git.allocated)
            privateBytes += Int(git.privateBytes)
            entryCount += git.entryCount + 1                     // + the `.git` directory itself

        case let .nodeModules(name, packages, bytesEach):
            try validate(name: name)
            var children: [FixtureSpec.Node] = []
            children.reserveCapacity(packages)
            for i in 0..<packages {
                let manifest = Materializer.packageManifest(index: i)
                let scriptBytes = max(0, bytesEach - manifest.utf8.count)
                children.append(.dir(name: "pkg-\(i)", children: [
                    .file(name: "package.json", logicalBytes: manifest.utf8.count),
                    .file(name: "index.js", logicalBytes: scriptBytes),
                ]))
            }
            try build(.dir(name: name, children: children), in: parentFD, parentPath: parentPath)
        }
    }

    static func packageManifest(index: Int) -> String {
        "{\"name\":\"pkg-\(index)\",\"version\":\"1.0.0\",\"main\":\"index.js\"}\n"
    }

    private func createFile(name: String, in parentFD: Int32, parentPath: String, logical: Int, written: Int,
                            mtimeDaysAgo: Int, mode: mode_t, flags: UInt32) throws {
        let path = parentPath + "/" + name
        let alloc = written < logical
            ? ExpectedSizes.sparseAllocation(logical: logical, written: written, blockSize: blockSize, pageSize: pageSize)
            : ExpectedSizes.fullAllocation(logical: logical, blockSize: blockSize)
        let fd = try FixtureFS.createFile(parent: parentFD, name: name)
        do {
            if written < logical, written > 0, alloc == ExpectedSizes.fullAllocation(logical: logical, blockSize: blockSize) {
                // The hole is < 16 MiB, so APFS would zero-fill it asynchronously (PRIVATESIZE then drifts
                // towards ALLOCSIZE for a while). Writing the zeros ourselves yields the same end state now.
                try FixtureFS.writePattern(fd: fd, count: written, path: path)
                try FixtureFS.writeZeros(fd: fd, count: logical - written, offset: off_t(written), path: path)
            } else if written < logical {
                try FixtureFS.truncate(fd: fd, to: logical, path: path)
                if written > 0 { try FixtureFS.writePattern(fd: fd, count: written, path: path) }
            } else if logical > 0 {
                try FixtureFS.writePattern(fd: fd, count: logical, path: path)
            }
            // Allocation and ATTR_CMNEXT_PRIVATESIZE are only authoritative once the data is flushed: until
            // then APFS reports the reserved ALLOCSIZE but a PRIVATESIZE of 0 (measured in Phase 0).
            if written > 0 { _ = fsync(fd) }
            try FixtureFS.setModificationTime(fd: fd, daysAgo: mtimeDaysAgo, path: path)
            if mode != 0o644 { try FixtureFS.setMode(fd: fd, mode: mode, path: path) }
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        if flags != 0 { try FixtureFS.setFlags(path: path, flags: flags) }

        self.logical += logical
        allocated += alloc
        privateBytes += alloc
        entryCount += 1
        states.append(FileState(logical: logical, allocated: alloc, privateCounted: alloc))
        stateIndex[path] = states.count - 1
    }

    private func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw FixtureError.invalidSpec("invalid node name \(name.debugDescription)")
        }
    }

    /// Resolves `reference` against `base` without touching the filesystem (so `/private` is preserved).
    private func resolve(_ reference: String, relativeTo base: String) -> String {
        let combined = reference.hasPrefix("/") ? reference : base + "/" + reference
        var components: [Substring] = []
        for part in combined.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(part)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}

// MARK: - Git

/// Runs `/usr/bin/git` with a hermetic environment (no user/system config, no gpg, no auto-gc).
enum GitRunner {
    static let executable = "/usr/bin/git"

    static func run(_ arguments: [String], in repoPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-C", repoPath,
            "-c", "user.name=Reclaim Fixture",
            "-c", "user.email=fixture@reclaim.invalid",
            "-c", "commit.gpgsign=false",
            "-c", "gc.auto=0",
            "-c", "core.fsmonitor=false",
            "-c", "maintenance.auto=false",
        ] + arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": repoPath,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        ]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.toolFailed(
                tool: executable,
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
