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
import CorpusKitProviders
import Foundation
import GeniusLocusKit
import LocusKit
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
    case basesTrained
    case providersCovered
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
    /// Refused before legacy derived state is cleared because the declared
    /// training working-set budget cannot safely hold this estate.
    case insufficientTrainingCapacity(
        contentCount: Int, requiredBytes: UInt64, budgetBytes: UInt64)
    /// The circuit breaker parked this migration after repeated identical
    /// failures. Call `clearParkedSharedContentMigration` or wait for a
    /// version upgrade to allow retries. moot-mgr's respawn loop detects
    /// this case and idles instead of spinning at 100% CPU.
    case migrationParked(
        atState: SharedContentMigrationState,
        failureCount: Int,
        error: String,
        parkedAt: String)

    /// A brief, stable description used by the circuit breaker to detect
    /// consecutive identical failures. Volatile per-run context (timestamps,
    /// row IDs) is excluded; the error class and first 200 chars of the
    /// reason form a stable identity key.
    var briefDescription: String {
        switch self {
        case .orphanedLegacySources(_, let state):
            return "orphanedLegacySources:\(state.rawValue)"
        case .verificationFailed(let reason):
            return "verificationFailed:\(reason.prefix(200))"
        case .storageFailure(let state, let reason):
            return "storageFailure:\(state.rawValue):\(reason.prefix(200))"
        case .injectedFault(let after):
            return "injectedFault:\(after.rawValue)"
        case .insufficientTrainingCapacity:
            return "insufficientTrainingCapacity"
        case .migrationParked:
            return "migrationParked"
        }
    }
}

/// Conservative five-signal training-capacity contract. The calibrated
/// 320 KiB/content slope exceeds the measured 26.9 GiB / 98,118-Drawer Rust
/// peak; the 2 GiB floor covers runtime and fixed provider workspaces. By
/// default migration may consume at most 80% of physical RAM. Operators may
/// provide a lower cgroup/job budget with MOOT_MIGRATION_MEMORY_BUDGET_BYTES.
public enum SharedContentTrainingCapacity {
    public static let fixedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    public static let bytesPerContent: UInt64 = 320 * 1_024

    public static func requiredBytes(contentCount: Int) -> UInt64 {
        fixedBytes + UInt64(max(0, contentCount)) * bytesPerContent
    }

    public static func budgetBytes(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt64 {
        if let raw = environment["MOOT_MIGRATION_MEMORY_BUDGET_BYTES"],
           let explicit = UInt64(raw), explicit > 0 {
            return explicit
        }
        return ProcessInfo.processInfo.physicalMemory * 4 / 5
    }

    public static func require(contentCount: Int) throws {
        try require(contentCount: contentCount, budgetBytes: budgetBytes())
    }

    public static func require(contentCount: Int, budgetBytes: UInt64) throws {
        let required = requiredBytes(contentCount: contentCount)
        guard required <= budgetBytes else {
            throw SharedContentMigrationError.insufficientTrainingCapacity(
                contentCount: contentCount, requiredBytes: required, budgetBytes: budgetBytes)
        }
    }
}

// MARK: - Circuit-breaker state

/// Tracks consecutive identical failures to detect deterministic failure loops
/// (e.g., a permanently oversized basis blob that causes step 7 to fail every
/// time moot-mgr respawns the migration). After `sharedContentCircuitBreakerThreshold`
/// identical failures, the migration is parked and the respawn loop idles.
/// Stored as an optional field in the migration record for backward compatibility:
/// old records decode with `circuitBreaker == nil`, meaning no failure history.
public struct CircuitBreakerState: Sendable, Codable, Equatable {
    /// Number of consecutive failures at `lastFailureState` with `lastFailureError`.
    public var failureCount: Int
    /// The committed migration state that was active when the last failure occurred.
    public var lastFailureState: SharedContentMigrationState?
    /// A brief, stable description of the last failure (for identity matching).
    public var lastFailureError: String?
    /// ISO8601 timestamp when the circuit breaker parked this migration.
    /// nil until the failure threshold is reached.
    public var parkedAt: String?
    /// The migration implementation version token active when the park was set.
    /// A version change causes the park to auto-clear on the next run, giving
    /// a new code build a fresh attempt without operator intervention.
    public var parkedUnderMigrationVersion: String?
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
    /// The ensemble/configuration fingerprint the migration completed
    /// under (corrective pass). Wiring a DIFFERENT configuration over a
    /// completed record is a follow-on upgrade, never trusted as complete.
    public var ensembleFingerprint: String?
    /// Per-provider basis generations (modelID → basis digest) recorded at
    /// `basesTrained` and re-verified at `verified`.
    public var providerGenerations: [String: String]?
    /// Circuit-breaker failure tracking. nil on old records (backward-compatible:
    /// Swift's synthesized Codable uses `decodeIfPresent` for Optional properties,
    /// so records written before this field was added decode with nil here).
    public var circuitBreaker: CircuitBreakerState? = nil
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
        default:
            throw SharedContentMigrationError.storageFailure(
                state: .discovered, reason: "migration record payload is missing or malformed")
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
    public static func detectLegacyLayout(storage: any Storage) async throws -> String? {
        let legacyVersion = try await storage.currentSchemaVersion(for: "CorpusKit")
        do { _ = try await storage.rowStore.count(table: "chunks", where: nil) }
        catch {
            // No legacy schema registration and no chunks table is the fresh
            // shape. Once a legacy version is registered, an unreadable/missing
            // table is corruption and must not be reclassified as fresh.
            if legacyVersion == 0 { return nil }
            throw error
        }
        do {
            _ = try await storage.rowStore.count(table: "corpus_metadata", where: nil)
            return "legacy-chunks+metadata"
        } catch {
            // BundleStore v1/v2 legitimately predates corpus_metadata. v3+
            // declares it, so an error at that version is not absence.
            if legacyVersion < 3 { return "legacy-chunks" }
            throw error
        }
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

// MARK: - Circuit-breaker constants

/// Number of consecutive identical failures required to park the migration.
/// Three is chosen as a practical trade-off — enough to absorb transient
/// storage hiccups (disk-full spike, momentary lock contention) without
/// letting a deterministic failure class spin forever at 100% CPU.
private let sharedContentCircuitBreakerThreshold = 3

/// Migration implementation version token. Update this constant when a code
/// change is expected to resolve a class of parked failures; a mismatch
/// between the stored token and this constant causes an auto-clear on the
/// next run, giving the updated code a fresh attempt without operator action.
private let sharedContentMigrationVersion = "mxe-bb"

// MARK: - Runner

public extension GeniusLocusKit {

    /// Test seam: when non-nil, the migration throws `injectedFault` right
    /// AFTER persisting the named state — the resume-proof harness.
    package var _sharedContentFaultAfter: SharedContentMigrationState? {
        get { migrationFaultToken().flatMap(SharedContentMigrationState.init(rawValue:)) }
        set { setMigrationFaultToken(newValue?.rawValue) }
    }

    /// Install the fault-injection seam (test-only; single-use).
    package func _setSharedContentFault(_ state: SharedContentMigrationState?) {
        setMigrationFaultToken(state?.rawValue)
    }

    /// Whether the estate's Corpus lane must stay DARK:
    ///   - a legacy copy lane is present and the migration record has not
    ///     reached `verified`; or
    ///   - a migration record EXISTS whose recorded ensemble fingerprint
    ///     differs from `wiredFingerprint` (an obsolete configuration —
    ///     the estate enters a follow-on upgrade instead of being trusted
    ///     as complete).
    /// LocusKit recall is unaffected either way.
    func sharedContentLaneMustStayDark(
        storage: any Storage, wiredFingerprint: String? = nil
    ) async -> Bool {
        try? await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
        do {
            if let record = try await SharedContentMigrationStore(storage: storage).load() {
                // A record is authoritative after schema retirement, when
                // absent legacy tables are no longer a valid detection probe.
                if record.state.ordinal < SharedContentMigrationState.verified.ordinal {
                    return true
                }
                if let wiredFingerprint, record.ensembleFingerprint != wiredFingerprint {
                    return true
                }
                return false
            }
        } catch { return true }
        do {
            // Current estates deliberately have no historical record and no
            // chunks table. Trust the core format stamp before consulting the
            // legacy structural detector.
            if try await EstateFormatStore(storage: storage).readIfPresent() == .current {
                return false
            }
        } catch { return true }
        do {
            return try await SharedContentMigrationDetection.detectLegacyLayout(
                storage: storage) != nil
        } catch { return true }
    }

    /// Run (or resume) the shared-content migration for `handle`'s estate.
    ///
    /// Idempotent and resumable: re-running continues from the persisted
    /// state. On a fresh (post-cutover) estate the record completes
    /// immediately. Returns the final report; throws a
    /// `SharedContentMigrationError` that leaves the lane dark otherwise.
    @discardableResult
    func runSharedContentMigration(
        handle: EstateHandle, now: Date,
        embeddingModels: [EmbeddingModel] = CorpusEnsemble.defaultEnsemble()
    ) async throws -> SharedContentMigrationReport {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw SharedContentMigrationError.storageFailure(
                state: .discovered, reason: "no storage registered for estate")
        }
        let estateObj = try estate(for: handle)
        let source = LocusDrawerCorpusContentSource(estate: estateObj)
        let wiredFingerprint = CorpusContentEngine.configurationFingerprint(
            mode: .attached, models: embeddingModels)
        try await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
        let store = SharedContentMigrationStore(storage: storage)

        var record: SharedContentMigrationRecord
        if let existing = try await store.load() {
            record = existing
        } else {
            if try await EstateFormatStore(storage: storage).readIfPresent() == .current {
                let complete = SharedContentMigrationRecord(
                    state: .complete,
                    detectedLayout: "current",
                    legacyChunkIDs: [], legacyVectorKeys: [],
                    protectedBaseline: [:],
                    rebuildCursor: nil, rebuiltContentCount: 0,
                    estimatedReclaimableBytes: nil, reclaimedBytes: nil,
                    legacyChunkCount: nil, legacyVectorKeyCount: nil,
                    ensembleFingerprint: wiredFingerprint,
                    providerGenerations: nil)
                return report(for: complete)
            }
            // 1. discovered — structural detection, never a version number.
            let layout = try await SharedContentMigrationDetection.detectLegacyLayout(storage: storage)
            let fresh = SharedContentMigrationRecord(
                state: .discovered,
                detectedLayout: layout ?? "fresh",
                legacyChunkIDs: [], legacyVectorKeys: [],
                protectedBaseline: [:],
                rebuildCursor: nil, rebuiltContentCount: 0,
                estimatedReclaimableBytes: nil, reclaimedBytes: nil,
                legacyChunkCount: nil, legacyVectorKeyCount: nil,
                ensembleFingerprint: nil, providerGenerations: nil)
            if layout == nil {
                // Fresh estate: stamp the current format without creating any
                // historical migration bookkeeping. A fresh SDK consumer that
                // does not compile this target uses the same core format row.
                try await EstateFormatStore(storage: storage).stamp(.current, now: now)
                var complete = fresh
                complete.state = .complete
                complete.ensembleFingerprint = wiredFingerprint
                return report(for: complete)
            }
            record = fresh
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }
        // Circuit-breaker: refuse to run if parked under the current version.
        // If the migration implementation version has changed (a code update),
        // auto-clear the park and give the new code a fresh attempt.
        if let cb = record.circuitBreaker, let parkedAt = cb.parkedAt {
            if cb.parkedUnderMigrationVersion == sharedContentMigrationVersion {
                throw SharedContentMigrationError.migrationParked(
                    atState: cb.lastFailureState ?? record.state,
                    failureCount: cb.failureCount,
                    error: cb.lastFailureError ?? "(unknown)",
                    parkedAt: parkedAt)
            }
            // Version changed — auto-clear the park and continue.
            migrationLog.notice(
                "shared-content migration auto-clearing park (version changed from \(cb.parkedUnderMigrationVersion ?? "<none>", privacy: .public) to \(sharedContentMigrationVersion, privacy: .public))")
            record.circuitBreaker = nil
            try await store.save(record, now: now)
        }

        if record.state == .complete {
            if record.ensembleFingerprint == wiredFingerprint {
                try await EstateFormatStore(storage: storage).stamp(.current, now: now)
                return report(for: record)
            }
            // Follow-on ENSEMBLE UPGRADE: the completed record's recorded
            // configuration differs from the wired one (new provider, new
            // version, new index layout). The structural rebuild is intact;
            // re-enter at the provider phases — train what is missing,
            // backfill only absent coverage, re-verify, and restamp the
            // fingerprint. Never trusted as complete until then.
            migrationLog.notice(
                "shared-content upgrade: recorded ensemble \(record.ensembleFingerprint ?? "<none>", privacy: .public) != wired \(wiredFingerprint, privacy: .public) — entering provider upgrade")
            record.state = .drawerIndexRebuilt
            try await store.save(record, now: now)
        }

        // Circuit-breaker wrapper: catch any failure from the state-machine steps,
        // track consecutive identical failures, and park when the threshold is reached.
        // Distinct errors or errors at different committed states reset the count so
        // that transient hiccups never park a healthy migration.
        do {

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

        // Capacity refusal is deliberately BEFORE the first destructive
        // transition. A resumed estate already beyond this point must finish;
        // it may not strand itself because the host's current free RAM changed.
        if record.state == .legacyInventoryCaptured,
           embeddingModels.contains(where: \.isTrainable) {
            try SharedContentTrainingCapacity.require(
                contentCount: try await source.activeContentIDs().count)
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
            let engine = try await migrationEngine(
                handle: handle, storage: storage, source: source, models: embeddingModels)
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
            var batchStart = resumeFrom
            while batchStart < allIDs.count {
                let batchEnd = min(batchStart + checkpointStride, allIDs.count)
                let batch = Array(allIDs[batchStart..<batchEnd])
                // Pure tokenization/stateless embedding fans out across the
                // engine's bounded worker cap; durable mutation remains one
                // deterministic serial writer. The cursor advances only after
                // the entire batch has committed.
                _ = try await engine.indexContentStructuralBatch(ids: batch, now: now)
                processed += batch.count
                record.rebuildCursor = batch.last
                record.rebuiltContentCount = processed
                try await store.save(record, now: now)
                batchStart = batchEnd
            }
            try await engine.sharedVectorStore.publishResidentIndex()
            record.rebuildCursor = allIDs.last
            record.rebuiltContentCount = processed
            record.state = .drawerIndexRebuilt
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 7. basesTrained — stream-train every trainable provider lacking a
        //    current basis (bounded pages; per-provider atomic basis+counts
        //    commit). Restart-idempotent: a crash before a provider's
        //    commit retrains it from zero; already-committed providers are
        //    skipped by their persisted generation.
        if record.state.ordinal < SharedContentMigrationState.basesTrained.ordinal {
            // Ensure the basis table is at its current schema HERE, immediately
            // before the step that writes to it. The same call in the
            // `legacyDerivedCleared` step above is not sufficient: that step is
            // skipped when the migration RESUMES past it, so a resume (crash,
            // respawn, or circuit-breaker unpark) reaches this write with the
            // table still at whatever version the estate was created on. That is
            // exactly how ee#49's fix failed in the field — a resume from
            // `drawerIndexRebuilt` trained bases and then could not write them,
            // because part_index had never been added on this run. migrate() is
            // idempotent and a no-op once the recorded version is current.
            try await storage.migrate(to: BasisStore.schemaDeclaration)
            let engine = try await migrationEngine(
                handle: handle, storage: storage, source: source, models: embeddingModels)
            _ = try await engine.trainTrainableSlots(now: now)
            record.providerGenerations = Dictionary(
                uniqueKeysWithValues: await engine.providerGenerations()
                    .map { ($0.modelID, $0.basisDigest) })
            record.state = .basesTrained
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 8. providersCovered — backfill ONLY the missing (Drawer,
        //    provider) representations under each provider's CURRENT basis
        //    generation. The durable coverage rows are the resume
        //    authority: a cursor/progress figure may lag them, never lead.
        //    No BM25 rewrite, no counts refold, no covered-row rewrites.
        if record.state.ordinal < SharedContentMigrationState.providersCovered.ordinal {
            let engine = try await migrationEngine(
                handle: handle, storage: storage, source: source, models: embeddingModels)
            // Engine generations are the durable truth (atomic commits);
            // reconcile the record's bookkeeping to them on resume.
            record.providerGenerations = Dictionary(
                uniqueKeysWithValues: await engine.providerGenerations()
                    .map { ($0.modelID, $0.basisDigest) })
            try await engine.sharedVectorStore.beginDeferredIndex()
            _ = try await engine.backfillProviderCoverage(now: now)
            try await engine.sharedVectorStore.publishResidentIndex()
            record.state = .providersCovered
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 9. verified — reconcile IDs, prove direct hydration, compare
        //    protected baselines, prove no chunk artifact survives, and
        //    prove PER-PROVIDER coverage: every wired provider covers every
        //    active Drawer under its recorded basis generation. A mismatch
        //    stops BEFORE the inventory/evidence is discarded.
        if record.state.ordinal < SharedContentMigrationState.verified.ordinal {
            let engine = try await migrationEngine(
                handle: handle, storage: storage, source: source, models: embeddingModels)
            try await verify(record: record, storage: storage, source: source, engine: engine)
            record.ensembleFingerprint = await engine.configurationFingerprint()
            record.state = .verified
            try await store.save(record, now: now)
            try checkFault(after: record.state)
        }

        // 10. reclaimPending — the lane is available from here; physical
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

        // The current runtime may open semantic substores as soon as the
        // rebuilt lane is verified. Physical page reclamation remains a
        // retryable maintenance step and does not hold the format gate dark.
        try await EstateFormatStore(storage: storage).stamp(.current, now: now)

        // 11. complete — after physical reclamation (P5's maintenance API).
        //    `completeSharedContentReclaim` flips the final state; until
        //    then the record honestly reports reclaimPending.

        // Success: reset the circuit-breaker failure history.
        if record.circuitBreaker != nil {
            record.circuitBreaker = nil
            try await store.save(record, now: now)
        }
        return report(for: record)

        } catch {
            // Circuit-breaker: track consecutive identical failures.
            // `record.state` is the last COMMITTED state before the failing step.
            let errorDesc = (error as? SharedContentMigrationError)?.briefDescription
                ?? "\(error)".prefix(200).description
            let failingState = record.state
            var cb = record.circuitBreaker ?? CircuitBreakerState(
                failureCount: 0, lastFailureState: nil, lastFailureError: nil,
                parkedAt: nil, parkedUnderMigrationVersion: nil)
            if cb.lastFailureState == failingState && cb.lastFailureError == errorDesc {
                cb.failureCount += 1
            } else {
                // Different state or different error — reset the streak counter.
                cb.failureCount = 1
                cb.lastFailureError = errorDesc
                cb.lastFailureState = failingState
            }
            if cb.failureCount >= sharedContentCircuitBreakerThreshold {
                let parkedAt = ISO8601DateFormatter().string(from: now)
                cb.parkedAt = parkedAt
                cb.parkedUnderMigrationVersion = sharedContentMigrationVersion
                migrationLog.error(
                    "shared-content migration parked after \(cb.failureCount, privacy: .public) identical failures at \(failingState.rawValue, privacy: .public): \(errorDesc, privacy: .public)")
            }
            record.circuitBreaker = cb
            // Best-effort save of circuit-breaker state. If the storage itself
            // is broken (same cause as the step failure), this save may also fail;
            // we discard that error and surface the original step failure.
            try? await store.save(record, now: now)
            throw error
        }
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
        guard let storage = try? migrationStorage(for: handle) else { return nil }
        let store = SharedContentMigrationStore(storage: storage)
        guard var record = try await store.load(),
              record.state == .reclaimPending else { return nil }
        // Remove the row-level inventories BEFORE physical maintenance. Saving
        // this compact reclaimPending record first makes the freed pages part
        // of the VACUUM itself. Trimming after VACUUM recreated about 60 MB of
        // freelist on the 98k-Drawer qualification estate. A crash here is
        // safe: verification is already complete and the next call retries
        // maintenance from the same reclaimPending state.
        if record.legacyChunkCount == nil {
            record.legacyChunkCount = record.legacyChunkIDs.count
        }
        if record.legacyVectorKeyCount == nil {
            record.legacyVectorKeyCount = record.legacyVectorKeys.count
        }
        record.legacyChunkIDs = []
        record.legacyVectorKeys = []
        record.protectedBaseline = [:]
        try await store.save(record, now: now)
        var report: StorageMaintenanceReport?
        if let maintenance = storage as? any StorageMaintenance {
            report = try await maintenance.performMaintenance()
        }
        record.reclaimedBytes = report?.reclaimedBytes ?? 0
        record.state = .complete
        try await store.save(record, now: now)
        return report
    }

    /// Clear a parked migration, allowing the next call to
    /// `runSharedContentMigration` to attempt the migration again.
    ///
    /// Call this after diagnosing and resolving the root cause of the repeated
    /// failure (e.g., freeing disk space, upgrading the binary to a version
    /// that addresses the failure class, or removing the offending content).
    /// Clearing without resolving the underlying cause will result in the
    /// migration re-parking after another three identical failures.
    ///
    /// Note: a binary version change also clears the park automatically — see
    /// `sharedContentMigrationVersion`. Explicit clear is the operator path for
    /// cases where the fix does not change the binary version token.
    func clearParkedSharedContentMigration(
        handle: EstateHandle, now: Date
    ) async throws {
        guard let storage = try? migrationStorage(for: handle) else { return }
        try await storage.migrate(to: SharedContentMigrationStore.schemaDeclaration)
        let store = SharedContentMigrationStore(storage: storage)
        guard var record = try await store.load() else { return }
        guard record.circuitBreaker?.parkedAt != nil else { return }
        record.circuitBreaker = nil
        try await store.save(record, now: now)
        migrationLog.notice(
            "shared-content migration park cleared for estate \(handle.estateUUID, privacy: .public)")
    }

    /// Whether the migration is currently parked (circuit breaker tripped).
    /// Returns false when no record exists or when the migration is not parked.
    func sharedContentMigrationIsParked(handle: EstateHandle) async -> Bool {
        guard let storage = try? migrationStorage(for: handle) else { return false }
        guard let record = try? await SharedContentMigrationStore(storage: storage).load()
        else { return false }
        guard let cb = record.circuitBreaker, let _ = cb.parkedAt else { return false }
        return cb.parkedUnderMigrationVersion == sharedContentMigrationVersion
    }

    /// The migration record's current state for the status surface (nil
    /// when no record exists — a fresh estate that never ran detection).
    func sharedContentMigrationState(
        handle: EstateHandle
    ) async throws -> SharedContentMigrationState? {
        guard let storage = try? migrationStorage(for: handle) else { return nil }
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
        guard let storage = try? migrationStorage(for: handle) else {
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
        guard !rows.isEmpty else { return "0000000000000000" }
        let workerCount = min(max(1, ProcessInfo.processInfo.activeProcessorCount), rows.count)
        let rowsPerWorker = max(1, (rows.count + workerCount - 1) / workerCount)
        let combined = await withTaskGroup(of: UInt64.self, returning: UInt64.self) { group in
            for start in stride(from: 0, to: rows.count, by: rowsPerWorker) {
                let end = min(start + rowsPerWorker, rows.count)
                group.addTask {
                    var local: UInt64 = 0
                    for row in rows[start..<end] {
                        guard case let .text(itemID)? = row["item_id"],
                              case let .int(vectorIndex)? = row["vector_index"],
                              case let .text(modelID)? = row["model_id"] else { continue }
                        let key = "\(itemID)|\(vectorIndex)|\(modelID)"
                        guard !legacyVectorKeys.contains(key) else { continue }
                        let encoded = DatabaseInventory.canonicalRowEncoding(
                            row, excluding: ["id"])
                        var h: UInt64 = 14_695_981_039_346_656_037
                        for byte in encoded.utf8 {
                            h = (h ^ UInt64(byte)) &* 1_099_511_628_211
                        }
                        local = local &+ h
                    }
                    return local
                }
            }
            var total: UInt64 = 0
            for await partial in group { total = total &+ partial }
            return total
        }
        return String(format: "%016llx", combined)
    }

    /// The migration's engine over the estate's wired configuration:
    /// the registered attached engine when present, else a fresh one.
    private func migrationEngine(
        handle: EstateHandle,
        storage: any Storage,
        source: LocusDrawerCorpusContentSource,
        models: [EmbeddingModel]
    ) async throws -> CorpusContentEngine {
        if let registered = migrationRegisteredCorpus(for: handle) { return registered }
        return try await CorpusContentEngine(
            storage: storage,
            configuration: CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent),
            source: source,
            models: models)
    }

    private func verify(
        record: SharedContentMigrationRecord,
        storage: any Storage,
        source: LocusDrawerCorpusContentSource,
        engine: CorpusContentEngine
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
        // Per-provider coverage: every wired provider must cover every
        // active Drawer under its CURRENT basis generation, and every
        // trainable provider must actually be trained. The migration is
        // not complete while any configured lane is dark.
        for generation in await engine.providerGenerations() {
            // An EMPTY estate has nothing to train on or cover; providers
            // train at first ingest. Digest emptiness is only a failure
            // when there was a corpus to train on.
            if generation.basisDigest.isEmpty && !activeIDs.isEmpty {
                throw SharedContentMigrationError.verificationFailed(
                    reason: "provider \(generation.modelID) is untrained after basesTrained")
            }
            let covered = try await engine.coveredCount(modelID: generation.modelID) ?? 0
            if covered < activeIDs.count {
                throw SharedContentMigrationError.verificationFailed(
                    reason: "provider \(generation.modelID) covers \(covered)/\(activeIDs.count) drawers")
            }
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
