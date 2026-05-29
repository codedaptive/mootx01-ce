# MOOTx01 Package Map

Agent-facing orientation guide for the `Packages/` directory. Read this
before touching any package. If you are lost, return here.

The packages are divided into two subdirectories:

- **`Packages/libs/`** — stateless, pure function libraries. Give you values
  back. No actors, no lifecycle, no managed state.
- **`Packages/kits/`** — stateful packages that manage something. Have actors,
  lifecycle, ongoing work.

Cross-references to individual specs live in `docs/reference/`. The authoritative
interface contracts live in `docs/concepts/KIT_INTERFACE_DESIGN.md`.

---

## Layer Overview

Packages compose bottom-up. Each layer depends only on layers below it.

```
REASONING   CognitionKit        NeuronKit
ORCHESTRAT  GeniusLocusKit
STANDALONE  LocusKit            VectorKit           CorpusKit
GROUNDING   LatticeKit          EideticLib
FOUNDATION  EngramLib           AriaLexiconLib
STORAGE     PersistenceKit      ConvergenceKit      QueueKit
MATH        SubstrateLib
```

`ARIA_MCP` (in `Apps/`) sits above all packages as the external access surface.

---

## Packages/libs/

---

### SubstrateLib

**Role:** The math bedrock. All numerical primitives the system depends on.
Every other package that needs math calls this one.

**Provides:**
- `Fingerprint256` — 256-bit typed vector, the universal hash unit
- `HLC` — Hybrid Logical Clock for deterministic timestamp ordering
- `GSetAuditLog` — append-only G-Set CRDT for audit trails
- Hamming distance, SimHash fingerprinting, OR-reduce over fingerprint sets
- BradleyTerry ranking, FFT, NMF (Non-negative Matrix Factorization)
- Platform-optimized kernel dispatch: CPU / NEON / Metal / ANE

**Does NOT:** No storage, no state, no management. Pure functions only.

**Dependencies:** None.  
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`

---

### EngramLib

**Role:** Typed 256-bit memory encoding API. Produces Engrams.

**Provides:**
- `Engram` — typealias for `Fingerprint256`, the memory encoding unit
- `distance`, `distances` — Hamming distance between Engrams
- `findNearest` — k-nearest-neighbor lookup
- `findWithin` — threshold-bounded search
- `union` — Engram aggregation (OR-reduce)
- `Session` — kernel-reuse handle for batch operations
- `Match` — index + distance result pair

**Does NOT:** No storage, no state. Pure encoding math over SubstrateLib.

**Dependencies:** SubstrateLib  
**Languages:** Swift + Rust (conformance-gated)

---

### EideticLib

**Role:** Deterministic text-to-anchor lookup. Produces Eidetics.
Given a term, returns the MDCC code + Wikidata Q-ID that anchor it in
the Eidetic Label Lattice.

**Provides:**
- `Anchor` — the Eidetic: mdccCode, wikidataQID, confidence, dataVersion
- `EideticLib.lookup(_:)` — term → Anchor (the primary entry point)
- `EideticLib.classifyLatticeCode(_:knownCodes:)` — code state check
- `EideticLib.defaultSchemeManifest()` — active scheme metadata
- `activationConsent` — consent gate for classification activation
- `version`, `defaultScheme` constants

**Does NOT:** No storage, no managed state. Stateless lookup against a
bundled gazetteer. Give it a term, get an Anchor back.

**Dependencies:** LatticeKit (for canon + code grammar)  
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/FDC_ENCODER_CANONICAL_v1.0.md`

---

### AriaLexiconLib

**Role:** The reified ARIA grammar. The single source of truth for the
vocabulary every consumer uses to talk to a MOOTx01 estate.

**Provides:**
- `Noun` enum — the drawer and its storage shapes
- `Verb` enum — nine verbs fixed by invariant I-7:
  capture, reanchor, mutate, withdraw, expunge, recall, propose, associate, learn
- `Adjective` enum — four categories fixed by invariant I-8:
  state, trust, sensitivity, exportability
- `Flow` enum — caller-driven, substrate-driven, grounding-driven
- `NounRole` enum
- `Acceptance` — verb-noun acceptance matrix
- `AriaLexiconLib.grammar` — the grammar contract string

**Does NOT:** No behavior, no storage, no logic. The vocabulary only.
Conformance-tested so Swift and Rust agree on every value.

**Dependencies:** None. Zero-dependency by design.  
**Languages:** Swift + Rust (conformance-gated)  
**Related:** `ARIA.md`, `ARIA_LEXICON.md` at repo root

---

## Packages/kits/

---

### PersistenceKit

**Role:** Storage backend abstraction. One protocol, three backends.
Every kit that needs durable storage goes through this one.

**Provides:**
- `Storage` protocol — the single interface every consumer uses
- `RowStore`, `BlobStore`, `VectorIndex`, `AuditLog`, `StorageObserver` protocols
- `EstateConfiguration`, `SchemaDeclaration`, `IsolationLevel`
- Backends: `PersistenceKitSQLite`, `PersistenceKitPostgreSQL`, `PersistenceKitInMemory`
- sqlite-vec extension integration for vector indexing on SQLite

**Does NOT:** No domain logic, no schema decisions, no query building above
the raw protocol. Pure plumbing.

**Dependencies:** SubstrateLib  
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`

---

### ConvergenceKit

**Role:** Sync backend abstraction. One protocol, three sync engines.
The optional network layer — estates are local-first; sync is layered on top.

**Provides:**
- `SyncEngine` protocol — enable, disable, push, pull, subscribe, state
- `SyncManifest`, `SyncRecord`, `SyncReceipt`, `SyncEvent`, `SyncState`
- Backends: `ConvergenceKitCloudKit`, `ConvergenceKitFederation`, `ConvergenceKitNone`

**Does NOT:** No storage decisions, no conflict resolution UI, no domain
knowledge. The None backend is the default for local-only estates.

**Dependencies:** SubstrateLib, PersistenceKit  
**Languages:** Swift + Rust (conformance-gated)

---

### QueueKit

**Role:** Fill-and-drain job queue. Serial dispatch with audit-ordered claims.

**Provides:**
- `Job`, `JobID`, `SessionID`, `ObservationStatus`, `ArtifactRef`
- Four core operations: `send`, `drain`, `watch`, `reply`
- `inFlight()`, `completed(streamID:)`
- Filesystem backend (maildir-pattern, atomic POSIX renames)
- PersistenceKit-backed backend for durable queues
- InMemoryStorage backend for GLK Brain layer serial lane

**Does NOT:** No domain logic, no message routing, not a pub/sub system.
Deterministic serial-dispatch queue only.

**Key invariant:** GeniusLocusKit uses QueueKit internally in its Brain
layer (StandingSignalScheduler). NeuronKit and CognitionKit do NOT import
QueueKit directly — they get queue behavior through GLK's estate surface.
One estate. One queue. One authority over serial dispatch.

**Dependencies:** SubstrateLib, PersistenceKit  
**Languages:** Swift + Rust + Python (three-way conformance parity)  
**Spec:** `docs/specs/QUEUEKIT_SPEC.md`, `docs/specs/QUEUE_PROTOCOL_SPEC.md`

---

### LatticeKit

**Role:** Moot Decimal Classification Codes (MDCC). Maintains the Eidetic
Label Lattice — the universal coordinate spine of the substrate.

**Provides:**
- `LatticeCanon` — the loaded in-memory classification canon
- `LatticeKit.bundledCanon()` — loads the bundled canon
- `LatticeCodeGrammar.isWellFormed(_:)` — code syntax validation
- `classifyLatticeCode(_:knownCodes:)` → `LatticeCodeState`
- `LatticeSchemeManifest` — scheme metadata
- `StableKeyRegistry` — stable code assignments across canon builds
- `Assembler` — builds the canon from Wikidata CC0 source data
- `mdcc-build` executable — CLI tool for editorial canon management
- Editorial pin files — human-authored classification decisions

**Does NOT:** No text processing, no live lookup, no search. Defines and
maintains the label space. EideticLib performs the actual lookups.

**Why Kit not Lib:** Actively managed — StableKeyRegistry persists state
across builds, Assembler runs editorial tooling, human editors author pin
files. There is a management interface and maintained mutable state.

**Dependencies:** None  
**Languages:** Swift only (Rust port pending)  
**Spec:** `docs/specs/MDCC_ANNEX_SPEC_v0.1.md`, `docs/specs/LATTICE_CITATION_UDC_WIKIDATA.md`

---

### LocusKit

**Role:** Spatial memory system with knowledge graph. One estate.
The structured storage tier of the substrate.

**Provides:**
- `Drawer` — the atomic memory unit (verbatim content, immutable at core)
- `KGFact` — knowledge graph triple (subject, predicate, object)
- `DiaryEntry` — temporal event log entry
- `Tunnel` — typed cross-reference between drawers
- `Estate` (actor) — the estate orchestrator
- Nine verbs on Estate: capture, reanchor, mutate, withdraw, expunge,
  recall, propose, associate, learn
- `RecallFrame` — spatial query with bitmap filters
- `RecallStream` — paginated result iterator
- `Manifest`, `LocusKitSchema` — self-describing estate metadata
- Full adjective bitmap system: state, trust, sensitivity, exportability
- Provenance bitmap per drawer
- Audit trail with historical state reconstruction
- `EstateAudit`, `ContainerFingerprintStore`, `DrawerFingerprint`

**Does NOT:** No vectors, no RAG, no cross-estate coordination, no Brain
layer. One estate, structured content only. Use GeniusLocusKit when you
need composition, vectors, or the Brain layer.

**Dependencies:** PersistenceKit  
**Languages:** Swift (Rust port pending)  
**Spec:** `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`

---

### VectorKit

**Role:** On-device embeddings and nearest-neighbor search.
The vector storage tier of the substrate.

**Provides:**
- `EmbeddingProvider` protocol — pluggable embedding model interface
- `EmbeddingModel`, `EmbeddingResult`
- `StoredVector` — model-tagged vector (embedding + model identity)
- `VectorStore` — queryable ANN store (HNSW via sqlite-vec)
- `VectorMatch` — result with similarity score
- `VectorKit.embed(_:using:)` — text → embedding
- `VectorKit.findNearest(query:in:k:)` — ANN search
- `FloatSimHashEmbeddingProvider` — built-in deterministic provider

**Does NOT:** No content storage, no RAG bundles, no chunking. Stores and
searches vectors; content lives alongside in LocusKit or CorpusKit.

**Key design:** Every stored vector carries a model identity tag. Mixed-version
corpora remain filterable — the maintenance daemon detects version drift.

**Dependencies:** EngramLib, SubstrateLib, PersistenceKit  
**Languages:** Swift + Rust (conformance-gated)

---

### CorpusKit

**Role:** Content-plus-vector RAG bundles. The RAG tier of the substrate.
A private, local-first body of retrievable knowledge.

**Provides:**
- `BundleStore` (actor) — content bundle management
- `BM25Index` — inverted text index for keyword retrieval
- `Chunker` — semantic content splitting
- `Chunk` — the stored content unit
- `HybridRecall` — combined BM25 + vector retrieval
- `EmbeddingProvider` protocol + `CorpusKitProviders` (MiniLM, MPNet, Gemma)
- `SyncManifest` — replication metadata
- `TokenizerProtocol`

**Does NOT:** No KG facts, no audit trail, no tunnels, no diary entries.
Those live in LocusKit. CorpusKit is content-for-retrieval, not content-for-memory.

**Dependencies:** VectorKit, PersistenceKit, ConvergenceKit, EngramLib, SubstrateLib  
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`

---

### GeniusLocusKit

**Role:** The Spirit of the Place. The autonomous orchestrator.
Composes LocusKit, VectorKit, and CorpusKit into unified estates and runs
the Brain layer — the autonomous intelligence beneath the reasoning layers.

**Provides:**

*Estate management:*
- `open(storage:owner:)` → `EstateHandle`
- `close(_:)`, `estate(for:)`, `openEstateCount`

*Nine verbs (unified surface):*
  capture, reanchor, mutate, withdraw, expunge, recall, propose, associate, learn

*Brain layer (the autonomous system):*
- `StandingSignalScheduler` — serial-dispatch scheduler per estate via QueueKit
- Six default standing signals: Dreaming, Maintenance, Training,
  Synchronization, ByReferenceValidity, VectorSimilarity
- Matrix tier: 16×16 bitmap reshape, M·M.T field correlation, asymmetry profile
- Training daemon (fires at Q34 threshold: 5K rows + 1K state transitions)

*Cross-estate capabilities:*
- `fanOutRecall` — query across multiple estates
- `UnifiedAuditLog`, `CrossEstateRead`

*COW branching:*
- `glkDeriveBranch`, `glkPromoteBranch`, `glkMergeDrawers`

*Grants and scope:*
- `GrantStore`, `ScopeKeyVault`, `LagrangeDecayKey`

*Migration:*
- `importFromMemPalace`, `ExternalCorpus`, `MigrationAPI`

**Critical invariants:**

**B-1:** NeuronKit and CognitionKit NEVER import LocusKit, VectorKit, or
CorpusKit directly. All substrate access flows through GeniusLocusKit's
estate verb surface.

**Queue authority:** GLK holds one QueueKit instance per estate in
StandingSignalScheduler. NeuronKit and CognitionKit never import QueueKit
directly. One estate. One queue. One authority over serial dispatch.

**Dependencies:** AriaLexiconLib, CorpusKit, LocusKit, PersistenceKit, QueueKit, VectorKit  
**Languages:** Swift (Rust port pending)  
**Spec:** `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`, `docs/specs/NEURONKIT_SPEC_v0.1.md`

---

### NeuronKit

**Role:** The subconscious mind. AI algorithms and autonomic daemons.
Algorithms the reasoning layer runs — not recipes, not workflows.

**Provides:**
- `NeuronKit.inferLatticeAnchor(_:)` — infer MDCC anchor from free text
- `LatticeAnchorInference` — inference result with confidence
- `HybridRecall` — multi-signal recall (vector + BM25 + KG)
- `MMRRank` — Maximal Marginal Relevance ranking
- `DreamingDaemon`, `DreamingPolicy`, `DreamingTriggerMode`, `RewardSource`
- `MaintenanceDaemon`, `MaintenancePolicy`, `MaintenanceSeams`
- `BradleyTerry`, `BradleyTerryScore`, `PairwiseOutcome`
- `Tournament` — pairwise comparison engine
- `ContextSynthesizer` — multi-signal context assembly
- `ScenarioProfile`
- Branch operations: `deriveBranch`, `promoteBranch`, `mergeDrawers`
- `BenchmarkAlgorithm`, `BenchmarkReport`

**Does NOT:** No user-facing recipes, no named workflows. Algorithms and
daemons only. CognitionKit composes these into recipes.

**Dependencies:** EideticLib, EngramLib, GeniusLocusKit, LocusKit  
**Languages:** Swift + Rust  
**Spec:** `docs/specs/NEURONKIT_SPEC_v0.1.md`

---

### CognitionKit

**Role:** The conscious mind. Named, composable behaviour recipes.

**Status:** Planned — Mission 10. Not yet built.

**Will provide:**
- `Workflow` protocol — composable named workflow definition
- `WorkflowStep` — atomic step in a workflow
- `FulcrumDailyFraming` — the canonical daily review recipe
- `ScenarioSkill` — scenario-driven workflow composition
- `WorkflowScheduler` — recipe execution scheduling

**Dependencies (planned):** NeuronKit, GeniusLocusKit  
**Languages:** Swift  
**Spec:** `docs/specs/COGNITIONKIT_SPEC_v0.1.md`

---

## Dependency Graph (ground truth from Package.swift)

```
AriaLexiconLib  ← (none)
SubstrateLib    ← (none)
LatticeKit      ← (none)
EngramLib       ← SubstrateLib
EideticLib      ← LatticeKit
PersistenceKit  ← SubstrateLib
ConvergenceKit  ← SubstrateLib, PersistenceKit
QueueKit        ← SubstrateLib, PersistenceKit
LocusKit        ← PersistenceKit
VectorKit       ← EngramLib, SubstrateLib, PersistenceKit
CorpusKit       ← VectorKit, PersistenceKit, ConvergenceKit, EngramLib, SubstrateLib
GeniusLocusKit  ← AriaLexiconLib, CorpusKit, LocusKit, PersistenceKit, QueueKit, VectorKit
NeuronKit       ← EideticLib, EngramLib, GeniusLocusKit, LocusKit
CognitionKit    ← NeuronKit, GeniusLocusKit (planned)
```

---

## Build Status

| Package | Swift | Rust | Status |
|---------|-------|------|--------|
| SubstrateLib | ✅ | ✅ | Built |
| PersistenceKit | ✅ | ✅ | Built |
| ConvergenceKit | ✅ | ✅ | Built |
| QueueKit | ✅ | ✅ | Built + Python parity |
| EngramLib | ✅ | ✅ | Built |
| AriaLexiconLib | ✅ | ✅ | Built |
| LatticeKit | ✅ | — | Rust port pending |
| EideticLib | ✅ | ✅ | Built |
| LocusKit | ✅ | — | Rust port pending |
| VectorKit | ✅ | ✅ | Built |
| CorpusKit | ✅ | ✅ | Built |
| GeniusLocusKit | ✅ | — | Rust port pending |
| NeuronKit | ✅ | — | Rust port pending |
| CognitionKit | 🔲 | — | Mission 10 |

No package has cleared the security/quality/slop review gate yet.
Build status reflects functional tests only.

---

*Last updated: 2026-05-26*
