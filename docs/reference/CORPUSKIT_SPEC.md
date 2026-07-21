---
title: CorpusKit Specification
version: 1.14.0
status: accepted-1.1-target
date: 2026-07-20
description: "Behavioral specification for CorpusKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/CORPUSKIT_INTERFACE.md
  - docs/reference/VECTORKIT_SPEC.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/CONVERGENCEKIT_SPEC.md
  - docs/reference/ENGRAMLIB_SPEC.md
  - docs/reference/EIDETICLIB_SPEC.md
  - docs/reference/INTELLECTUSLIB_SPEC.md
  - docs/reference/SUBSTRATELIB_SPEC.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#53-embedding-provider-seam
---

# CorpusKit Specification

## § 1 — What this package is

CorpusKit is a standalone-capable retrieval-augmented-generation database and
the RAG indexing engine used by GeniusLocusKit. It builds BM25 and model-tagged
vector retrieval state over a `CorpusContentSource`, fuses the available lanes,
and returns the canonical identity supplied by that source. It also defines the
`Tokenizer` protocol used by its concrete embedding providers (MiniLM, mpnet,
EmbeddingGemma), which conform to VectorKit's `EmbeddingProvider`; the providers
ship in a separate `CorpusKitProviders` target so the core kit pulls in no model
weights.

CorpusKit has two operating modes over the same indexing and retrieval engine:

- **Standalone:** CorpusKit supplies a `CorpusContentStore`, owns canonical
  corpus documents, and may optionally create token-budgeted passage index
  units. This is a complete independently usable RAG database.
- **Composed:** GeniusLocusKit injects a LocusKit-backed content source.
  LocusKit's GLK Drawer is the one canonical content object; CorpusKit stores
  only derived indexes, provider state, revision/digest checkpoints, and
  optional match evidence keyed by the GLK Drawer ID.

CorpusKit never imports LocusKit. The adapter lives in GeniusLocusKit, preserving
both kits' standalone use and the bottom-up dependency graph. VectorKit remains
the owner of embeddings, ANN search, and model tagging.

This 1.1 target contract supersedes the 1.0 assumption that every Corpus must
own a copied `chunks.text` corpus. Unless a clause below explicitly says
otherwise, a reference to `Chunk`, `Chunker`, `ScoredChunk`, or `BundleStore`
describes the standalone optional-passage compatibility surface only. None of
those types defines content identity in a GeniusLocusKit composition.

## § 2 — Scope

This specification defines:

- The content-source contract and canonical `CorpusContentID` identity.
- Standalone document ownership through `CorpusContentStore`.
- Whole-content indexing, which is mandatory in GeniusLocusKit and the default
  standalone policy.
- Optional standalone passage indexing with provider-token budgets and
  revision-bound offsets; passage text is never copied into passage rows.
- The BM25 inverted index and its scoring contract.
- Hybrid recall: candidate-window fan-out, Reciprocal Rank Fusion of
  vector and keyword hits, deterministic ranking, and aggregation to canonical
  content identity.
- The `Tokenizer` protocol, the concrete embedding providers (which
  conform to VectorKit's `EmbeddingProvider`), and the
  model-tagging discipline that forbids cross-model comparison.
- Standalone content synchronization and composed-mode derived-index
  invalidation.
- The 1.0-to-1.1 migration contract for chunk-backed GLK databases.

This specification does NOT define:

- API signatures — those live in `CORPUSKIT_INTERFACE.md`.
- Embedding storage, the ANN/HNSW index, or `VectorStore.findNearest`
  ordering — those are VectorKit's (`VECTORKIT_SPEC.md`).
- The `Storage` row-store backend, schema declaration semantics, or
  append-only trigger mechanics — those are PersistenceKit's
  (`PERSISTENCEKIT_SPEC.md`).
- CloudKit zone mechanics or conflict-policy execution — those are
  ConvergenceKit's (`CONVERGENCEKIT_SPEC.md`).
- KG facts, audit trail, tunnels, diary — those are LocusKit's
  (`LOCUSKIT_SPEC.md`).
- GLK Drawer storage or lifecycle — GeniusLocusKit supplies an adapter over
  LocusKit rather than moving that ownership into CorpusKit.

## § 3 — Position in the kit family

```
SubstrateLib (HLC, FloatSimHash)   EngramLib (Engram)
        ▲                                ▲
        └───────────────┬────────────────┘
                        │
PersistenceKit ── CorpusKit ── VectorKit ── ConvergenceKit
   (Storage)        │  ▲          (VectorStore)   (SyncManifest)
                    │  └── CorpusKitProviders (MiniLM, mpnet, Gemma)
                    ▼
              GeniusLocusKit / NeuronKit (composition)
```

**Depends on:** SubstrateLib (HLC, `FloatSimHash` projection),
EngramLib (the `Engram` type), EideticLib (sentence segmentation via
`EideticLib.sentences`), PersistenceKit (the `Storage`
backend and schema declaration; the in-memory backend backs the ingest
queue), ConvergenceKit (the `SyncManifest` type), VectorKit
(`VectorStore` for the kNN pass), and **QueueKit** (the per-corpus ingest
queue — see § 11). The `CorpusKitProviders` target additionally depends on
the core `CorpusKit` target. QueueKit is a low-level primitive
(SubstrateTypes + PersistenceKit); CorpusKit → QueueKit is
downstream→upstream, no inversion.

**Consumed by:** the composition layer (GeniusLocusKit) and the
reasoning layer (NeuronKit), which build higher-level recall pipelines
on top of `HybridRecall`. No other kit consumes CorpusKit's types at
the source level today (see INTERFACE § 2 final note).

## § 4 — Invariants

**I-1 (standalone 1.0 chunk identity):** a `Chunk.id` is the RFC 4122 v5
UUID derived from `(sourceID, startOffset, text)` under the fixed
CorpusKit namespace `d6f3a1b2-7c84-4e5f-9a0b-1c2d3e4f5061`. Identical
content yields an identical id; the namespace MUST NOT change, since
changing it re-keys every chunk fleet-wide and breaks the vector join.

**I-2 (standalone 1.0 append-only chunks):** the chunks table is append-only. A chunk
is never edited or deleted in place. The `BundleStore` exposes no
per-row update or delete; the PersistenceKit append-only triggers abort
any BEFORE UPDATE / BEFORE DELETE at the substrate.

**I-3 (standalone 1.0 idempotent ingestion):** inserting a chunk whose id is already
stored is a no-op (first write wins). Combined with I-1 this makes
re-ingestion and cross-device duplicate arrival idempotent.

**I-4 (no cross-model comparison):** every Engram is tagged with the
`modelID` (and `modelVersion`) of the provider that produced it.
Retrieval filters the kNN pass to a single `modelID`, so engrams from
different models are never compared. Model identity is part of the
stored bundle, not just the inference call.

**I-5 (standalone 1.0 chunk-vector join):** a compatibility chunk is joined
to its stored vector by `chunk.id.uuidString == storedVector.itemID` under the
same `modelID`. This convention is not used in GLK, where the vector item ID is
the canonical Drawer ID directly.

**I-6 (standalone 1.0 verbatim chunk text):** the compatibility store keeps chunk text exactly as
chunked — it does not normalize, lowercase, or trim. Normalization is a
tokenizer concern applied at index/query time, not at storage time.

**I-7 (cross-port parity):** the Swift and Rust ports produce
byte-identical canonical results, BM25 rankings, and RRF fusion for every
shared test vector. The standalone compatibility suite additionally gates chunk
ids and boundaries. Canonical keyword tokens lowercase the whole string and
fold Greek final sigma U+03C2 to U+03C3 before boundary splitting, preventing
platform Unicode engines from producing different training bytes. Neither port
leads.

**I-8 (provider separation):** the core `CorpusKit` target ships only
the `Tokenizer` protocol; the `EmbeddingProvider` protocol is
VectorKit's, consumed directly by `CorpusKitProviders`' concrete
providers. Concrete providers and
their tokenizers live in `CorpusKitProviders`, so a consumer that
needs only bundle storage and BM25 pulls in no CoreML model code.

**I-9 (one basis per provider key):** the `corpus_provider_basis` table
holds at most ONE persisted basis row per `(model_id, model_version)`.
A retrain UPSERTs the row in place — the basis is never duplicated and
never orphaned. The table is owned by CorpusKit core (`BasisStore`),
never imports `CorpusKitProviders`, and stores `trained_at` as TEXT
ISO8601 (never REAL) with NO Bool columns (schema invariant). Decoders
are primitive-tolerant: `trained_at` is read as `Timestamp` on a
migrate-aware connection and as ISO8601 `Text` on a fresh connection, so
a persisted basis survives reopen on both ports (the same read-back
discipline as I-2's chunk decode).

**I-10 (standalone 1.0 `ext` compatibility):** both legacy persistent entity tables
carry one nullable `.json` column named `ext` — `chunks` at BundleStore schema
v3 and `corpus_provider_basis` at BasisStore ("CorpusKitBasis") schema v2. On
`chunks` it is distinct from the existing per-chunk `metadata` column. In 1.0
`ext` is inert — written NULL / omitted on insert/upsert and never read; it
carries no behavior. Provisioned during the 1.0.0 free-migration window. See
the forward-compatible ext-slot contract.

**I-11 (standalone 1.0 hash-on-write):** every compatibility chunk insert computes a
`content_hash` via `MerkleHash.leaf` (SubstrateLib) and stores it in the
nullable `content_hash` BLOB column added in schema v3. The hash is computed
by the `HashingRowStore` decorator wrapping the `RowStore` and fed by a
`ContentHashProvider` callback specific to CorpusKit (text content hashed).
The `content_hash` column is nullable to tolerate rows written before v3;
new inserts always populate it.

**I-12 (standalone 1.0 as-of reads):** all six `BundleStore` query
methods (`get`, `getMany`, `chunksForSource`, `count`, `allChunks`, and
the internal `affectedSourceIDs`) accept an `AsOfCoordinate` parameter
(`.present` or `.asOf(HLC)`). In the current implementation, only methods
backed by `RowStore.query` forward the coordinate; `count` accepts the
parameter for API parity but does not filter temporally (PersistenceKit's
`RowStore.count` has no as-of variant).

**I-13 (standalone 1.0 content root):** the `corpus_metadata` table (added in
BundleStore schema v3) stores one row per source_id with its Merkle root.
After each insert batch, `BundleStore` recomputes the Merkle root for each
affected source by hashing all chunk `content_hash` values for that source
via `MerkleHash.interior`. The `corpusMerkleRoot(for:)` query returns the
per-corpus root (or `MerkleRoot.empty` if no chunks exist for that source).
The `globalCorpusMerkleRoot()` query computes the interior hash over all
per-corpus roots, enabling an estate-level integrity check across all
corpora.

**I-15 (standalone 1.0 removed-source persistence):** `RemovedSourceStore` records the set of
source IDs whose recall has been suppressed by `Corpus.remove` or
`Corpus.expunge`. Because `BundleStore.chunks` is append-only (I-2), every
rebuild path (reindex, InvertedIndexStore reload on open) must filter the corpus
through `removedIDs()` to exclude suppressed sources. A source exits the removed
set when it is re-ingested: `Corpus.ingest` calls `clearRemoved` before writing
new chunks so a subsequent reindex includes the source again. The table is
wiped by `destroyRecallIndex` so no orphaned removal records survive (I-9
analogue for the removed-sources table). Schema: kit-ID "CorpusKitRemovedSources"
v1, `removed_sources(source_id TEXT PK, removed_at TEXT ISO8601)`; no Bool
columns, dates TEXT ISO8601.

**I-14 (Apple NL providers are Swift-only, opt-in, absent-lane safe, the Apple embedding-provider contract):**
`CorpusKitProviders` ships two Apple NaturalLanguage embedding providers —
`NLEmbeddingProvider` (sentence-level, always-available) and
`NLContextualEmbeddingProvider` (transformer, requires a downloadable per-language
asset). Both are gated `#if canImport(NaturalLanguage)` and are absent from the
Rust port (sanctioned divergence — same class as the `.nlTagger` word-class path).
They are item-local (stateless, compute-once-on-write; no `TrainableEmbeddingBasis`
conformance). They are OPT-IN: neither joins `CorpusEnsemble.defaultEnsemble()`.
When the OS model or language asset is unavailable, `embedFloat` returns `[]`
(standard absent-lane opt-out — `FloatLaneOutcome.unavailableProviderOptOut`) and
`embed` returns `.zero`. The provider NEVER blocks on a download and NEVER throws
for an absent asset. Projection seeds are `nlEmbeddingProjectionSeed` ("APNLEMB1",
`0x4150_4E4C_454D_4231`) and `nlContextualEmbeddingProjectionSeed` ("APNLCTX1",
`0x4150_4E4C_4354_5831`) — distinct from each other and from all other providers,
so NL vectors key to their own `model_id` storage partitions (I-4).

**I-16 (canonical content identity):** every indexed record has one
`CorpusContentID` supplied by its content source. BM25 postings, CorpusKit vector
rows, provider state, invalidation checkpoints, fused results, and deletion
operations resolve to that identity. A derived passage identifier may address an
internal index unit but MUST NOT become the public result identity.

**I-17 (single content owner in composed mode):** when CorpusKit is composed by
GeniusLocusKit, LocusKit owns the canonical GLK Drawer content and identity.
CorpusKit reads that content through an injected `CorpusContentSource`, never
persists copied Drawer text, and never imports LocusKit. The adapter that bridges
the two kits is owned by GeniusLocusKit.

**I-18 (chunking dark in GLK):** a GeniusLocusKit-composed Corpus always uses
whole-content indexing. `Chunker`, passage identities, passage tables, overlap,
and passage-text storage are absent from that operating mode and therefore absent
from MOOTx01. One active GLK Drawer produces one BM25 document identity and one
logical provider result identity per model.

**I-19 (standalone passage containment):** standalone CorpusKit may enable
passage indexing only as an explicit `IndexUnitPolicy`. Boundaries are derived
from the selected provider's token budget. Persisted passage state contains the
canonical content ID, content revision/digest, and range only; the text remains
owned by the standalone document store. Public recall aggregates passage scores
to `CorpusContentID` and may attach the best range as evidence.

**I-20 (derived-state migration):** the 1.1 migration from a chunk-backed GLK
database preserves Drawers, audit history, lineage, tunnels, facts, and unrelated
Drawer-keyed vectors. It retires the GLK `chunks`/`corpus_metadata` content
projection and every chunk-keyed CorpusKit BM25/vector/provider artifact, then
rebuilds CorpusKit state from active Drawers under Drawer IDs. CorpusKit remains
dark until verification succeeds. Migration failure never damages canonical
Drawer content and is resumable through PersistenceKit's ordered migration
mechanism.

**I-21 (current-runtime provider reconciliation):** provider additions and
removals are normal CorpusKit lifecycle changes, not historical schema
migrations. On open, CorpusKit compares the configured `(modelID,
modelVersion)` generations with a singleton durable attestation. A changed
configuration selectively releases retired representation claims, deletes only
their unowned vectors/basis/counts/coverage, trains and backfills added slots,
then writes the attestation last. An equal attestation is an O(1) open path; a
crash before the final write safely replays reconciliation.

**I-22 (dataset handles are not prose):** a GLK Drawer whose content kind is
`.dataset`, including the legacy `dataset-handle` sentinel, is excluded from
CorpusKit indexing. Its backing MX-TAB table, typed row values, primary and
secondary indexes, statistics, signatures, and handle remain owned by the
dataset tier and byte-equivalent across shared-content migration. No dataset
handle receives a BM25 document or CorpusKit-provider vector.

## § 5 — Behavioral contracts

**B-1 (standalone 1.0 Chunker compatibility):** the legacy
`Chunker.chunk` emits passages of at most
`targetChars` (after sentence packing), each overlapping the previous by
`min(overlapChars, chunk length)` characters; `overlapChars` is clamped
to `[0, targetChars-1]`. Sentence boundaries are respected when
`respectSentences` is true, with segmentation delegated to
`EideticLib.sentences` (Swift) / `eidetic_lib::segmenter::sentences`
(Rust); the apple-nlp-accel pattern lives in EideticLib alongside the
rest of the linguistic pipeline (EideticLib SPEC B-10, I-13). Each
emitted chunk carries an HLC drawn in order from the supplied
generator.

**B-1a (1.1 standalone passage policy):** new passage indexing uses the
selected provider tokenizer and `PassagePolicy.maxTokens` /
`overlapTokens`. It persists only canonical content id, revision/digest, and
UTF-8 range. The source document remains the sole text owner. This policy is
rejected in attached GLK mode.

**B-2 (BM25 scoring):** `BM25Index.search` scores with the
Robertson–Spärck-Jones formula (defaults k1 = 1.5, b = 0.75) using
`log(1 + (N − n + 0.5)/(n + 0.5))` IDF smoothing for non-negative
scores, returns at most `limit` results sorted by score descending
with ties broken by `id.uuidString` ascending, and returns `[]` for an
empty corpus, a non-positive limit, or an empty query token set.

**B-3 (index mutation):** `index` adds canonical content IDs to the inverted index;
`remove` deletes a document's postings and corrects the corpus length
statistics. The index is in-memory and rebuilt on demand from the configured
content source. The standalone 1.0 compatibility path may hydrate that source
from `BundleStore`.

**B-4 (standalone passage fan-out and fusion):** the compatibility
`HybridRecall.recall` surface pulls a
candidate window of `max(limit*4, 32)` from each of the vector and
keyword passes, converts each pass's rank to a Reciprocal Rank Fusion
contribution `weight / (rrfK + rank+1)`, sums the weighted
contributions per chunk, ranks by fused score descending with ties
broken by `id.uuidString` ascending, truncates to `limit`, and
hydrates the surviving chunks from the bundle store. A vector or
keyword sub-score that did not contribute is reported as `nil`. The
kNN pass is filtered to the supplied `modelID` (I-4). `limit <= 0`
returns `[]`.

**B-5 (standalone legacy insert idempotency surface):** `BundleStore.insert` performs a
plain insert per chunk and treats a duplicate-key rejection as the
documented no-op (I-3); it never upserts, because the append-only
triggers would abort the UPDATE branch.

**B-6 (provider tagging):** `embed` tokenizes via the provider's
`tokenizer`, runs the injected inference closure, and projects the
pooled float vector to an Engram through `FloatSimHash.project` with the
provider's stable `projectionSeed`. Two providers with distinct seeds
produce distinct engrams for the same pooled vector; one provider
produces bit-identical engrams across calls and across ports for the
same vector. `embedBatch` defaults to sequential `embed`.

**B-15 (standalone legacy expunge contract):** in the 1.0-compatible standalone
passage store, `Corpus.expunge(sourceID:)` is a two-step
irreversible operation. Step 1 scrubs the verbatim `text` field of every chunk
row for the source in `BundleStore` (setting it to empty string at the database
level before step 2); step 2 delegates to `Corpus.remove` (removes BM25 postings
and vector rows, marks the source removed in `RemovedSourceStore`). The scrub
commit is durable before the recall-removal step begins, so content is erased even
if step 2 fails. BundleStore rows survive with emptied `text` fields — the
append-only invariant (I-2) holds; chunk IDs, offsets, metadata, and HLC values
are preserved. `expunge` does NOT delete the rows and does NOT prevent reindex
from re-embedding the emptied chunks (which yield near-zero vectors — the source
remains recall-suppressed via I-15).

**B-16 (standalone legacy source-aggregated BM25):**
`Corpus.bm25TopKBySource(query:limit:)`
returns up to `limit` `(sourceID, score)` pairs, one per source, scored by the
MAXIMUM BM25 chunk score across that source's chunks. Used as the Hunter BM25
prefilter path: candidates are raw source handles, not chunk handles. Empty query,
empty token set after tokenization, or limit ≤ 0 returns []. Not fused with the
vector lane; the caller decides how to combine.

**B-17 (standalone legacy indexed source IDs):** `Corpus.indexedSourceIDs()` returns the set of
all source IDs present in the BundleStore (the append-only verbatim-chunk
universe). This includes sources that have been `remove`d or `expunge`d, because
BundleStore rows are never deleted. It is NOT the set of actively-recalled
sources. Callers that need the active recall set must exclude `RemovedSourceStore.removedIDs()`.

**B-7 (determinism):** content indexing, optional standalone passage boundary
derivation, BM25 scoring, and RRF
fusion are deterministic functions of their inputs. Time enters only as
the `now`/HLC value the caller supplies to the chunker; no engine calls
`Date()` for ordering logic except the chunker's HLC stamping helper,
which takes wall-clock millis as an argument in the Rust version and
should be supplied by the caller for deterministic runs.

**B-18 (operating-mode construction):** a `Corpus` is constructed with exactly
one content source. `standalone` construction creates or accepts a
`CorpusContentStore`; `attached` construction accepts a read/change source and
has no content mutation API. Both modes execute the same tokenizer, provider,
BM25, vector, ranking, invalidation, and error paths.

**B-19 (change-driven indexing):** the source exposes additions, revisions, and
deletions using canonical content IDs plus a monotonic cursor and content
revision/digest. CorpusKit reads current text from the source, replaces all
derived state for that content ID atomically, and advances its checkpoint only
after the derived writes commit. Retrying the same change batch is idempotent.

**B-20 (canonical-result fusion):** whole-content and optional passage lanes
fuse by `CorpusContentID`. A source with several matching passage units appears
once. The result may carry the winning range and lane subscores as evidence, but
hydration always resolves the canonical content object from the source.

**B-21 (GLK migration availability):** opening a pre-1.1 GLK database makes the
CorpusKit lane unavailable while its derived state is migrated and rebuilt.
LocusKit recall remains available. CorpusKit activates only after every active
indexed ID resolves directly to a GLK Drawer ID and no chunk-keyed CorpusKit rows
remain. Direct Drawer-keyed vectors outside CorpusKit provider partitions are
not deleted or recalculated.

## § 6 — Error model (conceptual)

CorpusKit raises `CorpusKitError` (Swift) / `CorpusKitError` (Rust).
The behavioral meaning of each category:

| Category | Trigger | Recovery posture |
|---|---|---|
| `encodingFailure` | standalone document/passage metadata or derived provider state could not be encoded | abort the write; surface to caller |
| `decodingFailure` | standalone content or derived state could not be decoded | surface; indicates schema/data corruption |
| `contentUnavailable` | the content source could not hydrate a referenced canonical ID/revision | keep the prior checkpoint; retry or surface degradation |
| `modeViolation` | a caller attempts standalone content mutation or passage configuration in attached GLK mode | reject before any write |
| `migrationIncomplete` | a pre-1.1 GLK corpus has not completed verified derived-state rebuild | keep CorpusKit dark; resume migration |
| `tokenizerUnavailable` | a provider's tokenizer could not be resolved | abort the embed; caller selects another provider |
| `modelUnavailable` | the backing model bundle is absent at runtime | abort the embed; caller falls back or reports |
| `embeddingFailed` | the injected inference closure failed | abort the embed; retry or surface |
| `storeUnavailable` | the underlying `Storage` / `VectorStore` was unreachable | abort the operation; retry after recovery |

Duplicate source-change delivery and duplicate-key rejection on the standalone
compatibility surface are NOT errors; they are idempotent no-ops caught
internally. The concrete enum shapes live in INTERFACE § 4.

## § 7 — Conformance requirements

**C-1 (standalone passage-id parity):** `Chunk.deriveID(sourceID:startOffset:text:)`
produces the same UUID in Swift and Rust for every shared
`(sourceID, startOffset, text)` vector, under the fixed namespace
(I-1, I-7).

**C-2 (standalone passage boundaries):** `Chunker.chunk` produces identical chunk
counts, offsets, lengths, and overlaps in both ports for identical text
and `ChunkerConfiguration` on the delimiter-fallback path (B-1, I-7).

**C-3 (BM25 ranking):** `BM25Index.search` returns the same ranked
`(id, score)` order in both ports for every shared corpus + query, with
the documented IDF smoothing and tie-break (B-2).

**C-4 (standalone legacy idempotent insert):** re-inserting a chunk with an existing id
leaves the chunks table unchanged and raises no error; the table count
is unchanged (I-3, B-5).

**C-5 (hybrid fusion):** `HybridRecall.recall` produces the same fused
ranking, the same `nil`-vs-present sub-score reporting, and the same
`modelID`-filtered candidate set in both ports for every shared fixture
(B-4, I-4, I-7).

**C-6 (projection parity):** for a given pooled float vector and
`projectionSeed`, `embed` yields a bit-identical Engram across calls and
across ports (B-6, inherits SubstrateLib FloatSimHash parity).

**C-7 (standalone legacy append-only enforcement):** the chunks table declared by
`BundleStore.schemaDeclaration` is `appendOnly`, and the sync manifest
declares the same table with the `.appendOnly` conflict policy
(I-2, § 5 B-5).

**C-9 (content-source conformance):** one black-box suite runs the same
add/revise/delete/reindex/recall/reopen trace against the standalone content
store and the GLK/LocusKit adapter. Both executions produce the same canonical
ID set, provider participation, lane scores, and invalidation behavior for the
same logical corpus.

**C-10 (GLK identity):** every CorpusKit result, BM25 document ID, and
CorpusKit-provider vector item ID produced in GLK mode is an active GLK Drawer
UUID. The GLK suite asserts there is no chunk-to-source translation map and no
result identity that fails direct Drawer hydration.

**C-11 (GLK no-copy):** the GLK composite schema contains no CorpusKit verbatim
content table or passage-text column. Capturing and indexing a Drawer changes
the canonical Drawer row and derived index tables only.

**C-12 (passage darkness):** GLK construction rejects or ignores every passage
policy other than `.wholeContent`, produces one logical index identity per
Drawer, and never invokes `Chunker` during capture, drain, reindex, or recall.

**C-13 (migration preservation):** fixtures containing 1.0 chunk rows,
chunk-keyed CorpusKit vectors, and unrelated Drawer-keyed vectors migrate to
1.1 with identical canonical Drawer/audit data, rebuilt CorpusKit rows keyed by
Drawer ID, no surviving chunk-keyed artifacts, and byte-identical unrelated
Drawer-keyed vectors.

## § 8 — Self-report telemetry

### 8.1 Overview

CorpusKit emits substrate self-report telemetry via IntellectusLib when
monitoring is enabled. Monitoring is **off** by default; the off-path
cost is a single `AtomicBool` load + branch per emit site, with no
allocation and no clock read.

Telemetry is added to two operations: `BundleStore.insert` and
`HybridRecall.recall`. Both Swift and Rust ports emit identically-named
metrics with the same tags and value semantics.

### 8.2 Emitted metrics

**BundleStore.insert** (2 metrics, emitted after the full batch completes):

| Metric name | Value | Tags |
|---|---|---|
| `corpuskit.ingest.latency_ms` | Wall time for the insert batch (ms, ≥ 0) | `kit=CorpusKit` |
| `corpuskit.ingest.chunk_count` | Count of chunks in the batch (including idempotent no-ops) | `kit=CorpusKit` |

An empty batch returns immediately with no metrics emitted (the early-return
guard precedes the start-time capture).

**HybridRecall.recall** (4 metrics, emitted after the result is assembled):

| Metric name | Value | Tags |
|---|---|---|
| `corpuskit.recall.latency_ms` | Wall time for the full recall pipeline (ms, ≥ 0) | `kit=CorpusKit`, `model_id=<modelID>` |
| `corpuskit.recall.vector_result_count` | Raw kNN candidate count before RRF fusion | `kit=CorpusKit`, `model_id=<modelID>` |
| `corpuskit.recall.keyword_result_count` | Raw BM25 candidate count before RRF fusion | `kit=CorpusKit`, `model_id=<modelID>` |
| `corpuskit.recall.result_count` | Final output count after RRF fusion and hydration | `kit=CorpusKit`, `model_id=<modelID>` |

`limit == 0` returns early before any emit (early-return guard matches the
normal control-flow guard).

### 8.3 Off-path guarantee

When `Intellectus.isEnabled` is `false` (the default), the `report!`/
`Intellectus.report` macro evaluates to a single atomic load + branch.
No timestamp is read, no payload is allocated, and no sink is called. The
return value and every side effect of the enclosing operation are unchanged.

### 8.4 Conformance

Both ports produce identically-named metrics with the same value semantics
(I-7). The telemetry conformance suites verify:

- **§1 disabled gate:** no `corpuskit.*` metric emitted when monitoring is off.
- **§2 enabled gate:** exact counts (2 for insert, 4 for recall) when on.
- **§3 metric shapes:** names, tags, and value ranges (latency ≥ 0, count == batch size).
- **§4 conformance:** recall results are byte-identical with monitoring on and off.

## § 9 — Corpus actor (public entry point)

### 9.1 Purpose

`Corpus` is the public entry point that seals content-source access, BM25,
VectorStore, and embedding providers behind one SDK surface. A standalone
consumer creates, updates, and deletes documents through the standalone facade.
An attached consumer advances source changes and recalls canonical content IDs.
No VectorKit type, Engram, model ID, or internal passage identity crosses the
public result boundary. This is the sealed-vector principle applied at the Kit
level: callers know canonical content and queries, not retrieval storage units.

### 9.2 EmbeddingModel enum

`EmbeddingModel` is a CorpusKit-owned enum. It lets the host select
an embedding model without importing VectorKit or naming an
EmbeddingProvider. Cases:

- `.deterministic` / `Deterministic` — FNV-1a hash through FloatSimHash;
  no model bundle required. The default. Suitable for tests and offline
  contexts; not for semantic retrieval.
- `.miniLM(inference:)` / `MiniLM { inference }` — MiniLM v6 (384-dim).
  Caller supplies the inference closure; CorpusKit handles FNV-1a
  tokenization (vocab 30522, max 128 tokens) and FloatSimHash projection.
- `.mpNet(inference:)` / `MPNet { inference }` — MPNet base v2 (768-dim).
  FNV-1a tokenization (vocab 30522, max 128 tokens).
- `.embeddingGemma(inference:)` / `EmbeddingGemma { inference }` —
  Embedding-Gemma 300M (768-dim, vocab 256000, max 2048 tokens).

Both ports ship all four cases. The inference closure is host-supplied on
every platform: Swift callers wrap a CoreML model; Rust callers wrap
whatever runtime the host chooses (the kit bundles no model weights and
links no ML-runtime crate). The seam payload is identical — token IDs in,
pooled float vector out — so for any shared (text → pooled vector) pair
the projected Engram is bit-identical across ports (B-6, C-6).

### 9.3 Behavioral contracts

**B-8 (sealed-vector and sealed-index-unit principle):** No VectorKit type or
internal passage type appears in a public `CorpusHit`. VectorStore, Engram,
EmbeddingProvider, StoredVector, VectorMatch, model ID, passage ID, and
passage-storage details are internal implementation concerns.

**B-9 (index fan-out):** indexing one content change reads the current
`CorpusContentRecord`, tokenizes and indexes it into BM25, embeds it through
each selected provider, and stores derived rows keyed by
`CorpusContentRecord.id`. In standalone passage mode the same work may fan out
over range-addressed index units, but the fan-in identity remains the canonical
content ID. In GLK mode the fan-out always uses the whole Drawer and the vector
item ID is the GLK Drawer ID.

**B-10 (recall delegation):** `Corpus.recall` embeds the query, runs compatible
BM25/vector lanes, fuses internal index-unit scores to canonical content IDs,
and returns `[CorpusHit]`. Hydration of content is performed through the
configured content source. `[ScoredChunk]` remains only on the standalone 1.0
compatibility API.

**B-11 (remove contract):** a source deletion removes BM25, vector, and index
checkpoint state for the canonical content ID. Canonical content deletion is
performed by the owning store: `CorpusContentStore` in standalone mode or
LocusKit through GLK in composed mode. CorpusKit never deletes GLK Drawer rows.

**B-12 (mode-specific schema init):** standalone construction applies the
standalone document schema plus CorpusKit/VectorKit derived schemas. Attached
GLK construction applies only derived CorpusKit/VectorKit schemas; the GLK
composite supplies LocusKit's Drawer schema and excludes CorpusKit document and
passage tables. Callers do not need to pre-open the selected schema set.

**B-13 (basis training lifecycle):** for a trainable distributional
provider (RI/PPMI/LSA/NMF):
- *Load-on-open:* `Corpus.init`/`open` reconstructs the trained provider
  from the persisted basis (when present for the provider key), so the
  dense lane is trained-ready immediately after restart with no retrain.
- *First-index auto-train:* when no basis is yet persisted, indexing the first
  source batch trains a FRESH basis on the current corpus snapshot and
  persists it; subsequent changes fold new canonical documents onto the FROZEN basis
  with no retrain (LSA/NMF cannot incrementally refactor a basis).
- *reindex:* `Corpus.reindex(now:)` trains a FRESH basis from scratch on
  the full corpus (reconstructed from the empty-basis blob, because
  `trainOnCorpus` is additive), UPSERTs it (I-9), and re-embeds every
  canonical content item (binary v0 + float v1) replacing stale vectors with no duplicate
  rows. The empty-basis factory is retained for EVERY trainable slot —
  including a reopened-from-basis corpus — so `reindex` retrains after a
  restart (the frozen-after-restart fix); a non-trainable provider makes
  `reindex` a vector refresh with no basis row written. (Rust retains the
  trainable capability across reopen via `reconstruct_trainable_basis`,
  since it cannot cross-cast a boxed provider the way Swift's `as?` does.)
- *Lifecycle:* `destroyRecallIndex` additionally deletes all basis rows
  AND all counts rows (no orphans). All paths are deterministic — `now` is
  the only clock source; the engine never reads the wall clock. Swift and
  Rust produce the byte-identical basis blob and embedding for a shared
  corpus (I-7): the ingest → reindex → reopen → embed path reproduces the
  canonical RI basis blob and embedding bit patterns byte-for-byte on both ports.

**B-14 (incremental maintained counts):** each trainable provider's raw
additive statistics are maintained in the `corpus_provider_counts` table
(`CorpusProviderCountsStore`) so a retrain reads the maintained table instead
of rebuilding from scratch. The accumulator (held SEPARATELY from the serving
provider, so growing the maintained vocabulary never desyncs an LSA/NMF serving
basis) is restored on open, folded once per indexed canonical document (`addToCounts`), and
persisted at BATCH boundaries (end of `ingest` / `ingestBatch` / `reindex`) —
never per provider row (O(N·vocab) would re-introduce the import wall). LSA/NMF persist
only the lightweight vocab + document-count anchor (TF re-derived by
re-tokenizing at refactor — the re-tokenize-at-refactor decision); RI/PPMI
persist their full additive state. `Corpus.maintainedVocabAnchor()` exposes the
maximum maintained vocabulary across trainable slots. The autonomic governor's
auto-reindex trigger (NeuronKit) fires on VOCABULARY growth —
`max(floor, ceil(fraction × lastReindexVocab))`, defaults floor 25 / fraction
0.10 — reading that anchor, replacing the prior +25-index-unit gate. The counts codec
is byte-identical across ports (the provider owns it via the
`TrainableEmbeddingBasis` counts seam).

The counts table is intentionally retained in attached GLK estates. It is not a
second content store: it contains provider-specific additive statistics, not
Drawer text. Removing it would either lose the vocabulary-growth governor's
restart continuity or require a full corpus tokenization pass on every open.
Reopen conformance therefore proves that the maintained vocabulary anchor is
restored before serving.

### 9.4 Conformance

**C-8 (Corpus parity):** Swift and Rust `Corpus` / `EmbeddingModelConfig`
produce identical canonical IDs, identical BM25 results, and identical fused
rankings for shared test vectors. Optional standalone passage mode additionally
inherits C-1…C-7. The deterministic
embedding (`.deterministic` / `Deterministic`) uses the same FNV-1a
64-bit hash, LCG constants, and FloatSimHash seed (`0xC05BD15CA15D1B00`)
in both ports.

**C-8b (named-provider embedding-seam parity):** for any shared
(text → pooled float vector) pair, `MiniLMTextProvider` / `MPNetTextProvider` /
`EmbeddingGemmaProvider` in `corpus-kit-providers` and the corresponding
`EmbeddingModelConfig::MiniLM` / `MPNet` / `EmbeddingGemma` cases in
`corpus-kit` produce bit-identical Engrams and float-lane vectors in Swift
and Rust. Both ports share the same projection seeds
(`MINLM_v1` = `0x4D49_4E4C_4D5F_7631`, `MPNET_v1` = `0x4D50_4E45_545F_7631`,
`EMBGM_v1` = `0x454D_4247_4D5F_7631`), the same FNV-1a tokenizer, and
the same FloatSimHash projection (inherits SubstrateLib C-6). Both ports
verify against a shared set of Swift-generated canonical embedding-provider
fixtures.

## § 10 — Corpus lifecycle (destroyRecallIndex)

Called by GeniusLocusKit estate teardown.

`destroyRecallIndex` (Swift) / `destroy_recall_index` (Rust) destroys the
Corpus's active recall capability without deleting canonical content:

**What is destroyed:**
- CorpusKit BM25 term-frequency and document-length rows
- CorpusKit-provider vector rows and their resident index state
- All persisted basis rows in `corpus_provider_basis` (via `BasisStore.deleteAll`)
  — no orphaned basis survives a destroyed corpus (I-9, B-13)
- All persisted counts rows in `corpus_provider_counts` (via
  `CorpusProviderCountsStore.deleteAll`) — no orphaned counts survive (B-14)
- All CorpusKit revision/checkpoint rows
- Standalone-only passage range rows when the standalone Corpus itself is
  destroyed

**What is preserved:**
- Canonical standalone documents when only the recall index is destroyed
- Canonical GLK Drawers, their audit/lineage state, and all LocusKit structures
- Every vector row outside CorpusKit's provider partitions

**Invariant:** teardown deletes by CorpusKit ownership scope. It MUST NOT call an
unqualified `VectorStore.destroyAllVectors()` against a shared GLK vector table,
because that would remove unrelated Drawer-keyed representations. GLK content
erasure remains the responsibility of the GLK/LocusKit verb lifecycle.

## § 11 — Ingest pipeline (queue + drain + worker pool)

CorpusKit is a standalone-capable database substrate: a `Corpus` owns its own encode
pipeline and drains itself with **no orchestrator**. This relocated from
GeniusLocusKit (the encode queue formerly lived in GLK's `EncodeIntake`); it
belongs here so every SDK consumer — CorpusKit-direct, no GLK — gets multi-core
encode, and so GeniusLocusKit is pure orchestration.

**Mechanism.** A Corpus mounts the **shared per-estate encrypted queue** as its
encode lane (T4 / the recall-driven dreaming contract Decision 7): a PersistenceKit backend over
`queue.sqlite` beside the estate — derived via
`EstateConfiguration.queueSibling("queue.sqlite")`, carrying the estate's
encryption key — for a SQLite estate; an in-memory PersistenceKit backend for an
ephemeral estate. (The previous plaintext `corpus_ingest_queue/` maildir is
gone — it spilled verbatim content to disk beside an encrypted estate.) Captures
are enqueued under **`stream_id = "encode"`**. Content mutation commits to the
owning store before enqueue in either mode. Every job then carries only
canonical content ID, revision/digest, and source cursor; Corpus resolves text
through its content source, so the queue never becomes a second content store.
The foreground
drain worker pulls every currently-available **`encode`-stream** job each pass
(stream-scoped drain, so a future dreaming drainer sharing the same `queue.sqlite`
is never disturbed) and ingests the whole batch via `ingestBatch` —
**cross-document parallel embed compute, serial batched writes** (the bounded
worker pool). The bulk enqueue is wrapped in one transaction and batch completion
uses the single-pass session update, so the batched-throughput wins hold on the
DB backend. The drain is a ~15 ms poll loop on both ports; the parallelism is
cross-document, so a reindex/burst encodes multi-core.

**Contracts (I-series numbering continues in INTERFACE § for the API):**
- **Idempotent at-least-once.** A job is replied terminal only after its index
  succeeds; a transient failure is retried in place (bounded, 8 attempts) —
  content ID + revision/digest makes source-change application idempotent, so retry never
  duplicates. A permanently-failing or undecodable job is replied `.blocked` so
  the queue never wedges.
- **Output identity.** Applying a change batch produces byte-identical vectors,
  BM25 postings, and canonical result IDs to applying each change individually —
  deterministic regardless of task/thread completion order. GLK rows are keyed
  by Drawer ID in both ports.
- **First-index training stays serial.** When a trainable provider slot still
  lacks a persisted basis, the batch falls back to serial indexing per item
  (training is a mutating, corpus-wide re-embed that cannot parallelize); every
  subsequent batch (basis frozen) takes the parallel fold-in path.
- **`onEncoded` coordination callback.** After each drained batch indexes, the
  Corpus fires an optional `onEncoded(sourceIDs)` callback. `nil` when standalone;
  an orchestrator (GeniusLocusKit) sets it to roll up the touched LocusKit rooms
  for the encoded drawers. CorpusKit never reaches into LocusKit itself —
  coordination is the orchestrator's job.
- **Determinism.** No `Date()`/wall-clock read inside the engine — the capture
  instant rides the job payload (`IngestJob`, ISO8601 with fractional seconds,
  byte-identical serde keys across ports).

**1.0 vs 1.1.** The 1.0 worker pool is per-corpus. The process-global
cross-estate CPU cap is the 1.1 central drain master
(`the deferred central-drain design`); ~70% of this (the `ingestBatch`
concurrent compute) carries forward unchanged — only the pool's location moves.

## Changelog

### 1.14.0 -- 2026-07-20

Accepted the 1.1 shared-content contract. CorpusKit now has standalone and
attached content-source modes over one indexing/retrieval engine. Standalone
CorpusKit remains a complete RAG database and may opt into token-budgeted
passage indexing using revision-bound ranges without copied passage text.
GeniusLocusKit injects a LocusKit-backed source, uses whole-Drawer indexing,
stores no duplicate CorpusKit content, and returns GLK Drawer IDs directly.
Added canonical-identity, GLK passage-darkness, conformance, and 1.0-to-1.1
derived-state migration requirements. The existing Chunk/Chunker/BundleStore
clauses are scoped to the standalone 1.0 compatibility surface.

### 1.13.0 -- 2026-07-16
Surface audit against both Swift and Rust source trees.

Added **I-15** (removed-source persistence): `RemovedSourceStore` records the
set of recall-suppressed source IDs so every rebuild path (reindex, IIS reload)
can exclude them. Schema kit-ID "CorpusKitRemovedSources" v1. Updated
`destroyRecallIndex` (§ 10 "what is destroyed") to include
`RemovedSourceStore.deleteAll()` — the omission was an oversight; the code
already deletes the rows; the spec now matches.

Added **B-15** (expunge contract): the two-step scrub-then-remove sequence, step
ordering guarantee (scrub durable before recall removal), and the statement that
expunged chunk rows survive with emptied text (append-only invariant holds).

Added **B-16** (source-aggregated BM25): `bm25TopKBySource` scores one result
per source (max chunk BM25 score), the Hunter BM25 prefilter path.

Added **B-17** (indexed source IDs): `indexedSourceIDs()` returns the
append-only universe (includes removed sources); callers who need the active
recall set must subtract `RemovedSourceStore.removedIDs()`.

### 1.12.0 -- 2026-06-25
T4 (the recall-driven dreaming contract Decision 7): the encode queue moved off its own plaintext
`corpus_ingest_queue/` maildir onto the **shared per-estate encrypted queue** —
a PersistenceKit backend over `queue.sqlite` beside the estate (via
`EstateConfiguration.queueSibling`, same encryption key) for SQLite estates,
InMemory for ephemeral. Encode jobs are streamed under `stream_id="encode"` and
drained stream-scoped, so a future dreaming drainer shares the same queue.sqlite
without collision; the drain lease is now QueueKit's stream-keyed `DrainLease`
(keyed `"encode"`), replacing CorpusKit's private lease (deleted). Security: the
plaintext content spill beside an encrypted estate is closed. Perf parity: bulk
enqueue is wrapped in one transaction (`PersistenceKitBackend.writeBatch`, both
ports) and batch completion uses the single-pass session update, so the batched
throughput holds on the DB backend.

### 1.11.0 -- 2026-06-25
T3 (single-drainer lease): the encode drain now holds a heartbeat-TTL lease
(`corpus_ingest_queue/drain.lease`) before draining. New behavioral invariant: at
most one process drains a durable estate's ingest queue at a time — every process
still mounts a drain worker, but a worker drains only while it holds the lease;
others stand by and take over within one TTL (15 s) if the holder dies. Internal
mechanism (no public API): heartbeat-TTL, not PID-liveness, so it is portable
(Windows/Linux) and dep/FFI-free. In-memory estates (single-process) take no
lease. Safety net: a rare brief two-drainer overlap during takeover is harmless
because ingest is idempotent (content-addressed chunk ids). Wall-clock here is
infrastructure (same exception as the drain telemetry clock).

### 1.10.0 -- 2026-06-25
T1 (encode QoS throttle): the embed fan-out is now bounded by an `EncodeSpeed`
(`foreground` = all logical cores; `background` = `cores / 4`, floor 1) set via
`Corpus.setEncodeSpeed`. New invariant: the embed throttle changes ONLY
scheduling/concurrency — stored chunks and vectors remain byte-identical to the
prior unbounded fan-out (rows are reassembled in input order). The cap is uniform
across platforms (`available_parallelism`/`activeProcessorCount`) and identical
Swift↔Rust (chunked-batch fan-out). Write strategy remains size-gated, separate
from speed.

### 1.9.0 -- 2026-06-25
Additive (T6 — drain status): exposed `Corpus.ingestQueueDepth` — a read-only
`(pending, inFlight)` probe of the ingest drain's frontiers. OBSERVES only;
never claims or drains, so it adds no invariant and does not alter the drain
contract or byte-identity. Returns `(0, 0)` when no queue is mounted.

### 1.8.0 -- 2026-06-24
Added B-14 (incremental maintained counts): the `corpus_provider_counts` table
(`CorpusProviderCountsStore`) keeps each trainable provider's raw additive
statistics current — restored on open, folded per written chunk (`addToCounts`),
persisted at batch boundaries (never per chunk). LSA/NMF persist the lightweight
vocab+doc anchor (TF re-tokenized at refactor); RI/PPMI persist full state. The
`TrainableEmbeddingBasis` counts seam (`addToCounts` / `serializeCounts` /
`restoreCounts` / `countsVocabularySize`) is the byte-identical cross-port codec.
Updated B-13: the empty-basis factory is now retained for every trainable slot,
so `reindex` retrains after restart (frozen-after-restart fix; Rust uses
`reconstruct_trainable_basis`). The autonomic governor's auto-reindex trigger
(NeuronKit) moved from a +25-chunk delta to a vocab-growth trigger
(`max(floor 25, ceil(0.10 × lastReindexVocab))`) reading
`Corpus.maintainedVocabAnchor()`. `destroyRecallIndex` now also deletes counts
rows. ADDITIVE — no existing surface changed.

### 1.6.0 -- 2026-06-23
Added § 11 — the Corpus-owned ingest pipeline (queue + drain + bounded worker
pool + `onEncoded` callback + `ingestBatch` parallel compute), relocated from
GeniusLocusKit's `EncodeIntake`. Added QueueKit to the § 3 dependency list
(downstream→upstream, no inversion; the in-memory PersistenceKit backend backs
the queue). No change to the existing recall / embedding / lifecycle contracts.

### 1.5.0 -- 2026-06-21
BundleStore schema v2 → v3 (NT-C1, the node-integrity contract §19): added nullable `content_hash` BLOB column to `chunks` table (hash-on-write via `HashingRowStore`); added `corpus_metadata` table (source_id TEXT PK, merkle_root BLOB nullable) for per-corpus Merkle roots; added `AsOfCoordinate` parameter to all six BundleStore query methods for temporal reads. New invariants: I-11 (hash-on-write), I-12 (as-of temporal reads), I-13 (per-corpus Merkle root). Updated I-10 reference from v2 to v3.

### 1.4.0 -- 2026-06-17
Added invariant I-10 (the `ext` forward-compat slot, the forward-compatible ext-slot contract): `chunks` (BundleStore v2) and `corpus_provider_basis` (BasisStore v2) each carry a nullable `.json` `ext` column, inert in 1.0; on `chunks` it is distinct from `metadata`. Pre-ship pre-provisioning during the 1.0.0 free-migration window.

### 1.3.0 -- 2026-06-17
Added the per-signal dense float FARTHEST (anti-similarity) contract (mission
6b-modifiers-antisim), ADDITIVE and back-compatible. `floatFarthestPerSignal` /
`float_farthest_per_signal` runs the dense lane in the FARTHEST direction for
every held signal — surfacing the most DISSIMILAR sources ("find things UNLIKE
this") via VectorKit `findFarthestFloat`. The per-source aggregation inverts
nearest's max-cosine to MIN-cosine (a source is unlike the query only if even
its closest chunk is far) and ranks least-similar first, sourceID ascending on
tie. Same outcome shape, dark-lane observability, telemetry, and slot ordering
as the nearest seam; floatNearestPerSignal is byte-identical and unchanged.
Cross-port conformance is RANK IDENTITY on shared fixtures (the float lane is
reproducible-within-config, not four-way bit-identical — arch spec §6). This is
the seam GLK's RecallShape `antiSimilarLanes` consumes.

### 1.2.0 -- 2026-06-17
Added the N-provider capability + per-signal nearest contract (mission
6a-iii-core), ADDITIVE and back-compatible. A Corpus MAY hold an ORDERED
collection of embedding providers (one slot per model, keyed by modelID);
`models[0]` is the DEFAULT signal that every single-signal operation (recall,
floatNearest, embed, embedFloat, modelID, supportsFloat) delegates to. Every
fan-out operation (ingest embed, reindex train, remove, destroy) runs across all
held slots, each under its own modelID — the VectorStore/BasisStore are already
keyed by (modelID, modelVersion), so N providers' rows coexist with NO schema
change. The single-provider corpus is the N=1 special case and remains
byte-identical to the 1.1.0 behaviour (the 6a-ii-β basis fixture passes
unchanged). New per-signal nearest behavior: `floatNearestPerSignal` returns one
ranked `FloatLaneOutcome` per held signal tagged by modelID, in slot order — the
6b RRF-fusion seam (no fusion in this contract). Cross-port conformance is RANK
IDENTITY: with all five distributional/co-classification models over a fixed
corpus, the per-signal ranked itemID order is identical Swift↔Rust; raw cosine
similarity is NOT asserted bit-identical (the float lane Lane D is
reproducible-within-config, not four-way bit-identical — arch spec §6). VectorKit
Lane D became per-modelID so float rows of differing dimension across models are
queried in isolation. The production default stays SINGLE provider; the
default-flip to all-five is a later mission (6a-iii-wire). No existing contract
changed.

### 1.7.0 -- 2026-06-24
Added invariant I-14 (Apple NL embedding providers — the Apple embedding-provider contract): `NLEmbeddingProvider`
and `NLContextualEmbeddingProvider` are Swift-only, opt-in, item-local providers
gated `#if canImport(NaturalLanguage)`. No Rust counterpart (sanctioned divergence).
Absent asset → `[]` / `.zero` (graceful opt-out; never crash, never throw). Projection
seeds "APNLEMB1" and "APNLCTX1" isolate their `model_id` partitions. Neither joins the
default ensemble. Updated `relates_to` to include the Apple embedding-provider contract.

### 1.1.0 -- 2026-06-17
Added the basis-persistence + training lifecycle contract (mission 6a-ii-β,
single provider): invariant I-9 (one basis row per `(model_id, model_version)`,
core-owned `corpus_provider_basis` table, TEXT-ISO8601 dates, no Bool columns,
primitive-tolerant decode) and behavior B-13 (load-on-open, first-ingest
auto-train, `reindex` fresh-basis retrain + re-embed, lifecycle basis wipe; all
deterministic, byte-identical cross-port). Updated B-12 to note the third
(BasisStore) schema applied at init. Additive; no existing contract changed.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
