---
title: Kit Interface Inventory
status: canon
authors: MOOTx01 maintainers
date: 2026-07-20
version: 1.1.0
description: A per-kit inventory of every kit's public interface — types, functions, and protocol conformances — across the MOOTx01 substrate.
---

# Kit Interface Inventory: MOOTx01

> **Companion:** [`KIT_INTERFACE_DESIGN.md`](KIT_INTERFACE_DESIGN.md) — the design rollup that explains how these interfaces fit together.

**Purpose:** Rapid interface audit across all Kits to detect misplaced functions and interface shape correctness. One short section per Kit; no deep dive.

**Format:** Public types, main functions, and protocol conformances only. Internal/private omitted.

---

## Foundation Layer

### AriaLexiconLib
**Role:** Reified ARIA grammar (verbs, nouns, adjectives). Zero dependencies.  
**Language:** Swift + Rust

**Public Interface:**
- `AriaLexiconLib` enum (marker)
- `AriaLexiconLib.grammar: String` (statement of the contract)

**Notes:** Extremely minimal. Carries the grammar invariants (nine verbs, four adjectives) as a conformance checkpoint.

---

### SubstrateLib
**Role:** Math primitives: SimHash, Hamming distance, kernel dispatch, audit CRDT.  
**Language:** Swift + Rust

**Public Types:**
- `Fingerprint256` (256-bit typed vector)
- `Fingerprint512` (future)
- `HLC` (Hybrid Logical Clock)
- `GSetAuditLog` (append-only CRDT)

**Public Functions:**
- `hammingDistance256(Fingerprint256, Fingerprint256) -> Int`
- `hammingTopK(probe: Fingerprint256, candidates: [Fingerprint256], k: Int) -> [TopKResult]`
- `hammingDistanceBatch(probe: Fingerprint256, candidates: [Fingerprint256]) -> [Int]`
- `orReduce256([Fingerprint256]) -> Fingerprint256`

**Public Protocols:**
- `SubstrateKernel` (interface for backend kernels: SIMD, Metal, NEON, BNNS)
- `PortableKernel` (dispatcher)

**Notes:** Broad math surface. No storage or persistence here.

---

### PersistenceKit
**Role:** Storage abstraction (SQLite, PostgreSQL, InMemory backends).  
**Language:** Swift + Rust

**Public Interface:**
- `Storage` protocol
  - `open(schema:) async throws`
  - `close() async`
  - `transaction(_:) async throws`
  - `currentSchemaVersion() async throws`
  - `migrate(to:) async throws`

**Sub-stores:**
- `RowStore` protocol
- `BlobStore` protocol
- `VectorIndex` protocol
- `AuditLog` protocol
- `StorageObserver` protocol

**Supporting Types:**
- `EstateConfiguration`
- `SchemaDeclaration`
- `IsolationLevel` enum
- `StorageTransaction`

**Backends:**
- `PersistenceKitSQLite`
- `PersistenceKitPostgreSQL`
- `PersistenceKitInMemory`

---

### QueueKit
**Role:** Fill-and-drain job queue (RAM and database backends, serial dispatch).  
**Language:** Swift + Rust

**Public Types:**
- `Job`
- `JobID`
- `SessionID`
- `ObservationStatus` enum
- `ArtifactRef`

**Public Interface:**
- `init(root: URL, hlcGenerator:)`
- `init(backend:, root:)`

**Four public methods (spec § 3):**
- `send(_ job: Job) async throws`
- `drain() async throws -> [(job: Job, sessionID: SessionID)]`
- `watch(handler:) async throws`
- `reply(to:, status:, artifacts:) async throws`

**Additional:**
- `inFlight() async throws -> [Job]`
- `completed(streamID:) async throws -> [Job]`

**Maildir management:**
- `ensureMaildir(root:)`
- `cleanStaleTmpFiles(root:)`

---

### ConvergenceKit
**Role:** Sync abstraction (CloudKit, Federation, None).  
**Language:** Swift + Rust

**Public Interface:**
- `SyncEngine` protocol
  - `enable(manifest:, storage:) async throws`
  - `disable() async throws`
  - `push() async throws -> SyncReceipt`
  - `pull() async throws -> SyncReceipt`
  - `subscribe() -> AsyncStream<SyncEvent>`
  - `state: SyncState { get async }`

**Supporting Types:**
- `SyncManifest`
- `SyncRecord`
- `SyncReceipt`
- `SyncEvent`
- `SyncState`

**Backends:**
- `ConvergenceKitCloudKit`
- `ConvergenceKitFederation`
- `ConvergenceKitNone`

---

### EngramLib
**Role:** Typed 256-bit Engram API (similarity, retrieval, aggregation).  
**Language:** Swift + Rust

**Public Type:**
- `Engram` (typealias for `Fingerprint256`)

**Public Functions (distance):**
- `distance(_ a: Engram, _ b: Engram) -> Int`
- `distances(probe: Engram, candidates: [Engram]) -> [Int]`

**Public Functions (nearest neighbor):**
- `findNearest(probe: Engram, in: [Engram], k: Int) -> [Match]`
- `findNearest(probe: Engram, in: [Engram]) -> Match?`

**Public Functions (filtering):**
- `findWithin(probe: Engram, in: [Engram], maxDistance: Int) -> [Match]`

**Public Functions (aggregation):**
- `union(_ engrams: [Engram]) -> Engram`
- `union(_ a: Engram, _ b: Engram) -> Engram`

**Session API:**
- `Session` struct with same methods for kernel reuse

**Supporting Type:**
- `Match` (index + distance pair)

---

## Grounding Layer

### LatticeLib
**Role:** Free Decimal Correspondence (FDC) engine — encoder, frame, signatures (Dewey-like spine).  
**Language:** Swift + Rust

**Public Interface:**
- `FDC.encode(_ text: String) -> String?` / `FDC.encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?)`
- `FDC.isAvailable: Bool` / `FDC.dataVersion: String`
- `FDCMatcher`, `FDCFrame` / `FDCEntry` (the code tree)
- `Code.isWellFormed(_ code: String) -> Bool`

---

### EideticLib
**Role:** Deterministic text-to-anchor lookup, FDC-backed (FDC code + Wikidata Q-ID).  
**Language:** Swift + Rust

**Public Type:**
- `Anchor` (code, wikidataQID, confidence, dataVersion)

**Public Functions:**
- `EideticLib.lookup(_ term: String) -> Anchor`  (delegates to `FDC.encodeAnchor`)
- `EideticLib.classifyLatticeCode(_ code: String, knownCodes: Set<String>) -> LatticeCodeState`
- `EideticLib.sentences(_:)` / `EideticLib.sentencesByDelimiter(_:)`

**Public Constants:**
- `version: String`

---

## Substrate Layer

### LocusKit
**Role:** Spatial memory system with knowledge graph (one estate).  
**Language:** Swift

**Main Types:**
- `Drawer` (verbatim content)
- `DrawerID`
- `Wing` (taxonomy parent)
- `Room` (taxonomy child)
- `Tunnel` (cross-reference)
- `KGFact` (knowledge graph fact)
- `DiaryEntry` (temporal log)
- `Estate` (orchestrator actor)

**Estate Verbs:**
- `fileClaim(_ drawer: Drawer, in: DrawerID?) -> DrawerID`
- `reclaim(_ id: DrawerID) -> Drawer?`
- `forget(_ id: DrawerID)`
- `recall(_ query: RecallFrame) -> RecallStream`
- `witness(_ entry: DiaryEntry)`
- `tunnel(_ from: DrawerID, _ to: DrawerID, type: TunnelType)`
- ... (nine verbs total)

**Query Types:**
- `RecallFrame` (spatial query boundary)
- `RecallStream` (result iterator)

**Manifest & Schema:**
- `Manifest`
- `LocusKitSchema`

**Audit:**
- `EstateAudit`
- `auditTrail(since:, until:)`

**Error Type:**
- `LocusKitError`

---

### VectorKit
**Role:** On-device embeddings + nearest-neighbor search (model-tagged vectors).  
**Language:** Swift + Rust

**Public Types:**
- `EmbeddingProvider` protocol
- `EmbeddingModel`
- `EmbeddingResult`
- `Vector` (with model tag)
- `VectorIndex` (queryable ANN)

**Public Functions:**
- `VectorKit.embed(_ text: String, using: EmbeddingProvider) -> EmbeddingResult?`
- `VectorKit.findNearest(query: Vector, in: [Vector], k: Int) -> [Match]`
- `VectorKit.index(_ vectors: [Vector]) -> VectorIndex`

**Concrete Providers:**
- `MiniLM`
- `EmbeddingGemma`
- `mpnet`

---

### CorpusKit
**Role:** Standalone-capable RAG database and shared-content indexing engine.
**Language:** Swift + Rust

**Public Types:**
- `CorpusContentSource` (read/change input shared by both modes)
- `CorpusContentStore` (standalone canonical document ownership)
- `Corpus`, `CorpusOperatingMode`, `CorpusContentID`, `CorpusHit`
- `CorpusIndexUnitPolicy`, `PassagePolicy`
- `BM25Index` (inverted text index)
- `TokenizerProtocol`
- `SyncManifest` (replication metadata)

**Public Functions:**
- standalone document `put`/`remove` through `CorpusContentStore`
- `Corpus.applySourceChanges`, `rebuildFromSource`, and canonical-ID `recall`
- BM25/vector/provider operations shared by standalone and attached modes

**Chunking:**
- Whole-content indexing is the GLK/MOOTx01 policy.
- Optional token-budgeted, range-only passages are standalone-only.
- The text-copying 1.0 `Chunker`/`BundleStore` surface is compatibility-only
  and dark in GLK.

**Targets:**
- `CorpusKit` (content-source contracts, indexing/retrieval engine, optional
  standalone content store)
- `CorpusKitProviders` (text embedding providers with CoreML models)

---

### GeniusLocusKit
**Role:** Composition layer (N estates, unified substrate, unified audit log, Brain layer).  
**Language:** Swift

**Main Actor:**
- `GeniusLocusKit` (coordinates open estates)

**Lifecycle:**
- `open(storage: Storage, owner: String) -> EstateHandle`
- `close(_ handle: EstateHandle)`
- `handles: [EstateHandle]`
- `openEstateCount: Int`
- `estate(for: EstateHandle) -> LocusKit.Estate`

**Per-Handle Registry:**
- `storages: [EstateHandle: any Storage]`

**Unified Audit Log:**
- `auditLog(for: EstateHandle) -> UnifiedAuditLog`
- `feedAuditLog(for: EstateHandle) async throws`
- `verifyAuditChain`

**Fan-out Queries:**
- `fanOutRecall(_ frame: RecallFrame, region: SpatialRegion) -> AggregatedResults`

**COW Branching:**
- `glkDeriveBranch(from: EstateHandle) -> BranchHandle`
- `glkPromoteBranch(_ branch: BranchHandle) -> PromotionResult`
- `glkMergeDrawers(from: BranchHandle, to: EstateHandle)`

**Standing Signals:**
- `registerStandingSignal(...)`
- `triggerSignal(for: EstateHandle)`

---

## Reasoning & Behaviour Layer

### NeuronKit
**Role:** AI algorithms (reasoning, autonomic daemons).  
**Language:** Swift + Rust

**Status:** Implemented (Swift + Rust, conformance-gated).

**Public Type:**
- `LinguisticPipelineMode` enum

**Reasoning Surface:**
- `NeuronKit.inferLatticeAnchor(_ content: String) -> LatticeAnchorInference`

**Supporting Type:**
- `LatticeAnchorInference`

**Dreaming Daemon:**
- `NeuronKit.dreamingDaemon(reader:, sink:, policyStore:, rewardSource:, triggerMode:) -> DreamingDaemon`
- `DreamingDaemon.registerDreamingPolicy(...)`
- `DreamingDaemon.triggerDreamingCycle(now:)`

**Daemon Protocols:**
- `DreamingSubstrateReader`
- `DreamingProposalSink`
- `DreamingPolicyStore`
- `RewardSource`
- `DreamingTriggerMode`

**Branch Operations:**
- `deriveBranch(from: EstateHandle) -> BranchHandle`
- `promoteBranch(_ branch: BranchHandle) -> PromotionResult`
- `mergeDrawers(from: BranchHandle, to: EstateHandle)`

**Migration Benchmark:**
- `benchmark(branch: BranchHandle, against: ExternalCorpus, queries: [Query], now: Date) -> BenchmarkReport`
- `BenchmarkReport`
- `ExternalCorpus` / `ExternalEntry`

**Public Constants:**
- `version: String`
- `linguisticPipelineMode: LinguisticPipelineMode`

---

### CognitionKit
**Role:** Behaviour recipes (named, composable workflows).  
**Language:** Swift + Rust

**Status:** Implemented (Swift + Rust, conformance-gated). Source-available Brain layer in CE.

**Interface:**
- `Workflow` protocol
- `WorkflowStep`
- `FulcrumDailyFraming`
- `ScenarioSkill`
- `WorkflowScheduler`

---

## Access Layer

> **Content-completeness note (for a human/content-owner pass):** The
> shipped/planned statuses below now reflect the current surface (the
> ARIA MCP server and its Rust port are implemented). The entry list is
> still incomplete against the full access surface — it does not yet
> enumerate the mootx01 CLI, moot-mgr, moot-math-benchmark, or
> moot-agent-skills, and the per-entry interface detail is summary-level.
> A content-completeness pass is pending for those.

### aria-mcp
**Role:** MCP server exposing any MOOTx01 estate to Claude, Claude Code, etc.  
**Language:** Swift + Rust

**Status:** Implemented (Swift + Rust, conformance-gated). Built from AriaMcpKit.

**Expected Interface:**
- MCP server conformance
- Resources: `mootx01://estate/{estateHandle}/*`
- Tools: estate/file, estate/reclaim, estate/recall, estate/witness, estate/tunnel
- Subscriptions: estate changes as live notifications

---

### Mootx01-App (macOS)
**Role:** macOS demonstration of the sidecar pattern.  
**Language:** Swift

**Status:** Planned, after aria-mcp.

---

### Mootx01-App (iOS)
**Role:** iOS demonstration.  
**Language:** Swift

**Status:** Planned, after the macOS app.

---

### aria-mcp (Rust port)
**Role:** Rust demonstration (required for conformance parity).  
**Language:** Rust

**Status:** Implemented (conformance-gated against the Swift port).

---

## Summary by Role

| Role | Kits |
|------|------|
| **Foundation** | AriaLexiconLib, SubstrateLib, PersistenceKit, QueueKit, ConvergenceKit, EngramLib |
| **Grounding** | LatticeLib, EideticLib |
| **Substrate** | LocusKit, VectorKit, CorpusKit, GeniusLocusKit |
| **Reasoning** | NeuronKit |
| **Behaviour** | CognitionKit |
| **Access** | aria-mcp (Swift + Rust ports), Mootx01-App (macOS, iOS) |

---

## Cross-Kit Dependency Summary

```
AriaLexiconLib           (zero deps)
SubstrateLib          (zero deps)
PersistenceKit            (SubstrateLib)
ConvergenceKit               (SubstrateLib, PersistenceKit)
QueueKit              (SubstrateLib)
EngramLib             (SubstrateLib)
LatticeLib               (zero deps)
EideticLib             (LatticeLib)
LocusKit              (SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
VectorKit             (SubstrateLib, EngramLib, PersistenceKit)
CorpusKit                (VectorKit, PersistenceKit, ConvergenceKit, EngramLib)
GeniusLocusKit        (LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
NeuronKit             (EideticLib, GeniusLocusKit, EngramLib)
CognitionKit          (NeuronKit, GeniusLocusKit)
aria-mcp              (All substrate kits + NeuronKit)
```

---

**Status:** Foundation + Substrate + Grounding complete. Reasoning (NeuronKit), Behaviour (CognitionKit), and Access (aria-mcp, Swift + Rust) implemented and conformance-gated.
