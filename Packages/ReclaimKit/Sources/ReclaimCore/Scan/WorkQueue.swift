// LIFO directory queue (PLAN.md §2.6.5). Pops that hit a non-empty stack do not suspend: the Phase 1
// profile showed `swift_task_switch` is not the cost, and a hop on every one of 200 k directories
// would be the first user-space tax on a kernel-bound walk.
//
// Open directory fds are capped at `DirectoryOpen.schedulerCap` (2 048). A parent that still has
// children to open is parked on `deferred` (under the LIFO stack) so workers drain leaves and free
// slots before the parent opens more. That is the depth-300 / 50 k-directory case (T1-FDLIMIT).

import Darwin
import Foundation
import os

struct PendingSubdir: Sendable {
    var name: Data
    var entryID: EntryID
    var entryCount: UInt32
    var path: String
}

struct DirWork: Sendable {
    var fd: Int32
    var entryID: EntryID
    var path: String
    var device: UInt64
    var volumeIndex: UInt8
    var fsidA: Int32
    var fsidB: Int32
    /// `nil` until the directory has been read. After that, subdirectories not yet `openat`'d.
    var pending: [PendingSubdir]?
    var entryCountHint: UInt32
}

final class WorkQueue: @unchecked Sendable {
    private struct State {
        var stack: [DirWork] = []
        var deferred: [DirWork] = []
        var pending = 0
        var openFDs = 0
        var highWater = 0
        var cancelled = false
        var waiters: [CheckedContinuation<DirWork?, Never>] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var openFileDescriptors: Int {
        lock.withLock { $0.openFDs }
    }

    var highWater: Int {
        lock.withLock { $0.highWater }
    }

    func pushNew(_ items: [DirWork]) {
        guard !items.isEmpty else { return }
        let outcome = lock.withLock { state -> (resume: [(CheckedContinuation<DirWork?, Never>, DirWork)], drop: [DirWork]) in
            if state.cancelled { return ([], items) }
            state.pending += items.count
            state.openFDs += items.count
            state.highWater = max(state.highWater, state.openFDs)
            var handed: [(CheckedContinuation<DirWork?, Never>, DirWork)] = []
            for item in items.reversed() {
                if let waiter = state.waiters.popLast() {
                    handed.append((waiter, item))
                } else {
                    state.stack.append(item)
                }
            }
            return (handed, [])
        }
        for (waiter, item) in outcome.resume {
            waiter.resume(returning: item)
        }
        for item in outcome.drop where item.fd >= 0 {
            Darwin.close(item.fd)
        }
    }

    /// Put a parent that still holds its fd back under the live stack. Does not change `pending`.
    func defer_(_ item: DirWork) {
        lock.withLock { state in
            state.deferred.append(item)
        }
    }

    func tryPop() -> DirWork? {
        lock.withLock { state in
            if state.cancelled { return nil }
            if let item = state.stack.popLast() { return item }
            return state.deferred.popLast()
        }
    }

    func pop() async -> DirWork? {
        await withCheckedContinuation { (continuation: CheckedContinuation<DirWork?, Never>) in
            let immediate: DirWork?? = lock.withLock { state in
                if state.cancelled { return .some(nil) }
                if let item = state.stack.popLast() { return item }
                if let item = state.deferred.popLast() { return item }
                if state.pending == 0 { return .some(nil) }
                state.waiters.append(continuation)
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func finishedClosingFD() {
        let idle: [CheckedContinuation<DirWork?, Never>] = lock.withLock { state in
            if state.cancelled { return [] }
            state.pending -= 1
            state.openFDs = max(0, state.openFDs - 1)
            guard state.pending == 0 else { return [] }
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in idle { waiter.resume(returning: nil) }
    }

    func noteClosedWithoutWork() {
        lock.withLock { state in
            state.openFDs = max(0, state.openFDs - 1)
        }
    }

    /// Drop every queued fd. Workers still have to close the fd they currently hold.
    func cancel() -> [Int32] {
        let outcome = lock.withLock { state -> (fds: [Int32], waiters: [CheckedContinuation<DirWork?, Never>]) in
            state.cancelled = true
            state.pending = 0
            var fds: [Int32] = []
            fds.append(contentsOf: state.stack.map(\.fd))
            fds.append(contentsOf: state.deferred.map(\.fd))
            state.stack.removeAll()
            state.deferred.removeAll()
            state.openFDs = 0
            let waiters = state.waiters
            state.waiters.removeAll()
            return (fds, waiters)
        }
        for waiter in outcome.waiters { waiter.resume(returning: nil) }
        return outcome.fds
    }
}
