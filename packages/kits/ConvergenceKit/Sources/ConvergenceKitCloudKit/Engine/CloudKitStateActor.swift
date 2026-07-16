// CloudKitStateActor.swift
//
// Actor shell for CloudKitSyncEngine. Owns all mutable sync state:
// container, manifest, storage, observer tasks, subscriber continuations,
// pending outbound queue, HLC generator, server change token, and the
// enable/disable lifecycle.
//
// Push, pull, conflict-policy application, sync-meta side table,
// and clock helpers live in sibling files under Engine/:
//   PushCycle.swift       — outbound push path
//   PullCycle.swift       — inbound pull + deletion path
//   ApplyInbound.swift    — conflict-policy apply switch
//   SyncMetaStore.swift   — _ck_sync_meta side table
//   EngineClock.swift     — nowMillis() helper

import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
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
import os

private let logger = Logger(subsystem: "com.mootx01.synckit.cloudkit", category: "Engine")

// MARK: - State actor

actor CloudKitStateActor {
    let containerIdentifier: String?
    private var _container: CKContainer?
    var container: CKContainer {
        if let c = _container { return c }
        let c: CKContainer
        if let id = containerIdentifier {
            c = CKContainer(identifier: id)
        } else {
            c = CKContainer.default()
        }
        _container = c
        return c
    }
    var manifest: SyncManifest?
    var storage: (any Storage)?
    var isEnabled: Bool = false
    var lastPushAt: Date?
    var lastPullAt: Date?
    var serverChangeToken: CKServerChangeToken?
    var pendingOutbound: [TableChange] = []
    var observerTasks: [Task<Void, Never>] = []
    var subscribers: [AsyncStream<SyncEvent>.Continuation] = []
    /// Monotonic HLC source for locally-originated changes that
    /// reach the push path without an HLC of their own. nodeID is
    /// drawn from the low nibble per the substrate's 4-bit node
    /// field; a fresh send() preserves per-replica monotonicity
    /// rather than fabricating a colliding nodeID-0 timestamp.
    var hlcGenerator = HLCGenerator(nodeID: Int32.random(in: 1...0x0F))

    init(containerIdentifier: String?) {
        self.containerIdentifier = containerIdentifier
    }

    func enable(manifest: SyncManifest, storage: any Storage) async throws {
        if isEnabled { throw SyncError.alreadyEnabled }
        self.manifest = manifest
        self.storage = storage

        // Setup zone in private database.
        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
        } catch {
            // Zone might already exist; that's fine.
            logger.info("zone setup (may already exist): \(String(describing: error))")
        }

        // Ensure the _ck_sync_meta side table exists before any pull (#12 fix).
        try await Self.ensureSyncMetaTable(storage: storage)

        // Ensure the _ck_change_token side table exists, then restore the
        // persisted token so the first pull resumes from where the previous
        // process left off rather than re-pulling the entire zone. R5.
        try await TokenStore.ensure(storage: storage)
        serverChangeToken = try await TokenStore.load(zoneName: manifest.zoneIdentifier, storage: storage)

        // Start observing each declared table that is not pull-only.
        for table in manifest.tables where table.direction != .pullOnly {
            let stream = storage.observer.observe(table: table.name, events: [.insert, .update, .delete])
            let task = Task { [weak self] in
                for await change in stream {
                    await self?.recordOutbound(change)
                }
            }
            observerTasks.append(task)
        }

        isEnabled = true
    }

    func disable() async {
        isEnabled = false
        for task in observerTasks { task.cancel() }
        observerTasks.removeAll()
        for sub in subscribers { sub.finish() }
        subscribers.removeAll()
        pendingOutbound.removeAll()
        manifest = nil
        storage = nil
    }

    func attachSubscriber(_ continuation: AsyncStream<SyncEvent>.Continuation) {
        subscribers.append(continuation)
    }

    func emit(_ event: SyncEvent) {
        for sub in subscribers {
            sub.yield(event)
        }
    }

    func recordOutbound(_ change: TableChange) {
        pendingOutbound.append(change)
    }

    var currentState: SyncState {
        if let m = manifest, isEnabled {
            return .enabled(zone: m.zoneIdentifier, lastPushAt: lastPushAt, lastPullAt: lastPullAt)
        }
        return .disabled
    }
}
