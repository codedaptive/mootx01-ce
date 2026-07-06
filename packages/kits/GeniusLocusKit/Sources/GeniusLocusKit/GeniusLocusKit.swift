import ConvergenceKit
import CorpusKit
import Foundation
import OSLog
import LocusKit
import PersistenceKit
import QueueKit
import SubstrateTypes
import VectorKit

/// The composition layer for the GeniusLocus substrate.
///
/// `GeniusLocusKit` is the public actor that coordinates N estates on
/// one device. Each estate is its own composed substrate (LocusKit with
/// VectorKit and CorpusKit wired in) with its own manifest and its own
/// injected storage. Estates are isolated from one another: a handle
/// reaches exactly one estate's data.
///
/// Public surface:
///
/// - Lifecycle: `open(storage:owner:)` to admit a new estate into the
///   registry; `close(_:)` to remove it; `handles` to list what is
///   currently open.
/// - Nine-verb surface (GLK-02): `capture`, `recall`, `mutate`,
///   `withdraw`, `expunge`, `reanchor`, `propose`, `associate`,
///   `learn` — all implemented and dispatching to the underlying estate.
/// - Lattice-scoped read fan-out: `fanOutRecall(_:region:)` routes a
///   `RecallFrame` to every open estate whose zoom window overlaps the
///   query region, then aggregates results.
///
/// The per-estate unified audit log is wired (GLK-03): `auditLog(for:)`
/// issues a single SQL query against the estate's `_storagekit_audit`
/// table (Bug 1 fix, ADR025-AUDITLOG-GOVERNOR — replaced the former grow-
/// only in-memory G-Set CRDT fed by an N+1 per-drawer walk). Audit chain
/// verification is provided through the `verifyAuditChain` verb. The
/// Brain layer (standing-signal scheduler, matrix tier,
/// dreaming/maintenance daemons) is live.
///
/// Per the standing-signal serial-dispatch decision recorded for
/// GLK-04, the public type is an actor so the registry is serialized
/// by the actor model. No caller should assume concurrent mutation of
/// a single estate's state.
public actor GeniusLocusKit {

    /// Logger for the kit, fleet-standard subsystem and category per
    /// CLAUDE.md.
    private static let logger = Logger(
        subsystem: "com.mootx01.kit",
        category: "GeniusLocusKit"
    )

    /// Trace retention window in seconds: 30 days.
    ///
    /// Matches the dreaming daemon's prune window so any still-live trace
    /// row for a drawer is within the mark window used by `markRecallUsed`.
    /// Internal — only the verb surface and tests reference this constant.
    internal static let traceRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// Registry of currently-open estates keyed by handle.
    ///
    /// Internal so that the coordinator and read-fan-out extensions in
    /// sibling files can reach the live `Estate` references without
    /// exposing them to outside callers. Production callers go through
    /// `estate(for:)` which round-trips the lookup with a clear error.
    internal var registry: [EstateHandle: LocusKit.Estate] = [:]

    /// Registry of per-estate standing-signal schedulers. Empty until
    /// the first `registerStandingSignal` call against a given handle;
    /// the scheduler is minted lazily by `ensureScheduler(for:)` in
    /// `Brain/SignalAPI.swift`. One scheduler per estate so the
    /// single-serial-lane decision (DECISION_STANDING_SIGNAL_SCHEDULER
    /// _2026-05-21) applies per-estate, never across estates.
    internal var schedulers: [EstateHandle: StandingSignalScheduler] = [:]


    /// Registry of active and terminal COW branches keyed by `BranchID`.
    ///
    /// Branches are inserted on `glkDeriveBranch` and retained through
    /// all lifecycle states (`.active`, `.won`, `.merged`, `.discarded`)
    /// so that `glkPromoteBranch` and `glkMergeDrawers` can resolve a
    /// `BranchHandle` to its concrete `EstateBranch`. The in-memory
    /// estate is held here as long as the kit is alive; terminal branches
    /// are not automatically evicted (the audit trail must remain
    /// accessible per I-15).
    internal var branches: [BranchID: EstateBranch] = [:]

    /// The caller-supplied `Storage` for each open estate, retained so
    /// the grant surface can build a `GrantStore` backed by the estate's
    /// own database. Captured in `open`, dropped in `close`. The
    /// coordinator never shares a storage across estates, so this keeps
    /// grants in the same backend as the estate they belong to.
    internal var storages: [EstateHandle: any Storage] = [:]

    /// Per-estate `Corpus` instances for BM25 and embedding recall lanes.
    ///
    /// Populated via `registerCorpus(_:for:)` after an estate is opened.
    /// The RecallDirector reads this registry to drive `corpusOnly` and
    /// `hybrid` BM25/vector lanes. Dropped when the estate is closed.
    internal var corpusKits: [EstateHandle: Corpus] = [:]

    /// Per-estate `VectorStore` instances for Hamming nearest-neighbour recall.
    ///
    /// Populated via `registerVectorStore(_:for:)`. Expected to be keyed by
    /// drawer IDs (not chunk IDs) so RecallDirector hits join directly to
    /// LocusKit `Drawer` rows. Dropped when the estate is closed.
    internal var vectorStores: [EstateHandle: VectorStore] = [:]

    /// Per-estate grant persistence (GRT-01). Built lazily on the first
    /// grant verb against a handle via `ensureGrantSurface(for:)`; the
    /// `grants` table lives in the estate's storage. Dropped in `close`.
    internal var grantStores: [EstateHandle: GrantStore] = [:]

    /// Per-estate scope-key custody (GRT-01). Built lazily alongside the
    /// `GrantStore`. Mode-1 scope keys live here in memory only; the
    /// vault is dropped in `close`, which discharges all held keys.
    internal var scopeVaults: [EstateHandle: ScopeKeyVault] = [:]

    /// Per-estate diary `DrawerStore` facade (dreaming sink). Built lazily
    /// by `ensureDiaryStore(for:)` on the first `addDiaryEntry(in:_:)` call
    /// against a handle; the store is backed by the same `Storage` as the
    /// estate's LocusKit tier. Dropped in `close` via `EstateCoordinator`.
    internal var diaryStores: [EstateHandle: DrawerStore] = [:]

    /// Per-estate KGFact `DrawerStore` facade (verb surface). Built lazily
    /// by `ensureKGStore(for:)` on the first `captureKGFact` or `retireKGFact`
    /// call against a handle. Mirrors `diaryStores` — same backing `Storage`,
    /// separate facade to avoid cross-concern entanglement. Dropped in `close`.
    internal var kgStores: [EstateHandle: DrawerStore] = [:]

    /// Per-estate matrix tier snapshots for recall scoring.
    ///
    /// Populated via `registerMatrixTier(_:for:)` after an estate is opened
    /// and the caller has built or loaded a `MatrixTier` from the estate's
    /// unified audit log. The RecallDirector reads this registry to populate
    /// the `fieldFit`, `coOccurrence`, and `temporal` score columns during
    /// the `unionBest` lane's scoring pass. When absent, all three columns
    /// remain 0.0 (no matrix priors — correct behaviour for a fresh estate).
    /// Dropped when the estate is closed.
    internal var matrixTiers: [EstateHandle: MatrixTier] = [:]

    /// Per-estate graph cache snapshots for recall scoring.
    ///
    /// Populated via `registerGraphCache(_:for:)` after an estate is opened
    /// and the dreaming cycle has produced a graph projection. The
    /// RecallDirector reads this registry to populate the `graph` score
    /// column during the `unionBest` scoring pass. When absent, the column
    /// remains 0.0 — correct behaviour for a fresh estate with no graph
    /// data. Dropped when the estate is closed.
    internal var graphCaches: [EstateHandle: any GraphCache] = [:]

    /// Per-estate preference store snapshots for recall scoring.
    ///
    /// Populated via `registerPreferenceStore(_:for:)` after an estate is
    /// opened and the training daemon has produced preference weights.
    /// The RecallDirector reads this registry to populate the `preference`
    /// score column during the `unionBest` scoring pass. When absent, the
    /// column remains 0.0 — correct behaviour for a fresh estate. Dropped
    /// when the estate is closed.
    internal var preferenceStores: [EstateHandle: any PreferenceStore] = [:]

    /// Per-estate node topology providers for the `.nodeTreeNative` recall mode.
    ///
    /// Populated via `registerNodeTopology(_:for:)`. When present, the GLK
    /// `recallTunnels` path calls `provider.treeEdges(scope: nil)` exactly once
    /// (G1 — read-once-and-freeze) and unions the returned containment edges with
    /// the estate's stored tunnel edges before delivering the StructureGraph to the
    /// structural lenses. When absent, `recallTunnels` returns only stored tunnels
    /// (existing behaviour, unchanged). Dropped when the estate is closed.
    ///
    /// Topology boundary invariant (G4): this registry stores ONLY the three-method
    /// GLKNodeTopologyProvider adapter — no content is accessible through it. Any
    /// node-content need routes through CorpusKit.
    internal var nodeTopologyProviders: [EstateHandle: any GLKNodeTopologyProvider] = [:]

    /// Per-estate mount lifecycle states (GLK_PROVISION_001).
    ///
    /// Tracks whether each open estate is fully mounted, quiesced, or draining.
    /// Set to `.mounted` on `open` or `provision`; updated by `quiesce`, `drain`,
    /// and `close`/`destroy`. Dropped when the handle is removed from the registry.
    ///
    /// The admin plane reads this registry via `mountState(for:)` to drive the
    /// Estates view lifecycle badges in the moot-mgr GUI (ARIA_MCP_MANAGEMENT_GUI_SPEC §5.3).
    internal var mountStates: [EstateHandle: EstateMountState] = [:]

    /// Per-estate DrawerStore facade for temporal reads (dormant-surfaces mission).
    ///
    /// Built lazily by `ensureFingerprintStore(for:)` in `TemporalReads.swift` on the
    /// first `glkFingerprintsCaptured` or `glkFingerprintBitSeries` call. Follows the
    /// same pattern as `diaryStores` — backed by the same `Storage` as the estate,
    /// separate facade to avoid cross-concern entanglement. Dropped in `close`.
    internal var fingerprintStores: [EstateHandle: DrawerStore] = [:]

    /// Per-estate LLM calibration curve registries.
    ///
    /// Populated on first `glkRecordCalibrationOutcome` and readable via
    /// `glkCalibrationCurve`. Holds the in-memory state; callers that need
    /// persistence register a `MatrixPersistenceBackend` via
    /// `registerMatrixPersistence(_:for:)`. Dropped in `close`.
    internal var calibrationRegistries: [EstateHandle: MatrixCalibrationRegistry] = [:]

    /// Optional per-estate matrix persistence backends for calibration snapshots.
    ///
    /// When present, `glkRecordCalibrationOutcome` saves a `MatrixSnapshot`
    /// (tier + calibration registry) after each update so calibration survives
    /// a process restart. Registered via `registerMatrixPersistence(_:for:)`.
    /// Dropped in `close`.
    internal var matrixPersistenceBackends: [EstateHandle: MatrixPersistenceBackend] = [:]

    /// Per-estate dreaming QueueKit handles (ADR-021 Phase 2b).
    ///
    /// Lazy-mounted on the first external recall for each estate by
    /// `ensureDreamingQueue(for:)`. The queue opens the same per-estate
    /// queue.sqlite that the encode and signals streams use (one queue,
    /// many streams — ADR-021 Decision 7), with stream_id = "dreaming".
    /// SQLite estates → SQLiteStorage-backed QueueKit (crash-durable).
    /// InMemory estates → transient PersistenceKitBackend (no disk needed).
    /// Dropped in `close` so no handle outlives the estate.
    internal var dreamingQueues: [EstateHandle: QueueKit] = [:]

    /// Per-estate HLC generators for the dreaming queue (ADR-021 Phase 2b).
    ///
    /// One HLC per estate, derived from the estate UUID the same way the signals
    /// scheduler derives its HLC (first four UUID bytes big-endian → Int32 nodeID),
    /// so each estate produces a distinguishable monotone HLC family. Minted
    /// alongside the dreaming queue in `ensureDreamingQueue(for:)`.
    /// Dropped in `close` alongside `dreamingQueues`.
    internal var dreamingHLCs: [EstateHandle: HLCGenerator] = [:]

    // The encode QUEUE + DRAIN worker + per-estate HLC + at-least-once ingest
    // failure hook used to live here. They were relocated into CorpusKit: a
    // Corpus now owns its ingest queue, drain worker pool, and retry (see
    // CorpusKit's CorpusIngestQueue.swift). GLK reaches them through
    // `corpusKits[handle]` and is pure orchestration — it enqueues work and,
    // via the Corpus `onEncoded` callback, rolls up the touched LocusKit rooms.

    /// Per-estate active sync engine entry (ConvergenceKit backend + label).
    ///
    /// Registered via `registerSyncEngine(_:backendName:for:)` after `open(_:owner:)`.
    /// When present, `syncStateToken(for:)` queries `entry.engine.state` and formats
    /// the canonical token using `entry.backendName`. When absent the estate is
    /// local-only: `syncStateToken(for:)` returns `"local-only"`.
    ///
    /// `backendName` ("none", "cloudkit", "federation") is stored alongside the
    /// engine because `SyncEngine` is a protocol and GLK imports only the base
    /// `ConvergenceKit` module — it cannot recover the concrete type name without
    /// importing backend-specific targets. The caller supplies the label at
    /// registration time, keeping GLK's import surface minimal.
    ///
    /// Dropped in `close` so no engine reference outlives the estate.
    internal var syncEngines: [EstateHandle: SyncEngineEntry] = [:]

    // MARK: — Recall degradation test seams (P1 fail-loud contract)

    /// Test-only: when non-nil, the Hamming vector lane returns this error instead
    /// of calling `VectorStore.findNearest`. Consumed on the first call that checks
    /// it; subsequent calls behave normally. Never set in production code.
    ///
    /// Named with a `_test` prefix so future agents cannot mistake this for a
    /// production toggle. Visible to `@testable import GeniusLocusKit` only.
    var _testForceVectorHammingError: Error? = nil

    /// Test-only: when non-nil, `compileSketch` returns this error instead of
    /// calling `corpus.embed`. Consumed on the first call; subsequent calls behave
    /// normally. Never set in production code.
    var _testForceEmbedError: Error? = nil

    /// Test-only: when non-nil, the structured pool load (`estate.getDrawers` in
    /// step 5.5 of `recallUnionBest`) returns this error. Consumed on the first
    /// call; subsequent calls behave normally. Never set in production code.
    var _testForcePoolGetDrawersError: Error? = nil

    /// Test-only: when non-nil, the MMR body-hydration step (step 9.5 of
    /// `recallUnionBest`) returns this error. Consumed on the first call;
    /// subsequent calls behave normally. Never set in production code.
    var _testForceMMRHydrationError: Error? = nil

    /// Test-only: when non-nil, the returned-hits body-hydration step (step 10.5
    /// of `recallUnionBest`) returns this error. Consumed on the first call;
    /// subsequent calls behave normally. Never set in production code.
    var _testForceReturnHydrationError: Error? = nil

    /// Test-only: when non-nil, the hybrid lane's `estate.getDrawers` call for
    /// frontier candidates returns this error. Consumed on the first call;
    /// subsequent calls behave normally. Never set in production code.
    var _testForceHybridGetDrawersError: Error? = nil

    /// Test-only: when non-nil, the corpusOnly lane's `estate.getDrawers` call
    /// for fused candidates returns this error. Consumed on the first call;
    /// subsequent calls behave normally. Never set in production code.
    var _testForceCorpusOnlyGetDrawersError: Error? = nil

    // MARK: — Test seam injection helpers

    /// Inject a Hamming vector lane error for the next recall call.
    ///
    /// Intended for tests only (`@testable import`). Sets the single-use
    /// `_testForceVectorHammingError` seam. Never call in production code.
    func _inject(vectorHammingError error: Error) {
        _testForceVectorHammingError = error
    }

    /// Inject an embed error for the next `compileSketch` call.
    ///
    /// Intended for tests only. Never call in production code.
    func _inject(embedError error: Error) {
        _testForceEmbedError = error
    }

    /// Inject a pool `getDrawers` error for the next `recallUnionBest` step 5.5 call.
    ///
    /// Intended for tests only. Never call in production code.
    func _inject(poolGetDrawersError error: Error) {
        _testForcePoolGetDrawersError = error
    }

    /// Inject an MMR body-hydration error for the next `recallUnionBest` step 9.5 call.
    ///
    /// Intended for tests only. Never call in production code.
    func _inject(mmrHydrationError error: Error) {
        _testForceMMRHydrationError = error
    }

    /// Inject a return-hits body-hydration error for the next `recallUnionBest` step 10.5 call.
    ///
    /// Intended for tests only. Never call in production code.
    func _inject(returnHydrationError error: Error) {
        _testForceReturnHydrationError = error
    }

    /// Inject a hybrid `getDrawers` error for the next `recallHybrid` frontier load call.
    ///
    /// Intended for tests only. Never call in production code.
    func _inject(hybridGetDrawersError error: Error) {
        _testForceHybridGetDrawersError = error
    }

    /// Inject a corpusOnly `getDrawers` error for the next `hydrateHits` call.
    ///
    /// Intended for tests only. Never call in production code.
    func _inject(corpusOnlyGetDrawersError error: Error) {
        _testForceCorpusOnlyGetDrawersError = error
    }

    /// Construct an empty kit. The estate registry starts empty;
    /// callers admit estates via `open(storage:owner:)`.
    public init() {
        Self.logger.debug("GeniusLocusKit initialized with empty registry")
    }

    /// Number of estates currently open. Useful in tests and in
    /// diagnostics; the canonical listing surface is `handles`.
    public var openEstateCount: Int { registry.count }

    /// Snapshot of currently-open estate handles.
    ///
    /// Returns a fresh array on each call; the registry is not
    /// observable directly. Callers that need a stable ordering across
    /// reads should sort the result themselves.
    public var handles: [EstateHandle] {
        Array(registry.keys)
    }
}

// MARK: - CorpusKit / VectorStore registration (RECALL-DIRECTOR-002)

public extension GeniusLocusKit {

    /// Register a `Corpus` instance for the given estate handle.
    ///
    /// The RecallDirector reads this registry to drive the BM25 and embedding
    /// lanes in `corpusOnly` and `hybrid` recall. The corpus should already be
    /// populated via `Corpus.ingest` before recall is invoked; the director
    /// does not ingest on behalf of the caller.
    ///
    /// Re-registering with a different corpus for the same handle replaces the
    /// existing entry. Call with `close(_:)` semantics to drop the reference.
    ///
    /// - Parameters:
    ///   - corpus: The `Corpus` actor for BM25 and embedding recall.
    ///   - handle: The estate this corpus is associated with. Must be open.
    func registerCorpus(_ corpus: Corpus, for handle: EstateHandle) {
        corpusKits[handle] = corpus
    }

    /// Register a `VectorStore` for the given estate handle.
    ///
    /// The RecallDirector uses this store for Hamming top-K nearest-neighbour
    /// recall in `corpusOnly` and `hybrid` modes. The store should be keyed by
    /// drawer IDs (matching `Drawer.id`) so hits join back to LocusKit rows
    /// without an intermediate mapping step.
    ///
    /// Re-registering replaces the existing entry.
    ///
    /// - Parameters:
    ///   - store: The `VectorStore` for Hamming nearest-neighbour recall.
    ///   - handle: The estate this store is associated with. Must be open.
    func registerVectorStore(_ store: VectorStore, for handle: EstateHandle) {
        vectorStores[handle] = store
    }

    /// The `VectorStore` registered for `handle`, or `nil` when none has been
    /// registered (e.g. semantic recall was not wired for this estate).
    ///
    /// Public read accessor so a consumer that registered the store elsewhere
    /// (the resident daemon wires it in `AriaMCPMain`) can retrieve it to wire
    /// the standing-signal scheduler's `VectorSimilaritySignal` against the same
    /// store. The actor isolates the registry; this is a plain read.
    func registeredVectorStore(for handle: EstateHandle) -> VectorStore? {
        vectorStores[handle]
    }

    /// Register a `MatrixTier` snapshot for the given estate handle.
    ///
    /// The RecallDirector reads this registry to compute `fieldFit`,
    /// `coOccurrence`, and `temporal` score columns during the `unionBest`
    /// scoring pass. Build the tier via `MatrixTier.rebuild(from:)` or
    /// `MatrixPersistenceBackend.rebuild(from:)` after feeding the estate's
    /// unified audit log. Re-registering with a fresh snapshot replaces the
    /// existing entry; call with a fresh tier after each dreaming cycle to keep
    /// recall scoring current.
    ///
    /// When no tier is registered for an estate, all matrix score columns
    /// remain 0.0 — correct behaviour for a fresh estate with no captured
    /// content, and safe for estates where matrix scoring has not been
    /// configured.
    ///
    /// - Parameters:
    ///   - tier:   The in-memory `MatrixTier` snapshot to use for recall scoring.
    ///   - handle: The estate this tier is associated with. Must be open.
    func registerMatrixTier(_ tier: MatrixTier, for handle: EstateHandle) {
        matrixTiers[handle] = tier
    }
}

// MARK: - Graph cache + preference store protocols (RECALL-GRAPH-001)

/// Cache of pre-built graph projections for one estate.
///
/// Implementations hold pre-computed per-drawer graph centrality scores
/// (e.g. random-walk stationary distributions, eigenvalue centrality)
/// built during the dreaming cycle. The director queries this cache for
/// candidate-frontier lookups only — no synchronous estate-wide analytics
/// are performed at recall time (spec §15).
///
/// When no implementation is registered for an estate the graph column
/// remains 0.0, which is correct and not an error.
public protocol GraphCache: Sendable {
    /// Return the graph centrality score for the given drawer ID.
    ///
    /// Returns 0.0 when the drawer is not in the cache. Must not perform
    /// any synchronous estate-wide graph traversal.
    func graphScore(for drawerID: String) -> Float
}

/// Store of learned per-drawer preference scores for one estate.
///
/// Implementations hold pre-trained Bradley-Terry or RecallTrace
/// preference weights built by the training daemon. The director queries
/// this store for candidate-frontier lookups only — no synchronous
/// model retraining occurs at recall time (spec §15).
///
/// When no implementation is registered for an estate the preference
/// column remains 0.0, which is correct and not an error.
public protocol PreferenceStore: Sendable {
    /// Return the preference score for the given drawer ID.
    ///
    /// Returns 0.0 when the drawer is not in the store. Must not trigger
    /// any synchronous preference model update.
    func preferenceScore(for drawerID: String) -> Float
}

// MARK: - Graph cache + preference store registration (RECALL-GRAPH-001)

public extension GeniusLocusKit {

    /// Register a `GraphCache` for the given estate handle.
    ///
    /// The RecallDirector reads this cache to populate the `graph` score
    /// column during the `unionBest` scoring pass. The cache must hold
    /// pre-built per-drawer graph centrality scores from the dreaming
    /// cycle; the director performs candidate-frontier lookups only and
    /// never triggers synchronous estate-wide graph traversal (spec §15).
    ///
    /// Re-registering replaces the existing entry. The graph column
    /// remains 0.0 when no cache is registered for an estate — this is
    /// correct, not an error.
    ///
    /// - Parameters:
    ///   - cache:  The pre-built graph centrality cache.
    ///   - handle: The estate this cache is associated with.
    func registerGraphCache(_ cache: some GraphCache, for handle: EstateHandle) {
        graphCaches[handle] = cache
    }

    /// Register a `PreferenceStore` for the given estate handle.
    ///
    /// The RecallDirector reads this store to populate the `preference`
    /// score column during the `unionBest` scoring pass. The store must
    /// hold pre-trained per-drawer preference weights from the training
    /// daemon; the director performs candidate-frontier lookups only and
    /// never triggers synchronous preference model updates (spec §15).
    ///
    /// Re-registering replaces the existing entry. The preference column
    /// remains 0.0 when no store is registered — correct for a fresh estate.
    ///
    /// - Parameters:
    ///   - store:  The pre-trained preference weight store.
    ///   - handle: The estate this store is associated with.
    func registerPreferenceStore(_ store: some PreferenceStore, for handle: EstateHandle) {
        preferenceStores[handle] = store
    }
}

// MARK: - Node topology provider registration (w5-nodetree-native)

public extension GeniusLocusKit {

    /// Register a `GLKNodeTopologyProvider` for the given estate handle.
    ///
    /// The provider gives GLK access to the host's parent-child node tree for the
    /// `.nodeTreeNative` recall mode and for the structural lens path. When a
    /// provider is registered, `recallTunnels(_:wing:)` calls
    /// `provider.treeEdges(scope: nil)` EXACTLY ONCE at the start of each call
    /// (G1 — read-once-and-freeze) and unions the frozen containment edges with the
    /// estate's stored tunnel edges before returning. The provider is never called
    /// again during that recall; determinism does not depend on provider stability
    /// after the freeze point.
    ///
    /// Topology boundary invariant (G4, SPEC invariant I-G4): the provider exposes
    /// exactly three methods (parentID / childIDs / treeEdges) and NO content
    /// accessor. Any node-content need routes through CorpusKit. This seam will
    /// never be widened.
    ///
    /// Async/sync asymmetry (G3, sanctioned): Swift is async; the Rust mirror is
    /// synchronous. Conformance compares edge output, not call shape. This mirrors
    /// the NeuronKit policy-store precedent.
    ///
    /// Re-registering replaces the existing entry for the handle. Pass `nil` to
    /// deregister (no direct nil-pass API — close the estate and re-open without
    /// re-registering). When no provider is registered, `recallTunnels` returns
    /// only stored tunnels — existing behaviour unchanged.
    ///
    /// - Parameters:
    ///   - provider: The host-side topology adapter.
    ///   - handle:   The estate to associate this topology with. Must be open.
    func registerNodeTopology(_ provider: any GLKNodeTopologyProvider, for handle: EstateHandle) {
        nodeTopologyProviders[handle] = provider
    }
}

// MARK: - Unified audit log (GLK-03)

public extension GeniusLocusKit {

    /// Return a snapshot of the unified audit log for the given handle.
    ///
    /// Issues a single SQL query against `_storagekit_audit` — one
    /// `SELECT * FROM _storagekit_audit ORDER BY hlc ASC LIMIT 50_000`
    /// regardless of estate size. This replaces the former in-memory
    /// G-Set CRDT pattern (Bug 1 fix, ADR025-AUDITLOG-GOVERNOR): the
    /// old approach kept a grow-only `auditLogs: [EstateHandle:
    /// UnifiedAuditLog]` dictionary and fed it via an N+1 per-drawer
    /// walk (`feedAuditLog`). Both are removed — audit data lives on
    /// disk in `_storagekit_audit` and this method reads it directly.
    ///
    /// The returned `UnifiedAuditLog` is a value type, safe to use
    /// outside the actor without aliasing any shared state.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is
    ///   not in the registry (stale or never issued); any storage-tier
    ///   error surfaced by `AuditLog.iterate`.
    func auditLog(for handle: EstateHandle) async throws -> UnifiedAuditLog {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        // One SQL round-trip instead of N+1 per-drawer calls. AuditBridge
        // converts each substrate AuditEvent to one or more UnifiedAuditEntries
        // (one per changed bitmap column); the 50 000 row limit caps unbounded
        // growth on very large estates while covering normal usage.
        let events = try await storage.auditLog.iterate(after: nil, rowID: nil, limit: 50_000)
        var log = UnifiedAuditLog()
        log.add(contentsOf: events.flatMap { AuditBridge.bridge($0) })
        return log
    }
}
