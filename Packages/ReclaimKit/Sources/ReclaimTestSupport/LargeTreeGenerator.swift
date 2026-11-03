// LargeTreeGenerator — fast parallel generator for benchmark-scale trees (FixtureBuilder.largeTree).
// `reclaim-bench fixture` ships an equivalent generator; keep the layout identical (ADR-012).

import Darwin
import Foundation
import os

/// Layout: `top = ceil(sqrt(directories))` top-level directories `d<i>`, each holding leaf directories `s<j>`
/// so that the total directory count is exactly `directories`; `files` files `f<k>` are spread round-robin
/// over every directory (top-level ones included). Entries = directories + files.
enum LargeTreeGenerator {
    struct Plan: Sendable {
        let directories: Int
        let files: Int
        let topCount: Int

        init(directories: Int, files: Int) {
            self.directories = directories
            self.files = files
            topCount = directories == 0 ? 0 : min(directories, Int(Double(directories).squareRoot().rounded(.up)))
        }

        /// Leaf directories under top-level directory `i`.
        func leaves(under i: Int) -> Int {
            let remaining = directories - topCount
            let base = remaining / topCount
            return base + (i < remaining % topCount ? 1 : 0)
        }

        /// Files placed in the directory with global index `d` (0..<directories).
        func files(inDirectory d: Int) -> Int {
            let base = files / directories
            return base + (d < files % directories ? 1 : 0)
        }

        /// Global directory index of the first leaf under top-level directory `i` (top dirs occupy 0..<topCount).
        func firstLeafIndex(under i: Int) -> Int {
            var index = topCount
            for j in 0..<i { index += leaves(under: j) }
            return index
        }
    }

    static func generate(at rootPath: String, directories: Int, files: Int, bytesPerFile: Int, workers: Int) throws -> ExpectedSizes {
        guard directories > 0 else { throw FixtureError.invalidSpec("largeTree needs at least one directory") }
        guard bytesPerFile >= 0, files >= 0 else { throw FixtureError.invalidSpec("negative counts") }
        let plan = Plan(directories: directories, files: files)
        let blockSize = try FixtureFS.blockSize(at: rootPath)
        let rootFD = try FixtureFS.openDirectory(rootPath)
        defer { close(rootFD) }

        let failure = OSAllocatedUnfairLock<FixtureError?>(initialState: nil)
        let parallelism = max(1, min(workers, plan.topCount))
        DispatchQueue.concurrentPerform(iterations: parallelism) { worker in
            var i = worker
            while i < plan.topCount {
                if failure.withLock({ $0 != nil }) { return }
                do {
                    try generateTop(i, plan: plan, rootFD: rootFD, rootPath: rootPath, bytesPerFile: bytesPerFile)
                } catch let error as FixtureError {
                    failure.withLock { if $0 == nil { $0 = error } }
                    return
                } catch {
                    failure.withLock { if $0 == nil { $0 = .invalidSpec("\(error)") } }
                    return
                }
                i += parallelism
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }

        let perFile = ExpectedSizes.fullAllocation(logical: bytesPerFile, blockSize: blockSize)
        return ExpectedSizes(
            logical: UInt64(files) * UInt64(bytesPerFile),
            allocated: UInt64(files) * UInt64(perFile),
            privateBytes: UInt64(files) * UInt64(perFile),
            entryCount: directories + files
        )
    }

    private static func generateTop(_ i: Int, plan: Plan, rootFD: Int32, rootPath: String, bytesPerFile: Int) throws {
        let topName = "d\(i)"
        try FixtureFS.makeDirectory(parent: rootFD, name: topName)
        let topFD = try FixtureFS.openDirectory(parent: rootFD, name: topName)
        defer { close(topFD) }
        let topPath = rootPath + "/" + topName
        try fill(directory: topFD, path: topPath, count: plan.files(inDirectory: i), bytesPerFile: bytesPerFile)

        var leafIndex = plan.firstLeafIndex(under: i)
        for j in 0..<plan.leaves(under: i) {
            let leafName = "s\(j)"
            try FixtureFS.makeDirectory(parent: topFD, name: leafName)
            let leafFD = try FixtureFS.openDirectory(parent: topFD, name: leafName)
            do {
                try fill(directory: leafFD, path: topPath + "/" + leafName,
                         count: plan.files(inDirectory: leafIndex), bytesPerFile: bytesPerFile)
            } catch {
                close(leafFD)
                throw error
            }
            close(leafFD)
            leafIndex += 1
        }
    }

    private static func fill(directory fd: Int32, path: String, count: Int, bytesPerFile: Int) throws {
        for k in 0..<count {
            let name = "f\(k)"
            let file = try FixtureFS.createFile(parent: fd, name: name)
            if bytesPerFile > 0 {
                do {
                    try FixtureFS.writePattern(fd: file, count: bytesPerFile, path: path + "/" + name)
                } catch {
                    close(file)
                    throw error
                }
            }
            close(file)
        }
    }
}
