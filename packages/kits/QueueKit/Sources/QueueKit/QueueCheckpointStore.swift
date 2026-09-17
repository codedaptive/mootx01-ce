import Foundation
import Dispatch
import PersistenceKit
import SubstrateTypes

/// Retained operational checkpoints in the existing queue envelope. A checkpoint
/// is not a runnable job and never counts as successful domain work. Its opaque
/// payload owns that distinction. Keep these records when pruning job receipts.
/// PersistenceKit backends only: fail closed instead of silently losing progress.
public struct QueueCheckpointStore: Sendable {
    private let storage: any Storage
    public var isPersistent: Bool {
        if case .inMemory = storage.configuration.backend { return false }
        return true
    }

    public init(queue: QueueKit) throws {
        guard let backend = queue.backend as? PersistenceKitBackend else {
            throw QueueError.backendUnavailable(detail: "checkpoints require PersistenceKit")
        }
        storage = backend.storage
    }

    /// Heartbeats the existing stream lease for the lifetime of a bounded work
    /// batch. Infrastructure clock only; no model or domain policy in QueueKit.
    public func acquireDrainLease(stream: StreamID) throws -> QueueCheckpointLease? {
        switch storage.configuration.backend {
        case .inMemory: return QueueCheckpointLease(nil)
        case .sqlite(let url, _):
            let lease = DrainLease(directory: url.deletingLastPathComponent(),
                stream: stream.rawValue, instanceToken: UUID().uuidString)
            guard lease.tryAcquire(now: Date()) else { return nil }
            return QueueCheckpointLease(lease)
        default: throw QueueError.backendUnavailable(detail: "checkpoint drain lease unavailable for this backend")
        }
    }

    public func read(id: JobID, stream: StreamID) async throws -> Data? {
        let rows = try await storage.rowStore.query(table: queueKitTableName,
            where: Self.predicate(id, stream), orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first else { return nil }
        guard case .blob(let payload) = row["payload"] else {
            throw QueueError.backendUnavailable(detail: "invalid checkpoint payload")
        }
        return payload
    }

    /// Compare-and-swap fences concurrent writers and stale inference results.
    /// `nil` expects absence. The domain owns payload versions and lease expiry.
    @discardableResult
    public func compareAndSwap(
        id: JobID, stream: StreamID, expected: Data?, payload: Data, stamp: HLC
    ) async throws -> Bool {
        try await storage.transaction(isolation: .serializable) { txn in
            let rows = try await txn.rowStore.query(table: queueKitTableName,
                where: Self.predicate(id, stream), orderBy: [], limit: 1, offset: nil)
            if let row = rows.first {
                guard case .blob(let previous) = row["payload"], previous == expected else { return false }
                return try await txn.rowStore.update(table: queueKitTableName,
                    values: ["payload": .blob(payload)], where: Self.predicate(id, stream)) == 1
            }
            guard expected == nil else { return false }
            _ = try await txn.rowStore.insert(table: queueKitTableName, values: [
                "id": .text(id.rawValue), "stream_id": .text(stream.rawValue),
                "physical_time": .int(stamp.physicalTime), "logical_count": .int(Int64(stamp.logicalCount)),
                "node_id": .int(Int64(stamp.nodeID)), "priority": .int(50),
                // A distinct lifecycle value prevents generic done-receipt cleanup
                // from deleting the only copy of resumable domain progress.
                "status": .text("checkpoint"), "payload": .blob(payload),
                "extensions": .text("{\"retainedCheckpoint\":true}"),
            ])
            return true
        }
    }

    /// Remove one retained checkpoint row, if present. A no-op (returns
    /// `false`) when no row matches `id`/`stream` — deleting an already-absent
    /// checkpoint is not an error, the same idempotent posture `remove`d rows
    /// have elsewhere in this store.
    ///
    /// F6: added so a caller that permanently retires the checkpoint's
    /// SUBJECT — an expunged or tombstoned source drawer — can remove the row
    /// outright rather than leaving it retained forever. A retained
    /// checkpoint holds domain evidence (e.g. `GroundedFactCandidate`
    /// evidence quotes for fact extraction); the debt scan that would
    /// otherwise revisit and clean it up excludes tombstoned drawers, so an
    /// un-deleted row for an expunged source is retained indefinitely with
    /// no future pass that will ever look at it again.
    ///
    /// - Returns: `true` if a row was deleted, `false` if none matched.
    @discardableResult
    public func delete(id: JobID, stream: StreamID) async throws -> Bool {
        let deleted = try await storage.rowStore.delete(table: queueKitTableName,
            where: Self.predicate(id, stream))
        return deleted > 0
    }

    public func payloads(stream: StreamID) async throws -> [Data] {
        try await storage.rowStore.query(table: queueKitTableName,
            where: .and([.eq(Self.col("stream_id"), .text(stream.rawValue)),
                         .eq(Self.col("status"), .text("checkpoint"))]),
            orderBy: [], limit: nil, offset: nil).map { row in
                guard case .blob(let value) = row["payload"] else {
                    throw QueueError.backendUnavailable(detail: "invalid checkpoint payload")
                }
                return value
            }
    }

    private static func col(_ name: String) -> Column { Column(table: queueKitTableName, name: name) }
    private static func predicate(_ id: JobID, _ stream: StreamID) -> StoragePredicate {
        .and([.eq(col("id"), .text(id.rawValue)), .eq(col("stream_id"), .text(stream.rawValue)),
              .eq(col("status"), .text("checkpoint"))])
    }
}

public final class QueueCheckpointLease: @unchecked Sendable {
    private let timer: DispatchSourceTimer?
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    init(_ lease: DrainLease?) {
        guard let lease else { timer = nil; return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "queue-checkpoint-lease"))
        self.timer = timer
        timer.schedule(deadline: .now() + DrainLease.heartbeatInterval,
                       repeating: DrainLease.heartbeatInterval)
        timer.setEventHandler { lease.heartbeat(now: Date()) }
        let stopped = self.stopped
        timer.setCancelHandler { lease.release(); stopped.signal() }
        timer.resume()
    }
    public func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        if let timer { timer.cancel(); stopped.wait() }
    }
    deinit { release() }
}
