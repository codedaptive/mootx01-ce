---
title: Kit Interface Specification
status: canon
authors: Bob Pankratz (via/ claude)
date: 2026-05-26
version: 1.0
---

# Kit Interface Specification

**Purpose:** Authoritative public interface for each Kit derived from canonical specifications, architectural decisions, and completed mission deliverables.

**Use this to:**
- Verify that a Kit's public API matches its spec
- Detect when functions are in the wrong Kit
- Audit cross-Kit dependencies
- Understand which Kit owns which concern

**Source of truth hierarchy:**
1. `docs/concepts/TOPOLOGY.md` and `docs/concepts/MOOTX01_AND_ARIA_CANON.md` — Kit role and composition
2. `docs/decisions/DECISION_*.md` — Architectural decisions that shaped interfaces
3. `docs/_internal/missions/MISSION_*.md` — Completed mission deliverables with defined done
4. Source code public interfaces — actual implementation

---

## Foundation Layer (Missions 1–4)

All foundation kits are **built, green, and review-pending**.

### AriaLexiconLib (Zero Dependencies)

**Canonical Role:** Reified ARIA grammar as a zero-dependency module. The single source of truth for the grammar contract: every call is one verb applied to a noun, optionally constrained by adjectives.

**Spec:** ARIA_LEXICON.md + TOPOLOGY.md § The grammar is reified in `AriaLexiconLib`

**Invariants (design-time, spec I-7 and I-8):**
- One noun: the drawer
- Nine verbs: fixed count
- Four adjective categories: fixed count
- Acceptance matrix: fixed design-time semantics of which verbs each noun accepts

**Public Interface:**
- `AriaLexiconLib` enum
  - `grammar: String` (statement of the contract)

**Dependencies:** None

**Completion:** ✅ Mission 1 (promoted from GeniusLocusReference)

---

### SubstrateLib (Zero Dependencies)

**Canonical Role:** Math primitives, kernel dispatch, audit CRDT.

**Atomic-centralization rule (cookbook I-25):** Every substrate atomic
— bitfield extract/write, mask, shift, AND / OR / XOR, popcount,
Hamming distance, fold / reduce, the SHA-256 content hash, and the
Hybrid Logical Clock — lives here and is consumed by name. No kit
reimplements the math, not one line. This is M1 in its full strength:
SubstrateLib *executes* the math, it does not merely specify it. It is
also the basis of the portability contract — SubstrateLib is the one
hard port, and once its conformance corpus passes on a new platform
every kit works there without per-kit re-verification. Reference
primitives: `BitField`, `SHA256`, `HLC`, plus the distance and
aggregation families listed below.

**Spec:** docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md + engineering cookbook

**Architectural decisions:**
- DECISION_HAMMING_BACKENDS_2026-05-17.md
- DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17.md
- DECISION_SIMHASH_BACKENDS_2026-05-18.md
- DECISION_OR_REDUCE_BACKENDS_2026-05-17.md

**Core Types:**
- `Fingerprint256` — 256-bit typed vector (four 64-bit blocks)
- `HLC` — Hybrid Logical Clock
- `GSetAuditLog` — Append-only CRDT
- `MomentSummary` — Temporal statistics
- `BitmapEvaluator` — Sparse bitmap operations

**Public Functions (distance family):**
- `hammingDistance256(Fingerprint256, Fingerprint256) -> Int`
- `hammingDistanceBatch(probe: Fingerprint256, candidates: [Fingerprint256]) -> [Int]`
- `hammingTopK(probe: Fingerprint256, candidates: [Fingerprint256], k: Int) -> [TopKResult]`

**Public Functions (aggregation):**
- `orReduce256([Fingerprint256]) -> Fingerprint256`
- `bitwiseOR(Fingerprint256, Fingerprint256) -> Fingerprint256`

**Kernel Protocol:**
- `SubstrateKernel` — Interface for backend kernels
- `PortableKernel` — Dispatcher (SIMD, Metal, NEON, BNNS)

**Dependencies:** None

**Completion:** ✅ Mission 1

---

### PersistenceKit (SubstrateLib)

**Canonical Role:** Storage abstraction layer. Backend-agnostic interface for row stores, blob stores, vector indices, audit logs, and observers.

**Spec:** docs/decisions/DECISION_STORAGEKIT_DESIGN_2026-05-19.md

**Core Protocol:**
- `Storage` — Backend-agnostic interface
  - `open(schema: SchemaDeclaration) async throws`
  - `close() async`
  - `transaction<T>(isolation: IsolationLevel, _ block: @Sendable (...) -> T) async throws -> T`
  - `currentSchemaVersion() async throws -> Int`
  - `migrate(to: SchemaDeclaration) async throws`

**Sub-stores:**
- `RowStore` — Row operations
- `BlobStore` — Opaque byte blobs
- `VectorIndex` — Vector operations and ANN
- `AuditLog` — Append-only fact log
- `StorageObserver` — Change notifications

**Supporting Types:**
- `EstateConfiguration`
- `SchemaDeclaration`
- `IsolationLevel` enum
- `StorageTransaction`
- `StorageError`

**Concrete Backends:**
- `PersistenceKitSQLite` (zero external deps except sqlite-vec)
- `PersistenceKitPostgreSQL`
- `PersistenceKitInMemory` (tests)

**Dependencies:** SubstrateLib

**Completion:** ✅ Mission 2

---

### QueueKit (SubstrateLib)

**Canonical Role:** Fill-and-drain job queue with serial dispatch, maildir-style file structure, and database persistence.

**Spec:** QUEUEKIT_SPEC § 3 (four permanent method names), § 5 (maildir), § 6 (claim semantics)

**Core Types:**
- `Job` — Task record with ID, status, artifacts, claim metadata
- `JobID` — Unique identifier
- `SessionID` — Claim grouping for serial dispatch
- `ObservationStatus` enum
- `ArtifactRef` — Result reference
- `QueueError` — Failure enumeration

**Four Public Methods (spec § 3):**
- `send(_ job: Job) async throws`
- `drain() async throws -> [(job: Job, sessionID: SessionID)]`
- `watch(handler: @escaping @Sendable (Job, SessionID) async throws -> Void) async throws`
- `reply(to: JobID, status:, artifacts:) async throws`

**Additional Methods:**
- `inFlight() async throws -> [Job]`
- `completed(streamID:) async throws -> [Job]`

**Constructors:**
- `init(root: URL, hlcGenerator: HLCGenerator) throws` — Filesystem backend
- `init(backend: any QueueBackend, root: URL?)` — Explicit backend

**Maildir Mechanics (spec § 5):**
- `ensureMaildir(root: URL) throws`
- `cleanStaleTmpFiles(root: URL) throws`
- `staleTmpThreshold: TimeInterval` (5 minutes)

**Backend Protocol:**
- `QueueBackend` — Abstract interface
- `FilesystemBackend`, `PersistenceKitBackend` — Concrete

**Dependencies:** SubstrateLib

**Completion:** ✅ Mission 4 (relocated from Forge)

---

### ConvergenceKit (SubstrateLib, PersistenceKit)

**Canonical Role:** Sync abstraction layer. Backend-agnostic interface for pushing, pulling, and subscribing to changes.

**Spec:** docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md

**Core Protocol:**
- `SyncEngine` — Backend-agnostic sync
  - `enable(manifest: SyncManifest, storage: Storage) async throws`
  - `disable() async throws`
  - `push() async throws -> SyncReceipt`
  - `pull() async throws -> SyncReceipt`
  - `subscribe() -> AsyncStream<SyncEvent>`
  - `state: SyncState { get async }`

**Supporting Types:**
- `SyncManifest` — Metadata for sync boundary
- `SyncRecord` — Change record
- `SyncReceipt` — Summary of push/pull
- `SyncEvent` — Live activity
- `SyncState` — Current state enum

**Concrete Backends:**
- `ConvergenceKitCloudKit`
- `ConvergenceKitFederation`
- `ConvergenceKitNone` (offline-only)

**Dependencies:** SubstrateLib, PersistenceKit

**Completion:** ✅ Mission 3

---

### EngramLib (SubstrateLib)

**Canonical Role:** Typed 256-bit Engram API for similarity, nearest-neighbor retrieval, and aggregation.

**Spec:** Substrate architecture spec

**Core Type:**
- `Engram` — Typealias for `Fingerprint256`
  - `init(blocks b0: UInt64, _ b1: UInt64, _ b2: UInt64, _ b3: UInt64)`

**Public Functions (distance):**
- `distance(_ a: Engram, _ b: Engram) -> Int`
- `distances(probe: Engram, candidates: [Engram]) -> [Int]`

**Public Functions (nearest neighbor):**
- `findNearest(probe: Engram, in: [Engram], k: Int) -> [Match]`
- `findNearest(probe: Engram, in: [Engram]) -> Match?` (convenience)

**Public Functions (filtering):**
- `findWithin(probe: Engram, in: [Engram], maxDistance: Int) -> [Match]`

**Public Functions (aggregation):**
- `union(_ engrams: [Engram]) -> Engram`
- `union(_ a: Engram, _ b: Engram) -> Engram`

**Session API (kernel reuse):**
- `Session` struct
  - Same methods as static API

**Supporting Type:**
- `Match` — Index + distance pair

**Dependencies:** SubstrateLib

**Completion:** ✅ Mission 4

---

## Grounding Layer (Standalone, Parallel to Substrate)

### LatticeKit (Zero Dependencies)

**Canonical Role:** Moot Decimal Classification Codes — notation spine, canon from Wikidata CC0, lookup surface.

**Spec:** TOPOLOGY.md § MDCC, the classification spine

**Core Types:**
- `LatticeCanon` — In-memory parsed canon
- `LatticeSchemeManifest` — Scheme metadata
- `LatticeCodeGrammar` — MDCC code validator
- `ClassificationScheme` enum

**Public Functions:**
- `LatticeKit.bundledCanon() -> LatticeCanon?`
- `LatticeKit.canonVersion: String`
- `LatticeKit.classifyLatticeCode(_ code: String, knownCodes: Set<String>) -> LatticeCodeState`
- `LatticeCodeGrammar.isWellFormed(_ code: String) -> Bool`

**Code States:**
- `LatticeCodeState` enum — .malformed, .known, .pending

**Dependencies:** None

**Completion:** ✅ Mission MDCC-01 onward

---

### EideticLib (LatticeKit)

**Canonical Role:** Deterministic text-to-anchor lookup. Tokenize → normalize → stem → gazetteer → classify → resolve.

**Spec:** TOPOLOGY.md § Grounding, MOOTX01_AND_ARIA_CANON.md

**Core Type:**
- `Anchor` — Result of lookup
  - `mdccCode: String`
  - `wikidataQID: String?`
  - `confidence: UInt8`
  - `dataVersion: String`

**Public Functions:**
- `EideticLib.lookup(_ term: String) -> Anchor`
- `EideticLib.classifyLatticeCode(_ code: String, knownCodes: Set<String>) -> LatticeCodeState`
- `EideticLib.defaultSchemeManifest() -> LatticeSchemeManifest?`
- `EideticLib.defaultScheme: ClassificationScheme`

**Foreign Scheme Support:**
- `activationConsent: ActivationConsent` — Opt-in gate for foreign data

**Public Constants:**
- `version: String`

**Internals (cached, not exposed):**
- Bundled MDCC canon (CC0)
- Bundled Wikidata subset (CC0)
- Tokenizer, Normalizer, Stemmer

**Dependencies:** LatticeKit

**Completion:** ✅ Mission MDCC-03 onward

---

## Main Substrate Layer (Missions 5–8)

### LocusKit (SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit)

**Canonical Role:** Spatial memory system with knowledge graph. One estate per instance.

**Spec:** docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md

**Decisions:**
- DECISION_LOCUSKIT_BUNDLE_HIERARCHY_2026-05-20.md
- DECISION_PROVISIONAL_DRAWER_LIFECYCLE_2026-05-24.md

**Core Types (spatial primitives):**
- `Drawer` — Verbatim content + metadata
- `DrawerID` — Unique identifier
- `Wing` — Taxonomy parent
- `Room` — Taxonomy child
- `Tunnel` — Typed cross-reference
- `TunnelType` — Link semantics
- `KGFact` — Knowledge graph triple
- `DiaryEntry` — Temporal log entry
- `Filter` — Content predicate

**Estate Actor:**
- `Estate` — Main orchestrator (actor for serialization)
  - Injected storage: `any Storage`
  - Manifest: `Manifest`
  - Schema: `LocusKitSchema`

**Estate Verbs (EstateVerbs extension):**
- `fileClaim(_ drawer: Drawer, in: DrawerID?) -> DrawerID`
- `reclaim(_ id: DrawerID) -> Drawer?`
- `forget(_ id: DrawerID) async`
- `recall(_ frame: RecallFrame) -> RecallStream`
- `witness(_ entry: DiaryEntry) async`
- `tunnel(_ from: DrawerID, _ to: DrawerID, type: TunnelType) async`
- ... (nine verbs total, ARIA-compliant)

**Query Types:**
- `RecallFrame` — Spatial query boundary
- `RecallStream` — Result iterator
- `RecallTraceItem` — Audit entry

**Audit:**
- `EstateAudit` — Audit trail interface
- `auditTrail(since: Date?, until: Date?) async throws -> [AuditEntry]`

**Error Type:**
- `LocusKitError` — Enumeration

**Dependencies:** SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit, EideticLib

**Completion:** ✅ Mission 5

---

### VectorKit (SubstrateLib, EngramLib, PersistenceKit)

**Canonical Role:** On-device embeddings and nearest-neighbor search. Model-tagged vectors.

**Spec:** Substrate architecture spec

**Core Protocols:**
- `EmbeddingProvider` — Embedding model abstraction
  - `embed(_ text: String) -> Vector?`

**Core Types:**
- `EmbeddingModel` — Model metadata
- `Vector` — Typed vector with model tag
- `EmbeddingResult` — Embedding result
- `VectorIndex` — Queryable ANN (HNSW-style)

**Public Functions:**
- `VectorKit.embed(_ text: String, using: EmbeddingProvider) -> EmbeddingResult?`
- `VectorKit.findNearest(query: Vector, in: [Vector], k: Int) -> [Match]`
- `VectorKit.index(_ vectors: [Vector]) -> VectorIndex`

**Concrete Providers (CorpusKitProviders target):**
- `MiniLM`
- `EmbeddingGemma`
- `mpnet`

**Key Invariant (spec I-12):**
- Every vector tagged with model ID and version
- Cross-model comparisons forbidden

**Dependencies:** SubstrateLib, EngramLib, PersistenceKit

**Completion:** ✅ Mission 6

---

### CorpusKit (VectorKit, PersistenceKit, ConvergenceKit, EngramLib)

**Canonical Role:** Content-plus-vector RAG bundles with hybrid BM25 + vector retrieval.

**Spec:** TOPOLOGY.md § Standalone substrate

**Core Types:**
- `RAGBundle` — Content + vectors + metadata
- `BM25Index` — Inverted text index
- `ChunkingStrategy` — Document segmentation
- `SyncManifest` — Replication metadata

**Public Functions:**
- `CorpusKit.addDocument(_ content: String, to: RAGBundle) async throws`
- `CorpusKit.queryBM25(_ term: String, in: RAGBundle) -> [Result]`
- `CorpusKit.queryVector(_ embedding: Vector, in: RAGBundle, k: Int) -> [Result]`
- `CorpusKit.queryHybrid(_ term: String, embedding: Vector, in: RAGBundle) -> [Result]`

**Chunker:**
- `Chunker` — Splits content into semantic units

**Tokenization:**
- `TokenizerProtocol` — Text tokenization (lives here, not VectorKit)

**Targets:**
- `CorpusKit` — Core: tokenizer, chunker, BM25, storage, sync
- `CorpusKitProviders` — Providers with CoreML models (MiniLM, mpnet, Gemma)

**Key Design (Mission 7):**
- Tokenization in CorpusKit, not VectorKit
- Providers (with weights) in CorpusKitProviders to keep weights out of core
- Hybrid retrieval fuses BM25 + vector signals

**Dependencies:** VectorKit, PersistenceKit, ConvergenceKit, EngramLib

**Completion:** ✅ Mission 7

---

### GeniusLocusKit (LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit)

**Canonical Role:** Composition layer. Unifies LocusKit and CorpusKit into one estate, runs Brain layer, coordinates persistence.

**Spec:** TOPOLOGY.md § Composition, MOOTX01_AND_ARIA_CANON.md § Instance mode

**Missions:**
- MISSION_GLK_01_COMPOSITION_SCAFFOLD.md ✅
- MISSION_GLK_02_VERB_SURFACE.md ✅
- MISSION_GLK_03_UNIFIED_AUDIT_LOG.md ✅
- MISSION_GLK_04_STANDING_SIGNALS_SCHEDULER.md ✅
- MISSION_GLK_05_SIX_STANDING_SIGNALS.md ✅
- MISSION_GLK_06_MATRIX_TIER.md ✅
- MISSION_GLK_07_TRAINING_DAEMON.md ✅
- MISSION_GLK_08_THEOREMS_PERF_GATE.md ✅

**Main Actor:**
- `GeniusLocusKit` — Serialized coordinator (actor model)

**Lifecycle:**
- `open(storage: Storage, owner: String) -> EstateHandle`
- `close(_ handle: EstateHandle) async`
- `handles: [EstateHandle]`
- `openEstateCount: Int`
- `estate(for: EstateHandle) async throws -> LocusKit.Estate`

**Per-Handle Registry:**
- `registry: [EstateHandle: LocusKit.Estate]` (internal)
- `storages: [EstateHandle: any Storage]` (internal)

**Unified Audit Log (GLK-03):**
- `auditLog(for: EstateHandle) async throws -> UnifiedAuditLog`
- `feedAuditLog(for: EstateHandle) async throws`
- `verifyAuditChain` (async)

**Fan-out Queries:**
- `fanOutRecall(_ frame: RecallFrame, region: SpatialRegion) async throws -> AggregatedResults`

**COW Branching:**
- `glkDeriveBranch(from: EstateHandle) -> BranchHandle`
- `glkPromoteBranch(_ branch: BranchHandle) async throws -> PromotionResult`
- `glkMergeDrawers(from: BranchHandle, to: EstateHandle) async throws`
- `branches: [BranchID: EstateBranch]` (internal, retained through all lifecycle states)

**Standing Signals (Brain layer, GLK-04+):**
- `schedulers: [EstateHandle: StandingSignalScheduler]` (internal)
- `registerStandingSignal(...) async`
- `triggerSignal(for: EstateHandle) async`

**Scope & Grants (access control, GRT-01):**
- `grantStores: [EstateHandle: GrantStore]` (internal)
- `scopeVaults: [EstateHandle: ScopeKeyVault]` (internal)

**Dependencies:** LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit, EideticLib

**Completion:** ✅ Mission 8 (all sub-missions done as of 2026-05-22)

---

## Reasoning & Behaviour Layer

### NeuronKit (EideticLib, SubstrateLib, EngramLib)

**Canonical Role:** AI algorithms — reasoning functions and autonomic daemons.

**Spec:** TOPOLOGY.md § Behaviour, MOOTX01_AND_ARIA_CANON.md

**Missions:**
- MISSION_NK_1A_REASONING_SURFACE.md ✅
- MISSION_NK_DREAM_DAEMON.md ✅
- MISSION_NK_BR_01_BRANCH_BENCHMARK.md ✅
- MISSION_NK_MIG_01_ESTATE_MIGRATION_API.md (in progress)

**Reasoning Surface:**
- `NeuronKit.inferLatticeAnchor(_ content: String) -> LatticeAnchorInference`

**Supporting Type:**
- `LatticeAnchorInference`

**Autonomic Daemons (§ 3.1):**
- `NeuronKit.dreamingDaemon(reader:, sink:, policyStore:, rewardSource:, triggerMode:) -> DreamingDaemon`
- `DreamingDaemon.registerDreamingPolicy(...) async`
- `DreamingDaemon.triggerDreamingCycle(now:) async`

**Daemon Seams (B-1):**
- `DreamingSubstrateReader` — Read seam
- `DreamingProposalSink` — Write seam
- `DreamingPolicyStore` — Policy persistence
- `RewardSource` protocol
- `DreamingTriggerMode`

**Branch Operations (§ 4.3, thin forwards over GeniusLocusKit):**
- `deriveBranch(from: EstateHandle) -> BranchHandle`
- `promoteBranch(_ branch: BranchHandle) async throws -> PromotionResult`
- `mergeDrawers(from: BranchHandle, to: EstateHandle) async throws`

**Migration Benchmark (§ 4.7):**
- `benchmark(branch: BranchHandle, against: ExternalCorpus, queries: [Query], now: Date) async throws -> BenchmarkReport`
- `BenchmarkReport` (includes `notFoundInBranch` zero-tolerance signal)
- `ExternalCorpus` / `ExternalEntry`

**Linguistic Pipeline:**
- `LinguisticPipelineMode` enum (.deterministicReference, .appleNLAccel)
- `NeuronKit.linguisticPipelineMode: LinguisticPipelineMode`

**Public Constants:**
- `version: String` ("0.1.0")

**Dependencies:** EideticLib, SubstrateLib, EngramLib, GeniusLocusKit

**Completion:** 🔧 Mission 9 (reasoning + dreaming done; branch ops + migration API in progress)

---

### CognitionKit (NeuronKit, GeniusLocusKit)

**Canonical Role:** Behaviour BrainKit. Named, composable workflows and recipes.

**Spec:** TOPOLOGY.md § Behaviour, MOOTX01_AND_ARIA_CANON.md

**Expected Interface (not yet built):**
- `Workflow` protocol
- `WorkflowStep`
- `FulcrumDailyFraming` (workflow)
- `ScenarioSkill` (workflow)
- `WorkflowScheduler`

**Dependencies:** NeuronKit, GeniusLocusKit

**Completion:** 🔲 Mission 10 (planned, after NeuronKit complete)

---

## Access Layer

### ARIA_MCP (GeniusLocusKit + NeuronKit)

**Canonical Role:** MCP server exposing any MOOTx01 estate to Claude, Claude Code, OB1, and other MCP clients.

**Spec:** MOOTX01_AND_ARIA_CANON.md § Consumption surfaces, ARIA.md, ARIA_LEXICON.md

**Mission:** LAUNCH-04 (pending NeuronKit completion)

**Expected Resources (MCP model):**
- `mootx01://estate/{estateHandle}/*` (browsable)

**Expected Tools (MCP model):**
- `estate/file` (create/update drawer)
- `estate/reclaim` (retrieve)
- `estate/recall` (spatial query)
- `estate/witness` (log event)
- `estate/tunnel` (cross-reference)
- ... (nine tools, one per ARIA verb)

**Subscriptions (live notifications):**
- Estate changes as real-time events

**Completion:** 🔧 LAUNCH-04 (in progress)

---

### ARIA_MacOS (GeniusLocusKit)

**Canonical Role:** macOS demonstration app showing sidecar pattern and SDK usage.

**Spec:** MOOTX01_AND_ARIA_CANON.md § Demonstration apps

**Purpose:** Worked example for developers; teaches sidecar integration and basic SDK usage.

**Completion:** 🔲 Planned after ARIA_MCP

---

### ARIA_iOS (GeniusLocusKit)

**Canonical Role:** iOS demonstration app (Rev 3.0).

**Completion:** 🔲 Planned after ARIA_MacOS

---

### ARIA_Rust (GeniusLocusKit Rust port)

**Canonical Role:** Rust demonstration app. **Required** for conformance parity between Swift and Rust ports.

**Spec:** MOOTX01_AND_ARIA_CANON.md § Demonstration apps (required, not optional)

**Completion:** 🔲 Planned after ARIA_MacOS

---

## Special Kits

### Installer

**Role:** First-run, system integration, app updater.

**Mission:** LAUNCH-01

**Completion:** 🔲 Planned

---

### Sidecar_Demo_macOS

**Role:** Prototype demonstration of sidecar pattern.

**Completion:** ✅ (proto, not shipped)

---

### tools/

**Role:** Build utilities, test harness, reference implementations. Not shipped.

---

## Summary by Role

| Role | Kits |
|------|------|
| **Grammar** | AriaLexiconLib |
| **Foundation** | SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit, EngramLib |
| **Grounding** | LatticeKit, EideticLib |
| **Substrate** | LocusKit, VectorKit, CorpusKit |
| **Composition** | GeniusLocusKit |
| **Reasoning** | NeuronKit (in progress) |
| **Behaviour** | CognitionKit (planned) |
| **Access** | ARIA_MCP (in progress), ARIA_MacOS (planned), ARIA_iOS (planned), ARIA_Rust (planned) |

---

## Cross-Kit Dependency Graph

```
AriaLexiconLib          (zero deps)
SubstrateLib         (zero deps)
  ├── PersistenceKit     (SubstrateLib)
  ├── ConvergenceKit        (SubstrateLib, PersistenceKit)
  ├── QueueKit       (SubstrateLib)
  └── EngramLib      (SubstrateLib)
LatticeKit              (zero deps)
  └── EideticLib      (LatticeKit)
LocusKit             (SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
VectorKit            (SubstrateLib, EngramLib, PersistenceKit)
  └── CorpusKit         (VectorKit, PersistenceKit, ConvergenceKit, EngramLib)
GeniusLocusKit       (LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
NeuronKit            (EideticLib, SubstrateLib, EngramLib, GeniusLocusKit)
CognitionKit         (NeuronKit, GeniusLocusKit)
ARIA_MCP             (GeniusLocusKit, NeuronKit)
ARIA_MacOS           (GeniusLocusKit)
ARIA_iOS             (GeniusLocusKit)
ARIA_Rust            (GeniusLocusKit Rust port)
```

---

## Completion Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Built, green tests, review pending |
| 🔧 | In progress (active mission stream) |
| 🔲 | Planned (gating dependency shown) |

---

## Interface Audit Checklist

When reviewing for placement and shape correctness:

**AriaLexiconLib:**
- [ ] Only grammar statements and invariants
- [ ] Zero dependencies
- [ ] Acceptance matrix correct

**SubstrateLib:**
- [ ] All public items are math primitives or kernel dispatch
- [ ] No storage, persistence, or application semantics
- [ ] Kernel protocol correct

**PersistenceKit:**
- [ ] All public items are storage protocol, schema, or transactions
- [ ] RowStore/BlobStore/VectorIndex abstractions correct
- [ ] Backend pluggability working

**QueueKit:**
- [ ] Four public methods correct (send, drain, watch, reply per spec § 3)
- [ ] Maildir directory structure correct
- [ ] Job lifecycle and session semantics correct

**ConvergenceKit:**
- [ ] Backend abstraction pattern correct (mirrors PersistenceKit)
- [ ] Manifest defines sync boundary
- [ ] Push/pull/subscribe semantics correct

**EngramLib:**
- [ ] Engram type opaque to callers (no access to blocks outside init)
- [ ] All operations Hamming-distance-based
- [ ] Session API for kernel reuse correct

**LatticeKit:**
- [ ] Only MDCC-specific concerns
- [ ] No network, no foreign schemes in core
- [ ] Canon version pinned and frozen

**EideticLib:**
- [ ] Stateless from caller view, caches internally
- [ ] Pipeline correct (tokenize → normalize → stem → resolve)
- [ ] Foreign scheme activation consent gate correct

**LocusKit:**
- [ ] Nine verbs ARIA-compliant
- [ ] Spatial primitives correct
- [ ] Estate actor serialization correct
- [ ] Audit trail complete and immutable

**VectorKit:**
- [ ] Every vector tagged with model ID and version
- [ ] Cross-model comparisons forbidden
- [ ] EmbeddingProvider protocol correct

**CorpusKit:**
- [ ] Tokenization lives here, not VectorKit
- [ ] Hybrid BM25 + vector retrieval
- [ ] Bundle is unit of sync and persistence

**GeniusLocusKit:**
- [ ] Multi-estate coordinator correct
- [ ] Per-estate state isolated
- [ ] Unified audit log merges from all estates
- [ ] Fan-out queries route to overlapping estates
- [ ] COW branches retained through all lifecycle states
- [ ] Standing-signal scheduler per-estate, serial lane
- [ ] Persistence through QueueKit over PersistenceKit

**NeuronKit:**
- [ ] Reasoning surface thin wrapper over EideticLib
- [ ] Dreaming daemon seams (B-1) correct
- [ ] Branch ops thin forwards (no state stored locally)
- [ ] Benchmark read-only

---

**Last Updated:** 2026-05-26  
**Canonical Source:** docs/concepts/TOPOLOGY.md, docs/concepts/MOOTX01_AND_ARIA_CANON.md  
**Mission Status Source:** docs/_internal/missions/  
**Decisions Source:** docs/decisions/  
**Code Source:** Actual public interfaces
