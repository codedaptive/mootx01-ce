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
REASONING   CognitionKit        NeuronKit           VaultKit
ORCHESTRAT  GeniusLocusKit
STANDALONE  LocusKit            VectorKit           CorpusKit
GROUNDING   LatticeLib          EideticLib
FOUNDATION  EngramLib           AriaLexiconLib
STORAGE     PersistenceKit      ConvergenceKit      QueueKit
SUBSTRATE   SubstrateLib  (orchestration: verbs + row-state automaton + AuditGate)
MATH        SubstrateTypes      SubstrateKernel     SubstrateML
TELEMETRY   IntellectusLib  (zero-dependency floor: stat model + sink + report gate)
            ObserverSink    (PersistenceKit-backed StatsSink + SQLite stats store + retention)
```

The substrate ships as **four packages** (the four-package substrate contract
addendum 2026-05-29): `SubstrateTypes` (pure data), `SubstrateKernel`
(hot-path kernels), `SubstrateML` (cold-path / ML algorithms), and
`SubstrateLib` — the orchestration layer over the other three.

`ARIA_MCP` (in `Apps/`) sits above all packages as the external access surface.

---

## Packages/libs/

---

### IntellectusLib

**Role:** Substrate self-report telemetry faculty. The floor of the telemetry
tree. Zero-dependency leaf — depends on nothing in the repo (std/Foundation
only) so that SubstrateTypes, SubstrateKernel, and SubstrateLib can safely
depend on it in Mission 2 without creating a layering cycle.

**Provides:**
- `StatSample` — the telemetry datum (`.metric` or `.event` variant)
- `EventKind` — the verb class for topology events (`capture`/`think`)
- `StatsSink` — protocol/trait for receiving `StatSample` values
- `NoOpSink` — the default discard implementation (safe no-op)
- `Intellectus` — global holder: installed sink + enabled flag
- `report(_:)` (Swift autoclosure) / `report!` (Rust macro) — short-circuit
  emission API: payload never evaluated when monitoring is off

**Key invariant:** When monitoring is disabled (the default), the payload
expression is **never evaluated**. Off-path cost: a single lock-free atomic-bool
load + branch (Swift `Synchronization.Atomic<Bool>`, Rust
`AtomicBool::load(Acquire)`; <1 ns). No allocation, no payload construction.

**Does NOT:** No transport, no serialisation, no observer, no clock reads.
Timestamps are caller-supplied (`now` as epoch seconds). The real reporting
sink is installed by a host in a later mission.

**Dependencies:** None (zero-dependency foundation leaf).
**Languages:** Swift + Rust (conformance-gated, 17+3 tests each)
**Spec:** `docs/reference/INTELLECTUSLIB_SPEC.md`

---

### ObserverSink

**Role:** The reusable telemetry sink + stats store — the bridge between
IntellectusLib's self-report faculty and durable storage. A host installs its
`PersistenceStatsSink` into `Intellectus`; each `StatSample` is serialised into
a local SQLite stats database. The read-plane data source for the management
console (moot-mgr).

**Provides:**
- `StatsStore` — the SQLite stats-store schema (`metric_samples`,
  `event_samples`, a `control` flag table), open/migrate, the monitoring on/off
  flag, retention (delete rows before a caller-supplied cutoff), and
  `storageStats(now:)` DB-health via PersistenceKit `StorageIntrospection`
- `PersistenceStatsSink` — `StatsSink` conformer that serialises each sample
  into the correct table and honours the monitoring flag

**Key invariant:** Timestamps stored TEXT(ISO8601); the stats store is
`sync = None` — its own file, never an estate DB, never federated. Retention
takes the cutoff as a parameter — no clock read inside the engine.

**Does NOT:** No transport beyond the local SQLite write, no inference. It
records what hosts self-report; the console reads it back.

**Dependencies:** IntellectusLib, PersistenceKit (SQLite backend).
**Languages:** Swift + Rust (conformance-gated, 12 tests each).
**Spec:** `docs/reference/OBSERVERSINK_SPEC.md`

---

### SubstrateTypes

**Role:** The data bedrock. The value types every kit speaks; zero compute.

**Provides:**
- `Fingerprint256` — 256-bit typed vector, the universal hash unit
- `HLC` + `HLCGenerator` — Hybrid Logical Clock and its generator
- `GSetAuditLog` — append-only G-Set CRDT for audit trails
- `AuditEvent`, `LatticeAnchor`, `Row`, `NounType`, `RowState`
- `MatrixF/C/O/T` (storage + indexing), `RowBitmaps`, `BlockMask`, `BitVector216`
- The algebra: `Hamming`, `SimHash`, `ORReduce`, `BitwiseArithmetic`, `HyperplaneFamily`, `CountVector256`, `FNV`, `ThreeDBitTensor`, `RecallTypes`

**Does NOT:** No compute kernels, no algorithms, no I/O. Pure shape + algebra.

**Dependencies:** None.  **Languages:** Swift + Rust (conformance-gated)

---

### SubstrateKernel

**Role:** Hardware-dispatched hot-path kernels (the §17.6 measured path).

**Provides:**
- `PortableKernel` + `SubstrateKernel` protocol; `ScalarKernel`, `SimdKernel`, NEON/BNNS/Metal backends
- `SHA256` (content-ID / seal), `HammingNN` top-K, `BitField` extraction

**Does NOT:** No pure types (those are in SubstrateTypes), no ML algorithms.

**Dependencies:** SubstrateTypes.  **Languages:** Swift + Rust (conformance-gated)

---

### SubstrateML

**Role:** Cold-path and dreaming-driven algorithms — learning, graph, projection.

**Provides:**
- `BradleyTerry`, `NMF`, `FFT`, `CommunityDetection`, `RandomWalks`, `AnomalyDetection`, `LLMCalibrationCurve`, `InformationTheory`, `EigenvalueCentrality`
- `MatrixDecay`, `MomentSummary`, `TemporalCompression`, `AuditLogFold`, `PartialStateRecall`, `FloatSimHash`, `LatticeDistance`, `CompositeDistance`, `FeatureExtractors`
- Federation: `PairingHandshake`, `TierContributionFingerprint`, `TierAscendingQuery`, `ActionOutcomeMatrix`, `DPORReduction`

**Does NOT:** No pure types, no hot-path kernels.

**Dependencies:** SubstrateTypes, SubstrateKernel.  **Languages:** Swift + Rust

---

### SubstrateLib

**Role:** The orchestration layer over the three sub-packages. The control
surface that composes Types, Kernel, ML, and the audit log into the substrate.

**Provides:**
- `Verbs` — the nine-verb substrate mechanics
- `RowStateAutomaton` — the row-state finite-state machine (legal transitions, I-22)
- `AuditGate` — the single write gate (admits FieldWrite sets, validates against the vocabulary and RowStateAutomaton, assigns content-ID)

**Does NOT:** No pure types, kernels, or ML algorithms — it depends on those.
As of 2026-05-29 it no longer re-exports them (the transitional shim was removed).

**Dependencies:** SubstrateTypes, SubstrateKernel, SubstrateML.  
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

### LatticeLib

**Role:** Frame Decimal Classification (FDC). Maintains the Eidetic
Label Lattice — the universal coordinate spine of the substrate.

**Provides:**
- `LatticeCanon` — the loaded in-memory classification canon
- `LatticeLib.bundledCanon()` — loads the bundled canon
- `LatticeCodeGrammar.isWellFormed(_:)` — code syntax validation
- `classifyLatticeCode(_:knownCodes:)` → `LatticeCodeState`
- `LatticeSchemeManifest` — scheme metadata
- `StableKeyRegistry` — stable code assignments across canon builds
- `Assembler` — builds the canon from Wikidata CC0 source data
- `mdcc-build` executable — CLI tool for editorial canon management
- Editorial pin files — human-authored classification decisions

**Does NOT:** No text processing, no live lookup, no search. Defines and
maintains the label space. EideticLib performs the actual lookups.

**Why Lib:** Editorial tooling (`Assembler`, `mdcc-build`) and `StableKeyRegistry`
operate at build time, not runtime. The deployed library loads a bundled, static
canon — no actors, no lifecycle, no ongoing state mutations during estate
operation. Directory placement in `libs/` reflects this: LatticeLib produces
and validates the FDC label space; it does not manage that space at runtime.

**Dependencies:** None  
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/MDCC_ANNEX_SPEC.md`, `docs/specs/LATTICE_CITATION_UDC_WIKIDATA.md`

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

**Dependencies:** LatticeLib (for canon + code grammar)  
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/FDC_ENCODER_CANONICAL.md`

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
- InMemoryStorage backend for the GLK Brain serial lane and the CorpusKit
  ingest queue

**Does NOT:** No domain logic, no message routing, not a pub/sub system.
Deterministic serial-dispatch queue only.

**Key invariant:** two kits consume QueueKit. GeniusLocusKit uses it in its
Brain layer (`StandingSignalScheduler` — the standing-signal serial lane), and
CorpusKit uses it as the per-corpus **ingest queue** (the encode pipeline,
relocated from GLK's `EncodeIntake`). NeuronKit and CognitionKit do NOT import
QueueKit directly — they reach queue behavior through the owning kit's surface.

**Dependencies:** SubstrateLib, PersistenceKit  
**Languages:** Swift + Rust + Python (three-way conformance parity)  
**Spec:** `docs/specs/QUEUEKIT_SPEC.md`

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
- Nine verbs on Estate: `capture`, `recall`, `withdraw`, `expunge`, `reanchor`,
  `mutate` (all six kinds — `.confirm`, `.reject`, `.contest`, `.resolve`,
  `.supersede`, `.revive` — live through the RowStateAutomaton gate), and
  `learn` (live, persists `LearnedReference` rows) are fully implemented.
  `propose` and `associate` have no Estate method — they are substrate-driven
  Brain-layer verbs dispatched by the Standing Signal Scheduler, not by callers.
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
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`

---

### VectorKit

**Role:** On-device embeddings and nearest-neighbor search.
The vector storage tier of the substrate.

**Provides:**
- `EmbeddingProvider` protocol — pluggable embedding model interface
- `EmbeddingModel`, `EmbeddingResult`
- `StoredVector` — model-tagged vector (embedding + model identity)
- `VectorStore` — queryable vector store (exact linear scan; ANN/HNSW is a separate decision, not yet adopted)
- `VectorMatch` — result with similarity score
- `VectorKit.embed(_:using:)` — text → embedding
- `VectorKit.findNearest(query:in:k:)` — nearest-neighbour search (linear scan)
- `FloatSimHashEmbeddingProvider` — built-in deterministic provider

**Does NOT:** No content storage, no RAG bundles, no chunking. Stores and
searches vectors; content lives alongside in LocusKit or CorpusKit.

**Key design:** Every stored vector carries a model identity tag. Mixed-version
corpora remain filterable — the maintenance daemon detects version drift.

**Dependencies:** EngramLib, SubstrateLib, PersistenceKit  
**Languages:** Swift + Rust (conformance-gated)

---

### CorpusKit

**Role:** Vector recall techniques — content-plus-vector bundles for
vector-based retrieval. A private, local-first body of retrievable
knowledge. CorpusKit is the vector recall tier; LocusKit is the semantic
recall tier (structured knowledge, KG facts, diary, associations).

**Provides:**
- `CorpusContentEngine` — canonical-ID whole-content BM25/vector indexing
- `CorpusDocumentStore` — canonical standalone document ownership
- `BM25Index` — inverted text index for keyword retrieval
- Optional `StandalonePassages` / `standalone-passages` range-only token
  windows with database-bound window and overlap; not compiled for GLK/MOOTx01
- `BundleStore`, `Chunker`, `Chunk`, and `HybridRecall` — legacy standalone
  1.0 compatibility only; never GLK content identity
- `EmbeddingProvider` protocol + `CorpusKitProviders` (MiniLM, MPNet, Gemma)
- `SyncManifest` — replication metadata
- `TokenizerProtocol`
- **Ingest pipeline** (`mountIngestQueue` / `enqueueIngest` / `awaitIngestDrain`
  / `drainIngestQueueOnce` + the `onEncoded` callback): a Corpus owns a
  per-corpus QueueKit-backed encode queue and drains it on its own bounded
  worker pool (`ingestBatch` — cross-document parallel embed compute, serial
  batched writes). A Corpus queues, drains, and encodes its own content with no
  orchestrator; GeniusLocusKit only enqueues and coordinates the room rollup.
  Relocated from GLK's `EncodeIntake`.

**Does NOT:** No KG facts, no audit trail, no tunnels, no diary entries.
Those live in LocusKit. CorpusKit is content-for-retrieval, not content-for-memory.

**Dependencies:** VectorKit, PersistenceKit, ConvergenceKit, EngramLib, SubstrateLib, QueueKit  
**Languages:** Swift + Rust (conformance-gated)  
**Spec:** `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`

---

### GeniusLocusKit

**Role:** The Spirit of the Place. The composition layer.
Composes LocusKit, VectorKit, and CorpusKit into unified estates and defines
the Brain layer types (standing-signal registry, matrix tier, training-daemon) — emitting signals
the AutonomicGovernor (in NeuronKit, started by the AriaResident host) drives.

**Provides:**

*Estate management:*
- `open(storage:owner:)` → `EstateHandle`
- `close(_:)`, `estate(for:)`, `openEstateCount`

*Nine verbs (unified surface)* — every verb is a legal lexicon target; status
reflects the live dispatch behavior asserted by
`GeniusLocusKitTests/VerbSurfaceTests.swift`:
- Live round-trip: `capture`, `recall`, `withdraw`, `expunge`, `reanchor`
- `mutate`: all six kinds live — `.confirm` (provenance axis), `.reject`,
  `.contest`, `.resolve`, `.supersede`, `.revive` (state-axis, each guarded
  by the RowStateAutomaton). An illegal source state throws
  `VerbError.underlyingEstateFailure`, not `notSupportedByEstate`.
- `learn`: live — persists `LearnedReference` rows via `Estate.learn` in both
  Swift and Rust ports.
- `propose`, `associate`: surface `VerbError.notSupportedByEstate` — these are
  substrate-driven Brain-layer verbs with no caller-facing Estate method.
  `notSupportedByEstate` here is a permanent runtime channel, not a work item:
  estates that genuinely do not expose these verbs return this error by design.

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

*Migration (orchestration only — mass ingestion lives in VaultKit per the data-movement contract):*
- `runParallel`, `verifyMigration` (`MigrationAPI`), `ExternalCorpus`

**Critical invariants:**

**B-1:** NeuronKit and CognitionKit reach the substrate (LocusKit,
VectorKit, CorpusKit) only through GeniusLocusKit's estate verb surface —
no estate/IO call, no SQL. The one exception is **read-only value types**:
they MAY import LocusKit to name value types (e.g. `Drawer`, `ContentKind`,
`RecallFrame`, `Filter`) in their inputs and outputs. They MUST NOT call any
LocusKit (or VectorKit / CorpusKit) estate, verb, or storage surface. Both
ports hold this posture — Swift held it from the start; the Rust BrainKit
reader layer was brought into compliance by TASK-MXE-2026-0070 (stream
`rb-rust-brainkit-substrate-boundary`). The Swift port re-exports
`LocusKit.Drawer` via `NeuronKit/HybridRecall.swift`; the Rust port
re-exports `locus_kit::Drawer` and allied value types via `genius_locus_kit`
so NeuronKit readers carry zero direct `locus_kit::` storage imports. The
CognitionKit recipes (`Drift`, `AssociationRules`, `FormalConcepts`, …)
import LocusKit for frame value types only.
(Boundary-owned DTOs that would drop even the value-type import are a
separate architecture decision — deferred, not adopted here.)
A B-1 conformance test in `packages/kits/NeuronKit/rust/tests/brain_kit_boundary_test.rs`
enforces the reader boundary mechanically for both reader adapters.

**Queue authority:** GLK holds the standing-signal QueueKit instance per estate
in `StandingSignalScheduler` (the Brain serial-dispatch lane). The encode/ingest
queue is NOT GLK's — it relocated to CorpusKit (a Corpus owns its own ingest
queue + drain worker pool). NeuronKit and CognitionKit never import QueueKit
directly. Each queue has one owner; GLK orchestrates the encode path but does
not own its queue.

**Dependencies:** AriaLexiconLib, CorpusKit, LocusKit, PersistenceKit, QueueKit, VectorKit  
**Languages:** Swift + Rust (conformance-gated)  
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
A recipe is a sequence of NeuronKit reasoning calls and GeniusLocusKit
estate verbs — it implements no algorithm and holds no substrate state.

**Provides:**
- `Recipe` protocol — typed `Input`/`Output` behaviour definition
- `RecipeCatalog` — the discovery registry (type-erased `RecipeDescriptor`
  metadata: name, version, description, required capabilities)
- `NeuronKitCapability` — the capability set a recipe declares it sequences
- Shipped recipes (`RecipeCatalog.all`, 18 total):
  - *Foundational:* `grounded_synthesis`, `migration_benchmark`
  - *Structure lenses:* `keystones`, `constellation`, `free_association`
  - *Topic lenses:* `theme_weather`, `latent_themes`
  - *Preference lens:* `bias`
  - *Surprise lenses:* `drift`, `contradiction`
  - *Grounding/trust lens:* `trust_grounded_synthesis`
  - *Associative lens:* `partial_cue_recall`
  - *Prediction lenses:* `anticipate`, `tunnel_successor`
  - *Federated lenses:* `mind_overlap`, `estate_divergence`
  - *Analytics lenses:* `association_rules`, `formal_concepts`

**Does NOT:** No algorithms of its own (those are NeuronKit), no direct
substrate calls. Every read and write descends through NeuronKit or the
passed GeniusLocusKit estate handle.

**Dependencies:** GeniusLocusKit, NeuronKit, LocusKit (read-only value
types), SubstrateTypes  
**Languages:** Swift + Rust (conformance-gated; `rust/src/catalog.rs` is the
recipe-descriptor conformance anchor)  
**Spec:** `docs/reference/COGNITIONKIT_SPEC.md`

---

### VaultKit

**Role:** Portable vault export/import — projects an estate to a plaintext,
file-based Markdown snapshot and back. Backs the ARIA `moot_vault_*` tool
family (export, import, reconcile, status).

**Provides:**
- export an estate's drawers to a vault directory as UTF-8 Markdown (one note
  per drawer, an `index.md` per folder, `log.md` for diary entries), and
  import a vault back into an estate (path/key projection between human paths
  and estate keys)
- vault reconcile + status surfaces consumed by the `moot_vault_*` tools
- sensitivity-tier exclusions on export: the `.secret` tier never rides bulk
  export, and `.restricted` is excluded unless the caller explicitly scopes it
  in. These are tier filters applied before anything is written — they are not
  a confidentiality control over what does get written.

**Vault contents are written in plaintext.** VaultKit encrypts nothing on
export or import; a drawer's text lands on disk verbatim and readable. The
confidentiality boundary is the destination directory — its filesystem
permissions, whatever whole-disk encryption sits under it, and whether it is
synced or backed up anywhere are the operator's responsibility to set before
exporting.

**Dependencies:** GeniusLocusKit, LocusKit, EideticLib, PersistenceKit.
**Languages:** Swift + Rust (conformance-gated).

---

## Dependency Graph (ground truth from Package.swift)

```
IntellectusLib  ← (none)   ← zero-dependency floor; Mission 2 wires SubstrateTypes etc. to depend on it
ObserverSink    ← IntellectusLib, PersistenceKit (SQLite backend)   ← telemetry sink + stats store
AriaLexiconLib  ← (none)
SubstrateTypes  ← (none)
SubstrateKernel ← SubstrateTypes
SubstrateML     ← SubstrateTypes, SubstrateKernel
SubstrateLib    ← SubstrateTypes, SubstrateKernel, SubstrateML
LatticeLib      ← (none)
EngramLib       ← SubstrateTypes, SubstrateKernel
EideticLib      ← LatticeLib
PersistenceKit  ← SubstrateTypes
ConvergenceKit  ← SubstrateTypes, PersistenceKit
QueueKit        ← SubstrateTypes, PersistenceKit
LocusKit        ← SubstrateTypes, SubstrateKernel, SubstrateML, SubstrateLib, PersistenceKit
VectorKit       ← EngramLib, SubstrateTypes, SubstrateML, PersistenceKit
CorpusKit       ← VectorKit, PersistenceKit, ConvergenceKit, EngramLib, SubstrateTypes, SubstrateML, QueueKit
GeniusLocusKit  ← AriaLexiconLib, CorpusKit, LocusKit, PersistenceKit, QueueKit, VectorKit, SubstrateTypes, SubstrateKernel
NeuronKit       ← EideticLib, EngramLib, GeniusLocusKit, LocusKit, SubstrateTypes
CognitionKit    ← GeniusLocusKit, NeuronKit, LocusKit, SubstrateTypes
VaultKit        ← GeniusLocusKit, LocusKit, EideticLib, PersistenceKit
```

Only LocusKit keeps a direct `SubstrateLib` dependency — it drives the
verbs (RowStateAutomaton + AuditGate). Every other consumer depends on
the precise sub-package(s) it uses.

---

## Build Status

| Package | Swift | Rust | Status |
|---------|-------|------|--------|
| SubstrateTypes | ✅ | ✅ | Built |
| SubstrateKernel | ✅ | ✅ | Built |
| SubstrateML | ✅ | ✅ | Built |
| SubstrateLib | ✅ | ✅ | Built (orchestration layer) |
| PersistenceKit | ✅ | ✅ | Built |
| ConvergenceKit | ✅ | ✅ | Built |
| QueueKit | ✅ | ✅ | Built + Python parity |
| EngramLib | ✅ | ✅ | Built |
| AriaLexiconLib | ✅ | ✅ | Built |
| LatticeLib | ✅ | ✅ | Built |
| EideticLib | ✅ | ✅ | Built |
| LocusKit | ✅ | ✅ | Built |
| VectorKit | ✅ | ✅ | Built |
| CorpusKit | ✅ | ✅ | Built |
| GeniusLocusKit | ✅ | ✅ | Built |
| NeuronKit | ✅ | ✅ | Built |
| CognitionKit | ✅ | ✅ | Built (18 recipes; descriptor conformance-gated) |
| VaultKit | ✅ | ✅ | Built (plaintext Markdown vault export/import; moot_vault_* bridge) |
| IntellectusLib | ✅ | ✅ | Built (17 tests each port; zero-dependency leaf) |
| ObserverSink | ✅ | ✅ | Built (12 conformance tests each port; PersistenceKit-backed stats store) |

No package has cleared the security/quality/slop review gate yet.
Build status reflects functional tests only.

---

*Last updated: 2026-06-06 (full kit-status reconcile: added ObserverSink + VaultKit; corrected LatticeLib/LocusKit/GeniusLocusKit/NeuronKit to Built Swift+Rust per the v1.0 parity-complete sweep; fixed the IntellectusLib off-path note to the lock-free atomic gate).*
