// SharedContentMigration.swift
//
// The resumable, fail-dark legacy migration (GLK shared-content 1.1, P4).
//
// Migrates a pre-cutover estate — one whose Corpus lane copied Drawer text
// into the legacy `chunks` table and keyed derived rows by chunk UUID —
// onto the shared-content layout in place:
//
//   discovered → canonicalValidated → legacyInventoryCaptured →
//   legacyDerivedCleared → legacySchemaRetired → drawerIndexRebuilt →
//   verified → reclaimPending → complete
//
// Every transition is idempotent and persisted in a migration record that
// is INDEPENDENT of the derived tables being replaced, so a crash or
// cancellation resumes from the last verified transition. The Corpus lane
// stays explicitly dark until `verified`; LocusKit recall is available
// throughout. Drawers, audit and lineage state, relationships, and
// unrelated/shared vector representations are never reconstructed or
// deleted — the protected-state baseline folds prove it at verification.
//
// DETECTION keys on schema declarations plus table/column layout probes —
// never on one magic version number: a legacy estate is one whose storage
// still carries the `chunks` copy lane. Fresh post-cutover estates never
// create it and bypass migration entirely.
//
// Rust twin: `rust/src/shared_content_migration.rs`.

import CorpusKit
import Foundation
import OSLog
import PersistenceKit
import VectorKit

private let migrationLog = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

// MARK: - State machine

/// The durable migration states, in order.
public enum SharedContentMigrationState: String, Sendable, Codable, CaseIterable {
    case discovered
    case canonicalValidated
    case legacyInventoryCaptured
    case legacyDerivedCleared
    case legacySchemaRetired
    case drawerIndexRebuilt
    case verified
    case reclaimPending
    case complete

    /// Ordinal for resume comparisons (declaration order).
    var ordinal: Int { Self.allCases.firstIndex(of: self)! }
}

/// The migration outcome surfaced to the caller/status surface.
public struct SharedContentMigrationReport: Sendable, Equatable {
    public let state: SharedContentMigrationState
    /// Legacy chunk rows inventoried (0 when fresh).
    public let legacyChunkCount: Int
    /// Exact legacy vector keys deleted.
    public let legacyVectorKeyCount: Int
    /// Drawers re-indexed in the rebuild.
    public let rebuiltContentCount: Int
    /// Estimated reclaimable bytes recorded at `reclaimPending`
    /// (freelist pages × page size; nil off-SQLite or pre-reclaim).
    public let estimatedReclaimableBytes: Int64?
}

/// Migration/reclaim status for the estate status/admin surface
/// (`sharedContentReclaimStatus`). All fields are nil-tolerant so the one
/// shape serves fresh estates (no record), mid-migration estates, and
/// completed estates.
public struct SharedContentReclaimStatus: Sendable, Equatable {
    /// The persisted migration state; nil when no record exists (a fresh
    /// estate that never ran detection).
    public let state: SharedContentMigrationState?
    /// The estimate captured at `reclaimPending` (freelist pages × page
    /// size at that moment).
    public let estimatedReclaimableBytes: Int64?
    /// Filesystem bytes the completed maintenance pass actually released.
    public let reclaimedBytes: Int64?
    /// LIVE estimate from the storage maintenance surface (freelist + WAL
    /// bytes right now); nil when the backend has no maintenance surface.
    public let liveReclaimableBytes: Int64?
}

/// A migration failure that leaves the lane dark, carrying the exact state
/// and retry action.
public enum SharedContentMigrationError: Error, Equatable {
    /// One or more legacy source_ids do not resolve to an existing Drawer.
    /// The migration stops dark BEFORE any destructive step; drawers are
    /// never synthesized from chunk text.
    case orphanedLegacySources(ids: [String], state: SharedContentMigrationState)
    /// Post-rebuild verification found a mismatch; the deletion inventory
    /// and record are retained for diagnosis.
    case verificationFailed(reason: String)
    /// A storage step failed at the recorded state; re-run to resume.
    case storageFailure(state: SharedContentMigrationState, reason: String)
    /// Test-seam fault injection fired after the recorded state.
    case injectedFault(after: SharedContentMigrationState)
}

// MARK: - Durable record

/// The persisted migration record (one singleton row per estate).
public struct SharedContentMigrationRecord: Sendable, Codable, Equatable {
    public var state: SharedContentMigrationState
    /// The layout marks detection observed ("legacy-chunks+metadata",
    /// "legacy-chunks", "fresh").
    public var detectedLayout: String
    /// Exact legacy chunk IDs (the BM25/vector deletion inventory).
    public var legacyChunkIDs: [String]
    /// Exact legacy vector keys (itemID|vectorIndex|modelID triples).
    public var legacyVectorKeys: [String]
    /// Protected-state baseline folds (table → contentFold) captured
    /// BEFORE any destructive step.
    public var protectedBaseline: [String: String]
    /// Rebuild resume cursor: the last content ID whose indexContent
    /// completed (ascending-ID streaming order).
    public var rebuildCursor: String?
    /// Drawers re-indexed so far.
    public var rebuiltContentCount: Int
    /// Estimated reclaimable bytes recorded at reclaimPending.
    public var estimatedReclaimableBytes: Int64?
    /// Filesystem bytes actually released by the maintenance pass at
    /// completion (nil until `completeSharedContentReclaim` runs).
    public var reclaimedBytes: Int64?
    /// Inventory counts persisted at completion so the bulky ID lists can be
    /// TRIMMED from the record (P6: a 1.1M-key inventory held ~60 MB in the
    /// record row forever; the evidence is consumed at verification).
    public var legacyChunkCount: Int?
    public var legacyVectorKeyCount: Int?
}

/// Store for the migration record. Its table is deliberately OUTSIDE every
/// composite/profile declaration — migration bookkeeping must survive the
/// replacement of the tables it describes.
public actor SharedContentMigrationStore {

    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "GLKSharedContentMigration",
        version: 1,
        tables: [
            TableDeclaration(
                name: "glk_shared_content_migration",
                columns: [
                    .text("id", nullable: false),
                    .text("state", nullable: false),
                    .json("record", nullable: false),
                    .timestamp("updated_at", nullable: false)
                ],
                primaryKey: ["id"]
            )
        ]
    )

    private static let singletonID = "shared-content-1.1"
    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    public func load() async throws -> SharedContentMigrationRecord? {
        let rows = try await storage.rowStore.query(
            table: "glk_shared_content_migration",
            where: .eq(Column(table: "glk_shared_content_migration", name: "id"),
                       .text(Self.singletonID)),
            orderBy: [], limit: 1, offset: nil)
        // Primitive tolerance (the BasisStore discipline): the SQLite
        // backend may hand a JSON column back as .json, .blob, or .text.
        guard let row = rows.first else { return nil }
        let data: Data
        switch row["record"] ?? .null {
        case .json(let d): data = d
        case .blob(let d): data = d
        case .text(let t): data = Data(t.utf8)
        default: return nil
        }
        return try JSONDecoder().decode(SharedContentMigrationRecord.self, from: data)
    }

    public func save(_ record: SharedContentMigrationRecord, now: Date) async throws {
        _ = try await storage.rowStore.upsert(
            table: "glk_shared_content_migration",
            values: [
                "id": .text(Self.singletonID),
                "state": .text(record.state.rawValue),
                "record": .json(try JSONEncoder().encode(record)),
                "updated_at": .timestamp(now)
            ],
            conflictColumns: ["id"])
    }
}

// MARK: - Detection

public enum SharedContentMigrationDetection {
    /// Probe the storage for the legacy copy lane. Fresh post-cutover
    /// estates never create `chunks`, so a present table IS the legacy
    /// mark; `corpus_metadata` distinguishes the v3-era layout from the
    /// v2/v7 era. Structural probes — never a version literal.
    public static func detectLegacyLayout(storage: any Storage) async -> String? {
        let chunksPresent = (try? await storage.rowStore.count(table: "chunks", where: nil)) != nil
        guard chunksPresent else { return nil }
        let metadataPresent =
            (try? await storage.rowStore.count(table: "corpus_metadata", where: nil)) != nil
        return metadataPresent ? "legacy-chunks+metadata" : "legacy-chunks"
    }
}

// MARK: - Retirement declaration

/// The DECLARED PersistenceKit migration that retires the legacy copy-lane
/// tables. Registered under the "CorpusKit" kit ID the legacy BundleStore
/// recorded, stepping every accepted legacy version to the retired layout
/// (v4). Both ports declare the identical operations; every supported
/// backend executes them through its own emitter.
enum SharedContentRetirement {
    static let retiredVersion = 4

    static var declaration: SchemaDeclaration {
        let operations: [SchemaOperation] = [
            .dropIndex(name: "idx_chunks_source"),
            .dropIndex(name: "idx_chunks_hlc"),
            .dropTable(name: "chunks"),
            .dropTable(name: "corpus_metadata"),
            .dropTable(name: "removed_sources")
        ]
        return SchemaDeclaration(
            kitID: "CorpusKit",
            version: retiredVersion,
            tables: [],
            indices: [],
            migrations: [
                // Every accepted legacy era steps through the same
                // retirement: v2 (pre corpus_metadata) and v3 (pre-cutover).
                Migration(fromVersion: 2, toVersion: 3, operations: []),
                Migration(fromVersion: 3, toVersion: retiredVersion, operations: operations)
            ]
        )
    }
}

// MARK: - Runner

public extension GeniusLocusKit {

    /// Test seam: when non-nil, the migration throws `injectedFault` right
    /// AFTER persisting the named state — the resume-proof harness.
    internal var _sharedContentFaultAfter: SharedContentMigrationState? {
        get { _sharedContentFaultAfterStorage }
        set { _sharedContentFaultAfterStorage = newValue }
    }

    /// Install the fault-injection seam (test-only; single-use).
    internal func _setSharedContentFault(_ state: SharedContentMigrationState?) {
        _sharedContentFaultAfterStorage = state
    }

    /// Whether the estate's Corpus lane must stay DARK: a legacy copy lane
    /// is present and the migration record has not reached `verified`.
    /// LocusKit recall is unaffected either way.
    func sharedContentLaneMustStayDark(storage: any Storage) async -> Bool {
        guard await SharedContentMigrationDetection.detectLegacyLayout(storage: storage) != nil
        else { return false }
        try? await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
        let state = try? await SharedContentMigrationStore(storage: storage).load()?.state
        guard let state else { return true }
        return state.ordinal < SharedContentMigrationState.verified.ordinal
    }

    /// Run (or resume) the shared-content migration for `handle`'s estate.
    ///
    /// Idempotent and resumable: re-running continues from the persisted
    /// state. On a fresh (post-cutover) estate the record completes
    /// immediately. Returns the final report; throws a
    /// `SharedContentMigrationError` that leaves the lane dark otherwise.
    @discardableResult
    func runSharedContentMigration(
        handle: EstateHandle, now: Date
    ) async throws -> SharedContentMigrationReport {
        guard let storage = storages[handle] else {
            throw SharedContentMigrationError.storageFailure(
                state: .discovered, reason: "no storage registered for estate")
        }
        let estateObj = try estate(for: handle)
        let source = LocusDrawerCorpusContentSource(estate: estateObj)
        try await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
        let store = SharedContentMigrationStore(storage: storage)

        var record: SharedContentMigrationRecord
        if let existing = try await store.load() {
            record = existing
        } else {
            // 1. discovered — structural detection, never a version number.
            let layout = await SharedContentMigrationDetection.detectLegacyLayout(storage: storage)
            record = SharedContentMigrationRecord(
                state: .discovered,
                detectedLayout: layout ?? "fresh",
                legacyChunkIDs: [], legacyVectorKeys: [],
                protectedBaseline: [:],
                rebuildCursor: nil, rebuiltContentCount: 0,
                estimatedReclaimableBytes: nil, reclaimedBytes: nil,
                legacyChunkCount: nil, legacyVectorKeyCount: nil)
            if layout == nil {
                // Fresh estate: bypass — nothing legacy exists or ever will.
                record.state = .complete
            }
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }
        if record.state == .complete {
            return report(for: record)
        }

        // 2. canonicalValidated — every active legacy source resolves to a
        //    Drawer. Stop dark on orphans; never synthesize Drawers.
        if record.state.ordinal < SharedContentMigrationState.canonicalValidated.ordinal {
            let sourceIDs = try await legacySourceIDs(storage: storage)
            var orphans: [String] = []
            for id in sourceIDs {
                if try await source.record(for: id) == nil { orphans.append(id) }
            }
            if !orphans.isEmpty {
                migrationLog.error(
                    "shared-content migration: \(orphans.count, privacy: .public) orphaned legacy sources — lane stays dark")
                throw SharedContentMigrationError.orphanedLegacySources(
                    ids: orphans.sorted(), state: .canonicalValidated)
            }
            record.state = .canonicalValidated
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 3. legacyInventoryCaptured — exact chunk IDs, exact vector keys,
        //    protected baselines. All captured BEFORE anything is dropped.
        if record.state.ordinal < SharedContentMigrationState.legacyInventoryCaptured.ordinal {
            let chunkIDs = try await legacyChunkIDs(storage: storage)
            record.legacyChunkIDs = chunkIDs
            record.legacyVectorKeys = try await legacyVectorKeys(
                storage: storage, chunkIDs: Set(chunkIDs))
            record.protectedBaseline = try await protectedBaseline(
                storage: storage, legacyVectorKeys: Set(record.legacyVectorKeys))
            record.state = .legacyInventoryCaptured
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 4. legacyDerivedCleared — delete EXACTLY the inventoried keys.
        if record.state.ordinal < SharedContentMigrationState.legacyDerivedCleared.ordinal {
            let vectorStore = VectorStore(
                storage: storage, sidecarURL: VectorStore.defaultSidecarURL(for: storage))
            var exactKeys: [VectorExactKey] = []
            for encoded in record.legacyVectorKeys {
                let parts = encoded.components(separatedBy: "|")
                guard parts.count == 3, let index = Int(parts[1]) else { continue }
                exactKeys.append(VectorExactKey(
                    itemID: parts[0], vectorIndex: index, modelID: parts[2]))
            }
            try await vectorStore.deleteVectors(keys: exactKeys)
            // Chunk-keyed BM25 postings, provider basis/counts, old
            // checkpoints: all rebuildable derived state, cleared wholesale
            // (they are corpus-exclusive tables).
            let iix = InvertedIndexStore(storage: storage)
            try await storage.migrate(to: InvertedIndexStore.schemaDeclaration)
            try await iix.open()
            try await iix.deleteAll()
            try await storage.migrate(to: BasisStore.schemaDeclaration)
            try await BasisStore(storage: storage).deleteAll()
            try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
            try await CorpusProviderCountsStore(storage: storage).deleteAll()
            try await storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)
            try await CorpusIndexStateStore(storage: storage).clearAll()
            record.state = .legacyDerivedCleared
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 5. legacySchemaRetired — drop the copy-lane tables through the
        //    DECLARED PersistenceKit migration (dropTable), then install
        //    the attached profile.
        if record.state.ordinal < SharedContentMigrationState.legacySchemaRetired.ordinal {
            try await storage.migrate(to: SharedContentRetirement.declaration)
            try await storage.migrate(to: CorpusSchemaProfile.attachedDeclaration)
            try await storage.migrate(to: VectorRepresentationClaims.schemaDeclaration)
            record.state = .legacySchemaRetired
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 6. drawerIndexRebuilt — stream active Drawers in ascending ID
        //    order through the attached engine; checkpoint the cursor so a
        //    crash resumes mid-stream. Bounded memory: IDs stream in pages
        //    through the adapter; indexContent embeds one Drawer at a time.
        if record.state.ordinal < SharedContentMigrationState.drawerIndexRebuilt.ordinal {
            let engine: CorpusContentEngine
            if let registered = corpusKits[handle] {
                engine = registered
            } else {
                engine = try await CorpusContentEngine(
                    storage: storage,
                    configuration: CorpusContentConfiguration(
                        mode: .attached, indexUnit: .wholeContent),
                    source: source)
            }
            // Deferred-index window (P6 scale fix): the engine's vector
            // write path rebuilds the resident binary index from the full
            // snapshot per call — O(n) per Drawer, quadratic over a
            // 100k-drawer rebuild. The deferred window makes every write
            // O(batch) and rebuilds the resident index ONCE at publish.
            // Crash-safe: the vectors TABLE is the durable source of truth;
            // a crash inside the window loses only the resident index,
            // which the next open rebuilds from the table, and the resumed
            // run opens a fresh window.
            try await engine.sharedVectorStore.beginDeferredIndex()
            let allIDs = try await source.activeContentIDs()
            var resumeFrom = 0
            if let cursor = record.rebuildCursor,
               let position = allIDs.firstIndex(where: { $0 > cursor }) {
                resumeFrom = position
            } else if record.rebuildCursor != nil {
                resumeFrom = allIDs.count
            }
            var processed = record.rebuiltContentCount
            let checkpointStride = 500
            var sinceCheckpoint = 0
            for id in allIDs[resumeFrom...] {
                try await engine.indexContent(id: id, now: now)
                processed += 1
                sinceCheckpoint += 1
                if sinceCheckpoint >= checkpointStride {
                    record.rebuildCursor = id
                    record.rebuiltContentCount = processed
                    try await store.save(record, now: now)
                    sinceCheckpoint = 0
                }
            }
            try await engine.sharedVectorStore.publishResidentIndex()
            record.rebuildCursor = allIDs.last
            record.rebuiltContentCount = processed
            record.state = .drawerIndexRebuilt
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 7. verified — reconcile IDs, prove direct hydration, compare
        //    protected baselines, prove no chunk artifact survives. A
        //    mismatch stops BEFORE the inventory/evidence is discarded.
        if record.state.ordinal < SharedContentMigrationState.verified.ordinal {
            try await verify(record: record, storage: storage, source: source)
            record.state = .verified
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 8. reclaimPending — the lane is available from here; physical
        //    page reclamation runs via the maintenance surface (P5) and is
        //    retryable during a maintenance window.
        if record.state.ordinal < SharedContentMigrationState.reclaimPending.ordinal {
            if let introspectable = storage as? any StorageIntrospection,
               let stats = try? await introspectable.stats(now: now),
               let freelist = stats.freelistPageCount, let pageSize = stats.pageSize {
                record.estimatedReclaimableBytes = Int64(freelist) * Int64(pageSize)
            }
            record.state = .reclaimPending
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 9. complete — after physical reclamation (P5's maintenance API).
        //    `completeSharedContentReclaim` flips the final state; until
        //    then the record honestly reports reclaimPending.
        return report(for: record)
    }

    /// Run the physical reclamation and mark the reclaim outcome (the P5
    /// completion hook). Idempotent: a record not in `reclaimPending`
    /// returns nil without touching storage.
    ///
    /// The reclamation itself is the PersistenceKit maintenance pass (WAL
    /// checkpoint + VACUUM on SQLite) probed via `StorageMaintenance` —
    /// call during a maintenance window; the pass requires quiescence and
    /// enough free disk for the live-page rewrite, and a failure leaves the
    /// record at `reclaimPending` for retry. Backends without a maintenance
    /// surface (or with server-managed reclamation) complete with a nil/no-op
    /// report — the record still flips to `complete`.
    @discardableResult
    func completeSharedContentReclaim(
        handle: EstateHandle, now: Date
    ) async throws -> StorageMaintenanceReport? {
        guard let storage = storages[handle] else { return nil }
        let store = SharedContentMigrationStore(storage: storage)
        guard var record = try await store.load(),
              record.state == .reclaimPending else { return nil }
        var report: StorageMaintenanceReport?
        if let maintenance = storage as? any StorageMaintenance {
            report = try await maintenance.performMaintenance()
        }
        record.reclaimedBytes = report?.reclaimedBytes ?? 0
        // Trim the consumed evidence (P6): the deletion inventory and the
        // protected baseline exist to drive and verify the migration; once
        // physically reclaimed, only the outcome (state, counts, cursor,
        // reclaimed bytes) stays durable — a 110k-chunk / 1.1M-key estate
        // otherwise carries ~60 MB of record forever.
        record.legacyChunkCount = record.legacyChunkIDs.count
        record.legacyVectorKeyCount = record.legacyVectorKeys.count
        record.legacyChunkIDs = []
        record.legacyVectorKeys = []
        record.protectedBaseline = [:]
        record.state = .complete
        try await store.save(record, now: now)
        return report
    }

    /// The migration record's current state for the status surface (nil
    /// when no record exists — a fresh estate that never ran detection).
    func sharedContentMigrationState(
        handle: EstateHandle
    ) async throws -> SharedContentMigrationState? {
        guard let storage = storages[handle] else { return nil }
        // The record table may not exist yet on a never-migrated estate.
        try await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
        return try await SharedContentMigrationStore(storage: storage).load()?.state
    }

    /// Migration/reclaim status for the estate status/admin surface: the
    /// persisted state and estimates plus the LIVE reclaimable-bytes figure
    /// from the storage maintenance surface. Read-only; safe to poll.
    func sharedContentReclaimStatus(
        handle: EstateHandle
    ) async throws -> SharedContentReclaimStatus {
        guard let storage = storages[handle] else {
            return SharedContentReclaimStatus(
                state: nil, estimatedReclaimableBytes: nil,
                reclaimedBytes: nil, liveReclaimableBytes: nil)
        }
        try await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
        let record = try await SharedContentMigrationStore(storage: storage).load()
        let live: Int64?
        if let maintenance = storage as? any StorageMaintenance {
            live = try? await maintenance.estimatedReclaimableBytes()
        } else {
            live = nil
        }
        return SharedContentReclaimStatus(
            state: record?.state,
            estimatedReclaimableBytes: record?.estimatedReclaimableBytes,
            reclaimedBytes: record?.reclaimedBytes,
            liveReclaimableBytes: live)
    }

    // MARK: - Steps

    private func checkFault(after state: SharedContentMigrationState) throws {
        if let fault = _sharedContentFaultAfter, fault == state {
            _sharedContentFaultAfter = nil
            throw SharedContentMigrationError.injectedFault(after: state)
        }
    }

    private func report(for record: SharedContentMigrationRecord) -> SharedContentMigrationReport {
        SharedContentMigrationReport(
            state: record.state,
            legacyChunkCount: record.legacyChunkCount ?? record.legacyChunkIDs.count,
            legacyVectorKeyCount: record.legacyVectorKeyCount ?? record.legacyVectorKeys.count,
            rebuiltContentCount: record.rebuiltContentCount,
            estimatedReclaimableBytes: record.estimatedReclaimableBytes)
    }

    private func legacySourceIDs(storage: any Storage) async throws -> [String] {
        let rows = try await storage.rowStore.query(
            table: "chunks", where: nil, orderBy: [], limit: nil, offset: nil)
        var out: Set<String> = []
        for row in rows {
            if case let .text(sourceID)? = row["source_id"] { out.insert(sourceID) }
        }
        return out.sorted()
    }

    private func legacyChunkIDs(storage: any Storage) async throws -> [String] {
        let rows = try await storage.rowStore.query(
            table: "chunks", where: nil, orderBy: [], limit: nil, offset: nil)
        var out: [String] = []
        for row in rows {
            if case let .uuid(id)? = row["id"] {
                out.append(id.uuidString)
            } else if case let .text(id)? = row["id"] {
                out.append(id.uppercased())
            }
        }
        return out.sorted()
    }

    /// Exact vector keys whose item_id is a legacy chunk ID — the ONLY
    /// vectors the migration may delete. Drawer-keyed rows (same model or
    /// not) are shared/retained representations and are never touched.
    private func legacyVectorKeys(
        storage: any Storage, chunkIDs: Set<String>
    ) async throws -> [String] {
        let rows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        var out: [String] = []
        for row in rows {
            guard case let .text(itemID)? = row["item_id"],
                  chunkIDs.contains(itemID.uppercased()),
                  case let .int(vectorIndex)? = row["vector_index"],
                  case let .text(modelID)? = row["model_id"] else { continue }
            out.append("\(itemID)|\(vectorIndex)|\(modelID)")
        }
        return out.sorted()
    }

    /// Protected-state baseline: drawers (canonical), associations, and
    /// the NON-legacy vector rows (shared/unrelated representations).
    /// hlc/created_at style wall-clock columns are excluded so the folds
    /// compare across capture instants.
    private func protectedBaseline(
        storage: any Storage, legacyVectorKeys: Set<String>
    ) async throws -> [String: String] {
        var baseline: [String: String] = [:]
        let inventory = try await DatabaseInventory.capture(
            storage: storage,
            tables: ["drawers", "associations"],
            excludingColumns: [:])
        for entry in inventory { baseline[entry.table] = entry.contentFold }
        baseline["vectors:protected"] = try await protectedVectorsFold(
            storage: storage, legacyVectorKeys: legacyVectorKeys)
        return baseline
    }

    /// Order-independent fold over the NON-legacy vector rows' logical
    /// bytes (surrogate id excluded — it churns on upsert by design).
    private func protectedVectorsFold(
        storage: any Storage, legacyVectorKeys: Set<String>
    ) async throws -> String {
        // Pin the DECLARED VectorKit schema before reading (P6 scale
        // finding): row decode forms depend on the connection's accumulated
        // schema view, and the baseline capture runs BEFORE any engine has
        // declared the vectors schema while verification runs AFTER — same
        // bytes decoded through different views fold differently and fail
        // verification as a false positive. Idempotent migrate makes both
        // folds read through the same declared view. Mirrors the Rust twin.
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        let rows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        var combined: UInt64 = 0
        for row in rows {
            guard case let .text(itemID)? = row["item_id"],
                  case let .int(vectorIndex)? = row["vector_index"],
                  case let .text(modelID)? = row["model_id"] else { continue }
            let key = "\(itemID)|\(vectorIndex)|\(modelID)"
            guard !legacyVectorKeys.contains(key) else { continue }
            let encoded = DatabaseInventory.canonicalRowEncoding(row, excluding: ["id"])
            var h: UInt64 = 14_695_981_039_346_656_037
            for byte in encoded.utf8 { h = (h ^ UInt64(byte)) &* 1_099_511_628_211 }
            combined = combined &+ h
        }
        return String(format: "%016llx", combined)
    }

    private func verify(
        record: SharedContentMigrationRecord,
        storage: any Storage,
        source: LocusDrawerCorpusContentSource
    ) async throws {
        // No chunk-keyed artifact or copied-text table survives.
        if (try? await storage.rowStore.count(table: "chunks", where: nil)) != nil {
            throw SharedContentMigrationError.verificationFailed(
                reason: "legacy chunks table still present after retirement")
        }
        if (try? await storage.rowStore.count(table: "corpus_metadata", where: nil)) != nil {
            throw SharedContentMigrationError.verificationFailed(
                reason: "legacy corpus_metadata table still present after retirement")
        }
        let activeIDs = Set(try await source.activeContentIDs())
        // Every vector item hydrates DIRECTLY as a Drawer (or aggregates to
        // one) — no legacy chunk key survives.
        let vectorRows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        let legacyChunkSet = Set(record.legacyChunkIDs)
        for row in vectorRows {
            guard case let .text(itemID)? = row["item_id"] else { continue }
            if legacyChunkSet.contains(itemID.uppercased()) {
                throw SharedContentMigrationError.verificationFailed(
                    reason: "chunk-keyed vector survived the selective delete: \(itemID)")
            }
        }
        // Reconcile checkpoints against the canonical set.
        let indexState = CorpusIndexStateStore(storage: storage)
        let indexedIDs = Set(try await indexState.allStates()
            .map(\.contentID)
            .filter { !$0.hasPrefix("\u{1F}") })
        if !activeIDs.isSubset(of: indexedIDs) {
            let missing = activeIDs.subtracting(indexedIDs).sorted().prefix(5)
            throw SharedContentMigrationError.verificationFailed(
                reason: "rebuild coverage gap — unindexed drawers: \(missing.joined(separator: ", "))")
        }
        // Protected-state folds must match the pre-destruction baseline.
        let current = try await protectedBaseline(
            storage: storage, legacyVectorKeys: [])
        for (table, fold) in record.protectedBaseline {
            if table == "vectors:protected" { continue }
            if current[table] != fold {
                throw SharedContentMigrationError.verificationFailed(
                    reason: "protected table \(table) changed during migration")
            }
        }
        // The protected (non-legacy) vector rows: every baseline row must
        // still be present with identical logical bytes. The rebuild ADDS
        // Drawer-keyed rows, so compare via superset fold semantics: recompute
        // the fold over exactly the baseline's key population.
        let baselineProtected = record.protectedBaseline["vectors:protected"]
        if let baselineProtected {
            let refold = try await protectedVectorsFold(
                storage: storage,
                legacyVectorKeys: Set(rebuiltVectorKeys(
                    storage: storage, excludingBaselineOf: record)))
            if refold != baselineProtected {
                throw SharedContentMigrationError.verificationFailed(
                    reason: "shared/unrelated vector bytes changed during migration")
            }
        }
    }

    /// Keys of vector rows the REBUILD created: Drawer-keyed rows under the
    /// representations the "corpus" consumer CLAIMS. Other lanes'
    /// drawer-keyed rows (a shared/unrelated representation under a
    /// different model) are NOT excluded — they must refold identically to
    /// the baseline, which is exactly the protection being proved.
    private func rebuiltVectorKeys(
        storage: any Storage, excludingBaselineOf record: SharedContentMigrationRecord
    ) async throws -> [String] {
        let indexState = CorpusIndexStateStore(storage: storage)
        let rebuilt = Set(try await indexState.allStates()
            .map(\.contentID)
            .filter { !$0.hasPrefix("\u{1F}") })
        let claims = VectorRepresentationClaims(storage: storage)
        let corpusModels = Set(
            (try await claims.claims(consumer: CorpusContentEngine.claimsConsumer))
                .map(\.modelID))
        let rows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        var out: [String] = []
        for row in rows {
            guard case let .text(itemID)? = row["item_id"],
                  rebuilt.contains(itemID),
                  case let .text(modelID)? = row["model_id"],
                  corpusModels.contains(modelID),
                  case let .int(vectorIndex)? = row["vector_index"] else { continue }
            out.append("\(itemID)|\(vectorIndex)|\(modelID)")
        }
        return out
    }
}
