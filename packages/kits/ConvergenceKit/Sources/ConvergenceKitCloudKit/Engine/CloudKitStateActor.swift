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

// MARK: - SyncRecord → DecodedRecord conversion (skew-queue replay, R9)

extension SyncRecord {
    /// Convert this SyncRecord back to a DecodedRecord for replay through
    /// CloudKitStateActor.applyInbound (R9, CVK-ICLOUD P3-M4).
    ///
    /// Used by the skew-queue replay path in enable(): records held in
    /// _ck_pending_skew are SyncRecord (the shared wire format); the
    /// CloudKit inbound apply path takes DecodedRecord.
    ///
    /// isTombstone is reconstructed from `syncDeleted`: if the field was true
    /// when the record was enqueued, it is true on replay. The field is nil
    /// (not a tombstone) for normal insert/update records.
    func asDecodedRecord() -> DecodedRecord {
        DecodedRecord(
            table: table,
            rowKey: rowKey,
            values: values?.asTypedValues ?? [:],
            syncMeta: SyncMeta(
                hlc: hlc.asHLC,
                schemaVersion: schemaVersion,
                kitID: kitID
            ),
            isTombstone: syncDeleted == true,
            columnHLCs: columnHLCs
        )
    }
}

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
    /// directly now go through this seam.
    var database: (any CloudKitDatabaseProtocol)?

    /// Test-injection point for the CloudKit database seam.
    ///
    /// When non-nil, `enable()` uses this value instead of resolving
    /// `container.privateCloudDatabase`. Must be set BEFORE calling `enable()`.
    /// Only for use in ConvergenceKitCloudKitTests/Harness/ (P4 series).
    /// Production code must never set this — it remains nil in all non-test paths.
    var _testDatabase: (any CloudKitDatabaseProtocol)? = nil

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

    /// Coalescing debouncer that fires push() after outbox write activity quiets.
    ///
    /// Created by enable() and cancelled by disable(). Nil when the engine is
    /// disabled. Prevents per-keystroke push storms (B-11): arm() is called after
    /// each successful OutboxStore.append, and the trigger fires push() once the
    /// coalescingWindow (2 s) elapses without a new write. The maxLatency ceiling
    /// (10 s) guarantees a trigger even under a sustained write stream.
    var drainDebouncer: OutboxDrainDebouncer?

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
        // Validate encrypted column declarations before any zone setup or push occurs.
        // Rejects _ck_* registry tables and moot_sync_* reserved columns (FAB5-EV Phase 2).
        try manifest.validateEncryptedColumns()
        self.storage = storage

        // Resolve the database seam. Tests inject a fake via _testDatabase before
        // calling enable(); production code leaves _testDatabase nil and resolves
        // the container's private database at enable-time. CKDatabase conforms to
        // CloudKitDatabaseProtocol via the retroactive extension in
        // Transport/CloudKitDatabaseProtocol.swift.
        let db = _testDatabase ?? container.privateCloudDatabase
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
        // CKSideSchema v7 covers _ck_sync_meta (v1), _ck_outbox (v2+), _ck_change_token (v3),
        // _ck_sync_meta_cols (v6, fieldLevelLWW), and _ck_pending_skew (v7, R9).
        // A separate TokenStore.ensure call is no longer needed.
        try await CKSideSchema.ensure(storage: storage)

        // Schema-skew replay (R9, CVK-ICLOUD P3-M4).
        //
        // The _ck_pending_skew table holds records from previous pull cycles
        // where the sender was on a newer schema than the receiver. Now that
        // enable() has been called with a (potentially updated) manifest, replay
        // any records whose schema_version equals the current manifest version.
        //
        // Echo suppression is active by construction: the observer tasks are
        // not yet started (see below), so replay writes via applyInbound
        // (upsertSync / deleteSync) cannot re-enter the outbox (I-10).
        let skewReady = try await SkewReplay.drainReady(
            currentVersion: manifest.schemaVersion,
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        if !skewReady.isEmpty {
            logger.info("skew-queue replay: \(skewReady.count) held record(s) ready for schema v\(manifest.schemaVersion)")
            var replayedIDs: [UUID] = []
            for (id, record) in skewReady {
                guard let syncedTable = manifest.table(named: record.table) else { continue }
                guard syncedTable.direction != .pushOnly else { continue }
                do {
                    try await applyInbound(record.asDecodedRecord(), syncedTable: syncedTable, storage: storage)
                    replayedIDs.append(id)
                } catch {
                    logger.warning("skew replay failed for \(record.table)/\(record.rowKey): \(String(describing: error))")
                }
            }
            try await SkewReplay.deleteApplied(
                ids: replayedIDs,
                from: storage,
                sideTable: CKSideSchema.pendingSkewTable
            )
            logger.info("skew-queue replay: applied \(replayedIDs.count)/\(skewReady.count) records")
        }
        // Emit recordsHeldForMigration for any records remaining in the queue
        // (i.e. records whose schemaVersion is still newer than this manifest).
        let skewStillHeld = try await SkewReplay.countHeld(
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        if skewStillHeld > 0 {
            emit(.recordsHeldForMigration(count: skewStillHeld))
        }

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

        // Create the drain debouncer (B-11, CVK-ICLOUD P3-M1).
        //
        // The trigger calls push() to flush the outbox after write activity
        // quiets. On transport failure, the debouncer re-arms with a backoff
        // delay to prevent hot-looping on network errors.
        //
        // Interaction with RetryPolicy (P1-M6): delay(forAttempt: 0) returns
        // ~1 s with ±20% jitter — the single-step "wait a moment, retry" path
        // for transient blips. The poll scheduler (P3-M2, AdaptivePollScheduler)
        // manages the multi-step retry arc for persistent failures.
        let retryPolicy = RetryPolicy.default
        self.drainDebouncer = OutboxDrainDebouncer(
            coalescingWindow: OutboxDrainDebouncer.Constants.coalescingWindow,
            maxLatency: OutboxDrainDebouncer.Constants.maxLatency,
            sleep: { try await Task.sleep(for: $0) },
            trigger: { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.push()
                } catch SyncError.transportFailure(let detail) {
                    // Re-arm with backoff so the next attempt is delayed rather
                    // than immediate. Without backoff, a broken network would cause
                    // the debouncer to fire on each subsequent write and hammer
                    // CloudKit with failing push attempts — a hot loop. The
                    // coalescingWindow (2 s) already de-dupes writes; this backoff
                    // adds a further wait before the retry attempt.
                    logger.warning("debouncer: push transport failure, backing off: \(detail)")
                    let backoff = retryPolicy.delay(forAttempt: 0)
                    try? await Task.sleep(for: .seconds(backoff))
                    await self.drainDebouncer?.arm()
                } catch SyncError.notEnabled {
                    // Engine disabled while trigger was in flight — expected; no-op.
                    ()
                } catch {
                    logger.error("debouncer: push error: \(String(describing: error))")
                }
            }
        )

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

        // If there were leftover outbox entries from a previous session, arm the
        // debouncer so they are pushed shortly after enable() returns — without
        // requiring the host app to call push() manually (B-11).
        if !leftovers.isEmpty {
            await drainDebouncer?.arm()
        }
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

        // Cancel the drain debouncer and AWAIT its task (I-2 deterministic teardown).
        // After cancel() returns, no push will fire — even if arm() was called
        // moments before disable(). The await closes the race window where the
        // debouncer's sleep just completed and the trigger is queued to run.
        await drainDebouncer?.cancel()
        drainDebouncer = nil

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

        // Column projection (R2, CVK-ICLOUD P2-M2): strip excluded columns
        // before building the outbox entry. Excluded columns are locally
        // recomputed on every device (scores, caches, derived values); syncing
        // them creates outbound traffic proportional to local compute — a sync
        // storm. Killing the entry here, before OutboxStore.append, ensures
        // zero database writes for derived-column recomputes.
        //
        // Deletes are unaffected: a delete carries no column values to strip,
        // and the tombstone must still propagate so remote replicas GC the row.
        let excluded = manifest?.table(named: change.table)?.excludedColumns ?? []
        let effectiveValues: [String: TypedValue]?
        if !excluded.isEmpty, let rawValues = change.values {
            let stripped = Projection.outboundStrip(values: rawValues, excluded: excluded)
            if change.event == .update {
                // Storm kill: no sync-meaningful columns survived exclusion.
                //
                // Precision path (CVK-WB4, Scorandum Q1 closed): when changedColumns
                // is present, check whether every column that was ACTUALLY written in
                // this event is excluded. This catches mixed-column writes (e.g. a score
                // recompute that carries title in the merged row snapshot but did not
                // actually change it). Without this check, `isStormKill` would see title
                // in `stripped` and let the entry through even though the write was
                // entirely in excluded columns.
                //
                // Classic fallback (changedColumns nil = unknown/all): check whether only
                // the primary key survived the strip. This is the pre-CVK-WB4 behavior.
                let pkColumn = manifest?.table(named: change.table)?.primaryKeyColumn ?? ""
                if let changedCols = change.changedColumns {
                    if changedCols.allSatisfy({ excluded.contains($0) }) {
                        return
                    }
                } else if Projection.isStormKill(stripped: stripped, primaryKeyColumn: pkColumn) {
                    return
                }
            }
            effectiveValues = stripped
        } else {
            effectiveValues = change.values
        }

        // Mint HLC if the observation did not carry one (the InMemory and
        // SQLite observers do not stamp HLCs on TableChange notifications today).
        let hlc = change.hlc ?? hlcGenerator.send(now: nowMillis())
        // Gap 6 (D38.1): full-width wire encoding, not the legacy 40-bit-
        // truncated `HLC.packed`. See OutboxEntry.swift's file header.
        let hlcWireBytes = Data(hlc.wireBytes)

        // Encode values as a JSON SyncValueMap blob for transport-agnostic storage.
        // effectiveValues is the projection-stripped set (R2) — excluded columns
        // never reach the wire, so they are also never column-HLC-stamped below.
        let valuesData: Data?
        if let stripped = effectiveValues {
            valuesData = try? JSONEncoder().encode(SyncValueMap(stripped))
        } else {
            valuesData = nil
        }

        // For fieldLevelLWW tables, stamp columns with the capture HLC and encode
        // as a ColumnHLCMap blob.
        //
        // Precision path (CVK-WB4): when changedColumns is present, stamp ONLY the
        // columns that were actually written in this event (intersection of
        // changedColumns with the projection-stripped key set). Columns present in
        // the row snapshot but not written retain their existing remote HLC — they
        // are not displaced by a coarser "stamp all" that would falsely advance an
        // unchanged column's HLC and suppress a later legitimate write from a peer.
        //
        // Fallback (changedColumns nil = unknown/all): stamp all present columns.
        // This is the pre-CVK-WB4 behavior and remains correct — it is conservative
        // (the receiver applies more columns than strictly necessary) but safe.
        //
        // Gap 3: `colMap` (the actual map, not just its encoded Data) is kept in
        // scope below so the SAME local write's HLC that gets shipped to peers on
        // the wire is also stamped into the LOCAL `_ck_sync_meta_cols` side table
        // (ColumnHLCStore.writeAll below) — closing the "local write never
        // HLC-gated" window. Without this, ApplyInbound's fieldLevelLWW gate has
        // no truthful local baseline for a column this device just wrote, so a
        // later-arriving stale remote edit for that column wins unconditionally
        // (FieldLWWMerge.merge: `localColumnHLC == nil` → `shouldApply = true`).
        let colMap: ColumnHLCMap?
        let columnHLCsData: Data?
        if let stripped = effectiveValues,
           let syncedTable = manifest?.table(named: change.table),
           syncedTable.conflictPolicy == .fieldLevelLWW {
            let keysToStamp: [String]
            if let changedCols = change.changedColumns {
                // Stamp only columns that were actually changed and survived projection.
                keysToStamp = stripped.keys.filter { changedCols.contains($0) }
            } else {
                // Unknown: stamp all projected columns (backward-compatible fallback).
                keysToStamp = Array(stripped.keys)
            }
            let map = ColumnHLCMap.stampAll(
                keys: keysToStamp,
                hlc: PackedHLC(hlc)
            )
            colMap = map
            columnHLCsData = try? JSONEncoder().encode(map)
        } else {
            colMap = nil
            columnHLCsData = nil
        }

        let enqueuedAt = ISO8601DateFormatter().string(from: Date())
        let entry = OutboxEntry(
            id: UUID(),
            tableName: change.table,
            rowKey: change.rowKey?.uuidString ?? "",
            event: SyncEventKind(from: change.event),
            valuesData: valuesData,
            hlcWireBytes: hlcWireBytes,
            enqueuedAt: enqueuedAt,
            columnHLCsData: columnHLCsData
        )

        do {
            // Gap 3: when this local write has a non-empty column-HLC stamp
            // (fieldLevelLWW table, non-delete event, at least one written
            // column), the local `_ck_sync_meta_cols` bookkeeping write and the
            // durable outbox append commit as ONE transaction — the same
            // atomicity guarantee shipped for the receive side in gap 4. This
            // does NOT (and cannot) extend to the original application-level
            // row write itself: that write already committed, via arbitrary
            // caller code, before the storage observer delivered this
            // `TableChange` to recordOutbound — recordOutbound is a reactive
            // notification handler, not the write path. What this transaction
            // guarantees is that recordOutbound's OWN two writes (column-HLC
            // bookkeeping + outbox entry) never partially land.
            if let colMap, !colMap.isEmpty, let rowKey = change.rowKey {
                try await storage.transaction(isolation: .serializable) { txn in
                    try await ColumnHLCStore.writeAll(
                        map: colMap,
                        to: txn, sideTable: CKSideSchema.syncMetaColsTable,
                        tableName: change.table, primaryKey: rowKey)
                    try await OutboxStore.append(entry: entry, to: txn)
                }
            } else {
                try await OutboxStore.append(entry: entry, to: storage)
            }
            // Arm the debouncer after a successful durable append (B-11).
            // The debouncer coalesces rapid writes into one push cycle, preventing
            // per-keystroke push storms. arm() is a no-op if the engine is being
            // torn down (drainDebouncer is nil after disable()).
            await drainDebouncer?.arm()
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
