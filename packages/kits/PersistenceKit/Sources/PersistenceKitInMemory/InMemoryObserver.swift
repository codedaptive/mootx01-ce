// InMemoryObserver.swift

import Foundation
import PersistenceKit

actor ObserverRegistry {
    struct Subscription {
        let id: UUID
        let table: String
        let events: Set<StorageEvent>
        let continuation: AsyncStream<TableChange>.Continuation
    }

    private var subs: [UUID: Subscription] = [:]

    func register(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        let id = UUID()
        let stream = AsyncStream<TableChange>(bufferingPolicy: .bufferingOldest(1024)) { continuation in
            let sub = Subscription(id: id, table: table, events: events, continuation: continuation)
            Task { await self.add(sub) }  // actor hop; await is required
            continuation.onTermination = { _ in
                Task { await self.remove(id: id) }
            }
        }
        return stream
    }

    private func add(_ sub: Subscription) {
        subs[sub.id] = sub
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

final class InMemoryObserver: StorageObserver, Sendable {
    let registry: ObserverRegistry

    init(registry: ObserverRegistry) {
        self.registry = registry
    }

    func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        // Bridge async registration through a passthrough stream.
        let (stream, continuation) = AsyncStream<TableChange>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        let bridgeTask = Task {
            let inner = await registry.register(table: table, events: events)
            for await change in inner {
                continuation.yield(change)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in bridgeTask.cancel() }
        return stream
    }
}
