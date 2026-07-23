// EstateHydration.swift
//
// GLK-level hydrate-on-launch integration.
//
// Wires `StorageReplicator.hydrate` into the GeniusLocusKit startup sequence
// so an in-memory estate can be fully reconstructed from a durable (SQLite)
// backend on launch. Also exposes a standalone `hydrate(handle:from:)` verb
// for warming an already-open in-memory estate from a durable one.
//
// HYDRATE SEQUENCE (authoritative, from REPLICATION_GROUND_TRUTH.md §7):
//
//   1. Schema open    — open both inMemory and durable with the composite
//                       GeniusLocusKitSchema.estateSchemaDeclaration.
//                       This registers "GeniusLocusKit" composite version in both backends so
//                       the replication schema gate (which checks per-kitID version)
//                       passes. For inMemory this creates all 19 tables blank.
//                       For durable this is idempotent (CREATE TABLE IF NOT EXISTS).
//   2. Row snapshot   — StorageReplicator.hydrate copies all 19 schema.tables
//                       rows (including tombstones and append-only rows)
//                       verbatim from durable into in-memory. Generated columns
//                       are excluded from the write; the destination recomputes.
//   3. Audit events   — StorageReplicator.hydrate also copies _storagekit_audit
//                       events (separate from schema.tables) via the AuditLog
//                       protocol path. This is load-bearing for matrix rebuild.
//   4. Estate open    — LocusKit.Estate.open runs against the now-populated
//                       in-memory backend. The estate reads the manifest that was
//                       copied in step 2; no second write to the manifest is needed.
//   5. Matrix rebuild — MatrixTier.rebuild(from: unifiedAuditLog) populates
//                       F, C, O matrices and liveRowCount.
//   6. rebuildTemporal — MatrixTier.rebuildTemporal(from: unifiedAuditLog)
//                        populates T (temporal causality). MUST follow step 5.
//   7. Register tier  — registerMatrixTier(_:for:) installs the rebuilt tier
//                       so RecallDirector scoring is live from the first recall.
//
// The ANN/HNSW index does NOT need an explicit rebuild step: VectorKit uses
// an O(N) in-process Hamming scan per query. The first query after hydrate
// operates on the hydrated `vectors` table rows with zero additional setup.
//
// WHY rows-then-Estate-open ordering: Estate.open reads the manifest from the
// storage backend to derive the estate UUID and zoom window. If open runs
// before the row-snapshot is present the manifest is absent and open fails.
// The hydrate must complete before open.
//
// Reference: REPLICATION_GROUND_TRUTH.md §Required hydrate ordering,
//            REPLICATION_TRACK_PLAN.md §3 GLK estate-level hydrate integration.

import Foundation
import OSLog
import LocusKit
import PersistenceKit
import PersistenceKitReplication

private let log = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

// MARK: - Hydrate-on-open API

public extension GeniusLocusKit {

    /// Open an estate by hydrating a fresh in-memory storage from a durable backend.
    ///
    /// This is the primary launch-time API for a GLK estate whose working state
    /// lives in an in-memory backend (fast reads, no disk I/O during session) but
    /// whose ground truth is persisted in a durable (SQLite) backend.
    ///
    /// The method performs the full hydrate sequence in order:
    ///
    ///   1. Schema open: open both `inMemory` and `durable` with the composite
    ///      `GeniusLocusKitSchema.estateSchemaDeclaration`. Both backends must
    ///      recognise the GLK composite kitID so the replication schema gate passes.
    ///      For `inMemory` this creates all 19 tables (blank, ready for hydration).
    ///      For `durable` this is idempotent — CREATE TABLE IF NOT EXISTS and a new
    ///      migration-version record for "GeniusLocusKit" (the data tables already
    ///      exist from prior LocusKit/VectorKit/CorpusKit opens).
    ///   2. Hydrate: copy all 19 schema-declared tables + audit events from
    ///      `durable` into `inMemory` via `StorageReplicator.hydrate`.
    ///   3. Open: run `LocusKit.Estate.open` against the now-populated `inMemory`
    ///      backend. The manifest is already present after step 2.
    ///   4. Feed audit log: bridge all drawers' audit events from the estate into
    ///      the GLK-level `UnifiedAuditLog` CRDT.
    ///   5. Rebuild matrix tier: call `MatrixTier.rebuild` then
    ///      `MatrixTier.rebuildTemporal` against the populated audit log.
    ///   6. Register tier: install the rebuilt tier so RecallDirector scoring
    ///      is active from the first recall.
    ///
    /// - Parameters:
    ///   - inMemory:   A freshly-constructed in-memory storage instance. This
    ///                 method opens it with the composite schema before hydrating.
    ///                 Typically `PersistenceKitInMemory.InMemoryStorage`.
    ///   - owner:      Credentials forwarded to `LocusKit.Estate.open`.
    ///   - durable:    An already-open durable storage (e.g. SQLite). This method
    ///                 calls `durable.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)`
    ///                 to register the GLK composite version in the migrations table.
    ///                 This is idempotent — the data tables already exist; only the
    ///                 migration version record for "GeniusLocusKit" is added if absent.
    /// - Returns:      A fresh `EstateHandle` for the hydrated estate.
    /// - Throws:
    ///   - `ReplicationError` if the schema gate fails or a storage operation fails.
    ///   - `GeniusLocusKitError.underlyingEstateFailure` if `Estate.open` fails.
    ///   - `GeniusLocusKitError.invalidManifest` if the manifest is malformed.
    ///   - `GeniusLocusKitError.duplicateEstate` if this estate's UUID is already open.
    func open(
        inMemory: any Storage,
        owner: OwnerCredentials,
        hydrateFrom durable: any Storage
    ) async throws -> EstateHandle {

        let schema = GeniusLocusKitSchema.estateSchemaDeclaration

        // Step 1 — Open both backends with the composite GLK schema.
        //
        // The replication schema gate (StorageReplicator.replicateFull) checks
        // `currentSchemaVersion(for: schema.kitID)` on BOTH source and destination.
        // A GLK estate in normal operation has its component kit schemas opened
        // individually (LocusKit opens "LocusKit" v1, VectorKit opens "VectorKit" v1,
        // etc.), but the GLK composite kitID "GeniusLocusKit" is never registered
        // unless we explicitly open it. We do that here for both backends:
        //
        //   - inMemory:  blank destination — creates all 19 tables + registers
        //                "GeniusLocusKit" composite version so the gate sees the composite version on destination.
        //   - durable:   existing source  — CREATE TABLE IF NOT EXISTS is a no-op for
        //                the 19 tables; records "GeniusLocusKit" composite version in the migrations
        //                table if not already present. Safe and idempotent.
        try await inMemory.open(schema: schema)
        try await durable.open(schema: schema)

        // Step 2 — Row snapshot + audit event copy.
        // StorageReplicator.hydrate copies all 19 schema-declared tables and the
        // _storagekit_audit table into `inMemory`. After this call the in-memory
        // backend contains the complete ground-truth state from the durable store.
        let cursor = try await StorageReplicator.hydrate(
            into: inMemory,
            from: durable,
            schema: schema
        )
        log.info("hydrate: rows=\(cursor.rowsWritten) auditEvents=\(cursor.auditEventsWritten)")

        // Step 3 — Estate open over the populated in-memory backend.
        // The manifest row is already present (copied in step 2). Estate.open
        // reads it to derive the estate UUID and zoom window.
        //
        // The Keychain key store is passed EXPLICITLY: this is a DURABLE
        // estate being served from hydrated in-memory storage, and its real
        // Ed25519 signing key lives in the login keychain. The backend-keyed
        // default would resolve `.inMemory` → InMemoryEstateIdentityKeyStore
        // and silently fail to load the key (grant signing would throw).
        let handle = try await open(
            storage: inMemory,
            owner: owner,
            identityKeyStore: KeychainEstateIdentityKeyStore()
        )

        // Steps 4-6 — Audit log, matrix rebuild.
        // Separated into a dedicated method so callers can also call it standalone
        // after a hot-reload (e.g. if they flush-then-hydrate on a live session).
        try await rebuildDerivedAccelerators(for: handle)

        log.info("open(hydrateFrom:): estate \(handle.estateUUID, privacy: .public) ready")
        return handle
    }

    /// Hydrate an already-open estate's derived accelerators from its durable
    /// storage.
    ///
    /// Use this when an estate was opened with a fresh in-memory backend that
    /// has already been hydrated via `StorageReplicator.hydrate`, but whose
    /// `UnifiedAuditLog` and `MatrixTier` have not yet been populated.
    ///
    /// Performs steps 3-5 of the hydrate sequence:
    ///   3. Feed audit log (bridge drawers → `UnifiedAuditLog` CRDT)
    ///   4. `MatrixTier.rebuild(from: log)` — F, O, C, liveRowCount
    ///   5. `MatrixTier.rebuildTemporal(from: log)` — T, temporalWatermarkHLC
    ///
    /// This method is idempotent: feeding the audit log with the same events
    /// again is a G-Set no-op, and the loaded-then-folded matrix equals a
    /// from-scratch rebuild (conformance-tested), so calling it twice produces
    /// the same registered tier.
    ///
    /// PERSISTENCE: the matrix tier is read from its on-disk SQLite snapshot
    /// (MatrixSnapshotStore) and folded FORWARD over only the audit tail past the
    /// snapshot's HLC watermark — it is NOT recomputed from the whole audit log on
    /// every launch. A full rebuild runs only when there is no snapshot (cold
    /// start) or the persisted format is stale. After computing, the fresh tier is
    /// persisted so the next launch loads it. This is the spec-mandated behaviour:
    /// all derived/reference state lives on disk, never memory-only, never
    /// reassembled from scratch on launch once it has been persisted.
    ///
    /// - Parameters:
    ///   - handle: A handle for an already-open estate. Must be in the registry.
    ///   - now: Persist timestamp for the saved snapshot's `updated_at` (metadata
    ///          only; the matrix math itself is deterministic and clock-free).
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    ///           Any storage-tier error surfaced by `AuditLog.iterate`.
    func rebuildDerivedAccelerators(
        for handle: EstateHandle,
        now: Date = Date()
    ) async throws {
        // Step 3 — Load the unified audit log.
        // `feedAuditLog` (N+1 per-drawer queries into a grow-only RAM dict)
        // is removed. `auditLog(for:)` now
        // issues a single bounded SQL query against `_storagekit_audit`.
        let log_ = try await auditLog(for: handle)

        // Build the eventTime map (rowID → authored-in-world epoch ms) so the
        // temporal (T) matrix pass keys off `eventTime`, not the capture HLC —
        // all temporal-cognition primitives key off eventTime. A bulk
        // historical import stamps every capture with one HLC, so hlc-based lags
        // are all 0 and no causality pairs form; the real ordering lives in each
        // drawer's eventTime. For streaming capture eventTime == captureTime, so
        // this leaves the T matrix unchanged there.
        let estate_ = try estate(for: handle)
        let drawers_ = try await estate_.allDrawers()
        var eventTimes: [UUID: Int64] = [:]
        eventTimes.reserveCapacity(drawers_.count)
        for d in drawers_ where !d.id.isEmpty {
            if let rowUUID = UUID(uuidString: d.id) {
                eventTimes[rowUUID] = Int64(d.eventTime.timeIntervalSince1970 * 1000)
            }
        }

        // Steps 4 + 5 — Matrix tier: LOAD from disk and fold the tail forward,
        // else cold-start full rebuild.
        let store = try await matrixSnapshotStore(for: handle)
        let tier: MatrixTier
        if let snapshot = try await store.load(estateID: handle.estateUUID) {
            // Persisted snapshot present: fold only the entries past its watermark
            // onto the loaded tier. incrementalUpdate is conformance-proven equal
            // to fullRebuild cell-for-cell, including cross-cursor expunge/withdraw
            // and temporal window-boundary pairs — so this is exact, not an
            // approximation, and it skips the O(N) full fold over the whole log.
            var loaded = snapshot.tier
            loaded.incrementalUpdate(from: log_, eventTimes: eventTimes)
            tier = loaded
            // Restore the persisted calibration registry if the estate has none in
            // memory yet — calibration is derived/reference state too, and lives in
            // the same on-disk snapshot row.
            if calibrationRegistries[handle] == nil {
                calibrationRegistries[handle] = snapshot.calibration
            }
            log.info("rebuildDerivedAccelerators: matrix tier loaded from snapshot + folded forward for \(handle.estateUUID, privacy: .public)")
        } else {
            // Cold start (no snapshot) or stale format — full two-pass rebuild.
            // fullRebuild runs F/O/C then T and merges them; see
            // MatrixTier.fullRebuild(from:) for the two-pass rationale.
            tier = MatrixTier.fullRebuild(from: log_, eventTimes: eventTimes)
            log.info("rebuildDerivedAccelerators: matrix tier full-rebuilt (no snapshot) for \(handle.estateUUID, privacy: .public)")
        }

        // Install the tier so RecallDirector scoring is live from the first recall.
        // Before this call matrixTiers[handle] is nil and all matrix score columns
        // read 0.0.
        registerMatrixTier(tier, for: handle)

        // Persist the freshly-computed tier so the NEXT launch loads it instead of
        // rebuilding. The watermark is the tier's lastHLC (the F/O/C cursor); the
        // saved calibration is the estate's current registry, defaulting to empty.
        let snapshot = MatrixSnapshot(
            tier: tier,
            calibration: calibrationRegistries[handle] ?? MatrixCalibrationRegistry(),
            hlcWatermark: tier.lastHLC
        )
        try await store.upsert(estateID: handle.estateUUID, snapshot: snapshot, now: now)

        // Persist the dense vector store's resident-array sidecar alongside the
        // matrix snapshot — both are derived accelerators that must live on disk so
        // a cold restart loads them instead of rebuilding from a full table scan.
        // The sidecar is write-behind; this is the periodic flush point (runs on
        // launch and on every dreaming cycle). No-op when the store has no sidecar
        // (in-memory backend) or no pending writes.
        if let vectorStore = vectorStores[handle] {
            do {
                try await vectorStore.flush()
            } catch {
                // A sidecar flush failure is non-fatal: the `vectors` table remains
                // the source of truth and the array rebuilds from it next launch.
                log.error("rebuildDerivedAccelerators: vector sidecar flush failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        log.info("rebuildDerivedAccelerators: matrix tier ready + persisted for \(handle.estateUUID, privacy: .public)")
    }

    /// Build a `MatrixSnapshotStore` over the estate's backing storage, ensuring
    /// its table exists. The schema migration is idempotent (CREATE TABLE IF NOT
    /// EXISTS under the store's own kitID), so calling this on every hydrate is
    /// safe and keeps the store available on every launch path (serve + hydrate)
    /// without threading a registry through wiring.
    private func matrixSnapshotStore(
        for handle: EstateHandle
    ) async throws -> MatrixSnapshotStore {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        try await storage.migrate(to: MatrixSnapshotStore.schemaDeclaration)
        return MatrixSnapshotStore(storage: storage)
    }

    // MARK: - Flush convenience

    /// Flush an open in-memory estate to a durable backend.
    ///
    /// Mirrors `open(inMemory:owner:hydrateFrom:)`: opens both backends with the
    /// composite `GeniusLocusKitSchema.estateSchemaDeclaration` so the replication
    /// schema gate passes, then calls `StorageReplicator.flush`.
    ///
    /// The caller is responsible for ensuring the in-memory storage used by the
    /// estate was opened with the composite schema (which is the case when the
    /// estate was opened via `open(inMemory:owner:hydrateFrom:)`).
    ///
    /// - Parameters:
    ///   - inMemory: The in-memory storage backing an already-open estate.
    ///   - durable:  The durable storage to flush into (e.g. SQLite). May be
    ///               empty (first flush) or contain a prior snapshot (re-flush).
    ///               This method calls `durable.open(schema:)` which is idempotent.
    /// - Returns: `ReplicationCursor` with row counts and HLC watermark.
    /// - Throws: `ReplicationError` if the schema gate fails or a storage error occurs.
    func flush(
        from inMemory: any Storage,
        into durable: any Storage
    ) async throws -> ReplicationCursor {
        let schema = GeniusLocusKitSchema.estateSchemaDeclaration

        // Open the composite schema on both backends so the replication gate
        // finds "GeniusLocusKit" composite version on both sides. For inMemory this is
        // idempotent if already opened via open(inMemory:owner:hydrateFrom:).
        // For durable this records "GeniusLocusKit" composite version in the migrations table
        // without altering existing data tables.
        try await inMemory.open(schema: schema)
        try await durable.open(schema: schema)

        let cursor = try await StorageReplicator.flush(from: inMemory, into: durable, schema: schema)
        log.info("flush: rows=\(cursor.rowsWritten) auditEvents=\(cursor.auditEventsWritten)")
        return cursor
    }
}
