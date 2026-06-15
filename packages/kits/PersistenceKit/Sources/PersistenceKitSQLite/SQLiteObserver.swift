// SQLiteObserver.swift
//
// SQLite change notification via sqlite3_update_hook. Each
// connection can register one update hook; we route through a
// shared registry that fans out to subscribers per table.
//
// BLOB OBSERVATION: sqlite3_update_hook fires for every SQLite table,
// including _storagekit_blobs. However, the hook does not carry column
// values — only (operation_type, table_name, rowid). Blob bytes are only
// available at the call site (putBlob/deleteBlob in SQLiteBackend), so
// blob notifications are emitted directly by those methods rather than
// reconstructed from hook data. SQLiteObserverRegistry holds a parallel
// blob-subscriber list; SQLiteBackend calls notifyBlobChange after each
// put/delete. observeBlobs() registers into this list and delivers live
// BlobChange events. The subscriber list is pruned when its continuation
// terminates, mirroring the row-change subscriber pattern.

import Foundation
import PersistenceKit

/// Registry installed on the connection's update_hook callback.
/// Sendable since access is serialized through the SQLiteBackend
/// actor that owns the connection.
actor SQLiteObserverRegistry {
    struct Subscription {
        let id: UUID
        let table: String
        let events: Set<StorageEvent>
        let continuation: AsyncStream<TableChange>.Continuation
    }

    // Row-change subscribers keyed by subscription ID.
    private var subs: [UUID: Subscription] = [:]

    // Blob-change subscribers keyed by subscription ID.
    // Each subscriber receives every BlobChange (there is no per-key filter
    // at the registry level; callers that want key-level filtering do so
    // after receiving the event, which no current caller requires).
    private var blobSubs: [UUID: AsyncStream<BlobChange>.Continuation] = [:]

    func register(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TableChange>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        let sub = Subscription(id: id, table: table, events: events, continuation: continuation)
        subs[id] = sub
        continuation.onTermination = { _ in
            Task { await self.remove(id: id) }
        }
        return stream
    }

    private func remove(id: UUID) {
        subs.removeValue(forKey: id)
    }

    func notify(_ change: TableChange) {
        for sub in subs.values where sub.table == change.table && sub.events.contains(change.event) {
            sub.continuation.yield(change)
        }
    }

    // MARK: - Blob observation

    /// Register a new blob subscriber. Returns an AsyncStream that receives every
    /// subsequent BlobChange (put/delete) on the blob store. The stream terminates
    /// when the continuation is cancelled.
    func registerBlobs() -> AsyncStream<BlobChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BlobChange>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        blobSubs[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeBlobs(id: id) }
        }
        return stream
    }

    private func removeBlobs(id: UUID) {
        blobSubs.removeValue(forKey: id)
    }

    /// Emit a blob change to all active blob subscribers.
    func notifyBlob(_ change: BlobChange) {
        for continuation in blobSubs.values {
            continuation.yield(change)
        }
    }
}

final class SQLiteObserver: StorageObserver, Sendable {
    let registry: SQLiteObserverRegistry

    init(registry: SQLiteObserverRegistry) {
        self.registry = registry
    }

    func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        let (stream, continuation) = AsyncStream<TableChange>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        let bridge = Task {
            let inner = await registry.register(table: table, events: events)
            for await change in inner {
                continuation.yield(change)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in bridge.cancel() }
        return stream
    }

    /// Subscribe to blob put/delete events on the SQLite blob store.
    ///
    /// MECHANISM: sqlite3_update_hook fires for _storagekit_blobs rows (it is
    /// a regular SQLite table), but the hook provides only (op, table, rowid) —
    /// no column values. Blob bytes are only available at the write call site
    /// (putBlob/deleteBlob in SQLiteBackend). SQLiteBackend therefore calls
    /// registry.notifyBlob(_:) directly after each successful put/delete, passing
    /// the key and bytes at the moment of the write. observeBlobs() connects the
    /// caller into the registry's blob-subscriber list so those notifications arrive
    /// as a live async stream.
    ///
    /// INCREMENTAL REPLICATION: IncrementalReplicationSession subscribes via this
    /// method and accumulates events in its BlobDirtySet. The dirty-set is
    /// in-memory, so it is lost on process restart; the caller falls back to a
    /// full-snapshot on restart (same semantics as the row dirty-set). Subscribers
    /// that start after a write missed the event for that write — they rely on
    /// full-snapshot to reach consistency, then track only deltas going forward.
    func observeBlobs() -> AsyncStream<BlobChange> {
        let (stream, continuation) = AsyncStream<BlobChange>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        let bridge = Task {
            let inner = await registry.registerBlobs()
            for await change in inner {
                continuation.yield(change)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in bridge.cancel() }
        return stream
    }
}
