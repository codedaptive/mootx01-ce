// Watcher.swift
//
// Directory-change wake source for FilesystemBackend.watch().
//
// Platform strategy:
//   Darwin  — DispatchSource.makeFileSystemObjectSource (kqueue VNODE),
//             event-driven, O(µs) latency. No external dependency.
//   Linux   — inotify (inotify_init1 / inotify_add_watch / poll+read) by
//             default, with automatic 200 ms poll fallback when inotify
//             cannot be established (watch-limit exhausted,
//             `EMFILE`/`ENOMEM`, filesystem that doesn't support inotify).
//   Other   — 200 ms poll (the same fallback used by Linux on setup failure).
//
// Contract: invoke `onChange` whenever the watched directory's contents may
// have changed. Spurious wakes are allowed; drain() is the authority on what
// is actually claimable. Every platform calls `onChange` once before entering
// its wait loop to drain any work already present.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum Watcher {
    /// Watch a directory for content changes. On each detected change, calls
    /// `onChange`. An initial `onChange` fires immediately to drain any work
    /// that arrived before the watcher was attached.
    ///
    /// - Darwin:  DispatchSource kqueue; returns when the source's cancel
    ///            handler fires (call the enclosing Task's cancel).
    /// - Linux:   inotify-evented by default; automatic poll fallback when
    ///            inotify is unavailable. Returns when the task is cancelled.
    /// - Other:   200 ms poll; returns when the task is cancelled.
    static func watchNewDirectory(
        at dir: URL,
        onChange: @escaping @Sendable () async -> Void
    ) async throws {
        // Initial drain: handle anything already present before the watcher
        // attaches. A job written between here and the attach point is caught
        // by the watch path's own drain-before-wait (see each path below).
        await onChange()

        #if canImport(Darwin)
        try await watchKQueue(at: dir, onChange: onChange)
        #elseif os(Linux)
        try await watchLinux(at: dir, onChange: onChange)
        #else
        try await watchPoll(at: dir, onChange: onChange)
        #endif
    }

    // ── Darwin: kqueue via DispatchSource ────────────────────────────────────

    #if canImport(Darwin)
    /// Darwin directory watcher using a kqueue VNODE DispatchSource.
    /// Fires for write, extend, delete, and rename events on the directory fd.
    /// Returns when the dispatch source cancel handler fires (i.e. when the
    /// enclosing Task is cancelled and the source is cancelled externally, or
    /// when the source itself terminates).
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

    // ── Linux: inotify-evented with poll fallback ────────────────────────────

    #if os(Linux)
    /// Linux directory watcher.
    ///
    /// Attempts inotify-evented watching (sub-millisecond latency on IN_MOVED_TO
    /// and IN_CREATE events, which cover the atomic tmp→new job rename). If
    /// inotify is unavailable (kernel watch-limit exhausted, filesystem that
    /// doesn't support inotify, etc.) falls back to 200 ms polling automatically
    /// — the same guarantee, at coarser granularity.
    static func watchLinux(
        at dir: URL,
        onChange: @escaping @Sendable () async -> Void
    ) async throws {
        let ifd = openInotify(at: dir)
        if ifd >= 0 {
            // Evented path: inotify is available. Defer close so it is always
            // released whether we return normally or via thrown error.
            defer { Glibc.close(ifd) }
            try await runInotifyLoop(fd: ifd, onChange: onChange)
        } else {
            // Inotify unavailable — fall back to 200 ms poll. The poll path is
            // shared with non-Darwin non-Linux platforms (where it is the sole
            // watcher). Always correct; the inotify-evented path is lower latency,
            // not a correctness requirement.
            try await watchPoll(at: dir, onChange: onChange)
        }
    }

    /// Attempts to set up an inotify instance watching `dir` for new-file events.
    ///
    /// Returns the ready inotify fd on success, or -1 when inotify is unavailable
    /// (e.g. `EMFILE` / `ENOMEM` / kernel watch-limit exhausted, or a filesystem
    /// that doesn't support inotify such as NFS or certain FUSE mounts).
    ///
    /// Caller must call `Glibc.close(fd)` on the returned fd when it is >= 0.
    ///
    /// Events watched:
    ///   IN_MOVED_TO   — the atomic tmp→new rename that QueueKit uses for
    ///                   O_EXCL job enqueue (the primary event).
    ///   IN_CREATE     — direct file creation (belt-and-suspenders).
    private static func openInotify(at dir: URL) -> Int32 {
        // IN_CLOEXEC prevents fd leakage across exec(). Matches O_CLOEXEC
        // semantics; the kernel constant is defined as O_CLOEXEC in <sys/inotify.h>.
        let ifd = inotify_init1(IN_CLOEXEC)
        guard ifd >= 0 else { return -1 }

        // IN_MOVED_TO catches the atomic tmp→new rename (the primary QueueKit
        // enqueue path). IN_CREATE catches any direct creation as a fallback.
        let mask: UInt32 = IN_CREATE | IN_MOVED_TO
        let wd = dir.path.withCString { inotify_add_watch(ifd, $0, mask) }
        if wd < 0 {
            // add_watch can fail when the per-process or system-wide inotify
            // watch limit is exhausted (ENOSPC / ENOMEM), or on filesystems
            // that don't support inotify. Signal fallback to the caller.
            Glibc.close(ifd)
            return -1
        }
        return ifd
    }

    /// Event loop for an already-initialized inotify fd.
    ///
    /// Uses `poll(2)` with a 500 ms timeout so Task cancellation is detected
    /// within half a second between event batches — inotify fd reads would
    /// otherwise block indefinitely. Each non-empty read drains the kernel event
    /// buffer and triggers one `onChange` call. The onChange handler calls
    /// `drain_available()` upstream, which is the authority on what is claimable;
    /// the inotify event is a wake hint only (spurious wakes are harmless).
    private static func runInotifyLoop(
        fd ifd: Int32,
        onChange: @escaping @Sendable () async -> Void
    ) async throws {
        // 4096-byte buffer fits dozens of `inotify_event` structs per read.
        // We don't parse the events — we just need to drain the fd so it
        // doesn't accumulate unread events between wakes.
        let bufSize: Int = 4096
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        while !Task.isCancelled {
            // poll() with 500 ms timeout — wakes on inotify events or on
            // timeout. The timeout keeps the Task.isCancelled check responsive
            // without introducing a busy-wait spin.
            var pfd = pollfd(fd: ifd, events: Int16(POLLIN), revents: 0)
            // P9-secfix: Swift 6.2 on Linux requires an explicit nfds_t cast
            // for the second argument to poll(); the integer literal 1 became
            // ambiguous after the nfds_t → UInt type alias change in glibc bindings.
            let ret = Glibc.poll(&pfd, nfds_t(1), 500)
            if ret < 0 {
                let err = errno
                if err == EINTR { continue }  // interrupted by signal — retry
                throw QueueError.watcherFailed(
                    underlying: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(err), userInfo: nil))
            }
            guard ret > 0 else { continue }  // timeout — loop to check cancellation

            // Read and discard the inotify event structs to drain the kernel
            // buffer. Multiple renames may batch into one read; a single
            // onChange covers the whole batch since drain_available() scans new/.
            let n = Glibc.read(ifd, buf, bufSize)
            if n > 0 {
                await onChange()
            }
        }
    }
    #endif  // os(Linux)

    // ── Poll fallback: all non-Darwin non-Linux platforms, and Linux fallback ─

    /// 200 ms poll fallback.
    ///
    /// Scans the directory for content changes on a fixed cadence and calls
    /// `onChange` when the snapshot differs from the previous tick. Used:
    ///   - On Linux when inotify is unavailable (watch-limit exhausted,
    ///     unsupported filesystem).
    ///   - On non-Darwin non-Linux platforms as the sole directory watcher.
    ///
    /// Correct and always works. Lower latency than one poll interval only when
    /// a change arrives just after a tick — average latency is 100 ms (half the
    /// 200 ms interval). Returns when the task is cancelled.
    static func watchPoll(
        at dir: URL,
        onChange: @escaping @Sendable () async -> Void
    ) async throws {
        let fm = FileManager.default
        var lastSnapshot: Set<String> = Set(
            (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms poll cadence
            let current = Set(
                (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            if current != lastSnapshot {
                lastSnapshot = current
                await onChange()
            }
        }
    }
}

// ── ContinuationBox ─────────────────────────────────────────────────────────

/// Bridges a DispatchSource cancel handler (on a DispatchQueue callback)
/// back to the async call site. The Darwin kqueue watcher parks here until
/// the source fires its cancel handler.
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
