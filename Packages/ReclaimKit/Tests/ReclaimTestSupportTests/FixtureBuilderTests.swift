// Phase 0 fixture tests: T0-FIXTURE-SIZES and T0-FIXTURE-CLEANUP (PLAN.md §6 Phase 0 exit criteria).

import Darwin
import Foundation
import Testing
@testable import ReclaimTestSupport

@Suite("FixtureBuilder", .tags(.requiresAPFS))
struct FixtureBuilderTests {
    private static let block = Int64(4096)

    /// A representative mixed tree: full/odd/empty files, old mtime, read-only, `uchg`, partially written
    /// file, sparse files, WhatsApp-style names with `@` and spaces, an NFD name, a clone, a hard link, symlink
    /// loops, a socket and a `node_modules` tree.
    private static let mixedSpec = FixtureSpec(root: [
        .file(name: "small.bin", logicalBytes: 1),
        .file(name: "odd.bin", logicalBytes: 4097),
        .file(name: "empty.bin", logicalBytes: 0),
        .file(name: "old.bin", logicalBytes: 10_000, mtimeDaysAgo: 120),
        .file(name: "readonly.bin", logicalBytes: 100, mode: 0o444),
        .file(name: "locked.bin", logicalBytes: 100, flags: UInt32(UF_IMMUTABLE)),
        .file(name: "partial.bin", logicalBytes: 1 << 20, allocatedBytes: 64 << 10),
        .sparse(name: "sparse.img", logicalBytes: 100 << 20, writtenBytes: 1 << 20),
        .sparse(name: "sparse-small.img", logicalBytes: 64 << 20, writtenBytes: 4096),
        .sparse(name: "sparse-empty.img", logicalBytes: 16 << 20, writtenBytes: 0),
        .dir(name: "Message", children: [
            .dir(name: "Media", children: [
                .dir(name: "120363076093068126@g.us", children: [
                    .file(name: "IMG 0001.jpg", logicalBytes: 300_000),
                    .file(name: "VID 0002.mp4", logicalBytes: 1_234_567, mtimeDaysAgo: 400),
                ]),
                .dir(name: "245861544149209@lid.status", children: [
                    .file(name: "status.mp4", logicalBytes: 123_456),
                ]),
                .dir(name: "cafe\u{301}", children: []),   // NFD "café"
            ]),
        ]),
        .clone(name: "clone.bin", of: "odd.bin"),
        .hardlink(name: "link.bin", of: "old.bin"),
        .symlink(name: "loop-a", to: "loop-b"),
        .symlink(name: "loop-b", to: "loop-a"),
        .symlink(name: "up", to: ".."),
        .socket(name: "docker.sock"),
        .nodeModules(packages: 5, bytesEach: 10_000),
    ])

    @Test("T0-FIXTURE-SIZES: du-equivalent (fts + st_blocks) equals ExpectedSizes within one block")
    func sizesMatchDuEquivalent() throws {
        let fixture = try FixtureBuilder.make(Self.mixedSpec)
        defer { fixture.cleanup() }

        let usage = try DiskUsage.measure(at: fixture.path)
        let expected = fixture.expected

        #expect(usage.errors == 0)
        #expect(usage.entryCount == expected.entryCount)
        #expect(usage.logical == expected.logical)
        #expect(abs(Int64(usage.allocated) - Int64(expected.allocated)) <= Self.block,
                "allocated: measured \(usage.allocated) vs expected \(expected.allocated)")
        #expect(abs(Int64(usage.privateBytes) - Int64(expected.privateBytes)) <= Self.block,
                "private: measured \(usage.privateBytes) vs expected \(expected.privateBytes)")

        // Structural counts: Message, Media, 3 JID dirs, node_modules + 5 packages = 11 directories.
        #expect(usage.directories == 11)
        #expect(usage.symlinks == 3)
        #expect(usage.others == 1)                       // the socket
        #expect(usage.files == 12 + 3 + 10)              // root files (incl. clone + hard link) + media + package files
    }

    @Test("T0-FIXTURE-SIZES: sparse fixture allocates ≤ written + one VM page and is flagged EF_IS_SPARSE")
    func sparseAllocation() throws {
        let written = 8 << 20
        let logical = 256 << 20
        let fixture = try FixtureBuilder.make(FixtureSpec(.sparse(name: "Docker.raw", logicalBytes: logical, writtenBytes: written)))
        defer { fixture.cleanup() }

        let attrs = try FileAttributes.read(atPath: fixture.path + "/Docker.raw")
        let st = try FixtureFS.stat(path: fixture.path + "/Docker.raw")
        #expect(attrs.totalSize == UInt64(logical))
        #expect(Int64(st.st_size) == Int64(logical))
        #expect(attrs.allocatedSize >= UInt64(written))
        #expect(attrs.allocatedSize <= UInt64(written + FixtureBuilder.pageSize))
        #expect(attrs.allocatedSize == UInt64(st.st_blocks) * 512)
        #expect(attrs.isSparse)
        #expect(fixture.expected.allocated == attrs.allocatedSize)
        #expect(fixture.expected.logical == UInt64(logical))
    }

    private struct SparseCase {
        let name: String
        let logical: Int
        let written: Int
        let expectSparse: Bool
    }

    @Test("T0-FIXTURE-SIZES: sparse heads follow the APFS page/16 MiB-hole allocation model")
    func sparseHeadModel() throws {
        let page = FixtureBuilder.pageSize
        let block = try FixtureBuilder.blockSize()
        let cases = [
            SparseCase(name: "one-byte", logical: 64 << 20, written: 1, expectSparse: true),
            SparseCase(name: "three-blocks", logical: 64 << 20, written: 3 * block, expectSparse: true),
            SparseCase(name: "page-plus-one", logical: 64 << 20, written: page + 1, expectSparse: true),
            SparseCase(name: "hole-exactly-16MiB", logical: 32 << 20, written: 16 << 20, expectSparse: true),
            SparseCase(name: "hole-just-under-16MiB", logical: 32 << 20, written: (16 << 20) + block, expectSparse: false),
            SparseCase(name: "tiny-logical", logical: 5000, written: block, expectSparse: false),
            SparseCase(name: "small-partial", logical: 1 << 20, written: 10 * block, expectSparse: false),
            SparseCase(name: "unaligned-tail", logical: (40 << 20) + 4096, written: 4096, expectSparse: true),
        ]
        let spec = FixtureSpec(root: cases.map { .sparse(name: $0.name, logicalBytes: $0.logical, writtenBytes: $0.written) })
        let fixture = try FixtureBuilder.make(spec)
        defer { fixture.cleanup() }

        for testCase in cases {
            let st = try FixtureFS.stat(path: fixture.path + "/" + testCase.name)
            let measured = Int64(st.st_blocks) * 512
            let predicted = ExpectedSizes.sparseAllocation(logical: testCase.logical, written: testCase.written,
                                                           blockSize: block, pageSize: page)
            #expect(measured == Int64(predicted), "\(testCase.name): st_blocks*512 \(measured) vs predicted \(predicted)")
            let full = ExpectedSizes.fullAllocation(logical: testCase.logical, blockSize: block)
            #expect((measured < Int64(full)) == testCase.expectSparse, "\(testCase.name): sparse=\(measured < Int64(full)) expected \(testCase.expectSparse)")
            if testCase.expectSparse {
                #expect(measured <= Int64(testCase.written + page), "\(testCase.name): allocated ≤ written + one page")
            }
        }
        let usage = try DiskUsage.measure(at: fixture.path)
        #expect(usage.allocated == fixture.expected.allocated)
    }

    @Test("T0-FIXTURE-SIZES: clone fixture — second file has privateBytes == 0 (ATTR_CMNEXT_PRIVATESIZE)")
    func cloneAccounting() throws {
        let size = 10 << 20
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .file(name: "original.bin", logicalBytes: size),
            .clone(name: "copy.bin", of: "original.bin"),
        ]))
        defer { fixture.cleanup() }

        let original = try FileAttributes.read(atPath: fixture.path + "/original.bin")
        let copy = try FileAttributes.read(atPath: fixture.path + "/copy.bin")

        #expect(copy.privateSize == 0)                               // PLAN.md T0-FIXTURE-SIZES
        #expect(copy.allocatedSize == UInt64(size))
        #expect(original.allocatedSize == UInt64(size))
        #expect(copy.sharesAllBlocks && copy.mayShareBlocks)
        #expect(original.cloneID == copy.cloneID)
        // Phase 0 measurement feeding ADR-011: APFS attributes fully shared blocks to neither side.
        #expect(original.privateSize == 0)
        #expect(original.privateSize + copy.privateSize <= UInt64(size))

        let usage = try DiskUsage.measure(at: fixture.path)
        #expect(usage.allocated == UInt64(2 * size))                 // du counts both clones
        #expect(usage.privateBytes == fixture.expected.privateBytes)
        #expect(fixture.expected.privateBytes == original.privateSize + copy.privateSize)
    }

    @Test("hard link: one inode counted once, two directory entries")
    func hardLink() throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .file(name: "data.bin", logicalBytes: 8192),
            .hardlink(name: "data-link.bin", of: "data.bin"),
            .dir(name: "nested", children: [.hardlink(name: "deep-link.bin", of: "../data.bin")]),
        ]))
        defer { fixture.cleanup() }

        let a = try FixtureFS.stat(path: fixture.path + "/data.bin")
        let b = try FixtureFS.stat(path: fixture.path + "/data-link.bin")
        let c = try FixtureFS.stat(path: fixture.path + "/nested/deep-link.bin")
        #expect(a.st_ino == b.st_ino && b.st_ino == c.st_ino)
        #expect(a.st_nlink == 3)

        let usage = try DiskUsage.measure(at: fixture.path)
        #expect(usage.entryCount == 4)
        #expect(usage.allocated == 8192)
        #expect(usage.logical == 8192)
        #expect(usage == DiskUsage(logical: 8192, allocated: 8192, privateBytes: 8192, entryCount: 4, directories: 1, files: 3))
        #expect(fixture.expected == ExpectedSizes(logical: 8192, allocated: 8192, privateBytes: 8192, entryCount: 4))
    }

    @Test("symlink loops and a Unix socket are created and enumerate without following")
    func symlinkLoopsAndSocket() throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .symlink(name: "a", to: "b"),
            .symlink(name: "b", to: "a"),
            .dir(name: "d", children: [.symlink(name: "parent", to: "..")]),
            .socket(name: "run.sock"),
        ]))
        defer { fixture.cleanup() }

        let a = try FixtureFS.stat(path: fixture.path + "/a")
        #expect((a.st_mode & S_IFMT) == S_IFLNK)
        #expect(a.st_blocks == 0)
        var st = stat()
        let followed = stat(fixture.path + "/a", &st)
        let followErrno = errno
        #expect(followed != 0 && followErrno == ELOOP)
        let sock = try FixtureFS.stat(path: fixture.path + "/run.sock")
        #expect((sock.st_mode & S_IFMT) == S_IFSOCK)

        let usage = try DiskUsage.measure(at: fixture.path)
        #expect(usage.entryCount == 5)
        #expect(usage.symlinks == 3)
        #expect(usage.others == 1)
        #expect(usage.logical == UInt64("b".utf8.count + "a".utf8.count + "..".utf8.count))
        #expect(usage.allocated == 0)
        #expect(fixture.expected.entryCount == 5)
        #expect(fixture.expected.logical == usage.logical)
    }

    @Test("git repositories: clean and dirty, sizes include the measured .git subtree")
    func gitRepositories() throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .gitRepo(name: "clean", dirty: false, children: [
                .file(name: "README.md", logicalBytes: 120),
                .dir(name: "src", children: [.file(name: "main.swift", logicalBytes: 2048)]),
            ]),
            .gitRepo(name: "dirty", dirty: true, children: [
                .file(name: "package.json", logicalBytes: 64),
                .nodeModules(packages: 2, bytesEach: 5000),
            ]),
        ]))
        defer { fixture.cleanup() }

        #expect(access(fixture.path + "/clean/.git/HEAD", F_OK) == 0)
        #expect(access(fixture.path + "/dirty/.git/HEAD", F_OK) == 0)
        #expect(access(fixture.path + "/clean/UNCOMMITTED.txt", F_OK) != 0)
        #expect(access(fixture.path + "/dirty/UNCOMMITTED.txt", F_OK) == 0)
        #expect(try gitStatus(in: fixture.path + "/clean").isEmpty)
        #expect(try gitStatus(in: fixture.path + "/dirty").contains("UNCOMMITTED.txt"))

        let usage = try DiskUsage.measure(at: fixture.path)
        #expect(usage.entryCount == fixture.expected.entryCount)
        #expect(usage.logical == fixture.expected.logical)
        #expect(abs(Int64(usage.allocated) - Int64(fixture.expected.allocated)) <= Self.block)
    }

    @Test("home layout: root is the fake home, library nodes land under <root>/Library")
    func homeLayout() throws {
        let fixture = try FixtureBuilder.home(HomeLayout(
            library: [.dir(name: "Caches", children: [.dir(name: "com.example.app", children: [.file(name: "blob", logicalBytes: 5000)])])],
            home: [.dir(name: "Downloads", children: [.file(name: "installer.dmg", logicalBytes: 7000, mtimeDaysAgo: 30)])]
        ))
        defer { fixture.cleanup() }

        #expect(fixture.path.hasPrefix("/private/tmp/rcl-home-"))
        #expect(access(fixture.path + "/Library/Caches/com.example.app/blob", F_OK) == 0)
        #expect(access(fixture.path + "/Downloads/installer.dmg", F_OK) == 0)
        let usage = try DiskUsage.measure(at: fixture.path)
        #expect(usage.entryCount == 6)
        #expect(usage == DiskUsage(logical: 12_000, allocated: 16_384, privateBytes: 16_384, entryCount: 6, directories: 4, files: 2))
        #expect(fixture.expected == ExpectedSizes(logical: 12_000, allocated: 16_384, privateBytes: 16_384, entryCount: 6))
    }

    @Test("largeTree: exact directory/file counts and sizes at small scale")
    func largeTreeSmall() throws {
        let fixture = try FixtureBuilder.largeTree(dirs: 37, filesPerDir: 3, bytesPerFile: 10)
        defer { fixture.cleanup() }

        let usage = try DiskUsage.measure(at: fixture.path)
        #expect(usage.directories == 37)
        #expect(usage.files == 111)
        #expect(usage.entryCount == 148)
        #expect(usage.allocated == 111 * 4096)
        #expect(usage.logical == 1110)
        #expect(fixture.expected == ExpectedSizes(logical: 1110, allocated: 111 * 4096, privateBytes: 111 * 4096, entryCount: 148))
    }

    @Test("T0-FIXTURE-CLEANUP: cleanup clears uchg flags, restores modes, and leaves no temp directory")
    func cleanupRemovesEverything() throws {
        let fixture = try FixtureBuilder.make(FixtureSpec(root: [
            .file(name: "locked.bin", logicalBytes: 4096, flags: UInt32(UF_IMMUTABLE)),
            .file(name: "append-only.log", logicalBytes: 10, flags: UInt32(UF_APPEND)),
            .dir(name: "locked-dir", children: [.file(name: "inner.bin", logicalBytes: 10)]),
            .dir(name: "no-access", mode: 0o000, children: [
                .file(name: "hidden.bin", logicalBytes: 10),
                .dir(name: "deeper", mode: 0o000, children: [.file(name: "deepest.bin", logicalBytes: 10)]),
            ]),
            .dir(name: "read-only", mode: 0o555, children: [.file(name: "ro.bin", logicalBytes: 10, mode: 0o000)]),
            .symlink(name: "loop-a", to: "loop-b"),
            .symlink(name: "loop-b", to: "loop-a"),
            .socket(name: "ctl.sock"),
            .sparse(name: "sparse.img", logicalBytes: 32 << 20, writtenBytes: 4096),
        ]))
        let path = fixture.path
        // Lock a directory after its children exist, like Sparkle's staged installs (EC-05) but with uchg.
        try FixtureFS.setFlags(path: path + "/locked-dir", flags: UInt32(UF_IMMUTABLE))

        let locked = try FixtureFS.stat(path: path + "/locked.bin")
        #expect(locked.st_flags & UInt32(UF_IMMUTABLE) != 0)
        let unlinkResult = unlink(path + "/locked.bin")  // proves the flag is in force before cleanup
        let unlinkErrno = errno
        #expect(unlinkResult != 0 && unlinkErrno == EPERM)

        fixture.cleanup()

        var st = stat()
        let rc = lstat(path, &st)
        let lstatErrno = errno
        #expect(rc != 0 && lstatErrno == ENOENT, "fixture root still exists after cleanup: \(path)")
    }

    @Test("FixtureBuilder.remove throws on a missing path and make rolls back on an invalid spec")
    func errorPaths() throws {
        #expect(throws: FixtureError.self) {
            try FixtureBuilder.remove(at: URL(fileURLWithPath: "/private/tmp/rcl-fixture-does-not-exist-\(getpid())"))
        }
        // A private base directory so parallel tests cannot interfere with the "nothing left behind" check.
        let base = try FixtureFS.makeTempDir(prefix: "rcl-errtest", under: nil)
        defer { try? FixtureFS.removeTree(at: base) }
        #expect(throws: FixtureError.self) {
            try FixtureBuilder.make(FixtureSpec(root: [
                .file(name: "a", logicalBytes: 10),
                .clone(name: "b", of: "missing"),
            ]), at: URL(fileURLWithPath: base, isDirectory: true))
        }
        let fd = try FixtureFS.openDirectory(base)
        defer { close(fd) }
        #expect(try FixtureFS.listNames(of: fd, path: base).isEmpty, "a failed make() must remove its mkdtemp directory")
    }

    // MARK: - Helpers

    private func gitStatus(in repo: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo, "status", "--porcelain"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": repo, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

}

private extension DiskUsage {
    init(logical: UInt64, allocated: UInt64, privateBytes: UInt64, entryCount: Int, directories: Int, files: Int) {
        self.init()
        self.logical = logical
        self.allocated = allocated
        self.privateBytes = privateBytes
        self.entryCount = entryCount
        self.directories = directories
        self.files = files
    }
}
