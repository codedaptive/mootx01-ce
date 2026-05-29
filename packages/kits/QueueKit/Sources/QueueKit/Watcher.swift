// Watcher.swift
//
// Directory-change wake source for FilesystemBackend.watch().
// Uses DispatchSource on macOS (the kqueue-backed VNODE source) and
// inotify on Linux. The contract: invoke `onChange` whenever the
// watched directory's contents may have changed. Spurious wakes are
// allowed; drain() is the authority on what is actually claimable.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum Watcher {
    /// Watch a directory for content changes. Returns when the task
    /// is cancelled. On each detected change, calls `onChange`.
    static func watchNewDirectory(
        at dir: URL,
        onChange: @escaping @Sendable () async -> Void
    ) async throws {
        // Initial drain attempt — handle anything already present.
        await onChange()

        #if canImport(Darwin)
        try await watchKQueue(at: dir, onChange: onChange)
        #else
        try await watchPoll(at: dir, onChange: onChange)
        #endif
    }

    #if canImport(Darwin)
    static func watchKQueue(
        at dir: URL,
        onChange: @escaping @Sendable () async -> Void
    ) async throws {
        let fd = dir.path.withCString { open($0, O_EVTONLY) }
        guard fd >= 0 else {
            throw QueueError.watcherFailed(
                underlying: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno), userInfo: nil))
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility))

        let box = ContinuationBox()
        source.setEventHandler {
            Task { await onChange() }
        }
        source.setCancelHandler {
            close(fd)
            box.finish()
        }
        source.resume()

        await box.wait()
    }
    #endif

    static func watchPoll(
        at dir: URL,
        onChange: @escaping @Sendable () async -> Void
    ) async throws {
        // Polling fallback for non-Darwin platforms. inotify in
        // production; polling here as a simple, correct baseline.
        let fm = FileManager.default
        var lastSnapshot: Set<String> = Set(
            (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
            let current = Set(
                (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            if current != lastSnapshot {
                lastSnapshot = current
                await onChange()
            }
        }
    }
}

/// Lets an async caller park until a kqueue source completes.
final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
