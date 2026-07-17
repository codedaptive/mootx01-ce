// CloudKitSyncEngine.swift
//
// CloudKit-backed sync. A generalized SyncCoordinator
// pattern: setup zone, push pending local changes,
// pull remote changes since last token,
// apply via PersistenceKit. No CloudKit subscription is created.
//
// ConvergenceKit-CloudKit listens to StorageObserver for outbound changes
// and queues them for push. On pull, decodes CKRecords into
// DecodedRecord values via CKRecordMapping.decode, then applies through
// rowStore directly (which fires StorageObserver naturally, waking
// downstream watchers).
//
// Engine internals are split across Engine/:
//   CloudKitStateActor.swift  — actor shell, state, enable/disable
//   PushCycle.swift           — outbound push path
//   PullCycle.swift           — inbound pull + deletion path
//   ApplyInbound.swift        — conflict-policy apply switch
//   SyncMetaStore.swift       — _ck_sync_meta side table
//   EngineClock.swift         — nowMillis() helper

import Foundation
import ConvergenceKit
import PersistenceKit

public final class CloudKitSyncEngine: SyncEngine, Sendable {
    let stateActor: CloudKitStateActor
    let containerIdentifier: String?

    /// Construct with a container identifier. Pass nil to use
    /// `CKContainer.default()` at enable() time (requires the host
    /// app to declare an iCloud entitlement). The container is
    /// not resolved until enable() so the engine can be
    /// instantiated in unit tests without iCloud configuration.
    public init(containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
        self.stateActor = CloudKitStateActor(containerIdentifier: containerIdentifier)
    }

    public func enable(manifest: SyncManifest, storage: any Storage) async throws {
        try await stateActor.enable(manifest: manifest, storage: storage)
    }

    public func disable() async throws {
        await stateActor.disable()
    }

    public func push() async throws -> SyncReceipt {
        try await stateActor.push()
    }

    public func pull() async throws -> SyncReceipt {
        try await stateActor.pull()
    }

    public func subscribe() -> AsyncStream<SyncEvent> {
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let task = Task { await stateActor.attachSubscriber(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public var state: SyncState {
        get async { await stateActor.currentState }
    }
}
