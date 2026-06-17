---
title: CorpusKit Specification
version: 1.1.0
status: active
date: 2026-06-17
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
backend and schema declaration), ConvergenceKit (the `SyncManifest`
type), VectorKit (`VectorStore` for the kNN pass). The
`CorpusKitProviders` target additionally depends on the core `CorpusKit`
target.

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
  rows. A non-trainable provider — or a reopened-from-basis corpus — makes
  `reindex` a vector refresh with no basis row written.
- *Lifecycle:* `destroyRecallIndex` additionally deletes all basis rows
  (no orphans). All paths are deterministic — `now` is the only clock
  source; the engine never reads the wall clock. Swift and Rust produce
  the byte-identical basis blob and embedding for a shared corpus (I-7):
  the ingest → reindex → reopen → embed path reproduces the canonical RI
  basis blob and embedding bit patterns byte-for-byte on both ports.

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

## Changelog

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
