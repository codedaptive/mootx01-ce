---
title: VectorKit Specification
version: 1.1.0
status: active
date: 2026-06-17
description: "Behavioral specification for VectorKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - VECTORKIT_INTERFACE.md  (the API surface this spec contracts)
  - ENGRAMLIB_SPEC.md  (the typed 256-bit Engram and its similarity operations)
  - SUBSTRATELIB_SPEC.md  (the canonical FloatSimHash projection this kit calls)
  - PERSISTENCEKIT_SPEC.md  (the Storage/RowStore backend the vector store wraps)
  - GENIUSLOCUS_ARCHITECTURE_SPEC.md  (rung-3 vectors, invariants I-4 and I-12)
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
- The single-row write path (`addPayload` / `add_payload`) and its
  write-behind sidecar policy.
- The batch write path (`addPayloads` / `add_payloads`): amortised
  import/migration API that bounds sidecar writes and index builds to
  O(batches) — one sidecar write and one index build per batch regardless
  of batch size.
- `flush()` / `flush()`: the quiesce-point method that persists the
  write-behind sidecar to disk; crash-safe because the `vectors` table
  is always the durable source of truth.
- `VectorPayloadInput` / `VectorPayloadInput`: the batch-row input type
  that bundles a `VectorPayload` with its index metadata.
- Hamming-distance nearest-neighbour retrieval (`findNearest`) and its
  ordering, including the model-scoped query filter.
- The coarse keyword pre-filter (`findByKeyword`) and its boundary
  against CorpusKit's BM25 ownership.
- The `VectorMatch` result type and its ordering.

This specification does NOT define:

- API signatures — those live in `VECTORKIT_INTERFACE.md`.
- The fingerprint representation, kernel dispatch, or the FloatSimHash
  projection math — those are SubstrateLib's (`SUBSTRATELIB_SPEC.md`).
- Hamming distance, batch distance, and the k-nearest primitive over
  engrams — those are EngramLib's (`ENGRAMLIB_SPEC.md`); VectorKit
  delegates to them.
- The storage backend (SQLite + sqlite-vec, PostgreSQL + pgvector,
  InMemory), backend selection, and the row/vector index protocols —
  those are PersistenceKit's (`PERSISTENCEKIT_SPEC.md`).
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
conform to VectorKit's `EmbeddingProvider` directly, building on the
canonical FloatSimHash projection that
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

**I-3 (multi-vector, UNIQUE per item/index/model):** the `vectors` table
carries a UNIQUE constraint on `(item_id, vector_index, model_id)`.
`vector_index` is 0 for the common single-vector case; token indexes
0..N-1 support multi-vector (ColBERT) items. A second write for the same
triple updates the existing row in place; the stable `id` survives the
upsert. One item may hold many rows when they differ in `vector_index`
or `model_id`.

**I-4 (typed payloads, three lanes):** the `vectors` table stores
typed payloads via `kind` (0=binary, 1=float32, 2=int8), `dim`,
`payload`, and `scale`. Binary payloads (kind=0) are the canonical
256-bit Engram wire form (32 bytes, 4×UInt64 LE). Float32 payloads
(kind=1) are dim×4 bytes, IEEE-754 little-endian — the pooled dense
float vector retained from the provider's inference pass (Lane D).
Int8 payloads (kind=2) carry `dim` quantized bytes plus a non-null
`scale` for dequantization. Each row declares its type; callers must
not compare payloads across kinds.

**I-4a (int8 writes rejected until quantization policy is ratified):**
`VectorStore.addPayload` / `add_payload` and `addPayloads` / `add_payloads`
REJECT any payload whose `kind` is `.int8` / `Int8`, fail-closed, with
`VectorKitError.int8QuantizationPolicyUndefined` /
`VectorKitError::Int8QuantizationPolicyUndefined`. The `.int8` / `Int8`
variant and its `scale` field are retained in `VectorPayload` (no-removal
doctrine) so a future quantization-policy ratification does not require an
API change. The read-side decode path (`decodePayload` / `decode_payload`) is
symmetric: it returns `nil` (Swift) / `Err(Int8QuantizationPolicyUndefined)`
(Rust) for any int8 row, preventing silent consumption of hand-crafted rows.
There are zero existing int8 producers; this invariant is a precondition
guard for a latent trap. See arch spec §10.3.

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
scalar-reference and cross-port parity guarantees.

## § 5 — Behavioral contracts

**B-1 (provider determinism):** for a fixed inference closure and
projection seed, `embed(text)` is deterministic — the same text yields
the same engram across calls and across the Swift and Rust ports
(FloatSimHash is bit-identical per the substrate conformance harness).

**B-2 (provider error surface):** `embed` surfaces inference failure as
`embeddingFailed` carrying the underlying reason, and an unloaded /
unavailable model as `modelUnavailable`. The empty-input short-circuit
(I-5) cannot fail.

**B-3 (upsert in place):** `addPayload(itemID:vectorIndex:payload:modelID:
modelVersion:filedAt:)` (and its `addVector` binary convenience wrapper)
for an existing `(itemID, vectorIndex, modelID)` triple updates that row
— `model_version`, `payload`, `kind`, `dim`, `scale`, and `filed_at`
take the new values; the stable `id` is preserved (I-3).

**B-3a (write-behind sidecar for single-row writes):** `addPayload` /
`add_payload` uses a write-behind sidecar policy for the binary lane.
The in-memory resident array is updated immediately; the `.vec` sidecar
is marked dirty and NOT rewritten on each call. The caller persists the
sidecar by calling `flush()` at a quiesce point (e.g. end of an import
loop, before process exit, on a periodic checkpoint). Crash safety is
preserved: the `vectors` table is the durable source of truth; a stale
or absent sidecar is rebuilt from the table on the next store open
(detected by comparing the sidecar `live_count` header field against the
table's live binary-row count).

**B-3b (batch write amortisation):** `addPayloads(_ batch:)` /
`add_payloads(batch)` is the import and migration path. For a batch of
N items it performs exactly:
  - O(N) upserts to the `vectors` table (each row, unavoidable).
  - ONE tombstone pass for replaced keys in the resident array.
  - ONE append pass to the resident array (via `ResidentArrayStore.
    appendBatch` / `ResidentArrayStore::append_batch`).
  - ONE sidecar write.
  - ONE index build for both `BruteForceIndex` and `MIHIndex`.
  Float32 rows invalidate the Lane D float index once for a lazy rebuild.
  The memory-only (no-sidecar) path merges the batch in one pass and
  builds both indexes once — no per-row array clone.
  Search output is identical to N sequential `addPayload` calls (the
  total ordering (distance ASC, itemID ASC) is applied at query time).

**B-3c (flush — sidecar quiesce):** `flush()` (both ports) is a no-op
when there is no sidecar, when the in-memory array already matches the
file (`isDirty == false`), or after a `addPayloads` call (which writes
the sidecar eagerly). Crash safety never depends on `flush()`: the
`vectors` table is authoritative; the sidecar is a regenerable cache.

**B-4 (point read):** `getPayload(itemID:vectorIndex:modelID:)` returns
the stored `VectorPayload` for that exact triple, or `nil` / `None` when
no row exists. The `getVector` convenience wrapper decodes a binary
payload into an `Engram`. Neither method falls back to another model.

**B-5 (item listing order):** `vectors(forItemID:)` returns every row for
the item — one per distinct `(vectorIndex, modelID)` pair — ordered by
`filed_at` ascending. Rows that fail to decode are skipped, not surfaced
as errors.

**B-6 (nearest ordering):** `findNearest(probe:modelID:limit:)` scans
only binary rows tagged with the given `modelID` via the resident
DenseIndex (BruteForceIndex below the MIH threshold, MIHIndex at/above
it — both exact), scores each by Hamming distance to the probe, and
returns up to `limit` matches sorted by distance ascending, ties broken
by `itemID` ascending. `limit <= 0` / `k == 0` or an empty model
partition → empty. The ordering is stable across equivalent corpora.

**B-7 (keyword pre-filter):** `findByKeyword(query, limit)` returns up
to `limit` distinct `itemID`s whose `item_id` contains `query` as a
substring (SQL `LIKE %query%`), ordered by `itemID` ascending. This is a
coarse identifier pre-filter for hybrid-retrieval callers, not tokenized
BM25 scoring — full BM25 is CorpusKit's.

**B-8 (delete is idempotent):** `deleteVector(itemID:modelID:)` removes
the single-index (vectorIndex=0) row for that `(itemID, modelID)` pair
and is a no-op when no such row exists. `deleteAllVectors(itemID:
modelID:)` removes every row regardless of `vector_index`.

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
contract. `embedBatch` is part of VectorKit's `EmbeddingProvider` so the
three CorpusKit providers (MiniLM, mpnet, EmbeddingGemma) consume one
batched surface across both ports.

**B-12 (float lane source — Lane D):** `embedFloat(text)` returns the
provider's pooled dense float vector — the SAME vector `embed(text)` computes
on the way to the SimHash projection (retained, not recomputed: one inference
pass feeds both lanes). The default implementation OPTS OUT by throwing
`embeddingFailed` (Swift) / erroring (Rust) so a provider with no dense float
vector forces callers to handle the unsupported case explicitly rather than
receive a silently-wrong projection of the binary fingerprint. The three
CorpusKit providers and the internal `CorpusTextProvider` override it.
Empty input returns `[]` — there is no dense direction for the empty string,
and surfacing a zero-filled vector would make every empty row a
cosine-distance-1 spurious neighbour.

**B-13 (float nearest — Lane D cosine):** `findNearestFloat(probe:modelID:
limit:)` scans only the float32 rows tagged with `modelID`, scores each by
COSINE distance to the probe through the in-house `FloatBruteForceIndex`, and
returns up to `limit` matches sorted by cosine distance ascending, ties by
item id ascending. `VectorMatch.distance` is the cosine distance ×10_000 (the
integer scale both ports share). Lane D maintains ONE `FloatBruteForceIndex` PER
modelID, each built lazily on the first `findNearestFloat` for that model from
that model's float rows only (uniform stride) and updated incrementally on float
writes for that model. This is required because different models emit different
float dimensions and `FloatBruteForceIndex` requires a single stride per index;
spec I-4 keeps models on disjoint partitions, so a per-model index is the only
correct structure when one `vectors` table holds several models' float rows
(e.g. an N-provider corpus). `limit <= 0` / `k == 0`, an empty probe, or no
float rows for the model → empty. The float lane is
reproducible-within-config, NOT four-way bit-identical (arch spec §6): rank
order is stable across languages on shared fixtures; raw cosine values are not
asserted bit-identical.

**B-13a (float farthest — anti-similarity):** `findFarthestFloat(probe:
modelID:limit:)` is the FARTHEST sibling of B-13 (mission
6b-modifiers-antisim): same per-model `FloatBruteForceIndex`, same cosine,
same `modelID` partition scope (I-4), same `VectorMatch` ×10_000 quantisation,
but it returns the bottom-K by cosine similarity — the most DISSIMILAR rows
first (largest cosine distance first) — for the "find things UNLIKE this"
objective. It is NOT a negated nearest-list: the farthest rows are not in the
nearest top-K, so the index orders by the opposite end (no new distance math).
The ranking direction is named by the `SearchDirection` enum
(`nearest`/`farthest`); the tie-break stays item-id ascending in BOTH
directions, so the nearest path is byte-identical. Same emptiness conditions
and the same reproducible-within-config (not four-way bit-identical) boundary
as B-13.

## § 6 — Error model (conceptual)

VectorKit surfaces all failures through `VectorKitError` (per the
MOOTx01 standard — structured enum cases, never optionals plus logging).
The concrete cases and their per-language shapes are in
`VECTORKIT_INTERFACE.md § 4`.

| Category | Trigger | Recovery posture |
|---|---|---|
| `embeddingFailed` | The provider's inference closure throws (CoreML / ONNX inference error). | Surface to caller; retry is the caller's decision. |
| `modelUnavailable` | The requested model is not loaded or not available on this platform. | Abort the embed; the model must be provisioned first. |
| `storeUnavailable` | The vector store could not be opened, or a row failed to decode (e.g. a typed payload whose byte count disagrees with its declared `kind`/`dim` — a binary payload that is not 32 bytes, or a float32 payload that is not `dim × 4`). | Surface; indicates a storage / schema fault, not transient. |
| `notFound` | A query found no matching row. (Reserved; current reads model "absent" as `nil` / empty rather than throwing.) | Treat as empty result. |
| `int8QuantizationPolicyUndefined` | An `.int8` payload was submitted to `addPayload` / `add_payload` or `addPayloads` / `add_payloads`. The quantization policy has not been ratified; the write is rejected fail-closed (I-4a). | Use `.float` / `Float32` or the binary Engram lane until a policy is ratified. |

Point reads (`getVector`) and listings (`vectors`, `findByKeyword`,
`findNearest`) model "nothing matched" as `nil` / empty, not as an
error. `notFound` exists so the error surface is complete across the kit
graph but is not raised by the current read paths.

## § 7 — Conformance requirements

**C-1 (model tag round-trips):** a vector written with `(modelID,
modelVersion)` reads back with the identical tag through `getVector`
(engram) / `getPayload` (typed payload) and `vectors(forItemID:)` (full
`StoredVector`); every `findNearest` / `findNearestFloat` match carries
the queried `modelID` (I-1, B-10).

**C-2 (model isolation):** with two models' vectors stored for the same
drawer, `findNearest` under one `modelID` never returns a distance
computed against the other model's engram, and `getVector` for one model
never returns the other's engram (I-2, B-4).

**C-3 (upsert preserves id):** two `addPayload` calls for the same
`(itemID, vectorIndex, modelID)` triple leave exactly one row whose `id`
is unchanged and whose other fields reflect the second write (I-3, B-3).

**C-4 (nearest ordering):** `findNearest` results are sorted by distance
ascending then `itemID` ascending, truncated to `limit`; `limit`/`k`
of zero and the empty corpus both yield empty (B-6).

**C-5 (empty-input zero engram):** `embed("")` returns the canonical
zero engram in both ports without invoking the inference closure (I-5,
B-1).

**C-6 (provider determinism):** for a fixed seed and closure, `embed`
yields the same engram on repeated calls, and distinct seeds yield
distinct engrams for the same float vector (I-2, B-1).

**C-7 (keyword pre-filter):** `findByKeyword` returns distinct
substring-matching `itemID`s up to `limit`, ordered ascending, and the
empty set when nothing matches (B-7).

**C-8 (cross-port):** the Swift and Rust ports agree on `embed` engrams
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
B-11).

**C-10 (batch equivalence):** `addPayloads(batch)` / `add_payloads(batch)`
produces the same `findNearest` results as N sequential `addPayload` /
`add_payload` calls for the same inputs (B-3b).

**C-11 (batch sidecar cost):** a bulk ingest of N binary vectors via
`addPayloads` costs O(batches) sidecar writes, not O(N): the conformance
suite asserts `sidecarWriteCount <= expectedBatches + 1`.

**C-12 (crash-safe write-behind):** a store opened after a process kill
mid-write-behind-batch recovers correctly: the sidecar `live_count`
mismatches the table binary-row count, the stale sidecar is discarded,
and the array is rebuilt once from the `vectors` table. Search results
after recovery are identical to results before the kill.

## § 8 — Self-report telemetry

VectorStore emits
`vectorkit.*` metrics via IntellectusLib when monitoring is enabled. Off
by default (the global enabled gate is `false`); the off-path cost is
one `AtomicBool` load + branch per emit site (~1 ns, negligible).

**Design invariant:** telemetry MUST NOT affect results. `addVector`,
`findNearest`, and `findByKeyword` return byte-identical values whether
monitoring is on or off. The emit call is placed after the operation
completes, at the operation boundary; it never participates in the
result computation path.

### Metrics emitted

| Metric name | Value | Tags | Emitted by |
|---|---|---|---|
| `vectorkit.index.insert_latency_ms` | Wall time for the upsert round-trip (ms) | `kit="VectorKit"`, `model_id=<modelID>` | `addVector` / `addPayload` / `add_vector` / `add_payload` |
| `vectorkit.index.batch_insert_latency_ms` | Wall time for the full batch (table writes + one index build), in ms | `kit="VectorKit"`, `batch_size=<N>` | `addPayloads(_:)` / `add_payloads` |
| `vectorkit.search.latency_ms` | Wall time for the full findNearest scan + top-K + sort (ms) | `kit="VectorKit"`, `model_id=<modelID>` | `findNearest` / `find_nearest` |
| `vectorkit.search.result_count` | Number of matches returned (≤ limit) | `kit="VectorKit"`, `model_id=<modelID>` | `findNearest` / `find_nearest` |
| `vectorkit.search.keyword_result_count` | Number of distinct item IDs returned | `kit="VectorKit"` | `findByKeyword` / `find_by_keyword` |

### Tags

- `kit`: always `"VectorKit"` — identifies the emitting kit.
- `model_id`: the `modelID` argument to the operation. Present on insert
  and search metrics; absent from keyword metrics (keyword search is not
  model-scoped).
- `estate` tag is **not** emitted. VectorStore wraps a `Storage` handle
  and has no access to estate identity. If estate attribution is required,
  the consumer installs a wrapping sink that injects the tag.

### Off-path cost

When monitoring is disabled (the default):
- Swift: `Intellectus.report(_:)` evaluates its `@autoclosure` argument
  only when `_enabled.load(.relaxed) == true`. One atomic load + branch.
  The `Date().timeIntervalSince1970` start-time capture in `addVector`
  and `findNearest` is unconditional; this is the only added overhead on
  the disabled path.
- Rust: the `report!` macro expands to `if Intellectus::is_enabled() { … }`.
  One `AtomicBool::load(Acquire)` + branch. The `Instant::now()` start
  capture is unconditional.

### Parity

The Swift and Rust ports emit the same four metric names with the same
tag keys and values. The `ts` field is epoch seconds (f64) in both ports.
Value semantics: latency_ms is wall-clock milliseconds (f64);
count metrics are f64 with integer values.

## § 9 — Bulk ingest API and write-behind sidecar policy

The bulk-ingest path bounds the cost of large binary-vector ingests with
an amortised batch path and a write-behind sidecar policy for single-row
writes.

### Problem addressed

Without amortisation, each `addPayload` call rewrites the entire `.vec`
sidecar (O(N) bytes per write), so a bulk import of N vectors costs O(N²) bytes
written. At import scale (tens of thousands of vectors) this was the
dominant cost.

### Solution: two amortised paths on ResidentArrayStore

**`appendBatch(records:)` / `append_batch`** — the import/migration path.
Extends the in-memory array with all N records in one pass and calls
`writeSidecar` / `write_sidecar` EXACTLY ONCE. A batch of N binary
vectors costs one sidecar write regardless of N.

**`appendDeferred(key:bytes:)` / `append_deferred`** — the write-behind
single-add path. Mutates the in-memory array and sets `isDirty` /
`is_dirty` WITHOUT writing the sidecar. The caller (`VectorStore`) flushes
via `flush()` at a quiesce point.

The `append(key:bytes:)` / `append` immediate-write method is retained for
callers that need eager per-write persistence.

### Crash-safety invariant

Crash safety is independent of the sidecar amortisation policy.
The `vectors` SQLite table is the single durable source of truth at all
times. The `.vec` sidecar is a regenerable cache. On next open,
`VectorStore._ensureIndexBuilt` / `ensure_index_built_locked` compares the
sidecar `live_count` header field against the table's live binary-row count:
if they disagree the sidecar is discarded and the array is rebuilt from the
table. The rebuild is paid once per process start in the stale path; on the
happy path (sidecar current) the array is loaded with one OS read (mmap).

### `sidecarWriteCount` / `sidecar_write_count` (test instrumentation)

`ResidentArrayStore.sidecarWriteCount` / `sidecar_write_count()` is
incremented once per `writeSidecar` call (rebuild, appendBatch, tombstone,
compact, flush). It is exposed for test assertions only — the import-scale
regression test asserts a bulk ingest costs O(batches) sidecar writes,
not O(N). Callers must not drive application logic from this value.

Similarly, `VectorStore.sidecarWriteCount` / `sidecar_write_count` proxies
the value from the underlying `ResidentArrayStore` (returns 0 for
memory-only stores). The `sidecarRebuildCount` / `sidecar_rebuild_count`
field counts stale-sidecar rebuilds from the table (0 in the normal path).

## § 10 — VectorStore lifecycle (destroyAllVectors)

`destroyAllVectors` (Swift) / `destroy_all_vectors` (Rust) deletes all rows
from the `vectors` table. This is the estate-destruction primitive called by
`GeniusLocusKit.destroy(storage:corpusStorage:handle:)` when tearing down a
provisioned estate.

**Invariants:**
- The backing storage schema is preserved; only data rows are deleted.
- The caller (GLK) is responsible for closing the LocusKit estate before calling
  this method.
- The method does not close or remove the backing storage file.
- Parity: Swift uses `StoragePredicate.like(column("id"), "%")` (any non-null id);
  Rust uses `StoragePredicate::IsTrue` (always-true predicate). Both delete all rows.

## Changelog

### 1.1.0 -- 2026-06-17
Added B-13a — the Lane D float FARTHEST (anti-similarity) retrieval contract
(mission 6b-modifiers-antisim): `findFarthestFloat` / `find_farthest_float`
returns the bottom-K by cosine similarity (most dissimilar first), the "find
things UNLIKE this" objective, reusing the same cosine and item-id tie-break
with the sort order inverted. Names the `SearchDirection` enum. The nearest
contract (B-13) is unchanged. Additive (MINOR).

### 1.0.1 -- 2026-06-17
Lane D float nearest (B-13) now maintains ONE `FloatBruteForceIndex` per modelID
instead of a single shared index. The single shared index built from the first
record's stride was correct only while one model's float rows occupied the
`vectors` table; with several models' float rows present (an N-provider corpus,
mission 6a-iii-core) it corrupted every other model's dimension and errored on
query. The per-model index honors the long-stated B-13 contract ("scans only the
float32 rows tagged with `modelID`") and spec I-4's disjoint-partition rule.
Public surface unchanged (`findNearestFloat(probe:modelID:limit:)` /
`find_nearest_float` signatures preserved); behavior fix only, both ports. Float
writes invalidate/update only the affected model's index; `destroyAllVectors`
clears all per-model indices; `deleteAllVectors`/`delete*` clear the affected
model's index.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
