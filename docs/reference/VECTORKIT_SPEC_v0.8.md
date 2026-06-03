---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: VectorKit
kind: Kit
relates_to:
  - VECTORKIT_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - ENGRAMLIB_SPEC_v0.8.md  (the typed 256-bit Engram and its similarity operations)
  - SUBSTRATELIB_SPEC_v0.8.md  (the canonical FloatSimHash projection this kit calls)
  - PERSISTENCEKIT_SPEC_v0.8.md  (the Storage/RowStore backend the vector store wraps)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (rung-3 vectors, invariants I-4 and I-12)
  - DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md  (storage moved onto PersistenceKit)
purpose: |
  VectorKit is the on-device embedding and approximate-nearest-neighbour
  layer for one estate. It defines the `EmbeddingProvider` abstraction
  (text → model-tagged 256-bit `Engram`), the built-in deterministic
  `FloatSimHashEmbeddingProvider`, and a PersistenceKit-backed
  `VectorStore` that holds one model-tagged vector per (drawer, model)
  pair and answers Hamming-distance nearest-neighbour and coarse keyword
  queries. Every stored vector carries the identity and version of the
  model that produced it, so mixed-version corpora stay filterable and
  cross-model comparisons are structurally prevented. The companion
  INTERFACE document carries the signatures.
---

# VectorKit Specification

## § 1 — What this package is

VectorKit is the substrate kit that turns text into vectors and finds
the nearest stored vectors to a probe. It does two jobs and only two:
it generates embeddings through the `EmbeddingProvider` abstraction, and
it stores and retrieves those embeddings through `VectorStore`. A vector
in this kit is a 256-bit `Engram` (EngramLib's typed fingerprint), and
"nearest" means smallest Hamming distance over that engram.

Every embedding is tagged at generation with the producing model's
stable identity (`modelID`) and weights version (`modelVersion`), and
that tag is persisted on the storage row and carried back on every
match. This is the kit's organizing constraint: a Hamming distance is
only meaningful between two engrams produced by the same model at the
same weights, so the model tag is a first-class field on the provider,
on the stored row, and on the match result — never an out-of-band
bookkeeping concern. This realizes architecture invariant I-4 (every
model-generated rung carries `model_id` and `model_version`) for rung-3
vectors.

This package is a **Kit**: it manages persisted state (the `vectors`
table) and has a lifecycle (an opened `Storage` handle). It does not own
tokenizers, model bundles, model identity, or BM25 keyword scoring —
those live in CorpusKit. VectorKit supplies the low-level building block
("host supplies inference, kit supplies the canonical projection and the
model-tagged store"); CorpusKit composes it into RAG bundles.

## § 2 — Scope

This specification defines:

- The `EmbeddingProvider` abstraction and its empty-input contract.
- The built-in `FloatSimHashEmbeddingProvider`: host-supplied inference
  closure projected through SubstrateLib's canonical FloatSimHash.
- The `StoredVector` storage record and its model-tag fields.
- The `VectorStore` CRUD surface, its schema, and its
  one-row-per-(drawer, model) upsert semantics.
- Hamming-distance nearest-neighbour retrieval (`findNearest`) and its
  ordering, including the model-scoped query filter.
- The coarse keyword pre-filter (`findByKeyword`) and its boundary
  against CorpusKit's BM25 ownership.
- The `VectorMatch` result type and its ordering.

This specification does NOT define:

- API signatures — those live in `VECTORKIT_INTERFACE_v0.8.md`.
- The fingerprint representation, kernel dispatch, or the FloatSimHash
  projection math — those are SubstrateLib's (`SUBSTRATELIB_SPEC_v0.8.md`).
- Hamming distance, batch distance, and the k-nearest primitive over
  engrams — those are EngramLib's (`ENGRAMLIB_SPEC_v0.8.md`); VectorKit
  delegates to them.
- The storage backend (SQLite + sqlite-vec, PostgreSQL + pgvector,
  InMemory), backend selection, and the row/vector index protocols —
  those are PersistenceKit's (`PERSISTENCEKIT_SPEC_v0.8.md`).
- Tokenization, model bundles, model identity assignment, BM25 keyword
  scoring, and RAG bundle composition — those are CorpusKit's.

## § 3 — Position in the kit family

```
SubstrateLib          PersistenceKit
   ▲   (FloatSimHash)     ▲   (Storage / RowStore)
EngramLib                 │
   ▲   (Engram, distance) │
   └──────────┬───────────┘
          VectorKit        ← this package
              ▲
          CorpusKit        (RAG bundles: content + model-tagged vectors)
              ▲
        GeniusLocusKit     (composition layer, N estates)
```

**Depends on:** EngramLib (the `Engram` type and the Hamming
nearest-neighbour primitive), SubstrateLib (the canonical FloatSimHash
projection), PersistenceKit (the `Storage` / `RowStore` backend),
Foundation, OSLog.

**Consumed by:** CorpusKit. CorpusKit's `HybridRecall` takes a
`VectorStore` directly, and its three concrete embedding providers
(`MiniLMTextProvider`, `MPNetTextProvider`, `EmbeddingGemmaProvider`)
conform to VectorKit's `EmbeddingProvider` directly (F11 consolidation,
2026-05-27), building on the canonical FloatSimHash projection that
`FloatSimHashEmbeddingProvider` also uses. GeniusLocusKit composes
CorpusKit transitively.

## § 4 — Invariants

**I-1 (model tag is mandatory):** every embedding generated and every
vector stored carries a `modelID` and `modelVersion`. The provider
declares them, `addVector` persists them, and `VectorMatch` carries the
`modelID` back. There is no path that stores or returns an untagged
vector. This is VectorKit's realization of architecture invariant I-4.

**I-2 (cross-model comparison is forbidden):** a Hamming distance is
only meaningful between engrams produced by the same `(modelID,
modelVersion)`. `findNearest` therefore filters candidates to a single
`modelID` before scoring; it never compares a probe against a vector
from another model. Distinct FloatSimHash projection seeds enforce the
same separation at the projection layer — the same float vector under
two seeds yields two unrelated engrams.

**I-3 (one vector per drawer per model):** the `vectors` table carries a
UNIQUE constraint on `(drawer_id, model_id)`. A second write for the
same pair updates the existing row in place rather than inserting a
duplicate; the row's stable `id` survives the upsert. A single drawer
may hold several vectors only when they come from distinct models.

**I-4 (engram is the vector):** the stored vector IS the canonical
FloatSimHash projection of the model's float output — a 256-bit
`Engram`. There is no separate dense-float column and no reconstruction
step. The engram is persisted as a 32-byte BLOB (four little-endian
`UInt64` blocks).

**I-5 (empty input is the zero engram):** every `EmbeddingProvider`
returns the substrate's canonical zero engram (`Engram.zero` /
`Engram::ZERO`) for the empty string, short-circuiting before the
inference closure runs. This is the cross-provider contract: empty-text
rows from any provider collide on the same Hamming-distance-0 partition.

**I-6 (kit does not see the backend):** `VectorStore` wraps an
already-opened `Storage` handle and issues only `RowStore` operations.
It does not select, name, or branch on the backend (SQLite, PostgreSQL,
InMemory); backend selection is an application-layer concern via
`EstateConfiguration`. Per architecture invariant I-12, the substrate
provides storage and the application does not bring its own.

**I-7 (delegation of distance):** VectorKit performs no Hamming math of
its own. `findNearest` delegates the batch bitcount to EngramLib, which
routes to the substrate kernel (BNNS / NEON accelerated where
available). VectorKit therefore inherits EngramLib's and SubstrateLib's
scalar-reference and cross-leg parity guarantees.

## § 5 — Behavioral contracts

**B-1 (provider determinism):** for a fixed inference closure and
projection seed, `embed(text)` is deterministic — the same text yields
the same engram across calls and across the Swift and Rust versions
(FloatSimHash is bit-identical per the substrate conformance harness).

**B-2 (provider error surface):** `embed` surfaces inference failure as
`embeddingFailed` carrying the underlying reason, and an unloaded /
unavailable model as `modelUnavailable`. The empty-input short-circuit
(I-5) cannot fail.

**B-3 (upsert in place):** `addVector` for an existing `(drawerID,
modelID)` updates that row — its `model_version`, `engram`, and
`filed_at` take the new values; the stable `id` is preserved (I-3).

**B-4 (point read):** `getVector(drawerID:modelID:)` returns the stored
engram for that exact pair, or `nil` / `None` when no row exists. It
never falls back to another model.

**B-5 (drawer listing order):** `vectors(forDrawerID:)` returns every
row for the drawer — one per distinct model — ordered by `filed_at`
ascending. Rows that fail to decode are skipped, not surfaced as errors.

**B-6 (nearest ordering):** `findNearest(probe:modelID:limit:)` scans
only rows tagged with the given `modelID`, scores each by Hamming
distance to the probe, and returns up to `limit` matches sorted by
distance ascending, ties broken by `drawerID` ascending. `limit <= 0`
(Swift) / `k == 0` (Rust) or an empty model partition → empty. The
ordering is stable across equivalent corpora.

**B-7 (keyword pre-filter):** `findByKeyword(query, limit)` returns up
to `limit` distinct `drawerID`s whose `drawer_id` contains `query` as a
substring (SQL `LIKE %query%`), ordered by `drawerID` ascending. This is
a coarse identifier pre-filter for hybrid-retrieval callers, not
tokenized BM25 scoring — full BM25 is CorpusKit's.

**B-8 (delete is idempotent):** `deleteVector(drawerID:modelID:)` removes
the row for that pair and is a no-op when no such row exists.

**B-9 (filed-at fidelity):** `filedAt` is round-tripped through storage.
The Swift version persists it as a TEXT ISO8601 timestamp (sub-millisecond
precision is lost in the round trip); the Rust version carries it as `i64`
Unix epoch seconds matching PersistenceKit's `TypedValue::Timestamp`.
The caller supplies `filedAt` (determinism: time is passed in, never
read inside the kit).

**B-10 (match tag fidelity):** every `VectorMatch` carries the `modelID`
of the stored vector it matched, which equals the `modelID` the caller
passed to `findNearest` (a consequence of the I-2 filter).

**B-11 (batch embedding):** `embedBatch(texts:)` (Swift) /
`embed_batch(texts:)` (Rust) returns one engram per input text in the
same order — `output[i]` is the engram for `input[i]`. The default
implementation calls `embed` sequentially over the input array, so the
empty-input zero-engram short-circuit (I-5) applies per element and the
per-call determinism (B-1) and error surface (B-2) carry through
unchanged. Providers MAY override for throughput (batched CoreML graphs
on Swift, ONNX batch-dim inference on Rust); overriding implementations
MUST preserve order, per-element determinism, and the empty-input
contract. F11 consolidation (2026-05-27) added `embedBatch` to
VectorKit's `EmbeddingProvider` so the three CorpusKit providers
(MiniLM, mpnet, EmbeddingGemma) consume one batched surface across both
ports.

## § 6 — Error model (conceptual)

VectorKit surfaces all failures through `VectorKitError` (per the
MOOTx01 standard — structured enum cases, never optionals plus logging).
The concrete cases and their per-language shapes are in
`VECTORKIT_INTERFACE_v0.8.md § 4`.

| Category | Trigger | Recovery posture |
|---|---|---|
| `embeddingFailed` | The provider's inference closure throws (CoreML / ONNX inference error). | Surface to caller; retry is the caller's decision. |
| `modelUnavailable` | The requested model is not loaded or not available on this platform. | Abort the embed; the model must be provisioned first. |
| `storeUnavailable` | The vector store could not be opened, or a row failed to decode (e.g. an engram BLOB that is not 32 bytes). | Surface; indicates a storage / schema fault, not transient. |
| `notFound` | A query found no matching row. (Reserved; current reads model "absent" as `nil` / empty rather than throwing.) | Treat as empty result. |

Point reads (`getVector`) and listings (`vectors`, `findByKeyword`,
`findNearest`) model "nothing matched" as `nil` / empty, not as an
error. `notFound` exists so the error surface is complete across the kit
graph but is not raised by the current read paths.

## § 7 — Conformance requirements

**C-1 (model tag round-trips):** a vector written with `(modelID,
modelVersion)` reads back with the identical tag through `getVector`
(engram) and `vectors(forDrawerID:)` (full `StoredVector`); every
`findNearest` match carries the queried `modelID` (I-1, B-10).

**C-2 (model isolation):** with two models' vectors stored for the same
drawer, `findNearest` under one `modelID` never returns a distance
computed against the other model's engram, and `getVector` for one model
never returns the other's engram (I-2, B-4).

**C-3 (upsert preserves id):** two `addVector` calls for the same
`(drawerID, modelID)` leave exactly one row whose `id` is unchanged and
whose other fields reflect the second write (I-3, B-3).

**C-4 (nearest ordering):** `findNearest` results are sorted by distance
ascending then `drawerID` ascending, truncated to `limit`; `limit`/`k`
of zero and the empty corpus both yield empty (B-6).

**C-5 (empty-input zero engram):** `embed("")` returns the canonical
zero engram in both legs without invoking the inference closure (I-5,
B-1).

**C-6 (provider determinism):** for a fixed seed and closure, `embed`
yields the same engram on repeated calls, and distinct seeds yield
distinct engrams for the same float vector (I-2, B-1).

**C-7 (keyword pre-filter):** `findByKeyword` returns distinct
substring-matching `drawerID`s up to `limit`, ordered ascending, and the
empty set when nothing matches (B-7).

**C-8 (cross-leg):** the Swift and Rust versions agree on `embed` engrams
(for shared seeds and float vectors), on `findNearest` ordering, and on
`findByKeyword` results for every shared test vector — inheriting
SubstrateLib's bit-identical FloatSimHash and EngramLib's
nearest-neighbour parity.

**C-9 (batch parity):** `embedBatch([t_1, t_2, ..., t_n])` /
`embed_batch(&[t_1, t_2, ..., t_n])` returns the same engrams in the
same order as `[embed(t_1), embed(t_2), ..., embed(t_n)]` for a
provider using the default implementation, and the same outputs as the
per-element calls for any overriding implementation under conformance
test. An empty element at position `i` in the input array yields
`Engram.zero` / `Engram::ZERO` at position `i` in the output (I-5,
B-11). Verified by `FloatSimHashEmbeddingProviderTests.testEmbedBatchDefaultImplHandlesMixedEmptyAndNonEmpty` (Swift)
and `simhash_provider_tests::embed_batch_default_impl_handles_mixed_empty_and_non_empty`
(Rust).
