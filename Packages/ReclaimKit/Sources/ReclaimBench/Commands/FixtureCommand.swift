// `reclaim-bench fixture --dirs N --files M --out PATH` (PLAN.md §6 Phase 0 "Benchmark harness").

import ArgumentParser
import Darwin
import Foundation

struct FixtureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fixture",
        abstract: "Generate a large benchmark tree (directories + files) with POSIX calls only."
    )

    @Option(name: .long, help: "Number of directories to create (two-level tree).")
    var dirs: Int = 200_000

    @Option(name: .long, help: "Number of files to create, spread evenly over all directories.")
    var files: Int = 2_000_000

    @Option(name: .long, help: "Output directory; must not exist or must be empty.", transform: FixtureCommand.absolutePath)
    var out: String = "/private/tmp/rcl-fixture"

    @Option(name: .long, help: "Bytes written to each file (0 = inode-only fixture).")
    var bytesPerFile: Int = 0

    @Option(name: .long, help: "Parallel generator workers (default: active processor count).")
    var workers: Int = ProcessInfo.processInfo.activeProcessorCount

    @Flag(name: .long, help: "Emit a JSON report instead of text.")
    var json = false

    @Flag(name: .long, help: "Remove the fixture at --out instead of generating one (fd-based, /private/tmp only).")
    var remove = false

    static func absolutePath(_ raw: String) throws -> String {
        raw.hasPrefix("/") ? raw : FileManager.default.currentDirectoryPath + "/" + raw
    }

    func validate() throws {
        guard dirs >= 1 else { throw ValidationError("--dirs must be ≥ 1") }
        guard files >= 0 else { throw ValidationError("--files must be ≥ 0") }
        guard bytesPerFile >= 0 else { throw ValidationError("--bytes-per-file must be ≥ 0") }
        guard workers >= 1 else { throw ValidationError("--workers must be ≥ 1") }
    }

    func run() async throws {
        if remove {
            let clock = ContinuousClock()
            let start = clock.now
            try TreeRemover.remove(at: out)
            let elapsed = (clock.now - start).seconds
            if json {
                try print(Output.json(["removed": out, "wallSeconds": String(format: "%.3f", elapsed)]))
            } else {
                print("removed \(out) in \(Output.seconds(elapsed))")
            }
            return
        }
        try prepareOutputDirectory()
        let generator = try LargeTreeGenerator(directories: dirs, files: files, bytesPerFile: bytesPerFile)
        let clock = ContinuousClock()
        let start = clock.now
        try generator.generate(at: out, workers: workers)
        let elapsed = (clock.now - start).seconds
        let entries = dirs + files
        let report = FixtureReport(
            generatedAt: Output.timestamp(),
            host: HostInfo.current(),
            root: out,
            directories: dirs,
            files: files,
            entries: entries,
            bytesPerFile: bytesPerFile,
            workers: workers,
            wallSeconds: elapsed,
            entriesPerSecond: elapsed > 0 ? Double(entries) / elapsed : 0
        )
        if json {
            try print(Output.json(report))
        } else {
            print("fixture: \(out)")
            print("  directories: \(dirs)  files: \(files)  entries: \(entries)  bytes/file: \(bytesPerFile)")
            print("  created in \(Output.seconds(elapsed)) (\(Int(report.entriesPerSecond)) entries/s, \(workers) workers)")
        }
    }

    private func prepareOutputDirectory() throws {
        var st = stat()
        if lstat(out, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                throw ValidationError("\(out) exists and is not a directory")
            }
            let fd = open(out, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FixtureGeneratorError.posix(call: "open", path: out, errno: errno) }
            defer { close(fd) }
            guard let dir = fdopendir(dup(fd)) else { throw FixtureGeneratorError.posix(call: "fdopendir", path: out, errno: errno) }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let length = Int(entry.pointee.d_namlen)
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
                if name != ".", name != ".." {
                    throw ValidationError("\(out) exists and is not empty (found \(name)); refusing to generate into it")
                }
            }
        } else {
            guard errno == ENOENT else { throw FixtureGeneratorError.posix(call: "lstat", path: out, errno: errno) }
            guard mkdir(out, 0o755) == 0 else { throw FixtureGeneratorError.posix(call: "mkdir", path: out, errno: errno) }
        }
    }
}

extension Duration {
    /// Duration in seconds as a Double.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
