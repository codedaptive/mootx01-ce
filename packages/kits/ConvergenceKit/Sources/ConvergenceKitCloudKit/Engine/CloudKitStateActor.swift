// CloudKitStateActor.swift
//
// Actor shell for CloudKitSyncEngine. Owns all mutable sync state:
// container, database seam, manifest, storage, observer tasks, subscriber
// continuations, HLC generator, server change token, device identity, and
// the enable/disable lifecycle.
// The outbound queue is NOT in-memory state: it is the durable _ck_outbox
// side table (R4), written by recordOutbound and drained by PushCycle.
//
// Push, pull, conflict-policy application, sync-meta side table,
// and clock helpers live in sibling files under Engine/:
//   PushCycle.swift       — outbound push path (calls EpochFence before drain)
//   PullCycle.swift       — inbound pull + deletion path
//   ApplyInbound.swift    — conflict-policy apply switch
//   SyncMetaStore.swift   — _ck_sync_meta side table
//   EngineClock.swift     — nowMillis() helper
//
// Registry files under Registry/:
//   SlotRecordMapping.swift  — 15 well-known CKRecord ↔ DeviceSlot mapping
//   SlotClaimOperation.swift — CloudKit CAS claim flow
//   EpochFence.swift         — push-path heartbeat + epoch verification

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

    /// Injectable CloudKit database seam.
    ///
    /// Set to `container.privateCloudDatabase` (via CKDatabase's retroactive
    /// CloudKitDatabaseProtocol conformance) during `enable()`. Tests can inject
    /// a fake by supplying `_testDatabase` before calling enable, or by testing
    /// SlotClaimOperation and EpochFence directly through their own injectable parameters.
    ///
    /// All engine call sites that previously used `container.privateCloudDatabase`
    /// directly now go through this seam. P4-M1 will add a test-injection constructor
    /// to CloudKitSyncEngine for full engine integration tests.
    var database: (any CloudKitDatabaseProtocol)?

    var manifest: SyncManifest?
    var storage: (any Storage)?
    var isEnabled: Bool = false
    var lastPushAt: Date?
    var lastPullAt: Date?
    var serverChangeToken: CKServerChangeToken?
    var observerTasks: [Task<Void, Never>] = []
    var subscribers: [AsyncStream<SyncEvent>.Continuation] = []

    /// Persistent sync identity for this device.
    ///
    /// Loaded from `_ck_device_identity` during `enable()` and updated
    /// whenever the engine re-enrolls (slot changed). PushCycle reads this
    /// to supply `identity:` to `EpochFence.heartbeat`.
    var currentIdentity: DeviceIdentity?

    /// Side table manager for persisting the device's (deviceUUID, slot, epoch).
    /// Stored so PushCycle can update it after re-enrollment without needing storage
    /// passed through multiple call sites.
    var identityStore: DeviceIdentityStore?

    /// Monotonic HLC source for locally-originated changes that reach the push
    /// path without an HLC of their own.
    ///
    /// Initialized to a provisional value here; `enable()` immediately replaces
    /// it with a stable nodeID from the slot registry CAS claim. The provisional
    /// value is never used in production: `isEnabled` stays false until enable()
    /// completes, and `push()` guards on `isEnabled`.
    ///
    /// The stable nodeID from the shared slot registry (N2) eliminates the
    /// per-launch collision probability ≈1/15 per session pair from the previous
    /// random-draw approach. CloudKit CAS arbitrates uniqueness across all
    /// concurrently active devices.
    var hlcGenerator = HLCGenerator(nodeID: Int32.random(in: 1...0x0F))

    init(containerIdentifier: String?) {
        self.containerIdentifier = containerIdentifier
    }

    func enable(manifest: SyncManifest, storage: any Storage) async throws {
        if isEnabled { throw SyncError.alreadyEnabled }
        self.manifest = manifest
        self.storage = storage

        // Resolve the database seam from the container's private database.
        // All engine operations that reach CloudKit go through this seam.
        // CKDatabase conforms to CloudKitDatabaseProtocol via the retroactive
        // extension in Transport/CloudKitDatabaseProtocol.swift.
        let db = container.privateCloudDatabase
        self.database = db

        // Setup zone in private database.
        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await db.modifyRecordZones(saving: [zone], deleting: [])
        } catch {
            // Zone might already exist; that's fine.
            logger.info("zone setup (may already exist): \(String(describing: error))")
        }

        // Ensure all ConvergenceKit side tables exist (consolidated schema, B-12).
        // CKSideSchema v3 covers _ck_sync_meta (v1), _ck_outbox (v2, plus
        // retry_count and is_parked columns added in v3), and _ck_change_token
        // (v3, consolidated from TokenStore.swift in P1-M6 adjudication A11).
        // A separate TokenStore.ensure call is no longer needed.
        try await CKSideSchema.ensure(storage: storage)

        // Drain any outbox leftovers from a previous process life so the next
        // push cycle picks them up without waiting for a new local write. The
        // engine does not auto-schedule a push here (that is the host app's
        // responsibility), but the entries are ready in the outbox.
        let leftovers = try await OutboxStore.drainLeftovers(from: storage)
        if !leftovers.isEmpty {
            logger.info("outbox: \(leftovers.count) leftover entries from previous session")
        }

        // Restore the persisted server change token so the first pull resumes
        // from where the previous process left off rather than re-pulling the
        // entire zone. R5. The _ck_change_token table is guaranteed to exist
        // by the CKSideSchema.ensure call above.
        serverChangeToken = try await TokenStore.load(zoneName: manifest.zoneIdentifier, storage: storage)

        // Load or mint this device's persistent sync identity (N2: device slot registry).
        //
        // DeviceIdentityStore persists (deviceUUID, slot, epoch) in the
        // `_ck_device_identity` side table. A stable stored identity reduces
        // unnecessary slot changes across process restarts: we pass the stored slot
        // as `preferredSlot` to SlotClaimOperation so it is reclaimed if still free.
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let iStore = DeviceIdentityStore(storage: storage)
        self.identityStore = iStore
        let storedIdentity = try await iStore.load()

        // Claim a slot in the shared CloudKit registry via CAS (N2).
        //
        // SlotClaimOperation fetches all 15 slot records, runs SlotTable.claimSlot(),
        // and performs a conditional CloudKit save with .ifServerRecordUnchanged to
        // atomically claim the slot against all concurrently enrolling devices.
        // On CAS race loss it retries with jittered exponential backoff (A5).
        let deviceUUID = storedIdentity?.deviceUUID ?? UUID()
        let preferredSlot = storedIdentity?.slot

        let claimOp = SlotClaimOperation(
            database: db,
            zoneID: zoneID,
            deviceUUID: deviceUUID
        )
        let claimedSlot: DeviceSlot
        do {
            claimedSlot = try await claimOp.claim(preferring: preferredSlot)
        } catch let err as SyncError {
            throw err
        }

        // Persist the confirmed identity.
        let confirmedIdentity = DeviceIdentity(
            deviceUUID: claimedSlot.deviceUUID,
            slot: claimedSlot.slot,
            epoch: claimedSlot.epoch,
            claimedAt: claimedSlot.claimedAt
        )
        try await iStore.save(confirmedIdentity)
        self.currentIdentity = confirmedIdentity

        // If the claimed slot differs from the stored slot, re-mint any pending
        // outbox entries under the new nodeID (A2). Outbox entries with the old
        // nodeID must not be sent: they would produce HLC collisions with records
        // from the device that now owns the old slot.
        let oldNodeID = storedIdentity.map { Int32($0.slot) }
        let newNodeID = Int32(claimedSlot.slot)
        if let old = oldNodeID, old != newNodeID {
            logger.info("slot changed \(old) → \(newNodeID): re-minting \(leftovers.count) outbox entries")
            try await OutboxStore.remintAll(from: storage, newNodeID: newNodeID, nowMillis: nowMillis())
        }

        // Set the HLC generator to the confirmed slot's nodeID.
        hlcGenerator = HLCGenerator(nodeID: newNodeID)

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
        database = nil
        currentIdentity = nil
        identityStore = nil
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

    /// Re-enroll after a reenrollRequired event from EpochFence.
    ///
    /// Called by PushCycle when EpochFence throws reenrollRequired. The sequence:
    /// 1. Claim a fresh slot via SlotClaimOperation (picks a different slot since
    ///    the old one was evicted and re-epoch'd by another device).
    /// 2. Re-mint all pending outbox HLCs under the new nodeID (A2: safe because
    ///    outbox entries are unpushed local state — no remote replica has seen them).
    /// 3. Persist the new identity to DeviceIdentityStore.
    /// 4. Update the actor's HLC generator and currentIdentity.
    ///
    /// After this returns, PushCycle retries the push with the new nodeID.
    func reenroll(zoneID: CKRecordZone.ID) async throws {
        guard let storage, let db = database, let iStore = identityStore,
              let oldIdentity = currentIdentity else {
            throw SyncError.notEnabled
        }

        logger.info("re-enrolling: old slot \(oldIdentity.slot) epoch \(oldIdentity.epoch)")

        // Claim a fresh slot. Pass the old slot as preferred so we reclaim it
        // if available (e.g. the eviction was a false alarm / transient race).
        let claimOp = SlotClaimOperation(
            database: db,
            zoneID: zoneID,
            deviceUUID: oldIdentity.deviceUUID
        )
        let newSlot = try await claimOp.claim(preferring: oldIdentity.slot)
        let newNodeID = Int32(newSlot.slot)

        // Re-mint pending outbox entries under the new nodeID (A2).
        // WHY: entries in the outbox have HLCs with the old nodeID. If pushed as-is
        // they would collide with records from the device that now holds the old slot,
        // producing HLC ties that different replicas resolve differently (silent
        // LWW divergence). Re-minting under a fresh nodeID eliminates the collision.
        try await OutboxStore.remintAll(from: storage, newNodeID: newNodeID, nowMillis: nowMillis())

        // Persist and cache the new identity.
        let newIdentity = DeviceIdentity(
            deviceUUID: newSlot.deviceUUID,
            slot: newSlot.slot,
            epoch: newSlot.epoch,
            claimedAt: newSlot.claimedAt
        )
        try await iStore.save(newIdentity)
        self.currentIdentity = newIdentity
        self.hlcGenerator = HLCGenerator(nodeID: newNodeID)

        logger.info("re-enrolled: new slot \(newSlot.slot) epoch \(newSlot.epoch)")
    }

    var currentState: SyncState {
        if let m = manifest, isEnabled {
            return .enabled(zone: m.zoneIdentifier, lastPushAt: lastPushAt, lastPullAt: lastPullAt)
        }
        return .disabled
    }
}
