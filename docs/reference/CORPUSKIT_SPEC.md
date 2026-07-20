---
title: CorpusKit Specification
version: 1.13.0
status: active
date: 2026-07-16
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

CorpusKit is the retrieval-augmented-generation layer of the
GeniusLocus substrate. It takes source documents, splits them into
overlapping text chunks, stores those chunks in a content-addressed
append-only table, builds a BM25 inverted index over their text, and
fuses vector nearest-neighbour hits (from VectorKit) with BM25 keyword
hits into a single ranked list of `ScoredChunk`s. It also defines the
`Tokenizer` protocol used by its concrete embedding providers (MiniLM,
mpnet, EmbeddingGemma), which conform to VectorKit's `EmbeddingProvider`;
the providers ship in a separate
`CorpusKitProviders` target so the core kit pulls in no model weights.

CorpusKit is the **content half** of a content-plus-vector bundle; the
vector half — embeddings, the ANN index, model tagging — lives in
VectorKit. The two are joined by convention: a chunk's `id` (as a UUID
string) is the `drawerID` of its stored vector under the same
`modelID`. CorpusKit holds content *for retrieval* only. It does not
record knowledge-graph facts, audit history, typed tunnels, or diary
entries; those are LocusKit's concern (content *for memory*).

This package is a **Kit**: it manages persistent state (the chunks
table behind an actor) and a lifecycle (ingest → index → recall), as
opposed to a stateless math Lib.

## § 2 — Scope

This specification defines:

- Sentence-aware chunking with configurable target size and overlap.
- The `Chunk` content model and its content-addressed identity (a
  deterministic RFC 4122 v5 UUID over `(sourceID, startOffset, text)`).
- Append-only, idempotent chunk storage in the `BundleStore` actor.
- The in-memory BM25 inverted index and its scoring contract.
- Hybrid recall: candidate-window fan-out, Reciprocal Rank Fusion of
  vector and keyword hits, and deterministic ranking.
- The `Tokenizer` protocol, the concrete embedding providers (which
  conform to VectorKit's `EmbeddingProvider`), and the
  model-tagging discipline that forbids cross-model comparison.
- The per-estate sync manifest declaring the chunks table append-only.

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

**I-1 (content-addressed identity):** a `Chunk.id` is the RFC 4122 v5
UUID derived from `(sourceID, startOffset, text)` under the fixed
CorpusKit namespace `d6f3a1b2-7c84-4e5f-9a0b-1c2d3e4f5061`. Identical
content yields an identical id; the namespace MUST NOT change, since
changing it re-keys every chunk fleet-wide and breaks the vector join.

**I-2 (append-only chunks):** the chunks table is append-only. A chunk
is never edited or deleted in place. The `BundleStore` exposes no
per-row update or delete; the PersistenceKit append-only triggers abort
any BEFORE UPDATE / BEFORE DELETE at the substrate.

**I-3 (idempotent ingestion):** inserting a chunk whose id is already
stored is a no-op (first write wins). Combined with I-1 this makes
re-ingestion and cross-device duplicate arrival idempotent.

**I-4 (no cross-model comparison):** every Engram is tagged with the
`modelID` (and `modelVersion`) of the provider that produced it.
Retrieval filters the kNN pass to a single `modelID`, so engrams from
different models are never compared. Model identity is part of the
stored bundle, not just the inference call.

**I-5 (vector join by convention):** a chunk is joined to its stored
vector by `chunk.id.uuidString == storedVector.drawerID` under the same
`modelID`. CorpusKit owns the content row; VectorKit owns the vector
row; nothing else mediates the join.

**I-6 (verbatim chunk text):** the kit stores chunk text exactly as
chunked — it does not normalize, lowercase, or trim. Normalization is a
tokenizer concern applied at index/query time, not at storage time.

**I-7 (cross-port parity):** the Swift and Rust ports produce
byte-identical chunk ids, identical chunk boundaries for identical
configuration, identical BM25 rankings, and identical RRF fusion for
every shared test vector. Neither port leads.

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

**I-10 (`ext` forward-compat slot, the forward-compatible ext-slot contract):** both persistent entity tables
carry one nullable `.json` column named `ext` — `chunks` at BundleStore schema
v3 and `corpus_provider_basis` at BasisStore ("CorpusKitBasis") schema v2. On
`chunks` it is distinct from the existing per-chunk `metadata` column. In 1.0
`ext` is inert — written NULL / omitted on insert/upsert and never read; it
carries no behavior. Provisioned during the 1.0.0 free-migration window. See
the forward-compatible ext-slot contract.

**I-11 (hash-on-write, the node-integrity contract §19):** every chunk insert computes a
`content_hash` via `MerkleHash.leaf` (SubstrateLib) and stores it in the
nullable `content_hash` BLOB column added in schema v3. The hash is computed
by the `HashingRowStore` decorator wrapping the `RowStore` and fed by a
`ContentHashProvider` callback specific to CorpusKit (text content hashed).
The `content_hash` column is nullable to tolerate rows written before v3;
new inserts always populate it.

**I-12 (as-of temporal reads, the node-integrity contract §19):** all six `BundleStore` query
methods (`get`, `getMany`, `chunksForSource`, `count`, `allChunks`, and
the internal `affectedSourceIDs`) accept an `AsOfCoordinate` parameter
(`.present` or `.asOf(HLC)`). In the current implementation, only methods
backed by `RowStore.query` forward the coordinate; `count` accepts the
parameter for API parity but does not filter temporally (PersistenceKit's
`RowStore.count` has no as-of variant).

**I-13 (per-corpus Merkle root):** the `corpus_metadata` table (added in
BundleStore schema v3) stores one row per source_id with its Merkle root.
After each insert batch, `BundleStore` recomputes the Merkle root for each
affected source by hashing all chunk `content_hash` values for that source
via `MerkleHash.interior`. The `corpusMerkleRoot(for:)` query returns the
per-corpus root (or `MerkleRoot.empty` if no chunks exist for that source).
The `globalCorpusMerkleRoot()` query computes the interior hash over all
per-corpus roots, enabling an estate-level integrity check across all
corpora.

**I-15 (removed-source persistence):** `RemovedSourceStore` records the set of
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

## § 5 — Behavioral contracts

**B-1 (chunk overlap):** `Chunker.chunk` emits chunks of at most
`targetChars` (after sentence packing), each overlapping the previous by
`min(overlapChars, chunk length)` characters; `overlapChars` is clamped
to `[0, targetChars-1]`. Sentence boundaries are respected when
`respectSentences` is true, with segmentation delegated to
`EideticLib.sentences` (Swift) / `eidetic_lib::segmenter::sentences`
(Rust); the apple-nlp-accel pattern lives in EideticLib alongside the
rest of the linguistic pipeline (EideticLib SPEC B-10, I-13). Each
emitted chunk carries an HLC drawn in order from the supplied
generator.

**B-2 (BM25 scoring):** `BM25Index.search` scores with the
Robertson–Spärck-Jones formula (defaults k1 = 1.5, b = 0.75) using
`log(1 + (N − n + 0.5)/(n + 0.5))` IDF smoothing for non-negative
scores, returns at most `limit` results sorted by score descending
with ties broken by `id.uuidString` ascending, and returns `[]` for an
empty corpus, a non-positive limit, or an empty query token set.

**B-3 (index mutation):** `index` adds documents to the inverted index;
`remove` deletes a document's postings and corrects the corpus length
statistics. The index is in-memory, rebuilt on demand from the bundle
store.

**B-4 (hybrid fan-out and fusion):** `HybridRecall.recall` pulls a
candidate window of `max(limit*4, 32)` from each of the vector and
keyword passes, converts each pass's rank to a Reciprocal Rank Fusion
contribution `weight / (rrfK + rank+1)`, sums the weighted
contributions per chunk, ranks by fused score descending with ties
broken by `id.uuidString` ascending, truncates to `limit`, and
hydrates the surviving chunks from the bundle store. A vector or
keyword sub-score that did not contribute is reported as `nil`. The
kNN pass is filtered to the supplied `modelID` (I-4). `limit <= 0`
returns `[]`.

**B-5 (insert idempotency surface):** `BundleStore.insert` performs a
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

**B-15 (expunge contract):** `Corpus.expunge(sourceID:)` is a two-step
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

**B-16 (source-aggregated BM25):** `Corpus.bm25TopKBySource(query:limit:)`
returns up to `limit` `(sourceID, score)` pairs, one per source, scored by the
MAXIMUM BM25 chunk score across that source's chunks. Used as the Hunter BM25
prefilter path: candidates are raw source handles, not chunk handles. Empty query,
empty token set after tokenization, or limit ≤ 0 returns []. Not fused with the
vector lane; the caller decides how to combine.

**B-17 (indexed source IDs):** `Corpus.indexedSourceIDs()` returns the set of
all source IDs present in the BundleStore (the append-only verbatim-chunk
universe). This includes sources that have been `remove`d or `expunge`d, because
BundleStore rows are never deleted. It is NOT the set of actively-recalled
sources. Callers that need the active recall set must exclude `RemovedSourceStore.removedIDs()`.

**B-7 (determinism):** chunking, id derivation, BM25 scoring, and RRF
fusion are deterministic functions of their inputs. Time enters only as
the `now`/HLC value the caller supplies to the chunker; no engine calls
`Date()` for ordering logic except the chunker's HLC stamping helper,
which takes wall-clock millis as an argument in the Rust version and
should be supplied by the caller for deterministic runs.

## § 6 — Error model (conceptual)

CorpusKit raises `CorpusKitError` (Swift) / `CorpusKitError` (Rust).
The behavioral meaning of each category:

| Category | Trigger | Recovery posture |
|---|---|---|
| `encodingFailure` | chunk metadata could not be JSON-encoded for storage | abort the insert; surface to caller |
| `decodingFailure` | a stored row could not be decoded back into a `Chunk` | surface; indicates schema/data corruption |
| `tokenizerUnavailable` | a provider's tokenizer could not be resolved | abort the embed; caller selects another provider |
| `modelUnavailable` | the backing model bundle is absent at runtime | abort the embed; caller falls back or reports |
| `embeddingFailed` | the injected inference closure failed | abort the embed; retry or surface |
| `storeUnavailable` | the underlying `Storage` / `VectorStore` was unreachable | abort the operation; retry after recovery |

Duplicate-key rejections on insert are NOT errors — they are the
idempotent no-op of I-3 / B-5 and are caught internally. The concrete
enum shapes live in INTERFACE § 4.

## § 7 — Conformance requirements

**C-1 (id parity):** `Chunk.deriveID(sourceID:startOffset:text:)`
produces the same UUID in Swift and Rust for every shared
`(sourceID, startOffset, text)` vector, under the fixed namespace
(I-1, I-7).

**C-2 (chunk boundaries):** `Chunker.chunk` produces identical chunk
counts, offsets, lengths, and overlaps in both ports for identical text
and `ChunkerConfiguration` on the delimiter-fallback path (B-1, I-7).

**C-3 (BM25 ranking):** `BM25Index.search` returns the same ranked
`(id, score)` order in both ports for every shared corpus + query, with
the documented IDF smoothing and tie-break (B-2).

**C-4 (idempotent insert):** re-inserting a chunk with an existing id
leaves the chunks table unchanged and raises no error; the table count
is unchanged (I-3, B-5).

**C-5 (hybrid fusion):** `HybridRecall.recall` produces the same fused
ranking, the same `nil`-vs-present sub-score reporting, and the same
`modelID`-filtered candidate set in both ports for every shared fixture
(B-4, I-4, I-7).

**C-6 (projection parity):** for a given pooled float vector and
`projectionSeed`, `embed` yields a bit-identical Engram across calls and
across ports (B-6, inherits SubstrateLib FloatSimHash parity).

**C-7 (append-only enforcement):** the chunks table declared by
`BundleStore.schemaDeclaration` is `appendOnly`, and the sync manifest
declares the same table with the `.appendOnly` conflict policy
(I-2, § 5 B-5).

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

`Corpus` is the public entry point that seals the composition of
BundleStore, BM25Index, VectorStore, and an EmbeddingProvider behind
a four-verb SDK surface. A consumer calls `ingest`, `recall`, `remove`,
and `count` — no vector type, no Engram, no chunk id, no model id ever
crosses the public API boundary. This is the sealed-vector principle
applied at the kit level: the caller knows documents and queries, not
the internals of how retrieval works.

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

**B-8 (sealed-vector principle):** No VectorKit type appears in any
public signature of `Corpus` or `EmbeddingModel`. VectorStore, Engram,
EmbeddingProvider, StoredVector, VectorMatch, drawerID, and modelID are
internal implementation details; the caller never names them.

**B-9 (ingest fan-out):** `Corpus.ingest` executes the full RAG fan-out
in one call: chunk via Chunker, insert into BundleStore (idempotent on
content-addressed ids), index into BM25, embed via the selected provider,
and store vectors in VectorStore with `drawerID = chunk.id.uuidString`.
The chunk.id == vector.drawerID join (I-5) is maintained internally.

**B-10 (recall delegation):** `Corpus.recall` embeds the query and
delegates to `HybridRecall.recall`, passing the internal VectorStore,
BM25Index, and BundleStore. The caller receives `[ScoredChunk]`.

**B-11 (remove contract):** `Corpus.remove(sourceID:)` removes the
source's chunks from BM25 and deletes their vectors from VectorStore.
BundleStore is append-only (I-2); chunk rows are not deleted. `count()`
therefore does not decrease after `remove`; only recall results change.

**B-12 (dual-schema init):** `Corpus.init` applies the BundleStore,
VectorStore, AND BasisStore schemas to the supplied Storage via
`migrate(to:)`, which bypasses the version gate that would otherwise skip
the second/third schema application when the kits share version 1. The
caller does not need to pre-open schemas.

**B-13 (basis training lifecycle):** for a trainable distributional
provider (RI/PPMI/LSA/NMF):
- *Load-on-open:* `Corpus.init`/`open` reconstructs the trained provider
  from the persisted basis (when present for the provider key), so the
  dense lane is trained-ready immediately after restart with no retrain.
- *First-ingest auto-train:* when no basis is yet persisted, the first
  `ingest` trains a FRESH basis on the current corpus snapshot and
  persists it; subsequent ingests fold new chunks onto the FROZEN basis
  with no retrain (LSA/NMF cannot incrementally refactor a basis).
- *reindex:* `Corpus.reindex(now:)` trains a FRESH basis from scratch on
  the full corpus (reconstructed from the empty-basis blob, because
  `trainOnCorpus` is additive), UPSERTs it (I-9), and re-embeds every
  chunk (binary v0 + float v1) replacing stale vectors with no duplicate
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
basis) is restored on open, folded once per written chunk (`addToCounts`), and
persisted at BATCH boundaries (end of `ingest` / `ingestBatch` / `reindex`) —
never per chunk (O(N·vocab) would re-introduce the import wall). LSA/NMF persist
only the lightweight vocab + document-count anchor (TF re-derived by
re-tokenizing at refactor — the re-tokenize-at-refactor decision); RI/PPMI
persist their full additive state. `Corpus.maintainedVocabAnchor()` exposes the
maximum maintained vocabulary across trainable slots. The autonomic governor's
auto-reindex trigger (NeuronKit) fires on VOCABULARY growth —
`max(floor, ceil(fraction × lastReindexVocab))`, defaults floor 25 / fraction
0.10 — reading that anchor, replacing the prior +25-chunk gate. The counts codec
is byte-identical across ports (the provider owns it via the
`TrainableEmbeddingBasis` counts seam).

### 9.4 Conformance

**C-8 (Corpus parity):** Swift and Rust `Corpus` / `EmbeddingModelConfig`
produce identical chunk ids, identical BM25 results, and identical fused
rankings for shared test vectors (inherits C-1…C-7). The deterministic
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
Corpus's active recall capability without deleting verbatim content:

**What is destroyed:**
- BM25 index entries (all chunks removed from the in-memory BM25 index)
- `chunk_source_map` (in-memory reverse map cleared)
- All vector rows in the internal VectorStore (via `destroyAllVectors`)
- All persisted basis rows in `corpus_provider_basis` (via `BasisStore.deleteAll`)
  — no orphaned basis survives a destroyed corpus (I-9, B-13)
- All persisted counts rows in `corpus_provider_counts` (via
  `CorpusProviderCountsStore.deleteAll`) — no orphaned counts survive (B-14)
- All removed-source rows in `removed_sources` (via
  `RemovedSourceStore.deleteAll`) — no orphaned removal records survive (I-15)

**What is preserved:**
- BundleStore `chunks` rows — the append-only invariant holds. Verbatim
  content survives for audit and retention purposes. This is intentional:
  destroying a MOOT invalidates its active recall surface, not its stored
  verbatim content. A future storage-erasure primitive (redaction/compaction
  layer) handles verbatim content erasure separately.

**Invariant:** `destroyRecallIndex` calls the Corpus's internal VectorStore's
`destroyAllVectors` — it does NOT need to be called separately by the caller.
The caller (GLK's `destroy`) additionally calls `destroyAllVectors` on any
_standalone_ VectorStore registered for the estate (which uses separate storage
from the Corpus's internal VectorStore in the `.glk` / separate-corpusStorage
case).

## § 11 — Ingest pipeline (queue + drain + worker pool)

CorpusKit is a standalone database substrate: a `Corpus` owns its own encode
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
are enqueued under **`stream_id = "encode"`** (`enqueueIngest`); the foreground
drain worker pulls every currently-available **`encode`-stream** job each pass
(stream-scoped drain, so a future dreaming drainer sharing the same `queue.sqlite`
is never disturbed) and ingests the whole batch via `ingestBatch` —
**cross-document parallel embed compute, serial batched writes** (the bounded
worker pool). The bulk enqueue is wrapped in one transaction and batch completion
uses the single-pass session update, so the batched-throughput wins hold on the
DB backend. The drain is a ~15 ms poll loop on both ports; the parallelism is
cross-document, so a reindex/burst encodes multi-core.

**Contracts (I-series numbering continues in INTERFACE § for the API):**
- **Idempotent at-least-once.** A job is replied terminal only after its ingest
  succeeds; a transient failure is retried in place (bounded, 8 attempts) —
  `ingest` is idempotent (content-addressed chunk ids), so retry never
  duplicates. A permanently-failing or undecodable job is replied `.blocked` so
  the queue never wedges.
- **Output identity.** `ingestBatch([items])` produces byte-identical chunks,
  vectors, and BM25 postings to calling `ingest` once per item — deterministic
  regardless of task/thread completion order (rows keyed by chunk id; written in
  item order on both ports).
- **First-ingest training stays serial.** When a trainable provider slot still
  lacks a persisted basis, the batch falls back to serial `ingest` per item
  (training is a mutating, corpus-wide re-embed that cannot parallelize); every
  subsequent batch (basis frozen) takes the parallel fold-in path.
- **`onEncoded` coordination callback.** After each drained batch ingests, the
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
