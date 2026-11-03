// Parallel scan (PLAN.md §2.5–2.6). Workers pull a LIFO queue, read with `getattrlistbulk`, and copy
// names into one arena per directory. No per-file `String`, no per-directory `fstat` — the Phase 1
// profile put ~99 % of samples inside `getattrlistbulk` and `openat`.

import Darwin
import Foundation
import os

public actor ScanEngine {
    private let topology: VolumeTopology
    private let logger: Logger
    private var task: Task<FileIndexReader, Error>?
    private var reader: FileIndexReader?
    private let queue = WorkQueue()

    public init(topology: VolumeTopology, logger: Logger = .scan) {
        self.topology = topology
        self.logger = logger
    }

    public func run(_ options: ScanOptions) -> AsyncThrowingStream<ScanEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ScanEvent, Error>.makeStream()
        let task = Task { try await self.execute(options, continuation: continuation) }
        self.task = task
        continuation.onTermination = { @Sendable reason in
            if case .cancelled = reason { task.cancel() }
        }
        return stream
    }

    public func result() async throws -> FileIndexReader {
        if let reader { return reader }
        guard let task else { throw FSError.noResult }
        return try await task.value
    }

    public func cancel() {
        task?.cancel()
        for fd in queue.cancel() where fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func execute(
        _ options: ScanOptions,
        continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async throws -> FileIndexReader {
        DirectoryOpen.raiseSoftLimit()
        let canonicalizer = PathCanonicalizer.system()
        let index = FileIndex()
        await index.setFirmlinks(canonicalizer.firmlinks)
        if let limit = options.maxEntries { index.reserve(limit) }
        let volumes = (try? await topology.refresh()) ?? []
        let started = ContinuousClock.now
        let counters = ScanCounters(started: started)
        continuation.yield(.started(roots: options.roots))
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                continuation.yield(.progress(counters.progress()))
                counters.noteFootprint(Footprint.current())
            }
        }
        let context = ScanContext(
            index: index,
            queue: queue,
            options: options,
            counters: counters,
            volumes: volumes,
            canonicalizer: canonicalizer,
            continuation: continuation,
            logger: logger
        )
        do {
            try context.seed()
            let workers = options.maxConcurrency
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask { try await context.worker() }
                }
                try await group.waitForAll()
            }
        } catch is CancellationError {
            counters.requestStop("cancelled")
        } catch {
            ticker.cancel()
            continuation.finish(throwing: error)
            throw error
        }
        ticker.cancel()
        let leftover = queue.cancel()
        for fd in leftover where fd >= 0 {
            Darwin.close(fd)
        }
        let frozen = index.freeze(firmlinks: canonicalizer.firmlinks)
        reader = frozen
        let elapsed = started.duration(to: ContinuousClock.now)
        let completeness = counters.completeness()
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var reclaimable: UInt64 = 0
        for root in frozen.roots {
            let sizes = frozen.summary(root).sizes
            logical &+= sizes.logical
            allocated &+= sizes.allocated
            reclaimable &+= sizes.privateReclaimable
        }
        let summary = ScanSummary(
            roots: options.roots,
            entryCount: frozen.count,
            directoryCount: counters.directoryCount,
            fileCount: counters.fileCount,
            symlinkCount: counters.symlinkCount,
            unreadableCount: counters.unreadableCount,
            boundaryCount: counters.boundaryCount,
            bytesLogical: logical,
            bytesAllocated: allocated,
            bytesReclaimable: reclaimable,
            elapsed: elapsed,
            completeness: completeness,
            peakRSSBytes: max(counters.peakBytes, Footprint.peak()),
            maxOpenDirectoryFDs: queue.highWater,
            openDirectoryFDs: queue.openFileDescriptors
        )
        continuation.yield(.finished(summary))
        continuation.finish()
        return frozen
    }
}

final class ScanCounters: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let started: ContinuousClock.Instant
    private var entries = 0
    private var bytes: UInt64 = 0
    private var directories = 0
    private var files = 0
    private var symlinks = 0
    private var unreadable = 0
    private var boundaries = 0
    private var stopReason: String?
    private var peak: UInt64 = 0

    init(started: ContinuousClock.Instant) {
        self.started = started
    }

    func add(kind: EntryKind, allocated: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries += 1
        bytes &+= allocated
        switch kind {
        case .directory: directories += 1
        case .file: files += 1
        case .symlink: symlinks += 1
        case .unreadable: unreadable += 1
        case .mountBoundary: boundaries += 1
        case .socket, .fifo, .device: break
        }
    }

    func noteFootprint(_ bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        peak = max(peak, bytes)
    }

    func requestStop(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if stopReason == nil { stopReason = reason }
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopReason != nil
    }

    func progress() -> ScanProgress {
        lock.lock()
        defer { lock.unlock() }
        return ScanProgress(
            entries: entries,
            bytesAllocated: bytes,
            directoriesDone: directories,
            elapsed: started.duration(to: ContinuousClock.now)
        )
    }

    func completeness() -> ScanSummary.Completeness {
        lock.lock()
        defer { lock.unlock() }
        if let stopReason { return .partial(reasons: [stopReason]) }
        return .complete
    }

    var directoryCount: Int { lock.withLock { directories } }
    var fileCount: Int { lock.withLock { files } }
    var symlinkCount: Int { lock.withLock { symlinks } }
    var unreadableCount: Int { lock.withLock { unreadable } }
    var boundaryCount: Int { lock.withLock { boundaries } }
    var peakBytes: UInt64 { lock.withLock { peak } }
}

struct ScanContext: Sendable {
    let index: FileIndex
    let queue: WorkQueue
    let options: ScanOptions
    let counters: ScanCounters
    let volumes: [VolumeInfo]
    let canonicalizer: PathCanonicalizer
    let continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    let logger: Logger

    func seed() throws {
        let canonical = options.roots.map { canonicalizer.canonicalize($0) }
        let excludes = options.resolvedExcludes(canonicalRoots: canonical)
        for root in canonical {
            let opened = try FileDescriptor.openDirectory(atPath: root)
            let fd = opened.relinquish()
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                Darwin.close(fd)
                throw FSError.capture("fstat", path: root)
            }
            var fs = statfs()
            guard fstatfs(fd, &fs) == 0 else {
                Darwin.close(fd)
                throw FSError.capture("fstatfs", path: root)
            }
            let identity = FileIdentity(fsid: fs.f_fsid, fileID: UInt64(st.st_ino))
            if let existing = index.existingDirectory(identity) {
                index.addAlias(path: root, id: existing)
                Darwin.close(fd)
                continue
            }
            let volume = volumes.first { $0.device == UInt64(truncatingIfNeeded: st.st_dev) }
            var item = FastItem()
            item.kind = .directory
            item.mode = UInt16(truncatingIfNeeded: st.st_mode)
            item.uid = st.st_uid
            item.mtime = Int64(st.st_mtimespec.tv_sec)
            item.fileID = UInt64(st.st_ino)
            item.linkCount = UInt16(clamping: min(UInt32(st.st_nlink), UInt32(UInt16.max)))
            item.logical = UInt64(clamping: st.st_size)
            item.allocated = UInt64(clamping: st.st_blocks) * 512
            item.bsdFlags = st.st_flags
            item.volumeIndex = volume?.id ?? 0
            item.fsidA = identity.fsidA
            item.fsidB = identity.fsidB
            item.trackDirectory = true
            var batch = FastBatch(parent: .none)
            Array(root.utf8).withUnsafeBytes { raw in batch.add(name: raw, item: item) }
            let range = index.ingest(batch)
            guard let id = range.first else {
                Darwin.close(fd)
                continue
            }
            index.addRoot(id, path: root)
            counters.add(kind: .directory, allocated: item.allocated)
            let work = DirWork(
                fd: fd,
                entryID: id,
                path: root,
                device: UInt64(truncatingIfNeeded: st.st_dev),
                volumeIndex: volume?.id ?? 0,
                fsidA: identity.fsidA,
                fsidB: identity.fsidB,
                pending: nil,
                entryCountHint: 0
            )
            _ = excludes
            queue.pushNew([work])
        }
    }

    func worker() async throws {
        let bulk = BulkAttrEnumerator(bufferBytes: options.bufferBytes)
        let excludes = options.resolvedExcludes(canonicalRoots: options.roots.map { canonicalizer.canonicalize($0) })
        while true {
            if Task.isCancelled || counters.shouldStop {
                counters.requestStop("cancelled")
                for fd in queue.cancel() where fd >= 0 {
                    Darwin.close(fd)
                }
                return
            }
            let next: DirWork?
            if let ready = queue.tryPop() {
                next = ready
            } else {
                next = await queue.pop()
            }
            guard var item = next else { return }
            if Task.isCancelled {
                Darwin.close(item.fd)
                return
            }
            if overBudget() {
                Darwin.close(item.fd)
                queue.finishedClosingFD()
                counters.requestStop("timeBudget")
                for fd in queue.cancel() {
                    Darwin.close(fd)
                }
                return
            }
            try read(&item, bulk: bulk, excludes: excludes, accounted: true)
        }
    }

    private func overBudget() -> Bool {
        if let budget = options.timeBudget, counters.progress().elapsed >= budget { return true }
        if let maxEntries = options.maxEntries, counters.progress().entries >= maxEntries { return true }
        return false
    }

    private func read(
        _ item: inout DirWork,
        bulk: BulkAttrEnumerator,
        excludes: [String],
        accounted: Bool
    ) throws {
        if item.pending == nil {
            if options.forceFTS || DirectoryEnumeratorFactory.needsFTS(fsType: fsType(device: item.device), forceFTS: false) {
                try ingestFTS(item)
                Darwin.close(item.fd)
                if accounted { queue.finishedClosingFD() }
                return
            }
            var batch = FastBatch(parent: item.entryID)
            var metas: [(kind: EntryKind, entryCount: UInt32, path: String, name: Data)] = []
            do {
                try bulk.forEach(dirfd: item.fd, expectedCount: item.entryCountHint) { attributes, name in
                    let childPath = join(item.path, name)
                    var fast = makeItem(attributes, parent: item)
                    let decision = classify(attributes, path: childPath, excludes: excludes, item: &fast)
                    batch.add(name: name, item: fast)
                    metas.append((decision, attributes.entryCount, childPath, Data(name)))
                }
            } catch {
                if BulkAttrEnumerator.isUnsupported(error) {
                    try ingestFTS(item)
                    Darwin.close(item.fd)
                    if accounted { queue.finishedClosingFD() }
                    return
                }
                if let fs = error as? FSError, let code = fs.errno {
                    // One directory timing out or returning EIO must not abort the rest of the volume.
                    index.update(id: item.entryID, kind: .unreadable, errno: code)
                    counters.add(kind: .unreadable, allocated: 0)
                    continuation.yield(.unreadable(path: item.path, errno: code))
                    Darwin.close(item.fd)
                    if accounted { queue.finishedClosingFD() }
                    return
                }
                throw error
            }
            let range = index.ingest(batch)
            var pending: [PendingSubdir] = []
            var offset = 0
            for meta in metas {
                let id = range.lowerBound.advanced(by: offset)
                offset += 1
                counters.add(kind: meta.kind, allocated: 0)
                if meta.kind == .unreadable {
                    continuation.yield(.unreadable(path: meta.path, errno: EACCES))
                }
        if meta.kind == .mountBoundary {
            let volume = boundaryVolume(path: meta.path, device: item.device)
                ?? synthesizedVolume(path: meta.path, parent: item)
            if let volume {
                continuation.yield(.boundary(path: meta.path, volume: volume))
            }
        }
                if meta.kind == .directory {
                    pending.append(PendingSubdir(name: meta.name, entryID: id, entryCount: meta.entryCount, path: meta.path))
                }
            }
            item.pending = pending
            // Byte counters are filled from the frozen rollup. Per-entry allocated is applied below.
            _ = batch
        }
        guard var pending = item.pending else {
            Darwin.close(item.fd)
            if accounted { queue.finishedClosingFD() }
            return
        }
        while !pending.isEmpty {
            if Task.isCancelled { break }
            // Once the queue is near the cap, finish the remaining children on this worker.
            // Pushing them would spin: every worker re-defers the same wide directory (Data volume).
            // Inline descent holds O(depth) extra fds, so the cap stays under 2 048.
            let inline = queue.openFileDescriptors >= DirectoryOpen.schedulerCap - 64
            let sub = pending.removeFirst()
            let fd = openComponent(parent: item.fd, name: sub.name)
            if fd < 0 {
                let code = errno
                index.update(id: sub.entryID, kind: .unreadable, errno: code)
                continuation.yield(.unreadable(path: sub.path, errno: code))
                continue
            }
            var child = DirWork(
                fd: fd,
                entryID: sub.entryID,
                path: sub.path,
                device: item.device,
                volumeIndex: item.volumeIndex,
                fsidA: item.fsidA,
                fsidB: item.fsidB,
                pending: nil,
                entryCountHint: sub.entryCount
            )
            if inline {
                try read(&child, bulk: bulk, excludes: excludes, accounted: false)
            } else {
                queue.pushNew([child])
            }
        }
        Darwin.close(item.fd)
        if accounted { queue.finishedClosingFD() }
    }

    private func ingestFTS(_ item: DirWork) throws {
        let fts = FTSEnumerator()
        var stack: [EntryID] = [item.entryID]
        try fts.forEach(path: item.path, shouldSkip: { node in
            node.isMountBoundary || options.isExcluded(node.path, excludes: options.excludes)
        }) { node in
            if node.level == 0 { return }
            while stack.count > node.level { stack.removeLast() }
            let parent = stack.last ?? item.entryID
            var fast = FastItem()
            fast.kind = node.error != 0 ? .unreadable : EntryKind.from(objType: node.objType)
            fast.errno = UInt16(clamping: node.error)
            fast.mode = UInt16(truncatingIfNeeded: node.mode)
            fast.uid = node.uid
            fast.mtime = node.mtimeSeconds
            fast.fileID = node.fileID
            fast.linkCount = UInt16(clamping: min(node.linkCount, UInt32(UInt16.max)))
            fast.logical = node.logicalSize
            fast.allocated = node.allocatedSize
            fast.privateBytes = node.allocatedSize
            fast.bsdFlags = node.flags
            fast.extFlags = ExtFlags(kernel: 0, confidence: .allocatedOnly).rawValue
            fast.volumeIndex = item.volumeIndex
            fast.fsidA = item.fsidA
            fast.fsidB = item.fsidB
            fast.trackDirectory = fast.kind == .directory
            var batch = FastBatch(parent: parent)
            node.name.withUnsafeBytes { raw in batch.add(name: raw, item: fast) }
            let range = index.ingest(batch)
            counters.add(kind: fast.kind, allocated: fast.allocated)
            if fast.kind == .directory, let id = range.first {
                if stack.count == node.level {
                    stack.append(id)
                } else {
                    stack.append(id)
                }
            }
        }
    }

    private func makeItem(_ attributes: ParsedAttributes, parent: DirWork) -> FastItem {
        var item = FastItem()
        item.kind = attributes.error != 0 ? .unreadable : EntryKind.from(objType: attributes.objType)
        item.bsdFlags = attributes.flags
        item.extFlags = ExtFlags(kernel: attributes.extFlags).rawValue
        item.mode = UInt16(truncatingIfNeeded: attributes.mode)
        item.uid = attributes.uid
        item.mtime = attributes.mtimeSeconds
        item.fileID = attributes.fileID
        item.cloneID = attributes.cloneID
        item.linkCount = UInt16(clamping: min(attributes.linkCount, UInt32(UInt16.max)))
        item.logical = attributes.logical
        item.allocated = attributes.allocated
        item.privateBytes = attributes.hasPrivateSize ? attributes.privateSize : attributes.allocated
        if !attributes.hasPrivateSize {
            item.extFlags |= ExtFlags.allocatedOnly.rawValue
        }
        item.errno = UInt16(clamping: attributes.error)
        item.volumeIndex = parent.volumeIndex
        item.fsidA = parent.fsidA
        item.fsidB = parent.fsidB
        return item
    }

    private func classify(
        _ attributes: ParsedAttributes,
        path: String,
        excludes: [String],
        item: inout FastItem
    ) -> EntryKind {
        if attributes.error != 0 {
            item.kind = .unreadable
            return .unreadable
        }
        let flags = BSDFlags(rawValue: attributes.flags)
        let ext = ExtFlags(rawValue: item.extFlags)
        let mount = attributes.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
        let firmlink = flags.contains(.firmlink)
        if ext.contains(.synthetic) || options.isExcluded(path, excludes: excludes) {
            item.kind = .mountBoundary
            item.trackDirectory = false
            return .mountBoundary
        }
        if item.kind == .directory, mount, !firmlink, !options.crossMountPoints {
            if let info = MountPoint.read(atPath: path) {
                item.allocated = MountPoint.usedBytes(info)
                if !options.includeOtherVolumes || info.f_flags & UInt32(MNT_LOCAL) == 0 {
                    item.kind = .mountBoundary
                    item.trackDirectory = true
                    return .mountBoundary
                }
            } else {
                item.kind = .mountBoundary
                item.trackDirectory = true
                return .mountBoundary
            }
        }
        item.trackDirectory = item.kind == .directory
        return item.kind
    }

    private func boundaryVolume(path: String, device: UInt64) -> VolumeInfo? {
        let canonical = canonicalizer.canonicalize(path)
        return volumes.first { $0.mountPoint == path || $0.mountPoint == canonical || $0.device == device && $0.mountPoint == canonical }
    }

    private func synthesizedVolume(path: String, parent: DirWork) -> VolumeInfo? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let block = UInt64(truncatingIfNeeded: info.f_bsize)
        let total = UInt64(truncatingIfNeeded: info.f_blocks) &* block
        let free = UInt64(truncatingIfNeeded: info.f_bfree) &* block
        return VolumeInfo(
            id: parent.volumeIndex,
            fsidA: info.f_fsid.val.0,
            fsidB: info.f_fsid.val.1,
            device: parent.device,
            mountPoint: MountPoint.cString(info.f_mntonname),
            fsType: MountPoint.cString(info.f_fstypename),
            flags: UInt32(truncatingIfNeeded: info.f_flags),
            role: .diskImage,
            total: total,
            free: free,
            availableImportant: free,
            availableOpportunistic: free,
            diskName: nil,
            isBootContainer: false
        )
    }

    private func fsType(device: UInt64) -> String {
        volumes.first { $0.device == device }?.fsType ?? "apfs"
    }

    private func join(_ parent: String, _ name: UnsafeRawBufferPointer) -> String {
        let text = String(decoding: name, as: UTF8.self)
        if parent == "/" { return "/" + text }
        return parent + "/" + text
    }

    private func openComponent(parent: Int32, name: Data) -> Int32 {
        var buffer = [UInt8](name)
        buffer.append(0)
        let fd = buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return Int32(-1) }
            return openat(parent, base, DirectoryOpen.flags)
        }
        return fd
    }
}

enum Footprint {
    static func current() -> UInt64 { usage()?.ri_phys_footprint ?? 0 }
    static func peak() -> UInt64 { usage()?.ri_lifetime_max_phys_footprint ?? 0 }

    private static func usage() -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }
        return rc == 0 ? info : nil
    }
}
