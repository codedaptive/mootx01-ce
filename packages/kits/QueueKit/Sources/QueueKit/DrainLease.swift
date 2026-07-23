// DrainLease.swift
//
// A stream-keyed, heartbeat-TTL drain lease for QueueKit.
//
// Many processes can open the same durable estate and each can start its own
// drain worker for a given queue stream. This lease guarantees exactly ONE
// drainer per (estate, stream) pair runs at a time, while two DIFFERENT streams
// can each hold their own lease simultaneously — enabling the encode drainer
// and the dreaming drainer to run concurrently without blocking each other.
//
// The lease file is keyed by stream: `<dir>/<stream>.drain.lease`, so streams
// are fully independent — both can be acquired at once.
//
// This is a heartbeat-TTL lease, NOT a PID-liveness check. Portable across
// macOS/Windows/Linux: no FFI, no libc/Win32 OpenProcess, no OS-specific
// process table query. The holder refreshes a wall-clock heartbeat on each
// drain pass; a would-be drainer stands down while the lease is fresh and
// takes it over when it goes stale (holder crashed or exited uncleanly) or
// absent. Worst-case takeover latency is one TTL (15 seconds).
//
// This is the SQLite-first form: the lease file lives beside the durable
// maildir. A Postgres-estate DB-backed lease (row lock or advisory lock) is
// deferred while the queue implementation remains SQLite-first.
//
// Wall-clock here is INFRASTRUCTURE (lease liveness), not the deterministic
// drain engine. Same exception that QueueKit's drain telemetry clock takes.
// Mirrors the Rust `DrainLease` in `drain_lease.rs`.

import Foundation

/// A stream-keyed heartbeat-TTL drain lease.
///
/// One instance per (estate directory, stream) pair. Two different streams
/// produce independent lease files and can both be held simultaneously.
///
/// Owner identity is PID plus a per-process instance token (a nonce passed at
/// construction), so a reused PID after a crash cannot impersonate the prior
/// holder.
///
/// Made `public` (T4) so `CorpusKit` can replace its private `DrainLease` with
/// this shared implementation — the corpus encode drainer and any future drainers
/// (dreaming, signals) all use the same struct, keyed by their stream name.
/// `Sendable`: a pure value type over Sendable stored properties (`URL`,
/// `String`, `TimeInterval`). The conformance lets `Corpus`'s non-isolated
/// `deinit` read a stored `DrainLease?` and call `release()` directly, which
/// avoids the `isolated deinit` form that tripped a cross-module SIL-optimizer
/// cycle under release whole-module optimization. Matches the Rust twin, which
/// is `Send` by construction.
public struct DrainLease: Sendable {
    /// Path to the lease file: `<directory>/<stream>.drain.lease`.
    /// Each stream gets its own file, so leases are fully independent.
    public let leaseURL: URL

    /// Owner token: PID plus the caller-supplied instance nonce.
    /// Example: `"pid-1234-0x00007f..."`.
    public let owner: String

    /// A lease heartbeat older than this is reclaimable (the holder is
    /// presumed gone). 15 s matches the Rust twin's `DRAIN_LEASE_TTL_SECS`.
    public let ttl: TimeInterval

    /// The heartbeat refresh interval the drain loop should use. Callers
    /// heartbeat at this cadence to stay well inside the TTL. 5 s < 15 s TTL.
    /// Matches the Rust twin's `DRAIN_LEASE_HEARTBEAT_SECS`.
    public static let heartbeatInterval: TimeInterval = 5

    /// - Parameters:
    ///   - directory: The durable queue directory for this estate.
    ///   - stream: The stream key (e.g. `"encode"`, `"dreaming"`). Used as the
    ///     lease filename prefix so different streams have independent leases.
    ///   - instanceToken: A per-process nonce that, combined with the PID,
    ///     uniquely identifies this drainer (prevents PID reuse impersonation).
    ///   - ttl: Time-to-live for a heartbeat before the lease is reclaimable.
    ///     Defaults to 15 seconds.
    public init(directory: URL, stream: String, instanceToken: String, ttl: TimeInterval = 15) {
        // Sanitise the stream key so the filename is safe on all platforms.
        let safe = stream.unicodeScalars.map {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
                ? Character($0)
                : Character("_")
        }
        let safeStream = String(safe)
        self.leaseURL = directory.appendingPathComponent("\(safeStream).drain.lease", isDirectory: false)
        self.owner = "pid-\(ProcessInfo.processInfo.processIdentifier)-\(instanceToken)"
        self.ttl = ttl
    }

    // MARK: - Public API

    /// Acquire the lease iff it is absent or expired. Returns `true` iff this
    /// drainer holds the lease after the call.
    ///
    /// If another drainer holds a fresh (non-expired) lease, returns `false`
    /// and the caller should stand down. `now` is the wall-clock instant
    /// (infrastructure — not the deterministic engine).
    public func tryAcquire(now: Date) -> Bool {
        if let held = read(), held.owner != owner, now.timeIntervalSince(held.at) <= ttl {
            return false  // fresh and held by another drainer — stand down
        }
        // Absent, ours, or stale → (re)claim, then re-read to resolve a write
        // race: atomic replace is last-writer-win; the losing writer sees the
        // winner's token on re-read and defers.
        write(now: now)
        return read()?.owner == owner
    }

    /// Refresh the heartbeat while this drainer actively holds the lease.
    ///
    /// Call at `DrainLease.heartbeatInterval` cadence (every ~5 s) while
    /// draining to prevent the lease expiring during a slow drain pass. Does
    /// not check ownership — the caller is responsible for only heartbeating
    /// when it successfully acquired.
    public func heartbeat(now: Date) {
        write(now: now)
    }

    /// Whether another drainer currently holds a fresh (non-expired) lease.
    ///
    /// Returns `true` iff the lease file exists, its heartbeat is within the
    /// TTL, and its owner is not this drainer. Use this to check if standing
    /// down is warranted without attempting an acquire.
    public func isHeldByOther(now: Date) -> Bool {
        guard let held = read() else { return false }
        return held.owner != owner && now.timeIntervalSince(held.at) <= ttl
    }

    /// Release the lease on clean teardown. Removes the lease file so another
    /// drainer can take over immediately rather than waiting out the TTL.
    /// Only removes the file if this drainer still holds it.
    public func release() {
        if read()?.owner == owner {
            try? FileManager.default.removeItem(at: leaseURL)
        }
    }

    // MARK: - File I/O — format: `<owner>\n<epochSeconds>`

    private func read() -> (owner: String, at: Date)? {
        guard let text = try? String(contentsOf: leaseURL, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
              let secs = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return (String(parts[0]), Date(timeIntervalSince1970: secs))
    }

    private func write(now: Date) {
        let body = "\(owner)\n\(now.timeIntervalSince1970)"
        // Atomic replace (atomically: true uses a temp + rename internally) so
        // a concurrent reader never sees a torn file, and concurrent claimers
        // resolve to one last-writer winner.
        try? body.write(to: leaseURL, atomically: true, encoding: .utf8)
    }
}
