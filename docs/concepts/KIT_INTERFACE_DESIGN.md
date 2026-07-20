---
title: Kit Interface Design
status: canon
authors: MOOTx01 maintainers
date: 2026-06-14
version: 1.0.0
description: The cross-kit rollup of how each kit's public interface composes into the MOOTx01 substrate, grounding, composition, reasoning, and access layers.
---

# Kit Interface Design

**Purpose:** Rollup of how each Kit's public interface composes with the others,
derived from current source, canonical specifications, and the engineering
masters.

**Use this to:**
- Verify that a Kit's public API matches its spec
- Detect when functions are in the wrong Kit
- Audit cross-Kit dependencies
- Understand which Kit owns which concern

**Source of truth hierarchy:**
1. Source and conformance tests — shipped implementation
2. `docs/reference/` — current package specifications and interfaces
3. `docs/engineering/` — cross-cutting invariants and ownership
4. `docs/concepts/TOPOLOGY.md` and `docs/concepts/MOOTX01_AND_ARIA_CANON.md` — explanatory role and composition

---

## Foundation Layer

### AriaLexiconLib (Zero Dependencies)

**Canonical Role:** Reified ARIA grammar as a zero-dependency module. The single source of truth for the grammar contract: every call is one verb applied to a noun, optionally constrained by adjectives.

**Spec:** ARIA_LEXICON.md + TOPOLOGY.md § The grammar is reified in `AriaLexiconLib`

**Invariants (design-time, per ARIA_LEXICON.md and the architecture spec):**
- One noun: the drawer
- Nine verbs: fixed count
- Four adjective categories: fixed count
- Acceptance matrix: fixed design-time semantics of which verbs each noun accepts

**Public Interface:**
- `AriaLexiconLib` enum
  - `grammar: String` (statement of the contract)

**Dependencies:** None

---

### SubstrateLib (Zero Dependencies)

**Canonical Role:** Math primitives, kernel dispatch, audit CRDT.

**Atomic-centralization rule (the substrate engineering cookbook):** Every substrate atomic
— bitfield extract/write, mask, shift, AND / OR / XOR, popcount,
Hamming distance, fold / reduce, the SHA-256 content hash, and the
Hybrid Logical Clock — lives here and is consumed by name. No kit
reimplements the math, not one line. SubstrateLib *executes* the math,
it does not merely specify it. It is
also the basis of the portability contract — SubstrateLib is the one
hard port, and once its conformance corpus passes on a new platform
every kit works there without per-kit re-verification. Reference
primitives: `BitField`, `SHA256`, `HLC`, plus the distance and
aggregation families listed below.

**Spec:** docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md + engineering cookbook

**Architectural decisions:**
- the measured Hamming selection
- the kernel-dispatch design
- the measured SimHash selection
- the measured OR-reduce selection

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

---

### PersistenceKit (SubstrateLib)

**Canonical Role:** Storage abstraction layer. Backend-agnostic interface for row stores, blob stores, vector indices, audit logs, and observers.

**Spec:** docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#41-persistencekit-contract

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

---

### ConvergenceKit (SubstrateLib, PersistenceKit)

**Canonical Role:** Sync abstraction layer. Backend-agnostic interface for pushing, pulling, and subscribing to changes.

**Spec:** docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#43-convergencekit-contract

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

---

## Grounding Layer (Standalone, Parallel to Substrate)

### LatticeLib (Zero Dependencies)

**Canonical Role:** Free Decimal Correspondence (FDC) engine — the encoder, the FDC frame (code tree), and the FDC signatures it scores against.

**Spec:** TOPOLOGY.md § FDC, the classification spine; FDC_ENCODER_CANONICAL.md

**Core Types:**
- `FDCFrame` / `FDCEntry` — The FDC code tree
- `FDCMatcher` — Concept-bag → FDC code matcher
- `Code` — FDC code grammar (`isWellFormed`)

**Public Functions:**
- `FDC.encode(_ text: String) -> String?`
- `FDC.encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?)`
- `FDC.isAvailable: Bool` / `FDC.dataVersion: String`
- `Code.isWellFormed(_ code: String) -> Bool`

**Dependencies:** None

---

### EideticLib (LatticeLib)

**Canonical Role:** Deterministic text-to-anchor lookup, FDC-backed. `lookup` delegates to LatticeLib's `FDC.encodeAnchor` (canonicalize term to a concept bag → match against pinned FDC signatures → FDC code + dominant Wikidata Q-ID).

**Spec:** TOPOLOGY.md § Grounding, EIDETICLIB_SPEC.md

**Core Type:**
- `Anchor` — Result of lookup
  - `code: String`
  - `wikidataQID: String?`
  - `confidence: UInt8`
  - `dataVersion: String`

**Public Functions:**
- `EideticLib.lookup(_ term: String) -> Anchor`
- `EideticLib.classifyLatticeCode(_ code: String, knownCodes: Set<String>) -> LatticeCodeState`
- `EideticLib.sentences(_:)` / `EideticLib.sentencesByDelimiter(_:)`

**Code States:**
- `LatticeCodeState` enum — .malformed, .known, .pending
- `LatticeCodeGrammar` — dependency-free FDC code validator

**Public Constants:**
- `version: String`

**Internals (cached, not exposed):**
- FDC reference artifacts (owned by LatticeLib's FDC runtime)

**Dependencies:** LatticeLib

---

## Main Substrate Layer

### LocusKit (SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit)

**Canonical Role:** Spatial memory system with knowledge graph. One estate per instance.

**Spec:** docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md

**Decisions:**
- the containment-hierarchy contract
- the provisional-drawer proposal

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

**Key Invariant (substrate architecture spec):**
- Every vector tagged with model ID and version
- Cross-model comparisons forbidden

**Dependencies:** SubstrateLib, EngramLib, PersistenceKit

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

**Key Design:**
- Tokenization in CorpusKit, not VectorKit
- Providers (with weights) in CorpusKitProviders to keep weights out of core
- Hybrid retrieval fuses BM25 + vector signals

**Dependencies:** VectorKit, PersistenceKit, ConvergenceKit, EngramLib

---

### GeniusLocusKit (LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit)

**Canonical Role:** Composition layer. Unifies LocusKit and CorpusKit into one estate, runs Brain layer, coordinates persistence.

**Spec:** TOPOLOGY.md § Composition, MOOTX01_AND_ARIA_CANON.md § Instance mode

**Main Actor:**
- `GeniusLocusKit` — Serialized coordinator (actor model)

**Lifecycle:**
- `open(storage: Storage, owner: String) -> EstateHandle`
- `close(_ handle: EstateHandle) async`
- `handles: [EstateHandle]`
- `openEstateCount: Int`
- `estate(for: EstateHandle) async throws -> LocusKit.Estate`

**Unified Audit Log:**
- `auditLog(for: EstateHandle) async throws -> UnifiedAuditLog`
- `feedAuditLog(for: EstateHandle) async throws`
- `verifyAuditChain` (async)

**Fan-out Queries:**
- `fanOutRecall(_ frame: RecallFrame, region: SpatialRegion) async throws -> AggregatedResults`

**COW Branching:**
- `glkDeriveBranch(from: EstateHandle) -> BranchHandle`
- `glkPromoteBranch(_ branch: BranchHandle) async throws -> PromotionResult`
- `glkMergeDrawers(from: BranchHandle, to: EstateHandle) async throws`

**Standing Signals (Brain layer):**
- `registerStandingSignal(...) async`
- `triggerSignal(for: EstateHandle) async`

**Dependencies:** LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit, EideticLib

---

## Reasoning & Behaviour Layer

### NeuronKit (EideticLib, SubstrateLib, EngramLib)

**Canonical Role:** AI algorithms — reasoning functions and autonomic daemons.

**Spec:** TOPOLOGY.md § Behaviour, MOOTX01_AND_ARIA_CANON.md

**Reasoning Surface:**
- `NeuronKit.inferLatticeAnchor(_ content: String) -> LatticeAnchorInference`

**Supporting Type:**
- `LatticeAnchorInference`

**Autonomic Daemons (NeuronKit spec):**
- `NeuronKit.dreamingDaemon(reader:, sink:, policyStore:, rewardSource:, triggerMode:) -> DreamingDaemon`
- `DreamingDaemon.registerDreamingPolicy(...) async`
- `DreamingDaemon.triggerDreamingCycle(now:) async`

**Daemon Seams (NeuronKit spec):**
- `DreamingSubstrateReader` — Read seam
- `DreamingProposalSink` — Write seam
- `DreamingPolicyStore` — Policy persistence
- `RewardSource` protocol
- `DreamingTriggerMode`

**Branch Operations (NeuronKit spec; thin forwards over GeniusLocusKit):**
- `deriveBranch(from: EstateHandle) -> BranchHandle`
- `promoteBranch(_ branch: BranchHandle) async throws -> PromotionResult`
- `mergeDrawers(from: BranchHandle, to: EstateHandle) async throws`

**Migration Benchmark (NeuronKit spec):**
- `benchmark(branch: BranchHandle, against: ExternalCorpus, queries: [Query], now: Date) async throws -> BenchmarkReport`
- `BenchmarkReport` (includes `notFoundInBranch` zero-tolerance signal)
- `ExternalCorpus` / `ExternalEntry`

**Linguistic Pipeline:**
- `LinguisticPipelineMode` enum (.deterministicReference, .appleNLAccel)
- `NeuronKit.linguisticPipelineMode: LinguisticPipelineMode`

**Public Constants:**
- `version: String` ("0.1.0")

**Dependencies:** EideticLib, SubstrateLib, EngramLib, GeniusLocusKit

**Maturity:** Implemented (Swift + Rust, conformance-gated). Reasoning, dreaming, branch ops, and migration surfaces built.

---

### CognitionKit (NeuronKit, GeniusLocusKit)

**Canonical Role:** Behaviour layer. Named, composable workflows and recipes.

**Spec:** TOPOLOGY.md § Behaviour, MOOTX01_AND_ARIA_CANON.md

**Interface:**
- `Workflow` protocol
- `WorkflowStep`
- `FulcrumDailyFraming` (workflow)
- `ScenarioSkill` (workflow)
- `WorkflowScheduler`

**Dependencies:** NeuronKit, GeniusLocusKit

**Maturity:** Implemented (Swift + Rust, conformance-gated). Source-available Brain layer in CE.

---

## Access Layer

### aria-mcp (GeniusLocusKit + NeuronKit)

**Canonical Role:** MCP server exposing any MOOTx01 estate to Claude, Claude Code, and other MCP clients.

**Spec:** MOOTX01_AND_ARIA_CANON.md § Consumption surfaces, ARIA.md, ARIA_LEXICON.md

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

**Maturity:** Implemented (Swift + Rust, conformance-gated).

---

### AriaMcpKit (GeniusLocusKit + NeuronKit)

**Canonical Role:** The library form of the ARIA MCP surface — the reusable Swift/Rust target that `aria-mcp` is built from, embeddable by host apps.

**Spec:** MOOTX01_AND_ARIA_CANON.md § Consumption surfaces

**Maturity:** Implemented (Swift + Rust, conformance-gated).

---

### Mootx01-App (GeniusLocusKit)

**Canonical Role:** The MOOTx01 host application (macOS and iOS/iPadOS), demonstrating the sidecar pattern and exercising the SDK and the ARIA verb surface natively.

**Spec:** MOOTX01_AND_ARIA_CANON.md § Demonstration apps

**Purpose:** Worked example for developers; teaches sidecar integration and basic SDK usage.

**Maturity:** Planned after aria-mcp.

---

### aria-mcp Rust port (GeniusLocusKit Rust version)

**Canonical Role:** Rust port of the ARIA MCP surface. **Required** for conformance parity between the Swift and Rust ports.

**Spec:** MOOTX01_AND_ARIA_CANON.md § Demonstration apps (required, not optional)

**Maturity:** Implemented (conformance-gated against the Swift port).

---

## Special Kits

### mootx01 CLI (apps/mootx01)

**Role:** First-run setup, system integration, and app updates via the mootx01 command-line tool.

**Maturity:** Planned.

---

## Summary by Role

| Role | Kits |
|------|------|
| **Grammar** | AriaLexiconLib |
| **Foundation** | SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit, EngramLib |
| **Grounding** | LatticeLib, EideticLib |
| **Substrate** | LocusKit, VectorKit, CorpusKit |
| **Composition** | GeniusLocusKit |
| **Reasoning** | NeuronKit (implemented, Swift + Rust) |
| **Behaviour** | CognitionKit (implemented, Swift + Rust) |
| **Access** | aria-mcp (implemented), AriaMcpKit (implemented), Mootx01-App (planned), aria-mcp Rust port (implemented) |

---

## Cross-Kit Dependency Graph

```
AriaLexiconLib          (zero deps)
SubstrateLib         (zero deps)
  ├── PersistenceKit     (SubstrateLib)
  ├── ConvergenceKit        (SubstrateLib, PersistenceKit)
  ├── QueueKit       (SubstrateLib)
  └── EngramLib      (SubstrateLib)
LatticeLib              (zero deps)
  └── EideticLib      (LatticeLib)
LocusKit             (SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
VectorKit            (SubstrateLib, EngramLib, PersistenceKit)
  └── CorpusKit         (VectorKit, PersistenceKit, ConvergenceKit, EngramLib)
GeniusLocusKit       (LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
NeuronKit            (EideticLib, SubstrateLib, EngramLib, GeniusLocusKit)
CognitionKit         (NeuronKit, GeniusLocusKit)
aria-mcp / AriaMcpKit (GeniusLocusKit, NeuronKit)
Mootx01-App          (GeniusLocusKit)
aria-mcp Rust port   (GeniusLocusKit Rust version)
```

---

## Maturity Legend

| Maturity | Meaning |
|----------|---------|
| Built | Public interface implemented and test-covered |
| In progress | Interface partially built; some surface still landing |
| Planned | Not yet built; gating dependency shown |

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

**LatticeLib:**
- [ ] Only FDC-encoder concerns
- [ ] No network at runtime
- [ ] FDC signatures version pinned and frozen

**EideticLib:**
- [ ] Stateless from caller view; reference data cached by LatticeLib
- [ ] lookup delegates to FDC.encodeAnchor
- [ ] Empty anchor (no fallback code) on a miss

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
- [ ] Dreaming daemon seams correct
- [ ] Branch ops thin forwards (no state stored locally)
- [ ] Benchmark read-only

---

**Last Updated:** 2026-06-14  
**Canonical Source:** docs/concepts/TOPOLOGY.md, docs/concepts/MOOTX01_AND_ARIA_CANON.md  
**Engineering Source:** docs/engineering/README.md
**Code Source:** Actual public interfaces
