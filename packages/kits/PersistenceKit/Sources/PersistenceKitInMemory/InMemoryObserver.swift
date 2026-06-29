// InMemoryObserver.swift

import Foundation
import PersistenceKit

/// Registry of in-memory change subscriptions.
///
/// Subscriptions live under an `NSLock` rather than actor isolation so
/// that `register` is synchronous: `observe()` records the subscription
/// inline, before it returns the stream, with no fire-and-forget `Task`
/// hop. A change notified immediately after `observe()` therefore cannot
/// race ahead of the subscription being recorded. This mirrors the Rust
/// observer (`rust/src/inmemory.rs` → `ObserverHub::subscribe`), which
/// registers synchronously inside `observe`.
final class ObserverRegistry: @unchecked Sendable {
    struct Subscription {
        let id: UUID
        let table: String
        let events: Set<StorageEvent>
        let continuation: AsyncStream<TableChange>.Continuation
    }

    struct BlobSubscription {
        let id: UUID
        let continuation: AsyncStream<BlobChange>.Continuation
    }

    struct DirtyChainSubscription {
        let id: UUID
        let continuation: AsyncStream<DirtyChainEvent>.Continuation
    }

    // `subs`, `blobSubs`, and `dirtyChainSubs` are accessed exclusively
    // under `lock`; that discipline is what makes the `@unchecked Sendable`
    // conformance sound.
    private let lock = NSLock()
    private var subs: [UUID: Subscription] = [:]
    private var blobSubs: [UUID: BlobSubscription] = [:]
    private var dirtyChainSubs: [UUID: DirtyChainSubscription] = [:]

    /// Record a row subscription and return its stream. Synchronous.
    func register(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TableChange>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        lock.lock()
        subs[id] = Subscription(id: id, table: table, events: events, continuation: continuation)
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.remove(id: id)
        }
        return stream
    }

    /// Record a blob subscription and return its stream. Synchronous.
    func registerBlobs() -> AsyncStream<BlobChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BlobChange>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        lock.lock()
        blobSubs[id] = BlobSubscription(id: id, continuation: continuation)
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.removeBlobSub(id: id)
        }
        return stream
    }

    private func remove(id: UUID) {
        lock.lock()
        subs.removeValue(forKey: id)
        lock.unlock()
    }

    private func removeBlobSub(id: UUID) {
        lock.lock()
        blobSubs.removeValue(forKey: id)
        lock.unlock()
    }

    /// Snapshot the subscriptions whose filter matches `change`.
    ///
    /// The lock is taken and released entirely within this synchronous
    /// method — `NSLock` is unavailable across an `await`, so the locked
    /// region must not span a suspension point.
    private func subscriptions(matching change: TableChange) -> [Subscription] {
        lock.lock()
        defer { lock.unlock() }
        return subs.values.filter { $0.table == change.table && $0.events.contains(change.event) }
    }

    private func allBlobSubscriptions() -> [BlobSubscription] {
        lock.lock()
        defer { lock.unlock() }
        return Array(blobSubs.values)
    }

    /// Deliver `change` to every matching row subscription.
    ///
    /// Declared `async` to preserve the awaited call site in
    /// `InMemoryStateActor.notify`, which keeps delivery ordered with
    /// respect to the mutations that produced each change. The matching
    /// subscriptions are snapshotted under the lock and yielded to outside
    /// it, so a continuation's `onTermination` (which also takes the lock)
    /// cannot contend with an in-flight notify.
    func notify(_ change: TableChange) async {
        for sub in subscriptions(matching: change) {
            sub.continuation.yield(change)
        }
    }

    /// Deliver `change` to every blob subscription.
    func notifyBlob(_ change: BlobChange) async {
        for sub in allBlobSubscriptions() {
            sub.continuation.yield(change)
        }
    }

    // MARK: - Dirty-chain subscriptions

    /// Record a dirty-chain subscription and return its stream. Synchronous.
    func registerDirtyChain() -> AsyncStream<DirtyChainEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DirtyChainEvent>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        lock.lock()
        dirtyChainSubs[id] = DirtyChainSubscription(id: id, continuation: continuation)
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.removeDirtyChainSub(id: id)
        }
        return stream
    }

    private func removeDirtyChainSub(id: UUID) {
        lock.lock()
        dirtyChainSubs.removeValue(forKey: id)
        lock.unlock()
    }

    private func allDirtyChainSubscriptions() -> [DirtyChainSubscription] {
        lock.lock()
        defer { lock.unlock() }
        return Array(dirtyChainSubs.values)
    }

    /// Deliver `event` to every dirty-chain subscription.
    func notifyDirtyChain(_ event: DirtyChainEvent) async {
        for sub in allDirtyChainSubscriptions() {
            sub.continuation.yield(event)
        }
    }
}

final class InMemoryObserver: StorageObserver, Sendable {
    let registry: ObserverRegistry

    init(registry: ObserverRegistry) {
        self.registry = registry
    }

    func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        // `register` records the subscription synchronously and returns its
        // stream, so the subscription is live before `observe()` returns —
        // no bridge Task, no window for an immediately-following insert to
        // race ahead of registration. Mirrors the Rust observer, which
        // returns `hub.subscribe(...)` directly.
        registry.register(table: table, events: events)
    }

    func observeBlobs() -> AsyncStream<BlobChange> {
        registry.registerBlobs()
    }

    func observeDirtyChain() -> AsyncStream<DirtyChainEvent> {
        registry.registerDirtyChain()
    }
}
