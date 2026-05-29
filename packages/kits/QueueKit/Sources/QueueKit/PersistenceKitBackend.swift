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
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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

    // MARK: - drainAvailable (spec §10 / .serializable guarded claim)

    public func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)] {
        return try await storage.transaction(
            isolation: .serializable
        ) { txn -> [(Job, SessionID)] in
            let rows = try await txn.rowStore.query(
                table: queueKitTableName,
                where: .eq(Self.col("status"), .text("new")),
                orderBy: [
                    OrderClause(column: Self.col("physical_time")),
                    OrderClause(column: Self.col("logical_count")),
                    OrderClause(column: Self.col("node_id")),
                ],
                limit: nil, offset: nil)

            var claimed: [(Job, SessionID)] = []
            for row in rows {
                guard case .text(let rowID) = row["id"] else { continue }
                let session = SessionID.mint()
                let updated = try await txn.rowStore.update(
                    table: queueKitTableName,
                    values: [
                        "status": .text("cur"),
                        "session_id": .text(session.rawValue),
                    ],
                    where: .and([
                        .eq(Self.col("status"), .text("new")),
                        .eq(Self.col("id"), .text(rowID)),
                    ]))
                if updated == 1 {
                    if let job = Self.decodeRow(row) {
                        claimed.append((job, session))
                    }
                }
            }
            claimed.sort { $0.0.submittedAt < $1.0.submittedAt }
            return claimed
        }
    }

    // MARK: - watch (spec §10 / observer wake)

    public func watch(
        handler: @escaping @Sendable (Job, SessionID) async throws -> Void
    ) async throws {
        let stream = storage.observer.observe(
            table: queueKitTableName, events: [.insert])
        for await _ in stream {
            // Event payload is wake-only per spec §10 "Observer
            // timing". Re-read through drainAvailable() so we see
            // only durably committed rows.
            let batch = (try? await drainAvailable()) ?? []
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
