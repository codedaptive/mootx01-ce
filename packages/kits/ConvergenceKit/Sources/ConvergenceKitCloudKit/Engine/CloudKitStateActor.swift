// CloudKitStateActor.swift
//
// Actor shell for CloudKitSyncEngine. Owns all mutable sync state:
// container, manifest, storage, observer tasks, subscriber continuations,
// HLC generator, server change token, and the enable/disable lifecycle.
// The outbound queue is NOT in-memory state: it is the durable _ck_outbox
// side table (R4), written by recordOutbound and drained by PushCycle.
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
    var observerTasks: [Task<Void, Never>] = []
    var subscribers: [AsyncStream<SyncEvent>.Continuation] = []
    /// Monotonic HLC source for locally-originated changes that reach the push
    /// path without an HLC of their own.
    ///
    /// Initialized to a random provisional value here; `enable()` immediately
    /// replaces it with a stable identity-backed nodeID loaded from
    /// `DeviceIdentityStore` (side table `_ck_device_identity`). The provisional
    /// random draw is never used in production: `isEnabled` remains `false` until
    /// `enable()` completes, and `push()` guards on `isEnabled`.
    ///
    /// The stable nodeID eliminates the per-launch collision probability ≈1/15
    /// per session pair that the previous random draw produced (N2,
    /// DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16). Shared-registry
    /// arbitration (CloudKit CAS against the slot manifest zone) to enforce
    /// uniqueness across all devices arrives in P1-M3.
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

        // Ensure all ConvergenceKit side tables exist (consolidated schema, B-12).
        // CKSideSchema owns one SchemaDeclaration with kitID "ConvergenceKit" and
        // a single version counter covering _ck_sync_meta (v1) and _ck_outbox (v2).
        try await CKSideSchema.ensure(storage: storage)

        // Drain any outbox leftovers from a previous process life so the next
        // push cycle picks them up without waiting for a new local write. The
        // engine does not auto-schedule a push here (that is the host app's
        // responsibility), but the entries are ready in the outbox.
        let leftovers = try await OutboxStore.drainLeftovers(from: storage)
        if !leftovers.isEmpty {
            logger.info("outbox: \(leftovers.count) leftover entries from previous session")
        }

        // Ensure the _ck_change_token side table exists, then restore the
        // persisted token so the first pull resumes from where the previous
        // process left off rather than re-pulling the entire zone. R5.
        try await TokenStore.ensure(storage: storage)
        serverChangeToken = try await TokenStore.load(zoneName: manifest.zoneIdentifier, storage: storage)

        // Load or mint this device's persistent sync identity (N2: device slot registry).
        //
        // DeviceIdentityStore persists (deviceUUID, slot, epoch) in the
        // `_ck_device_identity` side table so the slot number is stable across
        // process restarts. The stable nodeID eliminates the per-launch collision
        // probability ≈1/15 per session pair that the previous random draw produced.
        //
        // This is a provisional local-only slot claim. Shared-registry arbitration
        // (CloudKit CAS against the slot manifest zone) to confirm or reassign the
        // slot among all concurrently active devices arrives in P1-M3. Until then,
        // two devices may independently pick the same slot number; this is strictly
        // better than per-launch random re-roll, which guarantees fresh collision
        // risk on every restart.
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let identityStore = DeviceIdentityStore(storage: storage)
        let identity = try await identityStore.loadOrMint(now: { Date() })
        hlcGenerator = HLCGenerator(nodeID: Int32(identity.slot))

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
        // The outbound queue is the durable _ck_outbox side table; no in-memory
        // queue to clear. Outbox entries survive disable() and are drained on
        // the next enable() (drainLeftovers above). This is the durability
        // guarantee R4 requires: the outbox survives process death and
        // disable/enable cycles.
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

    /// Durably append an outbound change to the _ck_outbox side table.
    ///
    /// The in-memory fast path (pendingOutbound array) is intentionally absent:
    /// the durable store IS the queue (R4). A change is not considered captured
    /// until it is written to the outbox. Process death before this write loses
    /// the change, which is acceptable (the observer will re-fire on the next
    /// enable if the local row still exists); process death AFTER this write and
    /// BEFORE push confirmation is safe — the entry survives in the outbox.
    ///
    /// HLC is minted here (before append) so the outbox stores the ordered HLC
    /// at capture time. The push path uses this stored HLC for the CKRecord, not
    /// a fresh mint — ensuring that the logical ordering established at observe
    /// time is preserved all the way to the wire.
    func recordOutbound(_ change: TableChange) async {
        // Echo suppression (I-10, CVK-ICLOUD P1-M1): discard changes that
        // originated from applyInbound. Without this guard, every inbound
        // sync write fires the storage observer, re-enters the outbox,
        // and is pushed back to the sending device — two live machines
        // ping-pong forever. The .syncApply origin is stamped by the
        // RowStore sync-tagged write paths (upsertSync / insertSync / deleteSync).
        guard change.origin != .syncApply else { return }
        guard let storage else { return }

        // Mint HLC if the observation did not carry one (the InMemory and
        // SQLite observers do not stamp HLCs on TableChange notifications today).
        let hlc = change.hlc ?? hlcGenerator.send(now: nowMillis())
        let packedHLC = Int64(bitPattern: hlc.packed)

        // Encode values as a JSON SyncValueMap blob for transport-agnostic storage.
        let valuesData: Data?
        if let rawValues = change.values {
            valuesData = try? JSONEncoder().encode(SyncValueMap(rawValues))
        } else {
            valuesData = nil
        }

        let enqueuedAt = ISO8601DateFormatter().string(from: Date())
        let entry = OutboxEntry(
            id: UUID(),
            tableName: change.table,
            rowKey: change.rowKey?.uuidString ?? "",
            event: SyncEventKind(from: change.event),
            valuesData: valuesData,
            packedHLC: packedHLC,
            enqueuedAt: enqueuedAt
        )

        do {
            try await OutboxStore.append(entry: entry, to: storage)
        } catch {
            logger.error("outbox append failed for \(change.table): \(String(describing: error))")
        }
    }

    var currentState: SyncState {
        if let m = manifest, isEnabled {
            return .enabled(zone: m.zoneIdentifier, lastPushAt: lastPushAt, lastPullAt: lastPullAt)
        }
        return .disabled
    }
}
