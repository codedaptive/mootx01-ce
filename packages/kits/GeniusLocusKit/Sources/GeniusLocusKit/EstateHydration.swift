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
//                       This registers "GeniusLocusKit" v3 in both backends so
//                       the replication schema gate (which checks per-kitID version)
//                       passes. For inMemory this creates all 14 tables blank.
//                       For durable this is idempotent (CREATE TABLE IF NOT EXISTS).
//   2. Row snapshot   — StorageReplicator.hydrate copies all 14 schema.tables
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
    ///      For `inMemory` this creates all 14 tables (blank, ready for hydration).
    ///      For `durable` this is idempotent — CREATE TABLE IF NOT EXISTS and a new
    ///      migration-version record for "GeniusLocusKit" (the data tables already
    ///      exist from prior LocusKit/VectorKit/CorpusKit opens).
    ///   2. Hydrate: copy all 14 schema-declared tables + audit events from
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
        //   - inMemory:  blank destination — creates all 14 tables + registers
        //                "GeniusLocusKit" v3 so the gate sees version 3 on destination.
        //   - durable:   existing source  — CREATE TABLE IF NOT EXISTS is a no-op for
        //                the 14 tables; records "GeniusLocusKit" v3 in the migrations
        //                table if not already present. Safe and idempotent.
        try await inMemory.open(schema: schema)
        try await durable.open(schema: schema)

        // Step 2 — Row snapshot + audit event copy.
        // StorageReplicator.hydrate copies all 14 schema-declared tables and the
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
        let handle = try await open(storage: inMemory, owner: owner)

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
    /// again is a G-Set no-op, and rebuilding the matrix from the same log
    /// produces the same result.
    ///
    /// - Parameters:
    ///   - handle: A handle for an already-open estate. Must be in the registry.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    ///           Any LocusKit error surfaced by `feedAuditLog`.
    func rebuildDerivedAccelerators(for handle: EstateHandle) async throws {
        // Step 3 — Feed the unified audit log.
        // feedAuditLog bridges per-drawer audit events from the estate's durable
        // storage into the GLK-level UnifiedAuditLog CRDT. This is required before
        // matrix rebuild: MatrixTier.rebuild consumes the CRDT, not raw storage events.
        try await feedAuditLog(for: handle)

        // Steps 4 + 5 — Matrix rebuild.
        // The two-step rebuild is documented in REPLICATION_GROUND_TRUTH.md §Fact 3.3:
        // rebuild(from:) populates F, C, O, liveRowCount, lastHLC;
        // rebuildTemporal(from:) populates T (temporal causality crosses pairs of rows).
        // Calling rebuild alone does NOT populate T. Both must run for full fidelity.
        let log_ = try auditLog(for: handle)
        // fullRebuild runs both passes (F/O/C then T) and merges the results
        // into a single tier — see MatrixTier.fullRebuild(from:) for the
        // rationale behind the two-pass design and the internal merge.
        let tier = MatrixTier.fullRebuild(from: log_)

        // Install the rebuilt tier so RecallDirector scoring is live from the
        // first recall against this estate. Before this call matrixTiers[handle]
        // is nil and all matrix score columns read 0.0.
        registerMatrixTier(tier, for: handle)

        log.info("rebuildDerivedAccelerators: matrix tier ready for \(handle.estateUUID, privacy: .public)")
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
        // finds "GeniusLocusKit" v3 on both sides. For inMemory this is
        // idempotent if already opened via open(inMemory:owner:hydrateFrom:).
        // For durable this records "GeniusLocusKit" v3 in the migrations table
        // without altering existing data tables.
        try await inMemory.open(schema: schema)
        try await durable.open(schema: schema)

        let cursor = try await StorageReplicator.flush(from: inMemory, into: durable, schema: schema)
        log.info("flush: rows=\(cursor.rowsWritten) auditEvents=\(cursor.auditEventsWritten)")
        return cursor
    }
}
