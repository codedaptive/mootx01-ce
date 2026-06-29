// QueueBackend.swift
//
// Per QUEUEKIT_SPEC §4. The protocol every backend conforms to.
// The public QueueKit class delegates all operations to its mounted
// backend.

import Foundation

public protocol QueueBackend: Sendable {
    func write(_ job: Job) async throws

    /// Enqueue many jobs in one pass — the bulk twin of `write`, for a bulk
    /// producer (the post-import reindex enqueuing tens of thousands of encode
    /// jobs). FilesystemBackend's per-job `write` fsyncs each file and `new/`; over
    /// a bulk enqueue that serial-fsyncs a full core. The default loops `write`;
    /// FilesystemBackend overrides it to write all files and fsync `new/` ONCE.
    /// SEPARATE from `write`, so per-job streaming durability is unchanged — only
    /// the bulk caller (jobs reconstructable from the estate via reindex on the
    /// next resume) opts into the batched barrier. Rust twin:
    /// `QueueBackend::write_batch`.
    func writeBatch(_ jobs: [Job]) async throws -> Int

    func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)]

    /// Returns the number of jobs currently waiting to be claimed (status = "new"
    /// for PersistenceKitBackend; files in `new/` for FilesystemBackend).
    /// Used by QueueKitTelemetry to compute depth and idle_nonempty.
    func pendingCount() async throws -> Int

    func watch(
        handler: @escaping @Sendable (Job, SessionID) async throws -> Void
    ) async throws

    func complete(
        _ jobID: JobID,
        status: ObservationStatus,
        artifacts: [ArtifactRef]
    ) async throws

    /// Complete many in-flight jobs in one pass — the batch twin of `complete`.
    /// Retires a whole drained batch without the per-job overhead `complete`
    /// pays: FilesystemBackend's per-job `complete` rescans `cur/` to locate each
    /// job's file (O(N²) over a batch) and fsyncs per job. The default loops
    /// `complete`; FilesystemBackend overrides it with one `cur/` scan and a
    /// single batched directory fsync. Completions carry no artifacts — a drain
    /// replies terminal with none. Returns the number completed. Mirrors the Rust
    /// twin's `QueueBackend::complete_batch`.
    func completeBatch(
        _ completions: [(jobID: JobID, status: ObservationStatus)]
    ) async throws -> Int

    func inFlight() async throws -> [Job]

    func completed(streamID: StreamID?) async throws -> [Job]

    // MARK: - Stream-scoped drain (ADR-021 Decision 7 / T1)

    /// Claim and return only the pending jobs that belong to `stream`.
    ///
    /// Allows multiple consumers (encode, dreaming, signals) to share one
    /// per-estate queue without stealing each other's jobs. The
    /// `(stream_id, status)` index means the predicate is cheap on the PK
    /// backend; the Filesystem backend filters by decoding each `new/` file
    /// and matching `job.streamID`. Backends that host a single stream may
    /// leave the default: it delegates to the all-streams `drainAvailable()`,
    /// which is correct when only one stream is present. Rust twin:
    /// `QueueBackend::drain_available_for_stream`.
    func drainAvailable(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)]

    /// Count pending jobs (status = "new") belonging to `stream` only.
    ///
    /// Used by the governor / dreaming trigger to ask "is there dreaming work
    /// right now?" without claiming anything. The default delegates to
    /// `pendingCount()` (conservative: may over-count in multi-stream queues;
    /// backends that host only one stream are unaffected). Rust twin:
    /// `QueueBackend::pending_count_for_stream`.
    func pendingCount(stream: StreamID) async throws -> Int
}

public extension QueueBackend {
    /// Default stream-scoped drain: delegates to the all-streams drain.
    /// Correct for single-stream backends; overridden by PersistenceKitBackend
    /// and FilesystemBackend for true per-stream isolation.
    func drainAvailable(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)] {
        // Filter the all-streams result to only this stream's jobs. This is
        // correct but claims ALL new jobs (other streams' jobs are claimed and
        // must be re-enqueued). Concrete backends MUST override this to avoid
        // cross-stream claiming in multi-stream deployments.
        let all = try await drainAvailable()
        return all.filter { $0.job.streamID == stream }
    }

    /// Default stream-scoped pending count: delegates to the all-streams count.
    /// Safe for single-stream backends; PersistenceKitBackend and
    /// FilesystemBackend override with an exact per-stream count.
    func pendingCount(stream: StreamID) async throws -> Int {
        try await pendingCount()
    }
}

public extension QueueBackend {
    /// Default batch enqueue: loop `write`. Correct for every backend;
    /// FilesystemBackend overrides for the one-fsync bulk path.
    func writeBatch(_ jobs: [Job]) async throws -> Int {
        var written = 0
        for job in jobs {
            try await write(job)
            written += 1
        }
        return written
    }

    /// Default batch completion: loop `complete`. Correct for every backend
    /// (PersistenceKit has no directory to scan); FilesystemBackend overrides
    /// for the cheap one-scan/one-fsync path.
    func completeBatch(
        _ completions: [(jobID: JobID, status: ObservationStatus)]
    ) async throws -> Int {
        var completed = 0
        for c in completions {
            try await complete(c.jobID, status: c.status, artifacts: [])
            completed += 1
        }
        return completed
    }
}
