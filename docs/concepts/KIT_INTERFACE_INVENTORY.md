# Kit Interface Inventory: MOOTx01

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

### LatticeKit
**Role:** Moot Decimal Classification Codes (Dewey-like spine, MDCC canon).  
**Language:** Swift

**Public Interface:**
- `LatticeCanon` (loaded reference data)
- `LatticeKit.bundledCanon() -> LatticeCanon?`
- `LatticeSchemeManifest`
- `LatticeCodeGrammar.isWellFormed(_ code: String) -> Bool`
- `classifyLatticeCode(_ code: String, knownCodes: Set<String>) -> LatticeCodeState`
- `LatticeKit.canonVersion: String`

---

### EideticLib
**Role:** Deterministic text-to-anchor lookup (MDCC code + Wikidata Q-ID).  
**Language:** Swift + Rust

**Public Type:**
- `Anchor` (mdccCode, wikidataQID, confidence, dataVersion)

**Public Functions:**
- `EideticLib.lookup(_ term: String) -> Anchor`
- `EideticLib.classifyLatticeCode(_ code: String, knownCodes: Set<String>) -> LatticeCodeState`
- `EideticLib.defaultSchemeManifest() -> LatticeSchemeManifest?`

**Scheme Registration:**
- `activationConsent` (ActivationConsent type)

**Public Constants:**
- `version: String`
- `defaultScheme: ClassificationScheme`

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
**Role:** Content-plus-vector RAG bundles (hybrid retrieval, no cloud).  
**Language:** Swift + Rust

**Public Types:**
- `RAGBundle`
- `BM25Index` (inverted text index)
- `TokenizerProtocol`
- `SyncManifest` (replication metadata)

**Public Functions:**
- `CorpusKit.addDocument(_ content: String, to: RAGBundle)`
- `CorpusKit.queryBM25(_ term: String, in: RAGBundle) -> [Result]`
- `CorpusKit.queryVector(_ embedding: Vector, in: RAGBundle, k: Int) -> [Result]`
- `CorpusKit.queryHybrid(_ term: String, embedding: Vector, in: RAGBundle) -> [Result]`

**Chunking:**
- `Chunker` (splits content into semantic units)

**Targets:**
- `CorpusKit` (core: tokenizer, chunker, BM25, bundle storage)
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
- `registry: [EstateHandle: LocusKit.Estate]` (internal)
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
- `branches: [BranchID: EstateBranch]` (internal)

**Standing Signals:**
- `schedulers: [EstateHandle: StandingSignalScheduler]` (internal)
- `registerStandingSignal(...)`
- `triggerSignal(for: EstateHandle)`

**Scope & Grants:**
- `grantStores: [EstateHandle: GrantStore]` (internal)
- `scopeVaults: [EstateHandle: ScopeKeyVault]` (internal)

---

## Reasoning & Behaviour Layer

### NeuronKit
**Role:** AI algorithms (reasoning, autonomic daemons).  
**Language:** Swift

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
**Language:** Swift

**Status:** Planned, Mission 10.

**Expected Interface:**
- `Workflow` protocol
- `WorkflowStep`
- `FulcrumDailyFraming`
- `ScenarioSkill`
- `WorkflowScheduler`

---

## Access Layer

### ARIA_MCP
**Role:** MCP server exposing any MOOTx01 estate to Claude, Claude Code, OB1, etc.  
**Language:** Swift + Python

**Status:** In progress, LAUNCH-04.

**Expected Interface:**
- MCP server conformance
- Resources: `mootx01://estate/{estateHandle}/*`
- Tools: estate/file, estate/reclaim, estate/recall, estate/witness, estate/tunnel
- Subscriptions: estate changes as live notifications

---

### ARIA_MacOS
**Role:** macOS demonstration of the sidecar pattern.  
**Language:** Swift

**Status:** Planned, after ARIA_MCP.

---

### ARIA_iOS
**Role:** iOS demonstration.  
**Language:** Swift

**Status:** Planned Rev 3.0, after ARIA_MacOS.

---

### ARIA_Rust
**Role:** Rust demonstration (required for conformance parity).  
**Language:** Rust

**Status:** Planned, after ARIA_MacOS.

---

## Special Kits

### Installer
**Role:** First-run and system integration.  
**Status:** Planned, LAUNCH-01.

---

### Sidecar_Demo_macOS
**Role:** Prototype demonstrating the sidecar pattern.

---

### tools/
**Role:** Build and test utilities, not shipped.

---

## Summary by Role

| Role | Kits |
|------|------|
| **Foundation** | AriaLexiconLib, SubstrateLib, PersistenceKit, QueueKit, ConvergenceKit, EngramLib |
| **Grounding** | LatticeKit, EideticLib |
| **Substrate** | LocusKit, VectorKit, CorpusKit, GeniusLocusKit |
| **Reasoning** | NeuronKit |
| **Behaviour** | CognitionKit |
| **Access** | ARIA_MCP, ARIA_MacOS, ARIA_iOS, ARIA_Rust |

---

## Cross-Kit Dependency Summary

```
AriaLexiconLib           (zero deps)
SubstrateLib          (zero deps)
PersistenceKit            (SubstrateLib)
ConvergenceKit               (SubstrateLib, PersistenceKit)
QueueKit              (SubstrateLib)
EngramLib             (SubstrateLib)
LatticeKit               (zero deps)
EideticLib             (LatticeKit)
LocusKit              (SubstrateLib, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
VectorKit             (SubstrateLib, EngramLib, PersistenceKit)
CorpusKit                (VectorKit, PersistenceKit, ConvergenceKit, EngramLib)
GeniusLocusKit        (LocusKit, CorpusKit, VectorKit, PersistenceKit, ConvergenceKit, QueueKit, EideticLib)
NeuronKit             (EideticLib, GeniusLocusKit, EngramLib)
CognitionKit          (NeuronKit, GeniusLocusKit)
ARIA_MCP              (All substrate kits + NeuronKit)
```

---

**Last Updated:** 2026-05-26  
**Status:** Foundation + Substrate + Grounding complete. Reasoning (NeuronKit) in progress. Access (ARIA_MCP) in progress.
