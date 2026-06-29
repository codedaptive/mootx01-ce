// PersistenceKitBackend.swift
//
// Per QUEUEKIT_SPEC §10 v1.1. Stores jobs in a PersistenceKit table. The
// backend takes any `Storage` instance and uses only the public
// PersistenceKit surface: rowStore for reads and writes,
// transaction(isolation:) for the atomic claim, and
// observer.observe(table:events:) for watch().
//
// Five v1.1 invariants enforced:
//   1. write() is a bare rowStore.insert, no enclosing transaction.
//   2. watch() treats the observer event as a wake signal; jobs are
//      read through drainAvailable(), never from TableChange.values.
//   3. The claim runs at .serializable with a status="new" guard.
//   4. Indices declared on (status), (status,phys,logical,node),
//      (stream_id,status).
//   5. The table is mutable; appendOnly is never set.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes
import PersistenceKit

public let queueKitTableName = "queuekit_jobs"

public enum QueueKitSchema {
    public static let kitID = "QueueKit"
    public static let version = 1

    public static func declaration() -> SchemaDeclaration {
        let table = TableDeclaration(
            name: queueKitTableName,
            columns: [
                ColumnDeclaration(name: "id", type: .text),
                ColumnDeclaration(name: "stream_id", type: .text),
                ColumnDeclaration(name: "physical_time", type: .int),
                ColumnDeclaration(name: "logical_count", type: .int),
                ColumnDeclaration(name: "node_id", type: .int),
                ColumnDeclaration(name: "priority", type: .int,
                    defaultValue: .int(50)),
                ColumnDeclaration(name: "status", type: .text),
                ColumnDeclaration(name: "payload", type: .blob),
                ColumnDeclaration(name: "extensions", type: .text),
                ColumnDeclaration(name: "signal_status",
                    type: .text, nullable: true),
                ColumnDeclaration(name: "artifacts",
                    type: .text, nullable: true),
                ColumnDeclaration(name: "session_id",
                    type: .text, nullable: true),
            ],
            primaryKey: ["id"],
            appendOnly: false)  // MUST remain false per spec §10
        let indices = [
            IndexDeclaration(
                name: "idx_queuekit_status",
                table: queueKitTableName,
                columns: ["status"]),
            IndexDeclaration(
                name: "idx_queuekit_claim_order",
                table: queueKitTableName,
                columns: ["status", "physical_time",
                          "logical_count", "node_id"]),
            IndexDeclaration(
                name: "idx_queuekit_stream",
                table: queueKitTableName,
                columns: ["stream_id", "status"]),
        ]
        return SchemaDeclaration(
            kitID: kitID, version: version,
            tables: [table], indices: indices)
    }
}

public final class PersistenceKitBackend: QueueBackend, @unchecked Sendable {
    public let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    public static func openSchema(on storage: any Storage) async throws {
        try await storage.open(schema: QueueKitSchema.declaration())
    }

    // MARK: - write (spec §10 / write)

    public func write(_ job: Job) async throws {
        let extJSON = try WireFormat.encoder.encode(job.extensions)
        let values: [String: TypedValue] = [
            "id": .text(job.id.rawValue),
            "stream_id": .text(job.streamID.rawValue),
            "physical_time": .int(job.submittedAt.physicalTime),
            "logical_count": .int(Int64(job.submittedAt.logicalCount)),
            "node_id": .int(Int64(job.submittedAt.nodeID)),
            "priority": .int(Int64(job.priority)),
            "status": .text("new"),
            "payload": .blob(job.payload),
            "extensions": .text(
                String(data: extJSON, encoding: .utf8) ?? "{}"),
        ]
        do {
            // Bare insert per spec §10 — DO NOT wrap in transaction.
            _ = try await storage.rowStore.insert(
                table: queueKitTableName, values: values)
        } catch let storageError as StorageError {
            throw QueueError.backendUnavailable(
                detail: "\(storageError)")
        } catch {
            throw QueueError.writeFailed(underlying: error)
        }
    }

    // MARK: - writeBatch (transactional bulk enqueue — T4 perf parity)

    /// Enqueue a batch of jobs in ONE transaction instead of N autocommits.
    ///
    /// The default `QueueBackend.writeBatch` loops `write` (one autocommit per
    /// job on SQLite). On the encrypted SQLite backend this is N write transactions
    /// — the same bottleneck the FilesystemBackend's per-job fsync was on the
    /// maildir. Wrapping all inserts in a single `.readCommitted` transaction
    /// recovers the bulk-enqueue throughput: one begin/commit round-trip regardless
    /// of batch size.
    ///
    /// Isolation is `.readCommitted` (not `.serializable`): these are bare inserts
    /// into `new` rows and do not interact with the drain's claim predicate (which
    /// flips `new` → `cur`). A claim racing a bulk enqueue partitions cleanly: the
    /// claim's `.serializable` UPDATE only sees rows that were `new` when the
    /// claim began; new rows committed by the enqueue after the claim's snapshot
    /// land in the next drain pass. No phantom-read issue. Mirrors spec §10 §10b:
    /// `write()` is a bare insert; `writeBatch` is a transactional multi-insert
    /// with the same isolation guarantees as N sequential `write()` calls, only
    /// cheaper. Rust twin: `PersistenceKitBackend::write_batch`.
    public func writeBatch(_ jobs: [Job]) async throws -> Int {
        guard !jobs.isEmpty else { return 0 }
        let count: Int = try await storage.transaction(isolation: .readCommitted) { txn -> Int in
            var inserted = 0
            for job in jobs {
                let extJSON = try WireFormat.encoder.encode(job.extensions)
                let values: [String: TypedValue] = [
                    "id": .text(job.id.rawValue),
                    "stream_id": .text(job.streamID.rawValue),
                    "physical_time": .int(job.submittedAt.physicalTime),
                    "logical_count": .int(Int64(job.submittedAt.logicalCount)),
                    "node_id": .int(Int64(job.submittedAt.nodeID)),
                    "priority": .int(Int64(job.priority)),
                    "status": .text("new"),
                    "payload": .blob(job.payload),
                    "extensions": .text(
                        String(data: extJSON, encoding: .utf8) ?? "{}"),
                ]
                _ = try await txn.rowStore.insert(
                    table: queueKitTableName, values: values)
                inserted += 1
            }
            return inserted
        }
        return count
    }

    // MARK: - pendingCount (telemetry depth probe)

    public func pendingCount() async throws -> Int {
        // COUNT(*) WHERE status = 'new' — single read, no claim. Used by
        // QueueKitTelemetry to snapshot queue depth without advancing the cursor.
        try await storage.rowStore.count(
            table: queueKitTableName,
            where: .eq(Self.col("status"), .text("new")))
    }

    // MARK: - Stream-scoped drain (ADR-021 Decision 7 / T1)

    /// Claim and return only the pending jobs that belong to `stream`.
    ///
    /// Uses the same serializable bulk-update pattern as `drainAvailable()`,
    /// but adds `AND stream_id = ?` to the claim predicate. The
    /// `idx_queuekit_stream (stream_id, status)` index makes the predicate
    /// cheap. Only this stream's "new" rows are flipped to "cur" under the
    /// batch session; other streams' rows are untouched. Rust twin:
    /// `PersistenceKitBackend::drain_available_for_stream`.
    public func drainAvailable(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)] {
        let session = SessionID.mint()
        let claimed = try await storage.transaction(
            isolation: .serializable
        ) { txn -> [(Job, SessionID)] in
            // 1. Atomically claim every "new" job for this stream into "cur".
            let claimedCount = try await txn.rowStore.update(
                table: queueKitTableName,
                values: [
                    "status": .text("cur"),
                    "session_id": .text(session.rawValue),
                ],
                where: .and([
                    .eq(Self.col("status"), .text("new")),
                    .eq(Self.col("stream_id"), .text(stream.rawValue)),
                ]))
            guard claimedCount > 0 else { return [] }

            // 2. Read back EXACTLY the rows this call claimed (by session), in
            //    HLC order. Same serializable transaction, so the read sees the
            //    update's own writes.
            let rows = try await txn.rowStore.query(
                table: queueKitTableName,
                where: .and([
                    .eq(Self.col("status"), .text("cur")),
                    .eq(Self.col("session_id"), .text(session.rawValue)),
                ]),
                orderBy: [
                    OrderClause(column: Self.col("physical_time")),
                    OrderClause(column: Self.col("logical_count")),
                    OrderClause(column: Self.col("node_id")),
                ],
                limit: nil, offset: nil)

            var out: [(Job, SessionID)] = []
            out.reserveCapacity(rows.count)
            for row in rows {
                if let job = Self.decodeRow(row) {
                    out.append((job, session))
                }
            }
            return out
        }
        return claimed.sorted { $0.0.submittedAt < $1.0.submittedAt }
    }

    /// Count pending jobs (status = "new") belonging to `stream` only.
    ///
    /// Uses `idx_queuekit_stream (stream_id, status)` — no cursor advance.
    /// Rust twin: `PersistenceKitBackend::pending_count_for_stream`.
    public func pendingCount(stream: StreamID) async throws -> Int {
        try await storage.rowStore.count(
            table: queueKitTableName,
            where: .and([
                .eq(Self.col("status"), .text("new")),
                .eq(Self.col("stream_id"), .text(stream.rawValue)),
            ]))
    }

    // MARK: - drainAvailable (spec §10 / .serializable guarded claim)

    public func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)] {
        // SINGLE-PASS CLAIM. One guarded bulk UPDATE flips every available
        // ("new") job to "cur" under this call's unique batch session, then we
        // read the claimed rows back BY THAT SESSION. This replaces the prior N
        // single-row guarded updates — each an O(N) predicate scan — which made a
        // bulk claim O(N²) in queue depth and the dominant cost of a 40k import.
        // The bulk update is one O(N) pass; the session-tagged read-back is
        // another, so a whole batch claims in O(N).
        //
        // Reading back by the call's UNIQUE session (not by status="cur") keeps
        // the claim robust under any isolation model: a concurrent drainer's rows
        // carry a different session, so the two partition the "new" frontier and
        // never double-count a job. spec §10 invariant 3 (the claim is still a
        // status-guarded atomic new→cur transition).
        let session = SessionID.mint()
        let claimed = try await storage.transaction(
            isolation: .serializable
        ) { txn -> [(Job, SessionID)] in
            // 1. Atomically claim EVERY "new" job into "cur" under this session.
            let claimedCount = try await txn.rowStore.update(
                table: queueKitTableName,
                values: [
                    "status": .text("cur"),
                    "session_id": .text(session.rawValue),
                ],
                where: .eq(Self.col("status"), .text("new")))
            guard claimedCount > 0 else { return [] }

            // 2. Read back EXACTLY the rows this call claimed (by session), in HLC
            //    order. Same serializable transaction, so the read sees the
            //    update's own writes.
            let rows = try await txn.rowStore.query(
                table: queueKitTableName,
                where: .and([
                    .eq(Self.col("status"), .text("cur")),
                    .eq(Self.col("session_id"), .text(session.rawValue)),
                ]),
                orderBy: [
                    OrderClause(column: Self.col("physical_time")),
                    OrderClause(column: Self.col("logical_count")),
                    OrderClause(column: Self.col("node_id")),
                ],
                limit: nil, offset: nil)

            var out: [(Job, SessionID)] = []
            out.reserveCapacity(rows.count)
            for row in rows {
                if let job = Self.decodeRow(row) {
                    out.append((job, session))
                }
            }
            return out
        }
        // HLC ascending — the query already orders; kept explicit so the final
        // contract is port-identical with the Rust drain_available.
        return claimed.sorted { $0.0.submittedAt < $1.0.submittedAt }
    }

    // MARK: - completeSession (single-pass batch completion)

    /// Complete EVERY in-flight ("cur") job claimed under `session` in one pass,
    /// flipping them to terminal `status`. Returns the number completed.
    ///
    /// The single-pass twin of the session-batched `drainAvailable` claim: a
    /// drain worker that claimed a whole batch under one session retires the
    /// whole batch with ONE guarded bulk update instead of N per-job `complete`
    /// calls (each an O(N) predicate scan → O(N²) per batch — the second half of
    /// the bulk-import wall, alongside the claim). Artifacts are empty: the batch
    /// fast path carries none; a job that needs artifacts uses per-job `complete`.
    ///
    /// Inherent (not on `QueueBackend`): only the PersistenceKit backend drives
    /// the encode drain, and the concrete handle is held there. The guard is
    /// status="cur", so any job already completed individually (e.g. an
    /// undecodable job replied "blocked" before this call) is untouched. Mirrors
    /// the Rust `PersistenceKitBackend::complete_session`.
    @discardableResult
    public func completeSession(
        _ session: SessionID,
        status: ObservationStatus
    ) async throws -> Int {
        guard status.isTerminal else {
            throw QueueError.invalidTerminalStatus(status)
        }
        let artifactsJSON = try WireFormat.encoder.encode([ArtifactRef]())
        let artifactsText = String(data: artifactsJSON, encoding: .utf8) ?? "[]"
        return try await storage.transaction(isolation: .serializable) { txn -> Int in
            try await txn.rowStore.update(
                table: queueKitTableName,
                values: [
                    "status": .text("done"),
                    "signal_status": .text(status.rawValue),
                    "artifacts": .text(artifactsText),
                ],
                where: .and([
                    .eq(Self.col("session_id"), .text(session.rawValue)),
                    .eq(Self.col("status"), .text("cur")),
                ]))
        }
    }

    // MARK: - watch (spec §10 / observer wake)

    public func watch(
        handler: @escaping @Sendable (Job, SessionID) async throws -> Void
    ) async throws {
        let stream = storage.observer.observe(
            table: queueKitTableName, events: [.insert])
        // Drain anything already present BEFORE awaiting events, so a job
        // enqueued between mount and this subscription is not stranded in `new/`
        // (its insert event predates the observe() above and would otherwise be
        // lost). Parity with the Rust PersistenceKitBackend.watch and the Swift
        // FilesystemBackend.watch, both of which drain-first.
        try await Self.drainUntilEmpty(self, handler)
        for await _ in stream {
            // Event payload is wake-only per spec §10 "Observer timing".
            // Re-read through drainAvailable() — and keep draining until the
            // queue is empty. Draining-until-empty (not once-per-event) is what
            // makes watch LOAD-robust: under a burst the observer may coalesce
            // inserts (fewer events than rows) or a wake may be dropped while a
            // serializable claim contends with concurrent inserts; a once-per-
            // event drain would then strand the rows whose wake was coalesced
            // away. Re-draining until empty on every wake guarantees no
            // committed job is left behind.
            try await Self.drainUntilEmpty(self, handler)
        }
    }

    /// Drain the queue repeatedly until a pass claims nothing, handing every
    /// claimed job to `handler`. The loop absorbs coalesced/dropped observer
    /// wakes (see `watch`). A claim error ends the pass (the next wake retries).
    private static func drainUntilEmpty(
        _ backend: PersistenceKitBackend,
        _ handler: @escaping @Sendable (Job, SessionID) async throws -> Void
    ) async throws {
        while true {
            // A claim/read failure must PROPAGATE, not collapse to an empty
            // batch: `(try? ...) ?? []` would make a backend fault look like
            // "queue empty" and end the drain pass silently, stranding any
            // committed jobs until — or past — the next wake. Throwing ends the
            // pass loudly so the caller (watch) surfaces the fault and the next
            // wake retries against a live backend. Parity with the Rust
            // drain_until_empty, which already uses `self.drain_available()?`.
            let batch = try await backend.drainAvailable()
            if batch.isEmpty { return }
            for pair in batch {
                try await handler(pair.0, pair.1)
            }
        }
    }

    // MARK: - complete (spec §10 / guarded update inside .serializable)

    public func complete(
        _ jobID: JobID,
        status: ObservationStatus,
        artifacts: [ArtifactRef]
    ) async throws {
        guard status.isTerminal else {
            throw QueueError.invalidTerminalStatus(status)
        }
        let artifactsJSON = try WireFormat.encoder.encode(artifacts)
        let artifactsText = String(
            data: artifactsJSON, encoding: .utf8) ?? "[]"
        let affected = try await storage.transaction(
            isolation: .serializable
        ) { txn -> Int in
            try await txn.rowStore.update(
                table: queueKitTableName,
                values: [
                    "status": .text("done"),
                    "signal_status": .text(status.rawValue),
                    "artifacts": .text(artifactsText),
                ],
                where: .and([
                    .eq(Self.col("id"), .text(jobID.rawValue)),
                    .eq(Self.col("status"), .text("cur")),
                ]))
        }
        if affected == 0 {
            throw QueueError.jobNotFound(jobID)
        }
    }

    // MARK: - reclaimInFlight (crash-recovery primitive)

    /// Reset every stale in-flight ("cur") job for `stream` back to "new", clearing
    /// the session_id so the next `drainAvailable(stream:)` re-claims and re-drives
    /// them. Returns the count reclaimed.
    ///
    /// SAFETY: this must only be called when the caller has JUST acquired the stream's
    /// `DrainLease` via `tryAcquire`. A freshly-acquired lease means the prior holder
    /// is dead (crashed or cleanly exited), so every "cur" row for this stream is an
    /// orphan — no live drainer is processing it. The lease-TTL gate is the guarantee:
    /// `tryAcquire` succeeds only when the prior lease is absent OR stale (heartbeat
    /// older than TTL = 15 s), so another drainer cannot hold a fresh lease at the same
    /// time. This rules out yanking a "cur" job out from under a live drainer.
    ///
    /// Idempotent + crash-safe: reclaimed jobs land in "new", are re-drained, and
    /// re-ingested. Ingest is content-addressed, so re-processing a reclaimed job is
    /// harmless. Mirrors `FilesystemBackend.reclaimInFlight()` but stream-scoped (the
    /// shared queue carries multiple streams — only reset this stream's "cur" rows,
    /// never another stream's). Rust twin:
    /// `PersistenceKitBackend::reclaim_in_flight_for_stream`.
    @discardableResult
    public func reclaimInFlight(stream: StreamID) async throws -> Int {
        try await storage.transaction(isolation: .serializable) { txn -> Int in
            try await txn.rowStore.update(
                table: queueKitTableName,
                values: [
                    "status": .text("new"),
                    "session_id": .null,
                ],
                where: .and([
                    .eq(Self.col("status"), .text("cur")),
                    .eq(Self.col("stream_id"), .text(stream.rawValue)),
                ]))
        }
    }

    // MARK: - inFlight / completed

    public func inFlight() async throws -> [Job] {
        try await listJobs(status: "cur", streamID: nil)
    }

    public func completed(streamID: StreamID?) async throws -> [Job] {
        try await listJobs(status: "done", streamID: streamID)
    }

    private static func col(_ n: String) -> Column {
        Column(table: queueKitTableName, name: n)
    }

    private func listJobs(
        status: String, streamID: StreamID?
    ) async throws -> [Job] {
        var preds: [StoragePredicate] = [
            .eq(Self.col("status"), .text(status))]
        if let s = streamID {
            preds.append(.eq(Self.col("stream_id"), .text(s.rawValue)))
        }
        let rows = try await storage.rowStore.query(
            table: queueKitTableName,
            where: .all(preds),
            orderBy: [
                OrderClause(column: Self.col("physical_time")),
                OrderClause(column: Self.col("logical_count")),
                OrderClause(column: Self.col("node_id")),
            ],
            limit: nil, offset: nil)
        return rows.compactMap { Self.decodeRow($0) }
    }

    private static func decodeRow(_ row: StorageRow) -> Job? {
        guard
            case .text(let id) = row["id"],
            case .text(let stream) = row["stream_id"],
            case .int(let phys) = row["physical_time"],
            case .int(let logical) = row["logical_count"],
            case .int(let node) = row["node_id"],
            case .int(let prio) = row["priority"],
            case .blob(let payload) = row["payload"],
            case .text(let extJSON) = row["extensions"]
        else { return nil }
        let exts: [String: CodableValue]
        if let data = extJSON.data(using: .utf8),
           let parsed = try? WireFormat.decoder.decode(
            [String: CodableValue].self, from: data) {
            exts = parsed
        } else {
            exts = [:]
        }
        let hlc = HLC(
            physicalTime: phys,
            logicalCount: Int32(truncatingIfNeeded: logical),
            nodeID: Int32(truncatingIfNeeded: node))
        return Job(
            id: JobID(rawValue: id),
            streamID: StreamID(rawValue: stream),
            submittedAt: hlc,
            priority: Int(prio),
            payload: payload,
            extensions: exts)
    }
}
