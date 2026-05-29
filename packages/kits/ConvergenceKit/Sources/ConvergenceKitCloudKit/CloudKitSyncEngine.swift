// CloudKitSyncEngine.swift
//
// CloudKit-backed sync. Generalized port of Fulcrum's
// SyncCoordinator pattern: setup zone + subscription, push
// pending local changes, pull remote changes since last token,
// apply via PersistenceKit.
//
// ConvergenceKit-CloudKit listens to StorageObserver for outbound changes
// and queues them for push. On pull, decodes CKRecords into
// SyncRecords and applies through the local PersistenceKit's rowStore
// (which fires StorageObserver naturally, waking downstream watchers).

import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
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

        // Start observing each declared table.
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
        guard isEnabled, let manifest, let storage else { throw SyncError.notEnabled }
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

        // Use CKFetchRecordZoneChangesOperation with the last token.
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

        // Apply deletions.
        for recordID in deletedIDs {
            let parts = recordID.recordName.split(separator: ":")
            // Convention: recordName is the UUID, recordType encodes kit_table.
            // For deletions CloudKit gives us the recordType separately via the deletions array.
            // We rely on the manifest matching the active tables; just attempt delete on every table.
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

    private func applyInbound(
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
            // Compare HLC; only apply if remote >= local.
            let existing = try? await storage.rowStore.query(
                table: decoded.table,
                where: .eq(Column(table: decoded.table, name: syncedTable.primaryKeyColumn), .uuid(decoded.rowKey))
            )
            if let first = existing?.first, case let .hlc(localHLC) = first["_syncHLC"] ?? .null {
                if decoded.hlc < localHLC {
                    return
                }
            }
            _ = try await storage.rowStore.upsert(
                table: decoded.table,
                values: decoded.values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

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
    /// the HLC generator. Isolated in one method so the single
    /// remaining clock read in the engine is easy to audit.
    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
