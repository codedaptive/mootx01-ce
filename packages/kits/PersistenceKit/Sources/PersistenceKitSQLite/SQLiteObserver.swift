// SQLiteObserver.swift
//
// SQLite change notification via sqlite3_update_hook. Each
// connection can register one update hook; we route through a
// shared registry that fans out to subscribers per table.

import Foundation
import PersistenceKit
import CSQLiteVec

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

    private var subs: [UUID: Subscription] = [:]

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
}
