---
status: decided
question: How should the GeniusLocus substrate be decomposed into kits, and how should storage and sync concerns be separated, for a complete-on-day-one v1.0?
authors: MOOTx01 maintainers
date: 2026-05-19
relates_to:
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md (substrate contract)
  - docs/reference/COGNITIONKIT_SPEC.md
  - docs/reference/NEURONKIT_SPEC.md
  - docs/reference/ARIA_MCP_SPEC.md
  - docs/decisions/DECISION_LATTICE_CITATION_UDC_WIKIDATA_2026-05-07.md
  - docs/decisions/DECISION_Q1_MANIFEST_SCHEMA_2026-05-08.md
  - docs/decisions/DECISION_Q1_PROVENANCE_BITMAP_2026-05-08.md
  - docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
  - docs/decisions/DECISION_PHASE_2_FINAL_SELECTION_2026-05-18.md
  - docs/decisions/DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17.md
supersedes:
  - "GENIUSLOCUS_ARCHITECTURE_SPEC.md §15.1 (Kit composition), replaced by §4 of this record"
context:
  - The architecture must be complete on day one and durable for ten years, with no architectural deferrals to v2.
  - A consuming application's integration is on the critical path as the ship-gating proof of the substrate's value.
  - Storage and sync are treated as orthogonal axes, motivated by an existing consuming-application codebase precedent.
---

# Decision: GeniusLocus v1.0 Kit Graph Refactor

## 1. Summary

GeniusLocus v1.0 ships as an eleven-kit family with explicit separation of storage and sync concerns, foundational substrate math factored into its own kit, and a consuming application on the critical path as the ship-gating integration. The reframe expands the previously envisioned five-kit family (LocusKit, VectorKit, CorpusKit, GeniusLocusKit, aria-mcp) plus three orchestration kits (NeuronKit, CognitionKit, in the spec corpus) into eleven kits total by promoting `GeniusLocusReference` to a published SubstrateLib, adding PersistenceKit and ConvergenceKit as foundation peers, and retaining EngramLib and VectorKit as durability seams rather than folding them into composing kits.

The reframe is motivated by a single constraint: design completeness on day one, ten-year durability, no architectural deferrals to v2. Every choice in this record is checked against that constraint.

## 2. Driving Principle: No v2 Deferrals

This record's premise is that the architecture must be complete on day one and last ten years without significant rework. Lazy patterns that push uncomfortable choices to v2 are rejected. Architectural seams that preserve flexibility against future composition patterns are paid for up front, even when no current consumer demands them.

The principle drives three concrete decisions in this record:

The first decision is to retain VectorKit as a separate kit despite no current standalone consumer. The argument that "no one calls VectorKit directly today" misses that the kit boundary preserves flexibility for future patterns (Rag2Kit, GraphRAG, hierarchical retrieval, multi-modal fusion). The same logic that justified factoring EngramLib out of the math layer (the math could not be trusted to be done consistently across kits) applies to vector primitives. The kit boundary's cost is one set of tests and one API surface; its benefit is durability against patterns that have not been invented.

The second decision is to ship three PersistenceKit backends at v1.0 rather than one with two stubs. SQLite plus PostgreSQL plus InMemory exercises the abstraction against fundamentally different storage shapes and proves the design works before any product depends on it. Shipping one backend and adding the rest in v1.x defers proof that the abstraction is correct.

The third decision is to ship Brain layer completeness (standing signals, matrix tier, dreaming daemon, maintenance daemon, audit chain monitor, SolverBandit) in v1.0 rather than deferring it to v1.x. A consuming application demonstrates the thesis by running it, and the substrate's value proposition (cognition accumulates in memory, AI reads it) requires the Brain layer running to be proven.

## 3. What Changes and What Does Not

### 3.1 The Eight Constitutional Items Hold

The foundations document names eight constitutional items that cannot change without v2 successor architecture work. This record does not touch any of them:

1. Verbatim is sacred. Rung 1 immutable after capture.
2. Audit is universal. Every mutation logged, append-only.
3. Nine verbs, fixed. Verb composition, not expansion.
4. Four adjective categories, fixed. Universal across nouns.
5. Three bitmap columns, fixed widths. Adjective, operational, provenance, all Int64.
6. Three storage tiers (bitmap, structured, blob). Each with its own read discipline.
7. Manifest-declared layout versioning. Old data remains readable.
8. Single-estate substrate. Federation lives outside.

The reframe operates entirely in implementation territory. The substrate's contract with its consumers stays identical to what is specified in GENIUSLOCUS_ARCHITECTURE_SPEC.md. The reframe changes how the substrate is decomposed into kits and how it interacts with storage and sync layers, not what it does.

### 3.2 The Twenty-Two Constitutional Invariants Hold

The paper's Appendix A invariants (I-1 through I-22) hold without modification. The kit graph reframe preserves them by construction: I-19 (bit-identity across conformance cells) is enforced by SubstrateLib's existing conformance gate; I-12 (cognition tier owns ANE routing) is preserved by keeping the Brain layer inside NeuronKit; I-13 (the substrate does not federate) is preserved by keeping federation as an aria-mcp responsibility mediated through ConvergenceKit's wire protocols.

### 3.3 What This Reframe Adds

This reframe adds three foundation kits (SubstrateLib, PersistenceKit, ConvergenceKit) and the architectural separation of storage and sync as orthogonal concerns. It clarifies LocusKit's role as structurally semantic search (not embedding-based) and folds embedding-aware tokenization into CorpusKit where it belongs. It commits a consuming application to the critical path as the ship-gating integration. It specifies the eleven-step sequence that takes the codebase from current state to a v1.0 shippable against that consuming application.

### 3.4 What This Reframe Does Not Change

The substrate's mathematical specification (paper §3 through §10), the algebra notebook's fingerprint construction (256-bit four-block SimHash), the Brain layer's six standing signals (paper §11.2), the nine verbs (spec §10), the four-block fingerprint compatibility property (I-17), the federation algebra (paper §9), the differential privacy protocol at tier boundaries (paper §9.4), and the conformance gate's bit-identity requirement (I-19) all hold unchanged.

The foundational work from the Phase 1 through Phase 4 build sequence is also preserved as completed work. Those phases landed the bitmap layout, adjective/operational/provenance columns, audit-trail-is-substrate discipline, Filter algebra, and the bitmap evaluator. This reframe builds on that foundation; it does not invalidate it.

## 4. The Eleven Kits

The kit graph has four logical layers. Foundation kits hold the math and the storage and sync primitives. The typed math kit wraps SubstrateLib's untyped output. Standalone substrate kits provide three independently usable products. Composition and orchestration kits assemble the substrate kits into the full memory architecture.

```
Foundation layer:
    SubstrateLib  (math, kernels, fingerprint, audit primitives, G-Set CRDT, HLC ordering)
    PersistenceKit    (backends: SQLite, PostgreSQL, InMemory; protocols for row, blob, vector, audit)
    ConvergenceKit       (implementations: CloudKit, Federation, None; protocols for sync transport)

Typed math:
    EngramLib (typed 256-bit Engram type, projection API, consumes SubstrateLib)

Standalone substrate:
    LocusKit   (structurally semantic search: KG, lattice, bitmap predicates)
    VectorKit  (vector primitives: storage, similarity, index management, projection)
    CorpusKit     (RAG pattern: tokenization, chunking, content plus vector, retrieval; depends on VectorKit)

Composition:
    GeniusLocusKit (assembles LocusKit plus CorpusKit plus Brain layer; owns audit log and standing signals)

Orchestration:
    NeuronKit    (algorithms: autonomic plus reasoning)
    CognitionKit (recipes: sequences NeuronKit calls)
    aria-mcp     (access surface: only external entry point)
```

The dependency relationships flow strictly upward. SubstrateLib, PersistenceKit, and ConvergenceKit have no dependencies on other kits. EngramLib depends on SubstrateLib. LocusKit, VectorKit, and CorpusKit depend on EngramLib plus PersistenceKit (and CorpusKit additionally on VectorKit and ConvergenceKit). GeniusLocusKit composes the standalone substrate kits. NeuronKit, CognitionKit, and aria-mcp sit at the top of the stack.

### 4.1 SubstrateLib (promotion of GeniusLocusReference)

SubstrateLib is the math layer of the substrate, promoted to a published kit from the existing `GeniusLocusReference` reference implementation. The reference implementation has accumulated significant rigor: a series of Phase 2 commits closing eight production needs, bit-identical parity between Swift and Rust ports verified at the conformance gate, learned dispatch across NEON and BNNS and Metal backends, and a measured kernel selection ledger documenting which approach wins for which need.

SubstrateLib's public surface holds the four-block SimHash fingerprint construction (paper §5), the Hamming distance and OR-reduction primitives (paper §5.5 through §5.8), the audit log CRDT primitives including G-Set union and HLC advancement (paper §6.1, §6.2), the projection function `project_current` and `project_at` (paper §6.3), the matrix tier kernel primitives (paper §7), and the kernel dispatch trait that backends override (DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17.md). The conformance gate from Phase 2 work is preserved: every backend produces bit-identical output to the scalar reference across all four conformance cells (Swift aarch64 macOS, Swift x86_64 Linux, Rust aarch64 Linux, Rust x86_64 Linux).

What changes from `GeniusLocusReference` to `SubstrateLib` is renaming, Sendable conformance hardening for Swift 6 strict concurrency, public API stabilization (no breaking changes once shipped), Swift Package manifest at the kit boundary, and removal of any reference-implementation-only test scaffolding from the public surface. No mathematical change, no algorithmic change, no kernel change.

### 4.2 PersistenceKit (new)

PersistenceKit is the storage abstraction layer that lets the substrate kits work against multiple database backends without per-backend code in the kit. It is one of the two foundation kits added in this reframe. Its protocols describe what every substrate kit needs from a backend; its backend implementations satisfy those protocols against specific stores.

The protocols are:

```swift
public protocol RowStore: Sendable {
    func insert(table: TableID, values: [TypedValue]) async throws -> RowHandle
    func upsert(table: TableID, values: [TypedValue]) async throws -> RowHandle
    func delete(table: TableID, where: Predicate) async throws -> Int
    func query(table: TableID, where: Predicate?, orderBy: OrderClause?, limit: Int?) async throws -> AsyncStream<Row>
    func count(table: TableID, where: Predicate?) async throws -> Int
}

public protocol BlobStore: Sendable {
    func put(key: BlobKey, bytes: Data) async throws
    func get(key: BlobKey) async throws -> Data?
    func delete(key: BlobKey) async throws
    func stream(key: BlobKey) async throws -> AsyncStream<Data>
}

public protocol VectorIndex: Sendable {
    func add(key: RowKey, vector: [Float], metadata: [String: Any]) async throws
    func delete(key: RowKey) async throws
    func knn(query: [Float], k: Int, metric: DistanceMetric, filter: MetadataFilter?) async throws -> [(RowKey, Float)]
    func reindex(parameters: IndexParameters) async throws
}

public protocol AuditLog: Sendable {
    func append(event: AuditEvent) async throws
    func query(rowID: RowID?, timeRange: ClosedRange<Date>?, actor: String?) async throws -> AsyncStream<AuditEvent>
    func project(rowID: RowID, asOf: HLC?) async throws -> ProjectedState?
}

public protocol Storage: Sendable {
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var vectorIndex: any VectorIndex { get }
    var auditLog: any AuditLog { get }
    
    func transaction<T>(_ block: (StorageTransaction) async throws -> T) async throws -> T
    func migrate(to schemaVersion: Int) async throws
    func close() async
}
```

The `Predicate` type is a tree of bitmap predicates, comparison predicates, and logical combinations. BitmapEvaluator (currently in LocusKit) compiles the Filter algebra (spec §7.9) into Predicate trees. The backend compiles Predicate trees into backend-native query language (SQL for SQLite and PostgreSQL, in-memory traversal for InMemory).

The `TypedValue` enum carries the typed columns. Cases include `.uuid`, `.bitmap` (Int64), `.text`, `.timestamp`, `.float`, `.int`, `.blob`, `.json`. Backends map each case to the appropriate wire format: SQLite uses INTEGER for bitmaps, TEXT for ISO8601 timestamps, BLOB for binary; PostgreSQL uses BIGINT for bitmaps, TIMESTAMPTZ for timestamps, BYTEA for binary.

#### 4.2.1 Backends

The v1.0 backends are:

**PersistenceKit-SQLite** is the Apple ecosystem default. Single-file SQLite database with the sqlite-vec extension loaded for vector indexing. WAL mode for concurrent reads. File location is configurable per-estate. Per-estate connection pool. Tested against millions of rows for the substrate's expected scale.

**PersistenceKit-PostgreSQL** is the server-side and not-Apple deployment target. Connection pool managed via the standard libpq client. pgvector extension for vector indexing. MVCC concurrency model. Tested against the MSP case study's expected scale (hundreds of users, tens of estates per user, millions of rows per estate).

**PersistenceKit-InMemory** is the test backend. No persistence between process restarts. All operations complete synchronously. Used for CI, fast iteration, and conformance tests. Not a production target.

#### 4.2.2 Schema Declaration and Migration

Each substrate kit declares its schema in PersistenceKit's vocabulary. The kit ships a `SchemaDeclaration` value that lists tables, columns, indices, and constraints. PersistenceKit's backends emit backend-specific DDL from the declaration. Migration ships per-version: when a kit changes its schema, it ships a numbered migration. PersistenceKit tracks applied migrations in a `migrations` table it owns and runs unapplied ones in order at estate open time.

The schema declaration and migration system is the seam that lets kits evolve their internal storage without PersistenceKit needing kit-specific knowledge. PersistenceKit handles the mechanics (apply this migration in this transaction); the kit owns the content (what the migration does).

#### 4.2.3 Bitmap Predicate Compilation

The Filter algebra from spec §7.9 is currently compiled to SQLite SQL by LocusKit's BitmapEvaluator. In the new shape, BitmapEvaluator compiles to a PersistenceKit `Predicate` tree, which PersistenceKit's backends compile to backend-native SQL. This adds one compilation stage but the stage is small and the benefit is portability across backends.

The mandatory filter ordering from spec §7.9.5 (tombstoned exclusion checked at bitmap-tier first, then default filter insertion for state/trust/provenance, then user-specified filters) is preserved by BitmapEvaluator. PersistenceKit sees only the compiled Predicate tree; it does not re-order or insert defaults.

#### 4.2.4 What PersistenceKit Does Not Do

PersistenceKit does not own the audit log's CRDT structure. The G-Set CRDT properties (paper §6.1) and HLC ordering (paper §6.2) are application-layer concerns owned by GeniusLocusKit. PersistenceKit provides the append-only persistence (AuditLog protocol) and the projection helpers (project function); the CRDT mathematics are upstream.

PersistenceKit does not handle sync. CloudKit, Federation, and other sync mechanisms live in ConvergenceKit. PersistenceKit and ConvergenceKit cooperate via ConvergenceKit reading and writing rows through PersistenceKit's protocols, but PersistenceKit has no knowledge of sync.

PersistenceKit does not provide encryption at rest. That is a backend-specific concern handled by SQLite's encryption extension or PostgreSQL's TDE features, configured per-backend at estate open time.

### 4.3 ConvergenceKit (new)

ConvergenceKit is the sync abstraction layer. It is the second foundation kit added in this reframe and the architectural acknowledgment that storage and sync are orthogonal concerns.

The protocols are:

```swift
public protocol SyncEngine: Sendable {
    func enableSync(estate: EstateHandle, configuration: SyncConfiguration) async throws
    func push(estate: EstateHandle) async throws -> SyncResult
    func pull(estate: EstateHandle) async throws -> SyncResult
    func disable(estate: EstateHandle) async throws
    var syncState: AsyncStream<SyncState> { get }
}

public protocol SyncTransport: Sendable {
    func sendAuditEvents(_ events: [AuditEvent], destination: SyncDestination) async throws -> SyncReceipt
    func receiveAuditEvents(source: SyncSource, since: HLC?) async throws -> [AuditEvent]
    func sendBlobs(_ keys: [BlobKey], destination: SyncDestination) async throws
    func receiveBlobs(_ keys: [BlobKey], source: SyncSource) async throws -> [BlobKey: Data]
    func handshake(peer: PeerIdentity, hyperplaneFamily: HyperplaneFamily) async throws -> HandshakeResult
}
```

The audit-event exchange surface is the canonical sync primitive. Federation between two estates consists of audit event exchange plus hyperplane handshake (paper §9.2). The blob exchange surface is for content not represented in the audit log (large drawer contents, attachments). The handshake surface establishes shared hyperplane families for federation per the paper's specification.

#### 4.3.1 Implementations

The v1.0 implementations are:

**ConvergenceKit-CloudKit** is the Apple ecosystem sync stack. It is built by porting a consuming application's existing CloudSync target into a kit-shaped package. The port preserves that application's working patterns: CKContainer wrapping, CKDatabaseSubscription for push notifications, per-entity push and pull engines, CKRecord mappers per entity type, conflict resolution via stored server records, per-zone state tracking.

The port does not migrate the host application to CKSyncEngine (the newer Apple API). The decision is to ship working code first and evaluate CKSyncEngine migration as a future ConvergenceKit-CloudKit v2 once the kit boundary is stable. The CKSyncEngine API offers some benefits (lower-level control, fewer assumptions, better cross-zone handling) but introduces new failure modes and would require the host application to be re-engineered against a different sync surface. v1.0 ships what works.

The CloudKit zone strategy is one zone per estate. Each estate's manifest declares its zone identifier (typically `GeniusLocus-{estate_uuid}`). Zones sync independently. Multiple estates on the same device sync to multiple zones in parallel. The consuming application's precedent of per-database zones generalizes to per-estate zones.

**ConvergenceKit-Federation** is the substrate-native sync implementation per paper §9. It implements the G-Set CRDT audit event exchange protocol, the hyperplane family handshake (paper §9.2), the tier-ascending query protocol (paper §9.3), and differential privacy at tier aggregation points (paper §9.4). This is the implementation that makes household federation (case study 1), fleet federation (case study 2), and MSP federation (case study 3) work cross-perimeter.


ConvergenceKit-Federation is not a competitor to CloudKit; the two address different sync problems. CloudKit syncs my devices to my other devices (single-owner, single-iCloud-account). Federation syncs my estate to your estate (cross-owner, perimeter-respecting). Both can run simultaneously: an estate may sync to iCloud via ConvergenceKit-CloudKit (for between-my-devices coherence) and also federate with my partner's estate via ConvergenceKit-Federation (for household-shared cognition). The two channels operate independently.

**ConvergenceKit-None** is the no-sync passthrough. Single-device deployments, development environments, and tests use it. Calling sync methods is a no-op; state stays local.

#### 4.3.2 Per-Estate Sync Zones

Because multiple GeniusLocus estates can run on one device (see §9), sync configuration is per-estate, not per-app. Each estate has its own SyncEngine instance configured against its own zone (for CloudKit), its own peer set (for Federation), or no engine (for None). The substrate kits do not know about sync directly; they call into PersistenceKit, and ConvergenceKit observes PersistenceKit's audit log to know what to sync.

This pattern matches the consuming application's existing architecture: SQLite is the source of truth, CloudSync observes SQLite for changes and pushes them to CloudKit. The ConvergenceKit generalization extends this to any sync backend.

#### 4.3.3 What ConvergenceKit Does Not Do

ConvergenceKit does not own the storage. Data lives in PersistenceKit; ConvergenceKit reads and writes through it. A device with ConvergenceKit-None still has full local data; what is missing is the sync wire that exchanges data with other devices.

ConvergenceKit does not own cross-estate mediation as a product feature. aria-mcp handles cross-estate operations at the access surface (presenting credentials for multiple estates, routing queries appropriately, applying tier-ascending protocols). ConvergenceKit-Federation provides the wire-level CRDT exchange that aria-mcp's mediation rides on, but the two layers are distinct.

ConvergenceKit does not provide conflict resolution as a high-level abstraction. The substrate's G-Set CRDT (paper §6) is conflict-free by construction; sync is always convergent. What ConvergenceKit-CloudKit handles in its conflict resolver is the case where a host application's pre-substrate, application-specific data (which is not in the substrate's CRDT form) has conflicts on push. That logic is preserved for that application-specific sync but does not apply to GeniusLocus estate sync.

### 4.4 EngramLib (existing, refactored)

EngramLib was previously factored out of the math layer because vector and engram operations could not be trusted to be done consistently across kits. That justification holds in the new graph: EngramLib is the typed 256-bit fingerprint API that all kits use when they need to construct, compare, or transmit a fingerprint.

In the new graph, EngramLib consumes SubstrateLib. The math is in SubstrateLib; EngramLib wraps it in a typed Swift API. The refactor removes EngramLib's local copies of the SimHash construction and points at SubstrateLib's primitives.

EngramLib also gains a typed `Engram.project(from: AnyNoun)` wrapper that VectorKit and other kits call when they need to compute a fingerprint for a noun. The projection logic itself is in SubstrateLib; EngramLib exposes the convenience API.

EngramLib remains a Swift-only kit. The Rust version is not exposed as a kit; Rust callers use SubstrateLib directly with their own typed wrappers.

### 4.5 LocusKit (existing, refactored)

LocusKit holds structurally semantic search. In this reframe, "semantic" is clarified to mean structural semantics (knowledge graph triples, UDC plus Wikidata lattice anchors, typed tunnels, bitmap predicate algebra), not embedding-based semantics (which live in CorpusKit).

The clarification matters because both flavors of "semantic" appear in the AI memory literature. RAG systems mean embedding-based. Knowledge graph systems mean structural. LocusKit is the latter; CorpusKit is the former. GeniusLocusKit fuses them through hybrid recall (paper §10.2, NeuronKit §4.1: BM25 plus vector plus RRF plus MMR).

The refactor moves LocusKit's bitmap math operations (currently in `BitmapOps.swift`) to consume SubstrateLib's primitives instead of defining its own. The Filter algebra and BitmapEvaluator remain in LocusKit because they are LocusKit's compositional surface; what changes is what they compile to (PersistenceKit Predicate trees instead of raw SQL).

LocusKit's storage moves to consume PersistenceKit instead of opening sqlite3 directly. The 333 passing tests stay passing; the test fixtures are exercised against PersistenceKit-InMemory in CI for speed and against PersistenceKit-SQLite for parity with production.

LocusKit's responsibility for the audit log moves to GeniusLocusKit (see §4.8). LocusKit becomes a standalone product that can be used independently of GeniusLocusKit, but in that standalone configuration its audit log is local-only (no cross-kit audit unification). GeniusLocusKit composition is where the audit log unifies across LocusKit, CorpusKit, and the Brain layer.

### 4.6 VectorKit (existing, retained for seam preservation)

VectorKit was previously planned to be folded into CorpusKit on the argument that no current consumer uses it standalone. That argument is rejected. The kit boundary preserves flexibility for future patterns that need vector primitives without RAG's opinions (Rag2Kit, GraphRAG, hierarchical retrieval, multi-modal fusion, federated retrieval). The cost of the boundary (one set of tests, one API surface) is small; the benefit (durability against patterns not yet invented) is large.

VectorKit's responsibility is vector primitives only: vector storage with model and version tagging, similarity search (k-nearest-neighbors, threshold queries), index management (flat, IVF, HNSW), vector arithmetic (add, subtract, normalize, mean), and projection to engrams via EngramLib. VectorKit does not own tokenization (which is text-specific and lives in CorpusKit), chunking, content storage, or retrieval augmentation.

The refactor fixes VectorKit's three current production blockers documented in the existing code: replace the homegrown `uuid_lite` with the `uuid` crate, replace the WordPiece tokenization stand-in with proper BERT vocabulary loading (or remove tokenization from VectorKit entirely if it moves to CorpusKit), and replace the sign-bit projection placeholder with SubstrateLib's SimHash projection via EngramLib.

The refactor also moves VectorKit's storage to PersistenceKit. Vector indexing happens through the VectorIndex protocol; backend implementations (sqlite-vec for SQLite, pgvector for PostgreSQL, in-memory linear scan for InMemory) handle the wire-level work.

### 4.7 CorpusKit (existing, refactored)

CorpusKit holds the RAG pattern. It depends on VectorKit (which it consumes for vector storage and similarity) and on PersistenceKit (which it consumes for content storage). The refactor absorbs tokenization from VectorKit, which was a layering mistake in the previous architecture; tokenization is text-specific and belongs with the kit that knows about text.

CorpusKit's surface holds embedding providers for text (MiniLM, mpnet, EmbeddingGemma), chunkers with sentence-boundary detection via NaturalLanguage, RAG bundles linking chunks plus vectors plus metadata, retrieval composition primitives, and the BM25 inverted index for keyword retrieval.

CorpusKit can be used standalone (a caller wanting RAG without the substrate's audit log or Brain layer). In that configuration, CorpusKit's audit log is local to CorpusKit. Composition with LocusKit through GeniusLocusKit unifies the audit log across both kits.

### 4.8 GeniusLocusKit (existing, composition)

GeniusLocusKit assembles LocusKit and CorpusKit and the Brain layer into the full memory substrate. It is where the audit log unifies across all substrate kits, where the nine verbs operate over the composed substrate, where the manifest holds the estate's configuration, and where the standing signals daemon ecology runs.

The composition shape is:

```swift
public actor GeniusLocusKit {
    private let estate: EstateHandle
    private let locus: LocusKit
    private let rag: CorpusKit
    private let brain: BrainLayer
    private let storage: any Storage
    private let sync: any SyncEngine
    
    public func capture(_ frame: CaptureFrame) async throws -> Drawer
    public func recall(_ frame: RecallFrame) async throws -> RecallStream
    public func mutate(_ drawerID: DrawerID, kind: MutationKind, payload: Any) async throws
    public func withdraw(_ drawerID: DrawerID, reason: String) async throws
    public func expunge(_ drawerID: DrawerID, reason: String) async throws
    public func reanchor(_ drawerID: DrawerID, to: LatticeAnchor) async throws
    public func learn(_ frame: LearnFrame) async throws
    public func propose(_ proposal: Proposal) async throws -> ProposalID
    public func associate(_ source: DrawerID, _ target: DrawerID, kind: TunnelKind) async throws
}
```

The nine verbs (spec §10) are GeniusLocusKit's public surface. Each verb writes a unified audit event that captures the verb's effect across both LocusKit's and CorpusKit's storage. The audit event is appended through PersistenceKit's AuditLog protocol, with the unified G-Set CRDT structure maintained at this layer.

The Brain layer (spec §11, paper §11) is a sub-module of GeniusLocusKit. It hosts the standing signals scheduler (paper §11.3), the four-emission-class contract for autonomic functions (paper §11.4), the matrix tier (paper §7) with M times M-transpose updates and asymmetry profile, the dreaming daemon (paper §11.2 row 1), the maintenance daemon (paper §11.2 row 2), the vector-similarity standing signal (paper §11.2 row 6), the decay sweep signal, the byReference validity signal, the federation sync signal, and the maintenance sweep signal.

The dreaming daemon's two-source reward signal retrieval (DiaryEntry rewards plus RecallTrace usage events) ships in v1.0 per the NeuronKit spec §3.1. The SolverBandit (paper §3.4, NeuronKit §3.4) ships in v1.0 with its three v1.0 decisions: ef_search level, dreaming trigger mode, compression tier.

### 4.9 NeuronKit (existing spec, unchanged in this reframe)

NeuronKit is the algorithms layer per NEURONKIT_SPEC.md. This reframe does not change NeuronKit's specification. The split between autonomic functions (downward-pointing, called by schedule or event) and reasoning functions (caller-driven) holds.

What the reframe clarifies is that NeuronKit's autonomic functions (the standing signals) execute inside the Brain layer of GeniusLocusKit (§4.8). NeuronKit defines what they do; GeniusLocusKit runs them on its scheduler. This is the same code organization that the NeuronKit spec already implies; the reframe makes the kit boundary explicit.

NeuronKit's reasoning functions (hybrid recall, ContextSynthesizer, branch derivation, tournament scoring, scenario elicitation, ScenarioProfile persistence, benchmark, write policy enforcement) stay as their own module called explicitly by CognitionKit recipes and by aria-mcp's algorithm call mode.

### 4.10 CognitionKit (existing spec, unchanged in this reframe)

CognitionKit is the recipe layer per COGNITIONKIT_SPEC.md. This reframe does not change CognitionKit's specification. The three v1.0 recipes (DailyFraming, MigrationBenchmark, ScenarioSkill) ship as specified.

What the reframe clarifies is that CognitionKit recipes receive an EstateHandle as a parameter. Recipes do not open estates. The estate handle points at a specific GeniusLocusKit estate. Multiple recipes can run against multiple estates on the same device by passing different handles. This pattern is already in the spec; the reframe operationalizes it for the multi-estate-per-device case.

### 4.11 aria-mcp (existing spec, unchanged in this reframe)

aria-mcp is the access surface per ARIA_MCP_SPEC.md. This reframe does not change aria-mcp's specification. The three call modes (transactional, algorithm, trigger plus webhook), the schema versioning discipline, the write policy enforcement at the boundary, the cross-estate mediation per invariant I-13, and the agent memory protocol all ship as specified.

What the reframe clarifies is that aria-mcp can serve multiple estates from a single aria-mcp instance. Each estate is identified by its UUID; per-estate authorization (owner credentials, scoped credentials) authenticates the caller. Cross-estate operations (cross-estate recall, federated queries) are aria-mcp's responsibility and are mediated through ConvergenceKit-Federation's wire protocol at the substrate level.

## 5. Storage and Sync as Orthogonal Axes

The architectural insight that motivates the PersistenceKit and ConvergenceKit separation is that storage and sync are orthogonal concerns. Storage answers where the durable bits live on this device; sync answers how bits converge across device or perimeter boundaries. Treating them as one axis is a category error that an existing consuming-application codebase already taught us not to make.

### 5.1 The Consuming-Application Precedent

A consuming application's existing kit (currently shipping) has two separate Swift targets:

`Sources/Persistence/Persistence.swift` opens with a comment identifying the module as the SQLite source of truth for the application. It defines a `PersistenceStore` protocol with `SQLiteStore` as the only conforming implementation. Single local SQLite file with a versioned schema (currently v16). Migration is destructive (drop and rebuild) up through development; production migrations are additive going forward.

`Sources/CloudSync/SyncCoordinator.swift` is a separate target that wraps `CKContainer` and `CKDatabase` directly (it does not use the newer CKSyncEngine API). It contains push engines and pull engines orchestrated by a SyncCoordinator that handles enable, push, pull, account-status checks, and zone setup. Every syncable entity has metadata on it (`sync_status: SyncStatus`, `sync_record_name: String?`) tracked in SQLite. The CKRecordMapper layer translates between SQLite rows and CKRecords per entity type.

The pattern is: data lives in SQLite on each device. CloudKit is the wire format for sync between devices. CloudKit is not the storage backend; it is the sync mechanism layered on top.

This pattern generalizes. SQLite plus CloudKit is the consuming-application case. SQLite plus ConvergenceKit-Federation is the paired-estate household scenario from case study 1. PostgreSQL plus a hypothetical server-authoritative sync is the MSP scenario. SQLite plus ConvergenceKit-None is local-only development. The two axes compose freely.

### 5.2 The Substrate Spec Implies This Already

Paper §6 specifies the audit log as a Grow-Only Set CRDT under HLC ordering. Theorem 1 (sync convergence) states that after exchanging audit events, two replicas' projected states are identical. Paper §9.2 specifies federation as audit event exchange plus hyperplane family handshake. These are sync mechanisms layered on whatever holds the audit log.

The substrate's mathematics do not specify which backend holds the audit log. The G-Set CRDT properties (commutativity, associativity, idempotence of set union) hold regardless of backend. SQLite holding the audit log is a deployment choice; PostgreSQL holding it is another deployment choice; an InMemory store holding it for tests is a third. Bit-identity across backends (invariant I-19) is preserved because the math is in the kit code, not in the backend.

The reframe makes this latent orthogonality explicit in the kit graph. PersistenceKit handles backend dispatch. ConvergenceKit handles sync dispatch. The substrate kits (LocusKit, CorpusKit, GeniusLocusKit) operate against PersistenceKit and ConvergenceKit through protocols that do not leak backend or sync details.

### 5.3 Why This Matters for Ten Years

Storage technology evolves. PostgreSQL was the obvious server choice in 2025; in 2035 it might still be obvious or it might be displaced by something currently unimagined. Sync technology evolves faster. Apple may replace CloudKit with a successor framework; new federation protocols may emerge from research; new sync wire formats may become standard.

The orthogonal-axes design accommodates change on either axis without requiring change on the other. Replacing CloudKit with its successor is a ConvergenceKit-NewSyncStack implementation; storage stays. Replacing PostgreSQL with its successor is a PersistenceKit-NewStore backend; sync stays. The substrate kits and the orchestration kits do not change in either case.

A single-axis design (treat CloudKit as a backend, or treat the database as a sync wire) couples the two concerns and forces lockstep upgrades. The orthogonal design lets each axis evolve at its own cadence.

## 6. Multi-Estate per Device

A device may run several GeniusLocus estates doing multiple things; a consuming application's GeniusLocus estate does not share a SQLite file with that application's existing domain storage. This is the spec's multi-estate property (paper §15.1, foundations §IV item 8) operationalized.

### 6.1 The Property

A device can hold multiple GeniusLocus estates. Each estate is a separate SQLite file with its own schema, its own manifest, its own audit log, its own hyperplane family for the 256-bit fingerprint, its own CloudKit zone (if sync is enabled), and its own Brain layer running on its own schedule.

Worked examples from the case study corpus:

A single user's general-life estate operates on UDC zoom window 0 through 9. Their woodworking-hobby estate operates on UDC 684.08. Their professional-coding estate operates on UDC 004.42. All three belong to the same user; none of them merge with the others. Cross-estate operations are mediated by aria-mcp.

On the same device, a consuming application has its own GeniusLocus estate (the parallel estate that runs alongside the application's domain storage). A separate brain app, if installed, has its own. A repo-craft agent, if running, has its own. Each app's estate is bounded to that app's domain and lifecycle.

### 6.2 What This Requires of the Kits

PersistenceKit's `open` operation takes an estate URL and returns an estate-scoped store. Multiple stores can be open simultaneously on the same device, each backed by its own file. They share no transactional context. Connection pooling (for PostgreSQL) is per-estate.

ConvergenceKit-CloudKit's zones are per-estate. The zone identifier convention encodes the estate UUID (typically `GeniusLocus-{estate_uuid}`). Multiple zones sync independently. The CKDatabaseSubscription is per-zone.

GeniusLocusKit composition is per-estate. Each estate gets its own composed substrate, its own Brain layer instance, its own standing signals running on its own schedule. Brain layer state (the dreaming daemon's tick history, the maintenance daemon's last-sweep timestamps, the SolverBandit's posterior distributions) is per-estate and lives in that estate's manifest.

aria-mcp can serve multiple estates from a single aria-mcp instance. Per-estate authorization (per the aria-mcp spec §4) authenticates the caller to a specific estate. Cross-estate operations (cross-estate recall per aria-mcp §8) present credentials for multiple estates and merge results at the response layer.

CognitionKit recipes receive an EstateHandle parameter. The same recipe runs against different estates by passing different handles. The daily-framing recipe runs against the consuming application's estate; the same recipe could run against another app's estate with different scoring weights.

### 6.3 The Substrate Stays Single-Estate

Invariant I-13 (the substrate does not federate; cross-estate operation is mediation outside the substrate) holds without modification. Multiple estates on one device do not federate at the substrate level. They federate at the aria-mcp access layer if at all. The substrate's single-estate correctness story is preserved.

## 7. A Consuming Application on the Critical Path

A consuming application runs a parallel GeniusLocus database on GeniusLocusKit as the proof of what the system is worth, and that application cannot ship without GeniusLocusKit being done.

This commits the consuming application to the critical path. It is not a future consumer of these kits; it is the integration test that ships, and GeniusLocusKit completion gates its ship date.

### 7.1 The Integration Shape

The consuming application continues to use its existing SQLite source-of-truth for its own application domain (its domain entities, places, delegates, journal, knowledge documents, settings, device settings). That database and its schema (currently v16) are untouched by the reframe. The application's product ships against that database as it does today.

Alongside the application's domain database, the application opens a parallel GeniusLocus estate on first launch. The estate lives in a separate SQLite file at a well-known path (typically `~/Library/Application Support/<app>/genius-locus/{estate_uuid}.sqlite`). It has its own schema (the substrate's schema, declared by GeniusLocusKit and emitted by PersistenceKit-SQLite). It has its own manifest with its own UUID, its own hyperplane family, and its own CloudKit zone configuration.

The two databases are loosely coupled. There is no shared transaction across them; eventual consistency is the contract. The application's domain-entity operations trigger corresponding GeniusLocus captures: a domain-entity creation generates a drawer capture into the GeniusLocus estate with the entity's title as content, the entity's lattice category as the lattice anchor, and a provenance bitmap encoding (source: user_stated, confirmation: user_confirmed, channel: cli, sensitivity: normal). A domain-entity status transition generates an audit event in the GeniusLocus estate's audit log alongside the application's existing journal entry.

The substrate accumulates structural knowledge about how the application is being used. Over weeks and months, the standing signals build up: the dreaming daemon discovers latent associations between domain entities; the maintenance daemon detects stale active entities; the vector-similarity signal identifies semantically adjacent entities; the matrix tier accumulates field correlations across the bitmap, lattice, lineage-temporal, and channel-source blocks; the end-of-day tournament signal scores active framings against the day's accumulated signals.

The application's leverage scoring augments with `CognitionKit.recall_current_posture(window)`. The returned 256-bit fingerprint summarizes recent application activity in a form leverage scoring can match against historical postures. The augmentation does not replace the existing leverage algorithm; it adds a substrate-derived context signal.

### 7.2 The Two CloudKit Zones

The application's existing domain CloudKit zone (named per the application's existing convention) syncs its domain entities as it does today. A new GeniusLocus zone (named `GeniusLocus-{estate_uuid}`) syncs the parallel estate. Both zones sync independently. On the receiving device, both zones converge separately.

ConvergenceKit-CloudKit's per-estate configuration handles both: the application's domain zone is configured by its existing CloudSync target (which gets refactored to consume ConvergenceKit-CloudKit's primitives in step 11); the GeniusLocus zone is configured by GeniusLocusKit through ConvergenceKit-CloudKit for the parallel estate.

Conflict resolution differs by zone. The application's domain zone uses its existing conflict resolver (the SyncConflictResolver with stored server records in `sync_server_records`). The GeniusLocus zone uses the G-Set CRDT structure (paper §6.1) which is conflict-free by construction; no resolver is needed because set union is commutative, associative, and idempotent.

### 7.3 Application-Journal Coexistence in v1.0

The application's existing journal entries (the journal of behavioral facts about domain-entity state transitions) coexist with the GeniusLocus audit log in v1.0. The coexistence is a one-way bridge: every journal entry generates a corresponding GeniusLocus audit event tagged with the journal's origin. The GeniusLocus audit log accumulates a richer structural view; the application journal stays the application's behavioral log.

The decision about whether to migrate the application journal entirely into the GeniusLocus audit log (eliminating duplicate storage) is deferred to the application's pricing decision. If GeniusLocus is included in the application's free tier, the migration becomes worthwhile to eliminate redundancy. If GeniusLocus is the paid tier, the application journal stays as the free-tier floor experience and the coexistence pattern continues indefinitely.

This deferral is not a v2 deferral of architectural design. The architecture supports both modes (coexistence and full migration) without further work. The deferral is a product positioning decision that can be made when the application's pricing is finalized.

### 7.4 The Ship Gate

Step 11 (the consuming application's integration) produces an application that demonstrates the thesis. The acceptance criteria are concrete and measurable:

The application opens, creates its parallel GeniusLocus estate on first launch, opens it on subsequent launches. The estate's manifest is populated with the v1 required keys. The audit log is initialized.

Every domain-entity capture in the application produces a corresponding capture in the GeniusLocus estate. The drawer carries the entity's title verbatim (rung 1 sacred per spec §I-1), a lattice anchor derived from the entity's category (UDC plus optional Wikidata Q-ID), and the provenance bitmap encoding the capture context.

Domain-entity state transitions write audit events to both the application's persistence (existing SQLite) and the GeniusLocus audit log (G-Set CRDT structure). The two logs are correlated through the entity's UUID, which appears in both.

CognitionKit's `recall_current_posture(window)` returns a 256-bit fingerprint summarizing recent application activity. The application's leverage scoring augments with this fingerprint. The augmentation is observable in the scoring breakdown when the user inspects a node's leverage score.

The standing signals run on their configured schedules. The dreaming daemon's tick produces association proposals when the minimum confidence and minimum attempts thresholds are crossed. The maintenance daemon's tick detects forbidden combinations (per spec I-3) and decay candidates. The vector-similarity signal emits association proposals for embedded drawers within the cosine-distance threshold. The end-of-day tournament signal produces a TournamentReport for active branches.

Theorem 5 (paper §5, hardware-tier-aware scaling) holds in production. P99 capture latency under 100 milliseconds on iPhone (measured against a representative workload of domain-entity captures). Enrichment throughput at least 60 drawers per hour on Mac (measured by the enrichment daemon's actual throughput on representative hardware).

The daily-framing recipe (CognitionKit §3.1) runs end-to-end. Two to four framings declared at start of day. Tournament at end of day scoring on the five signals (averageReward 0.15, proposalAcceptanceRate 0.15, tunnelFormationRate 0.15, stateProgressionRate 0.40, recallPrecisionProxy 0.15). Winner surfaced for user confirmation. On confirmation, the winning branch is promoted; losing branches are discarded with their audit trails preserved. ScenarioProfile is saved if the user opted in.

When all of the above pass on representative hardware against actual application usage, v1.0 ships.

## 8. The Eleven-Step Sequence

The implementation sequence from current state to a v1.0 shippable against the consuming application is eleven steps. Each step has a bounded scope, an acceptance criterion, and a definition of done that includes test additions, conformance gate passage where applicable, and a decision record for any load-bearing choice that emerges during execution.

### Step 1: Promote GeniusLocusReference to SubstrateLib

Rename `GeniusLocusReference` to SubstrateLib. Add Sendable conformance hardening for Swift 6 strict concurrency. Stabilize the public API (no breaking changes once shipped). Add Swift Package manifest at the kit boundary. Remove reference-implementation-only test scaffolding from the public surface. No mathematical change.

Conformance gate: every Phase 2 conformance fixture passes against SubstrateLib with bit-identical output to the prior reference implementation.

Acceptance: SubstrateLib builds standalone on Apple Silicon and on Linux. The 19 commits from Phase 2 plus the kernel selection ledger are preserved in the kit's documentation.

### Step 2: Build PersistenceKit

Build the Core protocols (RowStore, BlobStore, VectorIndex, AuditLog, Storage). Build PersistenceKit-SQLite as the first backend (sqlite-vec for vectors, WAL mode, per-estate connection). Build PersistenceKit-PostgreSQL as the second backend (pgvector for vectors, libpq client, per-estate connection pool). Build PersistenceKit-InMemory as the test backend. Build the conformance fixture suite that exercises all three backends against the same operations and verifies identical results.

Acceptance: every fixture in the conformance suite produces identical results across all three backends. The schema declaration system handles the substrate's expected schemas (drawers, tunnels, KG facts, audit events, manifest, bitmap audit). Migration runs are reproducible.

Decision records produced: a likely Q21 decision on schema declaration DSL shape; a likely Q22 decision on PostgreSQL connection pool defaults; a likely Q23 decision on bitmap predicate compilation conventions across backends.

### Step 3: Build ConvergenceKit

Build the Core protocols (SyncEngine, SyncTransport). Build ConvergenceKit-CloudKit by porting the consuming application's existing CloudSync target into a kit-shaped package. Build ConvergenceKit-Federation per paper §9 (audit event exchange with G-Set union, hyperplane family handshake, tier-ascending query protocol, differential privacy at tier aggregation). Build ConvergenceKit-None as the no-sync passthrough.

Acceptance: ConvergenceKit-CloudKit's port preserves the application's existing sync behavior bit-for-bit (the application on the refactored kit can sync against an existing iCloud zone without data loss). ConvergenceKit-Federation's audit event exchange satisfies Theorem 1 (sync convergence) when tested against synthetic estates.

Decision records produced: a likely Q24 decision on whether to migrate the application's existing CloudSync to CKSyncEngine at this step or defer to a v1.x; a likely Q25 decision on the federation handshake's out-of-band step (QR code, pairing code, AirDrop).

### Step 4: Refactor EngramLib on SubstrateLib

Point EngramLib's math operations at SubstrateLib's primitives. Add the typed `Engram.project(from: AnyNoun)` wrapper. Remove EngramLib's local copies of SimHash construction.

Acceptance: EngramLib's existing tests pass against the refactored implementation with identical results. The Swift wrappers expose SubstrateLib's primitives through the typed Engram API.

### Step 5: Refactor LocusKit on SubstrateLib and PersistenceKit

Point LocusKit's bitmap operations (BitmapOps.swift) at SubstrateLib's primitives. Refactor LocusKit's storage to consume PersistenceKit instead of opening sqlite3 directly. Update BitmapEvaluator to compile to PersistenceKit Predicate trees instead of raw SQL. Preserve the Filter algebra surface and the 333 passing tests.

Acceptance: LocusKit's 333 tests pass against PersistenceKit-InMemory in CI and against PersistenceKit-SQLite for parity. The bitmap layout (adjective, operational, provenance) is preserved bit-for-bit. The audit-trail-is-substrate discipline is preserved (every bitmap mutation writes an audit row through PersistenceKit's AuditLog protocol).

### Step 6: Refactor VectorKit on EngramLib and PersistenceKit

Fix the three production blockers: replace `uuid_lite` with `uuid` crate; remove WordPiece tokenization (which moves to CorpusKit in step 7); replace sign-bit projection with EngramLib's SimHash-via-SubstrateLib projection. Refactor VectorKit's storage to consume PersistenceKit's VectorIndex protocol.

Acceptance: VectorKit's existing tests pass against the refactored implementation. The vector storage uses sqlite-vec via PersistenceKit-SQLite or pgvector via PersistenceKit-PostgreSQL transparently. The model and version tagging on every vector is preserved.

### Step 7: Refactor CorpusKit on VectorKit and PersistenceKit and ConvergenceKit

Move tokenization from VectorKit to CorpusKit. Add embedding providers for text (MiniLM, mpnet, EmbeddingGemma). Add chunkers with sentence-boundary detection via NaturalLanguage framework. Add RAG bundle storage (chunks plus vectors plus metadata) consuming PersistenceKit. Add ConvergenceKit consumption for content sync.

Acceptance: CorpusKit ships with three production embedding providers. Chunking handles the substrate's documented chunk sizes (target 800 chars, overlap 100). Content storage round-trips through PersistenceKit. ConvergenceKit-CloudKit syncs RAG bundles in a per-estate CloudKit zone alongside the substrate audit log.

### Step 8: Build GeniusLocusKit Composition and Brain Layer

Build GeniusLocusKit as the composition of LocusKit, CorpusKit, and the Brain layer. Implement the nine verbs (capture, recall, mutate, withdraw, expunge, reanchor, learn, propose, associate) over the composed substrate. Implement the Brain layer's six standing signals (dreaming, maintenance, vector-similarity, decay-sweep, byReference-validity, end-of-day-tournament). Implement the matrix tier (M times M-transpose, asymmetry profile, eigenvalue spectrum) per paper §7. Implement the audit log unification across LocusKit's and CorpusKit's storage.

Acceptance: the nine verbs operate over a composed substrate. The audit log is unified (one log per estate, capturing events from both LocusKit and CorpusKit). The six standing signals run on their configured schedules and emit proposals through the propose verb. The matrix tier updates incrementally on capture and rebuilds on demand. Theorem 5 holds against representative hardware (P99 capture under 100ms on iPhone, enrichment throughput at least 60 drawers per hour on Mac).

Decision records produced: a likely Q26 decision on standing signal scheduler implementation (single dispatch queue or per-signal queues); a likely Q27 decision on matrix tier persistence (in-memory only versus periodic snapshot to PersistenceKit).

### Step 9: Build NeuronKit

Build NeuronKit's autonomic functions inside the Brain layer (overlapping with step 8): dreaming daemon, maintenance daemon, standing-signals scheduler, SolverBandit, audit chain monitor. Build NeuronKit's reasoning functions as the algorithm layer: hybrid recall (BM25 plus vector plus RRF plus MMR), ContextSynthesizer, branch derivation, tournament scoring, scenario elicitation, ScenarioProfile persistence, benchmark, write policy enforcement.

Acceptance: every NeuronKit function specified in NEURONKIT_SPEC.md ships and passes its conformance tests. The two-source reward signal in the dreaming daemon (DiaryEntry rewards plus RecallTrace usage events) is operational. The SolverBandit's three v1.0 decisions (ef_search, dreaming trigger, compression tier) are tunable through the manifest.

### Step 10: Build CognitionKit

Build CognitionKit with the three v1.0 recipes: DailyFraming, MigrationBenchmark, ScenarioSkill. Each recipe implements the Recipe protocol per COGNITIONKIT_SPEC.md §2. Each recipe declares its required NeuronKit capabilities up front. Each recipe receives an EstateHandle parameter and operates against the passed estate.

Acceptance: DailyFraming runs end-to-end against a test estate (deriveBranch, runTournament, promoteBranch). MigrationBenchmark throws RecipeError.silentConceptLoss when any plan has lost concepts. ScenarioSkill surfaces a divergence warning when divergenceScore is below 0.3.

### Step 11: Wire the Consuming Application to the Kit Stack

Refactor the application's existing CloudSync target to consume ConvergenceKit-CloudKit's primitives (preserving the application's existing domain zone sync). Add the application's parallel GeniusLocus estate (separate SQLite file, separate CloudKit zone). Add the bridge from domain-entity operations to GeniusLocus captures. Add the application-journal-to-audit-log one-way bridge. Augment the application's leverage scoring with `recall_current_posture`. Configure the daily-framing recipe to run on the application's GeniusLocus estate.

Acceptance: all seven ship-gate criteria from §7.4 pass on representative hardware against actual application usage. v1.0 ships.

## 9. Decision Records This Reframe Produces

The reframe itself is one decision record (this document). Each step may produce additional decision records as load-bearing choices emerge. The expected decision records by step are listed in §8 above (Q21 through Q27, indicative numbering; actual numbering follows the project's existing Q-series convention).

This record explicitly does not pre-decide:

The schema declaration DSL shape for PersistenceKit (step 2). The shape will emerge from implementing against three real backends.

The PostgreSQL connection pool defaults (step 2). Empirical tuning during the step will produce the defaults.

The CKSyncEngine migration timing (step 3). The decision is between "port the existing pattern now and migrate later" and "rebuild on CKSyncEngine now." The step will surface the tradeoffs concretely.

The federation handshake's out-of-band step (step 3). Several plausible mechanisms exist (QR code, manual pairing code, AirDrop, OS-mediated). The step will pick one.

The standing signal scheduler's implementation pattern (step 8). Single dispatch queue versus per-signal queues is a real tradeoff that the step will resolve.

The matrix tier persistence strategy (step 8). In-memory only versus periodic snapshot is also a real tradeoff.

These are not deferrals in the v2-deferral sense. They are concrete implementation decisions that need to be made during execution, with the decision being recorded against the relevant step.

## 10. Open Questions Tracked Forward

The open questions that remain genuinely open after this reframe are:

Q2 (multi-rung schema). Wide row versus skinny rows. The reframe does not resolve this; it is an internal LocusKit decision that depends on benchmark results in step 5.

Q2.5 (provenance schema specifics). Estate-level defaults, mutability rules per axis, audit retention, retrieval-layer filter semantics. Internal to LocusKit; step 5 resolves.

Q5 (federation conflict resolution specifics). Per case study 1 and case study 3, the substrate-native federation is conflict-free by G-Set CRDT. The remaining questions are about application-specific data in a consuming application's existing sync layer. Step 3 and step 11 resolve.

Q6 (upper ontology starter set). The 12-20 concept types with UDC and Wikidata anchors. Internal to LocusKit; step 5 resolves.

Q7 (frameworks shipped in v1). The reframe commits to one framework profile (personal life management for the consuming application) in v1.0 with specifications for the other two profiles written into the spec. Step 11 resolves the application-specific framework.

Q8 (publication target and timing). External strategic decision. Independent of this reframe.

Q9 (federation in v1 surface). The reframe commits to surfaced federation in v1.0 via ConvergenceKit-Federation. Resolved.

Q10 (compression mode defaults). Resolved by paper §3 and the algebra notebook. Internal to step 8 implementation.

Q20 (bitmap test fixtures). Internal to step 5. Resolved by extending the existing test fixture suite.

Q21 (epistemic fingerprint index). Internal to step 8. The Hamming-distance range query is a dreaming-daemon pre-filter; implementation choice during the step.

Q26 (non-contiguous filter compilation). Affects PersistenceKit's predicate compilation (step 2) and BitmapEvaluator (step 5). Resolved by the step 2 schema declaration DSL.

Q31 (field width growth beyond 4 bits). Constitutional-adjacent. The reframe does not change the field widths; if any field needs to grow beyond 4 bits in production, that triggers a separate decision record at that time.

Q32 (hardware path for binary matrix multiply). Internal to SubstrateLib; resolved by the existing Phase 2 kernel selection work.

Q33 (eigenvalue spectrum caching strategy). Internal to step 8.

Q34 (minimum estate size for useful tiny-model training). Per-estate concern. The reframe does not address it; step 8 and beyond may surface it.

## 11. Migration Path

This reframe does not break any existing committed work. The completed Phase 1 through Phase 4 build work is preserved as the foundation that the new steps build on.

Specifically, LocusKit's current state (333 passing tests, 27 source files, the three-bitmap discipline, the Filter algebra, the BitmapEvaluator, the manifest table with 18 required keys, the audit-trail-is-substrate enforcement) is the starting point for step 5. The refactor does not throw away this work; it routes the storage layer through PersistenceKit and points the math at SubstrateLib while preserving the kit's public API and its tests.

EngramLib's current state (typed math API, projection stub) is the starting point for step 4. The refactor points at SubstrateLib and adds the typed projection wrapper.

VectorKit's current state (three production blockers documented, sqlite-vec backend, MiniLM provider with WordPiece stand-in) is the starting point for step 6. The refactor fixes the blockers and consumes PersistenceKit.

CorpusKit's current state (skeleton spec, not yet built) is the starting point for step 7. The step builds it per the existing spec with the additional responsibility of absorbing tokenization from VectorKit.

GeniusLocusKit's current state (legacy code to be harvested for patterns and then archived) is the starting point for step 8. The new GeniusLocusKit is net-new construction, not refactor; the legacy code is harvested for its actor-mode-composition pattern and then archived.

The consuming application's current state (its existing kit, 14 targets including Persistence and CloudSync, schema v16, working iCloud sync) is the starting point for step 11. The integration adds the parallel GeniusLocus estate alongside the existing infrastructure without disturbing the application's product.

## 12. Verification

This reframe is correctly landed when the following are true:

The spec corpus reflects the eleven-kit graph. GENIUSLOCUS_ARCHITECTURE_SPEC.md §15.1 (Kit composition) is updated to point at this decision record. A new section in the spec describes PersistenceKit and ConvergenceKit at the architectural level. The build sequence is described by §8 of this record.

The implementation lands step by step. Each of the eleven steps in §8 has a written, dispatchable specification. Each step's acceptance criteria pass before the next step starts. Each step's decision records are filed against the relevant Q-number. Each step's conformance gate is enforced.

When all eleven steps land and the consuming application's seven ship-gate criteria in §7.4 pass, v1.0 ships.

## 13. Acknowledgments

This reframe emerged from a scope-and-draft review covering the full GeniusLocus spec corpus, reading approximately 30 documents (canon papers, specs, decisions, build-sequence plans, engineering substrate reference) before formulating the reframe. The governing principles drove the architecture: no v2 deferrals, design for ten years, preserve seams against future composition patterns, a consuming application on the critical path as the ship gate that proves the thesis.

The consuming-application precedent (SQLite source of truth, CloudKit overlay) was load-bearing in establishing the storage-sync orthogonality. The substrate's existing mathematical specification (paper §6 G-Set CRDT, paper §9 federation algebra, paper §3.4 substrate-interface contract) anticipated the kit boundary the reframe makes explicit. The reframe is more articulation than invention.
