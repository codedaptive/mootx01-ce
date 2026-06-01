---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: CorpusKit
kind: Kit
relates_to:
  - CORPUSKIT_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - VECTORKIT_SPEC_v0.8.md  (the vector half of the content-plus-vector bundle)
  - PERSISTENCEKIT_SPEC_v0.8.md  (the storage backend the bundle store writes to)
  - CONVERGENCEKIT_SPEC_v0.8.md  (the sync manifest the chunks table travels under)
  - ENGRAMLIB_SPEC_v0.8.md  (the 256-bit Engram embeddings project to)
  - SUBSTRATELIB_SPEC_v0.8.md  (HLC, FloatSimHash projection)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (the RAG layer in the kit graph)
purpose: |
  CorpusKit is the content-plus-vector RAG layer of the GeniusLocus
  substrate. It owns the "content half" of a retrieval bundle —
  sentence-aware chunking, content-addressed chunk storage, an in-memory
  BM25 keyword index, and hybrid (vector + keyword) recall fused by
  Reciprocal Rank Fusion — and the tokenizer protocol plus three concrete
  embedding providers (conforming to VectorKit's `EmbeddingProvider`) that
  produce the model-tagged Engrams VectorKit indexes. It
  is content-for-retrieval, not content-for-memory: it holds no KG facts,
  no audit trail, no tunnels, and no diary (those are LocusKit). The
  companion INTERFACE document carries the signatures.
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
mpnet, EmbeddingGemma), which conform to VectorKit's `EmbeddingProvider`
(F11 consolidation, 2026-05-27); the providers ship in a separate
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
  conform to VectorKit's `EmbeddingProvider` per F11), and the
  model-tagging discipline that forbids cross-model comparison.
- The per-estate sync manifest declaring the chunks table append-only.

This specification does NOT define:

- API signatures — those live in `CORPUSKIT_INTERFACE_v0.8.md`.
- Embedding storage, the ANN/HNSW index, or `VectorStore.findNearest`
  ordering — those are VectorKit's (`VECTORKIT_SPEC_v0.8.md`).
- The `Storage` row-store backend, schema declaration semantics, or
  append-only trigger mechanics — those are PersistenceKit's
  (`PERSISTENCEKIT_SPEC_v0.8.md`).
- CloudKit zone mechanics or conflict-policy execution — those are
  ConvergenceKit's (`CONVERGENCEKIT_SPEC_v0.8.md`).
- KG facts, audit trail, tunnels, diary — those are LocusKit's
  (`LOCUSKIT_SPEC_v0.8.md`).

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
`EideticLib.sentences`, F16 2026-05-27), PersistenceKit (the `Storage`
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
providers (F11 consolidation, 2026-05-27). Concrete providers and
their tokenizers live in `CorpusKitProviders`, so a consumer that
needs only bundle storage and BM25 pulls in no CoreML model code.

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
