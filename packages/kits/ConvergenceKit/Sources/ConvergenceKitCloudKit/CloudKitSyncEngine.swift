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
        // pendingOutbound is now the durable _ck_outbox side table; no in-memory
        // queue to clear. Outbox entries survive disable() and are drained on the
        // next enable() call (drainLeftovers above). This is the durability guarantee
        // that R4 requires: outbox survives process death and disable/enable cycles.
        manifest = nil
        storage = nil
    }

    func attachSubscriber(_ continuation: AsyncStream<SyncEvent>.Continuation) {
        subscribers.append(continuation)
    }

    private func emit(_ event: SyncEvent) {
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

    // MARK: - Push

    func push() async throws -> SyncReceipt {
        // Bind storage: push() now reads from the durable outbox, which requires
        // a live storage reference (unlike the old pendingOutbound array path).
        guard isEnabled, let manifest, let storage else { throw SyncError.notEnabled }
        emit(.pushCompleted(receipt: SyncReceipt.empty))  // start signal; reset after work

        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)

        // Read batch WITHOUT clearing. Entries remain in the outbox until the
        // transport confirms success. A transport failure throws before confirm(),
        // leaving all entries intact for the next push cycle. This is R4's
        // durability guarantee: no change is lost to a transport failure.
        //
        // P1-M6 seam: until per-record push results land (P1-M6 / P4-M1),
        // PushCycle confirms the full batch on transport success and retains
        // the full batch on transport failure. Per-record confirmation (partial
        // success from modifyRecords(atomically: false)) requires the per-record
        // result surface from P1-M6; confirm(ids:) already accepts a list so
        // the P1-M6 upgrade is a call-site change here, not a schema or
        // OutboxStore API change.
        let batch = try await OutboxStore.readBatch(from: storage)

        var saved: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var confirmedIDs: [UUID] = []
        var pushedCount = 0

        for entry in batch {
            guard let syncedTable = manifest.table(named: entry.tableName) else { continue }
            guard syncedTable.direction != .pullOnly else { continue }
            guard let rowKey = UUID(uuidString: entry.rowKey) else {
                logger.error("push: malformed row_key in outbox entry \(entry.id): \(entry.rowKey)")
                continue
            }

            // Recover the stored HLC from the outbox entry. This is the HLC
            // that was minted at observe time (recordOutbound), not a fresh
            // mint — preserving the logical ordering established at capture.
            let hlc = HLC(packed: UInt64(bitPattern: entry.packedHLC))

            switch entry.event {
            case .insert, .update:
                guard let valuesData = entry.valuesData else {
                    logger.error("push: missing values blob for \(entry.event.rawValue) entry \(entry.id)")
                    continue
                }
                let values: [String: TypedValue]
                do {
                    let valueMap = try JSONDecoder().decode(SyncValueMap.self, from: valuesData)
                    values = valueMap.asTypedValues
                } catch {
                    logger.error("push: values decode failed for entry \(entry.id): \(error)")
                    continue
                }
                do {
                    let record = try CKRecordMapping.record(
                        from: values,
                        table: entry.tableName,
                        rowKey: rowKey,
                        hlc: hlc,
                        schemaVersion: manifest.schemaVersion,
                        kitID: manifest.kitID,
                        zone: zoneID
                    )
                    saved.append(record)
                    confirmedIDs.append(entry.id)
                    pushedCount += 1
                } catch {
                    logger.error("push encode failed for entry \(entry.id): \(String(describing: error))")
                }
            case .delete:
                let ckID = CKRecordMapping.recordID(rowKey: rowKey, zone: zoneID)
                deleted.append(ckID)
                confirmedIDs.append(entry.id)
                pushedCount += 1
            }
        }

        // Send to CloudKit.
        if !saved.isEmpty || !deleted.isEmpty {
            do {
                _ = try await container.privateCloudDatabase.modifyRecords(
                    saving: saved,
                    deleting: deleted,
                    savePolicy: .changedKeys,
                    atomically: false
                )
            } catch {
                // Transport failed. Do NOT confirm — leave all outbox entries intact.
                // They will be retried on the next push cycle (either triggered by
                // the next local write or by the host app's retry timer).
                throw SyncError.transportFailure(detail: "CKDatabase.modifyRecords: \(error)")
            }
        }

        // Transport succeeded: confirm the entries that were encoded and sent.
        // Entries that were skipped (missing table, bad rowKey, decode failure)
        // are not in confirmedIDs and remain in the outbox.
        try await OutboxStore.confirm(ids: confirmedIDs, from: storage)

        let receipt = SyncReceipt(pushed: pushedCount, pulled: 0, conflicts: 0)
        lastPushAt = Date()
        emit(.pushCompleted(receipt: receipt))
        return receipt
    }

    // MARK: - Pull

    func pull() async throws -> SyncReceipt {
        guard isEnabled, let manifest, let storage else { throw SyncError.notEnabled }
        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)

        // Pull via async recordZoneChanges(inZoneWith:since:) API.
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = serverChangeToken

        var pulledRecords: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken? = serverChangeToken

        do {
            let result = try await container.privateCloudDatabase.recordZoneChanges(
                inZoneWith: zoneID,
                since: serverChangeToken
            )
            for (_, modResult) in result.modificationResultsByID {
                if case .success(let mod) = modResult {
                    pulledRecords.append(mod.record)
                }
            }
            for deletion in result.deletions {
                deletedIDs.append(deletion.recordID)
            }
            newToken = result.changeToken
        } catch {
            throw SyncError.transportFailure(detail: "recordZoneChanges: \(error)")
        }

        var appliedCount = 0
        var conflicts = 0

        for record in pulledRecords {
            do {
                let decoded = try CKRecordMapping.decode(record)
                guard decoded.kitID == manifest.kitID else {
                    throw SyncError.kitMismatch(expected: manifest.kitID, received: decoded.kitID)
                }
                guard decoded.schemaVersion == manifest.schemaVersion else {
                    throw SyncError.schemaMismatch(expected: manifest.schemaVersion, received: decoded.schemaVersion)
                }
                guard let syncedTable = manifest.table(named: decoded.table) else {
                    throw SyncError.unsupportedTable(name: decoded.table)
                }
                guard syncedTable.direction != .pushOnly else { continue }

                try await applyInbound(decoded, syncedTable: syncedTable, storage: storage)
                appliedCount += 1
            } catch let err as SyncError {
                logger.error("pull apply failed: \(String(describing: err))")
                conflicts += 1
            } catch {
                logger.error("pull apply failed (other): \(String(describing: error))")
                conflicts += 1
            }
        }

        // Apply deletions. Deletion events carry only a CKRecord.ID, no record type
        // that could identify the target table. Deletion is attempted against every
        // non-pushOnly manifest table; the manifest is the scope guard.
        for recordID in deletedIDs {
            let parts = recordID.recordName.split(separator: ":")
            guard let rowKey = UUID(uuidString: String(parts[0])) else { continue }
            for syncedTable in manifest.tables where syncedTable.direction != .pushOnly {
                let predicate = StoragePredicate.eq(
                    Column(table: syncedTable.name, name: syncedTable.primaryKeyColumn),
                    .uuid(rowKey)
                )
                _ = try? await storage.rowStore.delete(table: syncedTable.name, where: predicate)
            }
            appliedCount += 1
        }

        serverChangeToken = newToken
        let receipt = SyncReceipt(pushed: 0, pulled: appliedCount, conflicts: conflicts)
        lastPullAt = Date()
        if appliedCount > 0 {
            emit(.remoteChangesApplied(count: appliedCount))
        }
        return receipt
    }

    // Internal (not private) so the LWW tests can call it directly
    // via @testable import without going through the CloudKit stack.
    func applyInbound(
        _ decoded: DecodedRecord,
        syncedTable: SyncedTable,
        storage: any Storage
    ) async throws {
        switch syncedTable.conflictPolicy {
        case .appendOnly:
            // Audit log style. Idempotent upsert with the row key as primary.
            _ = try await storage.rowStore.upsert(
                table: decoded.table,
                values: decoded.values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .lastWriterWinsByHLC:
            // (#12) LWW comparison reads the persisted HLC from the
            // _ck_sync_meta side table. If the remote HLC is older than
            // the local HLC, the remote record is skipped (the local row
            // is newer). The side table is created at engine init so it
            // exists on all backends (SQLite, PG, InMemory).
            let localHLC = try await readSyncHLC(
                storage: storage, table: decoded.table,
                primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn)
            if let localHLC, decoded.hlc < localHLC {
                return // local is newer — skip remote
            }
            _ = try await storage.rowStore.upsert(
                table: decoded.table,
                values: decoded.values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )
            // Persist the sync HLC in the side table for future comparisons.
            try await writeSyncHLC(
                storage: storage, table: decoded.table,
                primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn,
                hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                kitID: decoded.syncMeta.kitID)

        case .remoteWins:
            _ = try await storage.rowStore.upsert(
                table: decoded.table,
                values: decoded.values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .localWins:
            // Only insert if no row exists.
            let existing = try? await storage.rowStore.count(
                table: decoded.table,
                where: .eq(Column(table: decoded.table, name: syncedTable.primaryKeyColumn), .uuid(decoded.rowKey))
            )
            if (existing ?? 0) == 0 {
                _ = try await storage.rowStore.insert(table: decoded.table, values: decoded.values)
            }
        }
    }

    /// Current wall-clock in milliseconds, passed explicitly into
    /// the HLC generator. Note: the engine also reads Date() when
    /// assigning lastPushAt and lastPullAt on receipts.
    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Sync metadata side table (#12)

    /// Side table name. The declaration lives in CKSideSchema (B-12
    /// governance); this alias keeps local read/write helpers readable.
    private static let syncMetaTable = CKSideSchema.syncMetaTable

    /// Ensure ALL ConvergenceKit side tables exist. Delegates to CKSideSchema,
    /// which owns the single consolidated SchemaDeclaration (kitID
    /// "ConvergenceKit", version counter covers _ck_sync_meta at v1 and
    /// _ck_outbox at v2). See SideSchema.swift for the governance rationale.
    ///
    /// Kept as a static func (not inlined at the enable() call site) so the
    /// call signature is stable for tests that exercise the ensure path.
    static func ensureSyncMetaTable(storage: any Storage) async throws {
        try await CKSideSchema.ensure(storage: storage)
    }

    /// Read the persisted sync HLC for a specific row.
    private func readSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID, pkColumn: String
    ) async throws -> HLC? {
        let rows = try await storage.rowStore.query(
            table: Self.syncMetaTable,
            where: .and([
                .eq(Column(table: Self.syncMetaTable, name: "table_name"), .text(table)),
                .eq(Column(table: Self.syncMetaTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
        guard let row = rows.first,
              case .int(let packed) = row["sync_hlc"] else { return nil }
        return HLC(packed: UInt64(bitPattern: packed))
    }

    /// Persist the sync HLC for a specific row after a successful upsert.
    private func writeSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID, pkColumn: String,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await storage.rowStore.upsert(
            table: Self.syncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc": .int(Int64(bitPattern: hlc.packed)),
                "schema_version": .int(Int64(schemaVersion)),
                "kit_id": .text(kitID)
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }
}
