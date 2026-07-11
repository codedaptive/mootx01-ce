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

    private func emit(_ event: SyncEvent) {
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

    // MARK: - Push

    func push() async throws -> SyncReceipt {
        // storage must be configured to push, but push() drives the CloudKit
        // operations directly off `manifest`/`pendingOutbound` and does not
        // read it here — so assert configuration without binding the value.
        guard isEnabled, let manifest, storage != nil else { throw SyncError.notEnabled }
        emit(.pushCompleted(receipt: SyncReceipt.empty))  // start signal; reset after work

        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)
        let pending = pendingOutbound
        pendingOutbound.removeAll()

        var saved: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var pushedCount = 0

        for change in pending {
            guard let syncedTable = manifest.table(named: change.table) else { continue }
            guard syncedTable.direction != .pullOnly else { continue }
            guard let rowKey = change.rowKey else { continue }

            switch change.event {
            case .insert, .update:
                guard let values = change.values else { continue }
                // Prefer the HLC that already ordered the change. If
                // the observation carried none (the InMemory and
                // SQLite observers do not stamp an HLC on the change
                // notification today), mint a monotonic one through
                // the HLC generator. send(now:) takes the clock as a
                // parameter so the engine stays deterministic, and
                // advances per-replica state so two changes pushed in
                // the same millisecond still order via the logical
                // counter. The earlier code fabricated an HLC inline
                // from Date() with nodeID 0, which both violated the
                // deterministic-engine rule and risked node collisions.
                let hlc = change.hlc ?? hlcGenerator.send(now: nowMillis())
                do {
                    let record = try CKRecordMapping.record(
                        from: values,
                        table: change.table,
                        rowKey: rowKey,
                        hlc: hlc,
                        schemaVersion: manifest.schemaVersion,
                        kitID: manifest.kitID,
                        zone: zoneID
                    )
                    saved.append(record)
                    pushedCount += 1
                } catch {
                    logger.error("push encode failed: \(String(describing: error))")
                }
            case .delete:
                let id = CKRecordMapping.recordID(rowKey: rowKey, zone: zoneID)
                deleted.append(id)
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
                throw SyncError.transportFailure(detail: "CKDatabase.modifyRecords: \(error)")
            }
        }

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

    /// Side table name. Owned by ConvergenceKit, not by the application schema.
    private static let syncMetaTable = "_ck_sync_meta"

    /// Ensure the side table exists. Must be called before any pull.
    /// Uses SchemaDeclaration + migrate so the table is created via the
    /// standard PersistenceKit schema path (works on all backends).
    static func ensureSyncMetaTable(storage: any Storage) async throws {
        let schema = SchemaDeclaration(
            kitID: "ConvergenceKitCloudKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: syncMetaTable,
                    columns: [
                        ColumnDeclaration(name: "table_name", type: .text, nullable: false),
                        ColumnDeclaration(name: "primary_key", type: .text, nullable: false),
                        ColumnDeclaration(name: "sync_hlc", type: .int, nullable: false,
                                          defaultValue: .int(0)),
                        ColumnDeclaration(name: "schema_version", type: .int, nullable: false,
                                          defaultValue: .int(0)),
                        ColumnDeclaration(name: "kit_id", type: .text, nullable: false,
                                          defaultValue: .text("")),
                    ],
                    primaryKey: ["table_name", "primary_key"]
                ),
            ],
            indices: []
        )
        // migrate(to:) is ADDITIVE — it creates missing tables without
        // replacing the backend's active schema declaration. open(schema:)
        // would clobber the application schema, breaking all row operations.
        try await storage.migrate(to: schema)
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
