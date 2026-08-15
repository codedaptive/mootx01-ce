// CorpusReindexLatch.swift
//
// The "reindex owed" snap-fit latch. Called at the tail of every migration
// that invalidates the dense float embedding lane. Takes no argument — the
// function can only set the latch, never clear it. Clearing happens only
// after a successful rebuild completes.
//
// Protocol (REINDEX_REQUIRED_MIGRATION_DESIGN §3.2):
//   1. Check the reindex stream: if a job already exists, go straight to
//      the bit-set step.
//   2. Enqueue a reindex marker job (best-effort; errors captured, not thrown).
//   3. Read back once — a call that returns without erroring is not proof
//      of a durable row.
//   4. Job confirmed: set the durable manifest flag.
//   5. No job: leave the flag clear, print the deferral line.
//
// Rules (§3.2):
//   • Enqueue first, record after. Bit-without-job is the silent failure.
//   • Verify by read-back, not by trusting the enqueue return value.
//   • No retry loop. The shape reads like it wants a `while`; one attempt
//     only, then out.
//   • Keyed on a fixed stream ID. A second enqueue is a no-op; the stream
//     key deduplicates at the backend.
//   • Called at the tail of the train. N steps produce exactly one rebuild.
//   • Cleared only by a successful rebuild — never here.

import Foundation
import OSLog
import PersistenceKit
import QueueKit
import SubstrateTypes

// OSLog category matches the CorpusKit convention (category = module name).
private let latchLog = Logger(subsystem: "com.mootx01.kit", category: "CorpusKit")

/// The QueueKit stream for reindex marker jobs. Fixed string — a second
/// enqueue on this stream is a no-op rather than a second row. The stream key
/// is the durable backstop; the manifest flag is the fast in-process guard.
///
/// Rust twin: the string literal `"reindex"` in `reindex_latch.rs`.
internal let reindexStreamID = StreamID(rawValue: "reindex")

/// The raw key written into the estate's `manifest` table when a reindex is
/// owed. Written via `storage.rowStore` (the same PersistenceKit surface
/// `DrawerStore.setMeta` uses internally). Cleared only when a successful
/// rebuild completes — not by this function.
///
/// Rust twin: the string literal `"corpus_reindex_required"` in
/// `reindex_latch.rs`.
internal let reindexManifestKey = "corpus_reindex_required"

/// JSON payload for the reindex marker job. Opaque to QueueKit; the drain
/// worker that mission-2 wires will interpret it. A full reindex across all
/// four providers is requested — per-slot scope (§5.2) is mission-2 scope.
private func reindexJobPayload() -> Data {
    Data(#"{"kind":"full_reindex"}"#.utf8)
}

/// Priority for the reindex marker job. Outranks routine encode work (50)
/// so recall quality is restored promptly after a migration, without
/// starving active ingest.
///
/// Per REINDEX_REQUIRED_MIGRATION_DESIGN §3.3: "Priority needs choosing:
/// a post-migration rebuild should outrank routine encode work, since recall
/// is degraded until it completes, without starving ingest of memories the
/// user is actively writing." Encode work runs at 50; reindex chosen at 80.
private let reindexJobPriority = 80

/// Mark that a corpus reindex is owed.
///
/// Enqueues a marker job on the fixed `"reindex"` stream, reads back once to
/// confirm durability, and sets an estate-manifest flag only when the job
/// exists. No argument, no retry loop — one attempt, one verification, then
/// out. N calls from N migration steps produce exactly one queued rebuild.
///
/// When the enqueue does not take, prints the deferral line to stdout and
/// returns without error. The daily maintenance duty heals the miss within
/// a day (REINDEX_REQUIRED_MIGRATION_DESIGN §3.4).
///
/// - Parameters:
///   - queue: The estate's shared `queue.sqlite`-backed `QueueKit`.
///   - storage: The estate storage; `rowStore` is used to write the manifest
///     flag. The caller must ensure `storage` is open and writable.
///   - now: The caller's timestamp — this function never calls `Date()`.
public func reindexRequired(queue: QueueKit, storage: any Storage, now: Date) async throws {
    // Step 1: check whether the stream already carries a pending job from a
    // prior latch call on this upgrade run. If so, skip straight to the
    // bit-set step — the job acts as the durable backstop.
    var existingCount = try await queue.pendingCount(stream: reindexStreamID)

    if existingCount == 0 {
        // Step 2: enqueue the reindex marker. Failure is captured and
        // absorbed — the read-back (step 3) is the authoritative check.
        // HLC node 0: upgrade-time stamping is not estate-scoped; an
        // arbitrary low node avoids colliding with the estate's own HLC
        // streams and still produces a monotone timestamp.
        let millis = Int64(max(0, now.timeIntervalSince1970) * 1000)
        var hlc = HLCGenerator(nodeID: 0)
        let stamp = hlc.send(now: millis)
        let job = Job(
            id: JobID.generate(),
            streamID: reindexStreamID,
            submittedAt: stamp,
            priority: reindexJobPriority,
            payload: reindexJobPayload(),
            extensions: [:]
        )
        // Best-effort: do not propagate an enqueue error. The read-back
        // captures any failure by returning 0 instead of 1.
        try? await queue.send(job)

        // Step 3: read back once. A returned-without-error is not proof of
        // a durable row; the pending count IS.
        existingCount = try await queue.pendingCount(stream: reindexStreamID)
    }

    if existingCount > 0 {
        // Step 4: job confirmed — set the durable manifest flag.
        // Uses the same underlying PersistenceKit rowStore operation that
        // DrawerStore.setMeta uses internally (manifest is a plain key-value
        // table in the estate SQLite).
        _ = try await storage.rowStore.upsert(
            table: "manifest",
            values: [
                "key": .text(reindexManifestKey),
                "value": .text("1")
            ],
            conflictColumns: ["key"]
        )
        latchLog.info(
            "CorpusReindexLatch: reindex latch set — job pending on 'reindex' stream"
        )
    } else {
        // Step 5: enqueue did not take. Leave the manifest flag clear so
        // the next `mootx01 upgrade` retries. Print the deferral line to
        // stdout — not stderr, no error marker, no underlying cause
        // (REINDEX_REQUIRED_MIGRATION_DESIGN §3.4 + Bob, 2026-08-14).
        print(
            "  · reindex not scheduled — daily maintenance will rebuild the index.\n"
            + "    Search results may be incomplete until it completes."
        )
    }
}
