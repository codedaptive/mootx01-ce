---
title: SynapseKit Specification
version: 2.3.0
status: accepted-1.1-target
date: 2026-09-07
description: "Behavioral specification for SynapseKit: invariants, conformance requirements, and the contract it guarantees. 2.1.0: I-10 schema-ledger continuity across the VectorKit → SynapseKit rename (prepareSchemaLedger before migrate; a conflicted ledger warns and opens). 2.0.0: the int8 quantisation policy is ratified (I-4a): int8 rows are written and read, the fail-closed rejection and its error case are gone, and the encoder span-row surface (writeSpanVectors / spanVectors / deleteSpanVectors) lands over the existing vectors table. 2.2.0: reclaimWholeRecordFloatRows, the whole-record float vacuum the GeniusLocusKit 1.6→1.7 capsule runs. 2.3.0: the .vec sidecar (format 0x0003) carries the serving-generation stamp it was built under and a store accepts it only when the stamp equals the registry and the live count equals the serving-row count, both ports."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - SYNAPSEKIT_INTERFACE.md  (the API surface this spec contracts)
  - ENGRAMLIB_SPEC.md  (the typed 256-bit Engram and its similarity operations)
  - SUBSTRATELIB_SPEC.md  (the canonical FloatSimHash projection this kit calls)
  - PERSISTENCEKIT_SPEC.md  (the Storage/RowStore backend the vector store wraps)
  - GENIUSLOCUS_ARCHITECTURE_SPEC.md  (rung-3 vectors, invariants I-4 and I-12)
  - the kit-ownership contract  (storage moved onto PersistenceKit)
purpose: |
  SynapseKit is the on-device embedding and approximate-nearest-neighbour
  layer for one estate. It defines the `EmbeddingProvider` abstraction
  (text → model-tagged 256-bit `Engram`), the built-in deterministic
  `FloatSimHashEmbeddingProvider`, and a PersistenceKit-backed
  `VectorStore` that holds model-tagged vectors per (item, index, model)
  pair and answers Hamming-distance nearest-neighbour and coarse keyword
  queries. Every stored vector carries the identity and version of the
  model that produced it, so mixed-version corpora stay filterable and
  cross-model comparisons are structurally prevented. The companion
  INTERFACE document carries the signatures.
---

# SynapseKit Specification

## § 1 — What this package is

SynapseKit is the substrate kit that turns text into vectors and finds
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
those live in CorpusKit. SynapseKit supplies the low-level building block
("host supplies inference, kit supplies the canonical projection and the
model-tagged store"); CorpusKit composes it into standalone or attached RAG
indexes.

## § 2 — Scope

This specification defines:

- The `EmbeddingProvider` abstraction and its empty-input contract.
- The built-in `FloatSimHashEmbeddingProvider`: host-supplied inference
  closure projected through SubstrateLib's canonical FloatSimHash.
- The `StoredVector` storage record and its model-tag fields.
- The `VectorStore` CRUD surface, its schema, and its
  one-row-per-(item, index, model) upsert semantics.
- The single-row write path (`addPayload` / `add_payload`) and its
  write-behind sidecar policy.
- The batch write path (`addPayloads` / `add_payloads`): amortised
  import/migration API that bounds sidecar writes and index builds to
  O(batches) — one sidecar write and one index build per batch regardless
  of batch size.
- `flush()` / `flush()`: the quiesce-point method that persists the
  write-behind sidecar to disk; crash-safe because the `vectors` table
  is always the durable authoritative store.
- `VectorPayloadInput` / `VectorPayloadInput`: the batch-row input type
  that bundles a `VectorPayload` with its index metadata.
- Hamming-distance nearest-neighbour retrieval (`findNearest`) and its
  ordering, including the model-scoped query filter.
- The coarse keyword pre-filter (`findByKeyword`) and its boundary
  against CorpusKit's BM25 ownership.
- The `VectorMatch` result type and its ordering.

This specification does NOT define:

- API signatures — those live in `SYNAPSEKIT_INTERFACE.md`.
- The fingerprint representation, kernel dispatch, or the FloatSimHash
  projection math — those are SubstrateLib's (`SUBSTRATELIB_SPEC.md`).
- Hamming distance, batch distance, and the k-nearest primitive over
  engrams — those are EngramLib's (`ENGRAMLIB_SPEC.md`); SynapseKit
  delegates to them.
- The storage backend (SQLite + sqlite-vec, PostgreSQL + pgvector,
  InMemory), backend selection, and the row/vector index protocols —
  those are PersistenceKit's (`PERSISTENCEKIT_SPEC.md`).
- Tokenization, model bundles, model identity assignment, BM25 keyword
  scoring, and RAG indexing/content-source composition — those are CorpusKit's.

## § 3 — Position in the kit family

```
SubstrateLib          PersistenceKit
   ▲   (FloatSimHash)     ▲   (Storage / RowStore)
EngramLib                 │
   ▲   (Engram, distance) │
   └──────────┬───────────┘
          SynapseKit        ← this package
              ▲
          CorpusKit        (standalone content or attached derived RAG index)
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
conform to SynapseKit's `EmbeddingProvider` directly, building on the
canonical FloatSimHash projection that
`FloatSimHashEmbeddingProvider` also uses. GeniusLocusKit composes
CorpusKit transitively.

## § 4 — Invariants

**I-1 (model tag is mandatory):** every embedding generated and every
vector stored carries a `modelID` and `modelVersion`. The provider
declares them, `addVector` persists them, and `VectorMatch` carries the
`modelID` back. There is no path that stores or returns an untagged
vector. This is SynapseKit's realization of architecture invariant I-4.

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

**I-4a (int8 quantisation policy, ratified):** int8 payloads follow the
symmetric per-vector policy implemented by SubstrateKernel `Int8Vec` /
`int8_vec` (ENCODER_RERANK_CONTRACT §4): for an L2-normalised float32
vector `v`, `scale = max_i |v_i| / 127` (`scale = 1` when the maximum is 0),
`q_i = clamp(round_half_away_from_zero(v_i / scale), -127, 127)`; the row
stores `q` (`dim` bytes, two's complement) and `scale` (REAL, never NULL).
Dequantisation is `q_i × scale`; a float query `u` scores a stored int8
vector as `(Σ u_i × q_i) × scale` with no renormalisation. Both ports match
`q` and `scale` bit for bit on the shared fixture
`Tests/Fixtures/encoder/int8_vectors.json` (20 vectors at dims 8, 384 and
768 plus edge vectors) and `dotQuery` within 1e-5 (C-15). `addPayload` /
`addPayloads` / `replaceModelVectors` / `reconcileModelVectors` accept int8
payloads and store them table-only, like float32: int8 rows never enter the
resident Hamming array or a float index. The read side (`decodePayload` /
`decode_payload`) treats an int8 row without a `scale` or with a byte count
other than `dim` as malformed and skips it.

**I-4b (encoder span rows):** the encoder-rerank stage stores ONE `vectors`
row per span of a drawer: `item_id` = the drawer UUID, `vector_index` = the
span index (0-based, span order), `kind = 2`, `dim` = the model dimension,
`payload` = the int8 bytes, `scale` = the per-vector scale, `generation` =
the model's serving generation, `ext` = the JSON object
`{"cv":"<content_version>","e":<end_word>,"s":<start_word>}` (sorted keys,
minimal escaping, byte-identical across ports) where `content_version` is
the drawer's `content_hash` at encode time. Whole-record encoder vectors are
never stored. `writeSpanVectors(itemID:modelID:modelVersion:spans:filedAt:)`
/ `write_span_vectors` replaces the item's span set under that model in ONE
transaction (delete the serving-generation int8 rows, insert the new set), so
a reader never sees a mix of old and new spans; a second write replaces,
never appends. `spanVectors(itemIDs:modelID:)` / `span_vectors` returns the
serving-generation rows keyed by item id in span order, chunking the id list
at 900 per statement; items with no rows are absent. `deleteSpanVectors` /
`delete_span_vectors` removes an item's span rows across all generations.
`reclaimRetiredVectorRows(retiredModelIDs:)` / `reclaim_retired_vector_rows`
is the `mootx01 upgrade` maintenance pass: it deletes every row of the named
model ids and every row at a non-serving generation (models with a shadow
build in flight are skipped), with the matching `hnsw_graph` rows, and
rebuilds the resident binary index from the table when anything was deleted.
`reclaimWholeRecordFloatRows()` / `reclaim_whole_record_float_rows` is the
GeniusLocusKit 1.6→1.7 capsule's pass: it deletes every `vectors` row of kind
1 (float32) and every `hnsw_graph` row, drops the resident float and HNSW
state, and always rebuilds the resident binary index and the `.vec` sidecar
from the surviving rows so the sidecar's live count and generation match the
serving table; kind 0 and kind 2 rows are never touched, and a second call
deletes nothing and rewrites an identical sidecar.

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

**I-7 (delegation of distance):** SynapseKit performs no Hamming math of
its own. `findNearest` delegates the batch bitcount to EngramLib, which
routes to the substrate kernel (BNNS / NEON accelerated where
available). SynapseKit therefore inherits EngramLib's and SubstrateLib's
scalar-reference and cross-port parity guarantees.

**I-8 (`ext` forward-compat slot, the forward-compatible ext-slot contract):** the `vectors` table carries one
nullable `.json` column named `ext` (schema v3), reserving migration-free space
for future per-vector typed metadata. In 1.0 `ext` is inert — written NULL /
omitted on insert and never read; it carries no behavior. Provisioned during the
1.0.0 free-migration window. See the forward-compatible ext-slot contract.

**I-9 (GLK canonical identity and scoped ownership):** SynapseKit treats
`itemID` as opaque. In GLK, CorpusKit-derived vector rows use canonical
`Drawer.id`; passage/index-unit IDs are permitted only in standalone
CorpusKit. Every composed vector row also belongs to a declared lane/model
scope so Corpus rebuild, expunge, and migration can delete their own rows
without touching unrelated Drawer-keyed vectors.

**I-10 (schema-ledger continuity across a kit-id rename):** the vector
tier's two PersistenceKit schema-version ledger rows are keyed by stored kit
ids, `VectorStore.kitID` (`SynapseKit`, ladder at v6) and
`VectorRepresentationClaims.kitID` (`SynapseKitClaims`, v1). Both stores name
the ids those rows carried under earlier names of the kit, oldest first:
`formerKitIDs` / `FORMER_KIT_IDS` = `["VectorKit"]` and `["VectorKitClaims"]`
(the tier was renamed because the old name collides with Apple's MapKit
VectorKit framework). A populated estate opened before the rename keys its
rows by the former ids; a `migrate(to:)` under the current id that finds no
row treats the estate as version 0 and replays the ladder against the current
layout — the v5→v6 step rebuilds `vectors` through a copy table that folds
every row's `generation` to 0 (darkening a swapped estate's recall) and fails
outright when a serving and a shadow row share a key. Therefore every open
path calls `prepareSchemaLedger(storage:)` / `prepare_schema_ledger` on each
store BEFORE `migrate(to:)` of that store's declaration. The preparation moves
each former-id row to the current id through `Storage.renameSchemaKit(from:to:)`
(PERSISTENCEKIT_SPEC I-7a), keeping version and applied-at: `.renamed` and
`.noRow` (fresh estate, or one already on the current id) pass with nothing
else changed; `.conflict` (rows under both ids) leaves both rows in place,
emits one warning through the kit logger naming both ids and versions, and
returns normally — the estate stays openable, and the `migrate(to:)` that
follows reads its ladder position from the current-id row, so no step
replays. This is the same warn-and-leave-rows policy the GeniusLocusKit
1.4 → 1.5 capsule applies to the same ledger; refusing to open would remove
access to an estate's existing data. Only a failed rename call (storage
error) throws `SynapseKitError.storeUnavailable` / `StoreUnavailable`; the
operator resolves the duplicate row. CorpusKit's standalone constructors (`Corpus`,
`CorpusContentEngine`) and GeniusLocusKit's 1.4 → 1.5 capsule both read the
pair from these constants, so there is one source of the rename. Pinned
regression, both ports: ledger row `VectorKit` v6 plus one `vectors` row at
generation 3 → after preparation and migrate the row is at generation 3 and
the ledger carries one row for the store, under `SynapseKit`; without
preparation the same estate replays and the row reads generation 0. Conflict
pin, both ports: the same estate plus a `SynapseKit` v6 row → preparation
returns, both ledger rows keep v6, and after migrate the row is still at
generation 3.

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
preserved: the `vectors` table is the durable authoritative store; a stale
or absent sidecar is rebuilt from the table on the next store open
(detected by two checks, both required: the sidecar's serving-generation
stamp, the `vector_generations` registry (model_id, serving_generation) it
was built under and written into the format 0x0003 header, must equal the
registry read at open; and the sidecar `live_count` header field must equal
the table's serving-generation binary-row count — the same row set the
sidecar is built from, so superseded rows still awaiting reclaim after a
shadow swap do not count; both ports apply the serving-generation predicate
to the count exactly as they apply it to the rebuild fetch). The stamp is
what tells a sidecar built from the previous generation apart from the
current one when the two generations hold the same number of rows, which a
full reindex commonly does: a crash between the registry flip of
`publishShadowGeneration` and its sidecar rebuild leaves the old vectors in
the sidecar under the new generation's name, and the count alone accepted
them. Every rebuild passes the registry it fetched the rows with
(`rebuild(from:generations:)` / `rebuild_from(records, generations)`), so the
stamp and the rows are always written together. A sidecar at format 0x0001
or 0x0002 fails to parse, the store starts empty, and the sidecar is rebuilt
once under the new format.

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
  total ordering (distance ASC, vecHash ASC, itemID ASC) is applied at
  query time).

**B-3d (replaceModelVectors — bulk re-embed path):**
`replaceModelVectors(modelID:_:)` / `replace_model_vectors(model_id, batch)` is
the bulk re-embed path for a single model. It performs:
1. A bulk-delete of all rows whose `model_id` equals `modelID`, followed by a
   plain-INSERT of the replacement batch, in ONE transaction (one fsync;
   INSERT is used — not upsert — because after the bulk delete nothing conflicts,
   eliminating the per-row existence SELECT).
2. ONE resident binary index rebuild from the table after the transaction commits
   (O(N) — avoids the O(N²) cost of N individual `addPayload` removes and adds
   each of which rebuilds the full index partition).

Invariants: Int8 payloads are accepted and written table-only (I-4a), same as `addPayloads`.
Any in-flight deferred-index window is published before the table write, so the
resident index is consistent at the point the transaction begins. Float (Lane D)
index state for the model is invalidated and rebuilt lazily on the next
`findNearestFloat` call, consistent with the batch-write behavior in B-3b.
The method is deliberate NOT a superset of `addPayloads`: live-capture writes
continue to use `addPayload` / `addPayloads` (which mutate the resident index
incrementally per key); `replaceModelVectors` is reserved for the full re-embed
case where the prior set is rendered obsolete by a model weights change.

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
returns up to `limit` matches sorted by the universal tie-break order:
distance ascending, then `vecHash` ascending (FNV-1a 64 over the stored
vector payload bytes — content-derived, so the order is identical
across independent provisionings of the same content even though item
UUIDs differ), then `itemID` ascending as the final backstop. Rows with
byte-identical vectors (identical content) still fall to the per-run
`itemID`; such rows are interchangeable for every ordering consumer.
`limit <= 0` / `k == 0` or an empty model partition → empty. The
ordering is stable across equivalent corpora AND across independent
imports of the same corpus.

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
contract. `embedBatch` is part of SynapseKit's `EmbeddingProvider` so the
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
returns up to `limit` matches sorted by cosine distance ascending, then
`vecHash` ascending (the same FNV-1a content-derived tie key as B-6),
then item id ascending. `VectorMatch.distance` is the cosine distance ×10_000 (the
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
(`nearest`/`farthest`); the tie-break stays (vecHash, item-id) ascending
in BOTH directions, so the nearest path is byte-identical. Same emptiness conditions
and the same reproducible-within-config (not four-way bit-identical) boundary
as B-13.

**B-13b (HNSW bulk build order — content-stable):** every BULK HNSW graph
build — a build from a row set, i.e. `rebuildHNSWIndex(for:)` /
`rebuild_hnsw_index` (THETA duty, also run by `publishShadowGeneration`
post-flip) and `HNSWIndex.compact()` / `HNSWIndex::compact` (BETA duty) —
inserts rows in the content-stable order `(vecHash ASC, key ASC)`, where
`vecHash` is the same FNV-1a 64 content tie key as B-6/B-13.
Neighbour-truncation cuts inside the build (forward-edge selection and
back-edge shrink at the M/M0 caps) break distance ties by `(vecHash,
itemID)`, never by internal node index (arrival order). Consequence:
building from the same content twice — including on independently
provisioned estates where item UUIDs differ — yields the identical graph
topology, per port. Rows with byte-identical vectors still fall to the
per-run `itemID` and are interchangeable. CAVEAT: incremental single-row
inserts (the write-path mirror into an active graph) keep ARRIVAL order —
only bulk rebuilds guarantee cross-run graph identity; the next THETA
rebuild converges an incrementally-grown graph. Cross-PORT graph identity
remains a non-goal (the float lane is reproducible-within-config, not
four-way bit-identical).

## § 6 — Error model (conceptual)

SynapseKit surfaces all failures through `SynapseKitError` (per the
MOOTx01 standard — structured enum cases, never optionals plus logging).
The concrete cases and their per-language shapes are in
`SYNAPSEKIT_INTERFACE.md § 4`.

| Category | Trigger | Recovery posture |
|---|---|---|
| `embeddingFailed` | The provider's inference closure throws (CoreML / ONNX inference error). | Surface to caller; retry is the caller's decision. |
| `modelUnavailable` | The requested model is not loaded or not available on this platform. | Abort the embed; the model must be provisioned first. |
| `storeUnavailable` | The vector store could not be opened, or a row failed to decode (e.g. a typed payload whose byte count disagrees with its declared `kind`/`dim` — a binary payload that is not 32 bytes, or a float32 payload that is not `dim × 4`). | Surface; indicates a storage / schema fault, not transient. |
| `notFound` | A query found no matching row. (Reserved; current reads model "absent" as `nil` / empty rather than throwing.) | Treat as empty result. |
| `invalidPayload` (span rows) | A `writeSpanVectors` set disagrees on dimension, carries an empty vector, repeats a span index, or inverts a word range (I-4b). | Fix the caller; nothing was written (the check precedes the transaction). |

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
mismatches the table's serving-generation binary-row count, the stale sidecar is discarded,
and the array is rebuilt once from the `vectors` table. Search results
after recovery are identical to results before the kill.

**C-12a (crash-safe publish, equal counts):** a store opened after a process
kill between the registry flip of `publishShadowGeneration` and its sidecar
rebuild, where the retired and the new generation hold the same number of
rows, rebuilds once from the table and serves the new generation: the
sidecar's generation stamp differs from the registry even though the live
count matches. The rebuilt sidecar is accepted by the next open. Pinned by
`SidecarFreshnessTests.swift` and `rust/tests/sidecar_freshness_tests.rs`.

**C-13 (GLK identity and selective deletion):** attached Corpus fixtures write
only Drawer-keyed vector items. Deleting/rebuilding the Corpus-owned scope
leaves an unrelated GLK lane for the same Drawer byte-identical and recallable.

**C-14 (top-K boundary ties, shared vector):** both ports assert the shared
fixture `packages/kits/SynapseKit/Tests/Conformance/hamming_topk_boundary_ties.json`
(300 fingerprints around one probe: a 45-way tie at the K=10 boundary and a
50-way tie at the K=80 boundary, with byte-identical payload pairs inside the
tie groups; insertion order is a deterministic shuffle) on every binary engine:
BruteForceIndex, MIHIndex at m=16 and m=4, and `findNearest` / `find_nearest`
on the brute-force tier and on the MIH tier (MIH forced active below the
default threshold through the init threshold). Each engine returns exactly K
hits in the B-6 order (distance ASC, vecHash ASC, itemID ASC). The expected
lists are one shared file with the vecHash of every entry recorded, so the
ports are pinned to one list and one hash definition, not to each other.

## § 8 — Self-report telemetry

VectorStore emits
`synapsekit.*` metrics via IntellectusLib when monitoring is enabled. Off
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
| `synapsekit.index.insert_latency_ms` | Wall time for the upsert round-trip (ms) | `kit="SynapseKit"`, `model_id=<modelID>` | `addVector` / `addPayload` / `add_vector` / `add_payload` |
| `synapsekit.index.batch_insert_latency_ms` | Wall time for the full batch (table writes + one index build), in ms | `kit="SynapseKit"`, `batch_size=<N>` | `addPayloads(_:)` / `add_payloads` |
| `synapsekit.search.latency_ms` | Wall time for the full findNearest scan + top-K + sort (ms) | `kit="SynapseKit"`, `model_id=<modelID>` | `findNearest` / `find_nearest` |
| `synapsekit.search.result_count` | Number of matches returned (≤ limit) | `kit="SynapseKit"`, `model_id=<modelID>` | `findNearest` / `find_nearest` |
| `synapsekit.search.keyword_result_count` | Number of distinct item IDs returned | `kit="SynapseKit"` | `findByKeyword` / `find_by_keyword` |

### Tags

- `kit`: always `"SynapseKit"` — identifies the emitting kit.
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
The `vectors` SQLite table is the single durable authoritative store at all
times. The `.vec` sidecar is a regenerable cache. On next open,
`VectorStore._ensureIndexBuilt` / `ensure_index_built_locked` compares the
sidecar `live_count` header field against the table's serving-generation
binary-row count: if they disagree the sidecar is discarded and the array is
rebuilt from the table. A sidecar that is current is NOT rebuilt on an estate
whose table still holds superseded generations pending reclaim. The rebuild is paid once per process start in the stale path; on the
happy path (sidecar current) the array is loaded with one OS read (mmap).

### Cross-restart persistence (both ports) — conformance requirement

Both ports persist vector state across a process restart over the on-disk
SQLite backend, with no full rebuild required on the happy path. A
`VectorStore` constructed over the PersistenceKit SQLite backend
(`SQLiteStorage` / `SqliteStorage`) — a backend the kit holds behind
`any Storage` / `Arc<dyn Storage>` and never names — writes every vector to
the durable `vectors` table. After the writing store is dropped, a NEW
`VectorStore` opened on the SAME file MUST reconstruct the resident state so
that:

- `findNearest` / `find_nearest` (binary Hamming lane) returns the persisted
  vectors with bit-identical Hamming distances — the identical probe ranks at
  distance 0. This is the four-way bit-identical lane (I-7).
- `findNearestFloat` / `find_nearest_float` and `findFarthestFloat` /
  `find_farthest_float` (Lane D float lane) return the identical RANK order
  produced before the close (reproducible-within-config, arch spec §6).
- When a `.vec` sidecar is supplied and is current (`live_count` matches the
  table), the binary array loads from the sidecar with no table rebuild
  (`sidecarRebuildCount` / `sidecar_rebuild_count` stays 0); the reopened
  top-k equals the pre-close top-k.

This requirement is gated in both ports: Swift
`findNearestSurvivesReopenSQLite` / `floatIndexSurvivesReopenSQLite`
(SynapseKitTests) and Rust `find_nearest_survives_reopen_sqlite`,
`find_nearest_survives_reopen_sqlite_with_sidecar`,
`float_index_survives_reopen_sqlite`. The row decoders MUST tolerate the
primitives the SQLite backend returns on read-back (`id` as TEXT, `filed_at`
as INTEGER); decoding only the in-memory backend's native `Uuid` / `Timestamp`
would silently drop every persisted row on reopen and blank the recall lane.

PostgreSQL persistence is the remote-backed v1.1 path (ships with federation)
and is out of scope here.

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
from the `vectors` table. It is a standalone SynapseKit administrative primitive
for a store whose caller owns every row. It is forbidden for a composed GLK
store because multiple lanes/models can share the table; GLK uses exact
item/lane/model deletion or a CorpusKit-owned scope delete instead.

**Invariants:**
- The backing storage schema is preserved; only data rows are deleted.
- The caller must prove exclusive ownership of the entire vector store.
- The method does not close or remove the backing storage file.
- Parity: Swift uses `StoragePredicate.like(column("id"), "%")` (any non-null id);
  Rust uses `StoragePredicate::IsTrue` (always-true predicate). Both delete all rows.

## Changelog

### 2.3.0 -- 2026-09-07
The `.vec` sidecar format is 0x0003: the header carries the serving-generation
stamp (the `vector_generations` registry the array was built under, ascending
model_id, byte-identical across ports). B-3a: a store accepts a sidecar only
when the stamp equals the registry read at open AND the live count equals
the serving-generation row count; every rebuild writes the stamp with the
rows. C-12a pins the equal-count publish crash both ports. Sidecars at
0x0001 or 0x0002 are rejected and rebuilt once.

### 2.2.0 -- 2026-09-07
`reclaimWholeRecordFloatRows()` / `reclaim_whole_record_float_rows()` on
`VectorStore`, both ports: the whole-record float vacuum the GeniusLocusKit
1.6→1.7 capsule runs (GENIUSLOCUSKIT_SPEC I-26). Deletes every `vectors` row
of kind 1 and every `hnsw_graph` row, drops the resident float and HNSW
state, rebuilds the binary index and the `.vec` sidecar from the surviving
rows, returns the two row counts. Kind 0 and kind 2 rows are untouched;
idempotent. Additive (MINOR).

### 2.1.0 -- 2026-09-07
New I-10 (schema-ledger continuity across a kit-id rename): `VectorStore`
and `VectorRepresentationClaims` name their current ledger id (`kitID` /
`KIT_ID`) and the ids that row carried before (`formerKitIDs` /
`FORMER_KIT_IDS`, `["VectorKit"]` and `["VectorKitClaims"]`), and expose
`prepareSchemaLedger(storage:)` / `prepare_schema_ledger`, which every open
path calls before `migrate(to:)` so a populated pre-rename estate never
replays the vector ladder (v5→v6 folds every `generation` to 0). `.noRow`
and `.renamed` pass; `.conflict` (rows under both ids) leaves both rows,
logs one warning, and returns so the estate still opens and `migrate(to:)`
runs under the current id without replaying; only a failed rename call
throws `storeUnavailable`. The CorpusKit standalone constructors and the GeniusLocusKit 1.4 → 1.5
capsule read the pair from these constants (one source). Additive (MINOR).

### 2.0.0 -- 2026-09-05
I-4a rewritten: the int8 quantisation policy is ratified (symmetric
per-vector, SubstrateKernel `Int8Vec`), so int8 payloads are written and
read like float32 (table-only) and the fail-closed rejection is gone. The
error case `int8QuantizationPolicyUndefined` / `Int8QuantizationPolicyUndefined`
is removed (BREAKING; MAJOR). New I-4b: encoder span rows over the existing
`vectors` table and the `writeSpanVectors` / `spanVectors` /
`deleteSpanVectors` / `reclaimRetiredVectorRows` surface (both ports). New
C-15: the shared int8 conformance fixture `int8_vectors.json`, asserted by
both ports (`q`, `scale` bit-exact; `dotQuery` within 1e-5).

### 1.12.0 -- 2026-09-05
Sidecar freshness (B-3a, C-12, § 9): the count compared against the sidecar
`live_count` is the table's serving-generation binary-row count — the row set
the sidecar is built from — not every binary row. The Swift port counted every
binary row, so any estate holding superseded generations pending reclaim
rebuilt and rewrote its sidecar on every open while the Rust port loaded it;
both ports now apply the serving-generation predicate. Added C-14: the shared
top-K boundary-tie conformance vector (`hamming_topk_boundary_ties.json`)
asserted by BruteForceIndex, MIHIndex (m=16, m=4), and both VectorStore index
tiers in both ports. Additive requirement (MINOR).

### 1.11.0 -- 2026-09-04
Renamed from VectorKit to SynapseKit. The name VectorKit collides with an Apple private framework in MapKit. All behavioral contracts, invariants, and conformance requirements are unchanged. File renamed from VECTORKIT_SPEC.md to SYNAPSEKIT_SPEC.md. Additive rename (MINOR).

### 1.10.1 -- 2026-08-26

Hedging-vocabulary sweep (Bob ruling 2026-08-25): normative prose now states facts as facts. No contract change.

### 1.10.0 -- 2026-08-26
Added B-13b: HNSW BULK graph builds (rebuildHNSWIndex / rebuild_hnsw_index,
HNSWIndex compact) insert rows in content-stable (vecHash ASC, key ASC)
order, and in-build neighbour-truncation cuts tie-break by (vecHash,
itemID) instead of arrival order. This closes the REPLAY_DRIFT_RCA
queued follow-up left open by 1.9.0: the graph STRUCTURE previously rode
insertion order, which rode per-run-random item UUIDs, so approximate
results were per-run stable but not cross-run stable. Incremental
single-row inserts keep arrival order (documented caveat: only bulk
rebuilds guarantee cross-run identity). Cross-port graph identity remains
a non-goal. Behavioral (MINOR).

### 1.9.0 -- 2026-08-26
The universal k-NN tie-break becomes content-stable in the BINARY lane:
B-6 orders (distance, vecHash, itemID) where vecHash is FNV-1a 64 over
the stored vector payload bytes. B-13/B-13a wording corrected to record
the same rule the float engines already implement (the code predated
this spec text). Rationale: item UUIDs are assigned per provisioning,
so a UUID tie-break is stable within one estate but NOT across
independent builds of the same content — measured as association-graph
run variance in the dream associate sweep (REPLAY_DRIFT_RCA
2026-08-26). Residual: byte-identical vectors still fall to itemID.
MaxSim (ColBERT lane, no production consumers) and HNSW graph BUILD
order are explicitly out of this change; HNSW cross-run graph stability
is a queued follow-up. Behavioral (MINOR).

### 1.7.0 -- 2026-08-15

Gate hardening (VEC-SHADOWSWAP-01, Unit A2):
- Updated B-16: `reclaimSupersededGenerations` now accepts `batchLimit` (Swift) /
  `batch_limit` (Rust). `nil`/`None` = unbounded production path (unchanged behavior).
  `Some(n)` = bounded pass that leaves registry 'pending-reclaim' for resumability.
  Adds explicit crash-safe resumability guarantee: a second unbounded pass after a
  mid-reclaim kill finishes without error and produces correct query results.
- Updated B-16 public API reference: `reclaimSupersededGenerations(batchLimit:)`.
- D-7: Swift `HNSWGraphMaintenance.clearFloatIndex(now:)` removed from the protocol
  and `EstateHNSWGraphMaintenance`; ALPHA cadence manages the float index through
  `publishShadowGeneration`. Rust `HNSWGraphMaintenance.clear_float_index` retained
  (called at `dreaming_cycle.rs:1847`).

### 1.6.0 -- 2026-08-15

Added shadow-generation vector swap (VEC-SHADOWSWAP-01, TASK-MXE-2026-0332):

**Schema v6:** The `vectors` table UNIQUE constraint changes from
`(item_id, vector_index, model_id)` to `(item_id, vector_index, model_id, generation)`,
allowing serving and shadow rows to coexist for the same item/model. A new
`generation INTEGER NOT NULL DEFAULT 0` column is added to `vectors` and `hnsw_graph`.
A new `vector_generations` registry table tracks `(model_id, serving_generation,
shadow_generation, shadow_state)` per model. A new index `idx_vectors_model_generation`
on `(model_id, generation)` supports generation-filtered scans. The v5→v6 migration
recreates the `vectors` table via four `.custom(sqlite:)` operations (SQLite cannot
ALTER TABLE to change UNIQUE constraints), copies all existing rows at generation 0,
and adds the new columns, table, and index.

**New behavioral contracts:**

**B-16 (shadow-generation swap):** `VectorStore` supports write-under-shadow semantics.
While a shadow generation is in flight for a model, `addPayload` and `addPayloads` writes
for that model are tagged with the shadow generation and do NOT update any resident
structure (binary array, float index, HNSW graph). The serving lane continues to answer
queries from the current serving generation. `publishShadowGeneration` atomically flips
`serving_generation` to `shadow_generation` in a single storage transaction and then
rebuilds resident structures from the new serving rows. After publish, queries answer from
the new generation. `reclaimSupersededGenerations(batchLimit:)` idempotently deletes
vectors rows and hnsw_graph rows whose generation is neither the current serving generation
nor an active shadow build. `batchLimit: nil` (unbounded, production path) deletes all
superseded rows in one pass and clears the registry state. `batchLimit: Int` (bounded,
incremental path) deletes at most `n` rows per model and leaves the registry
'pending-reclaim' so a subsequent unbounded pass can finish — enabling crash-safe
resumability across mid-reclaim kills.

**B-16a (no-serving-gap guarantee):** During a shadow build, all read paths (binary lane,
float/HNSW lane, findByKeyword, recentItemIDs, vectors(forItemID:)) filter to the current
serving generation. Shadow rows are invisible to callers until `publishShadowGeneration`
commits.

**B-16b (crash safety):** A crash mid-build leaves the shadow in `building` state; calling
`beginShadowGeneration` again allocates a new shadow generation strictly above the
abandoned one, making the abandoned rows reclaimable. A crash mid-publish leaves the
registry in a consistent state: either the old or the new `serving_generation` is
authoritative, never a partial flip. A crash mid-reclaim is safe to re-run (`reclaimSupersededGenerations`
is idempotent and resumes without error).

**B-16c (HNSW generation coherence):** The HNSW graph carries a `generation` tag. A graph
whose generation mismatches the model's `serving_generation` at query time is treated as
absent (falls back to exact scan). `publishShadowGeneration` rebuilds the graph from the
new serving rows and stamps it with the new `serving_generation` before any query can use
it. `lastServedGraphGeneration(for:)` returns the generation of the graph instance that
last answered a float nearest-neighbour query.

**New public API:** `beginShadowGeneration(modelIDs:)`, `publishShadowGeneration(modelIDs:)`,
`reclaimSupersededGenerations(batchLimit:)`, `peakShadowStorageBytes(for:)`,
`lastServedGraphGeneration(for:)`. See SYNAPSEKIT_INTERFACE.md §1.9.0 for signatures.

**Swift-only (Unit A):** The Rust port (Unit B) is a sequenced follow-up mission.

### 1.5.0 -- 2026-07-20

- Defined canonical `Drawer.id` keys for GLK Corpus vectors and limited passage
  identities to standalone CorpusKit.
- Required lane/model ownership-scoped deletion in GLK and removed
  `destroyAllVectors` from composed lifecycle and migration paths.

### 1.4.0 -- 2026-07-16
Added B-3d — behavioral contract for `replaceModelVectors(modelID:_:)` /
`replace_model_vectors`: the bulk re-embed path that deletes all rows for a
model and plain-INSERTs the replacement batch in ONE transaction, rebuilding
the resident binary index ONCE (O(N) vs O(N²) for N individual removes+adds).
Documents int8 fail-closed precondition (I-4a), deferred-index flush guarantee,
and the deliberate design boundary vs `addPayloads` (live-capture path).
Additive (MINOR).

### 1.2.0 -- 2026-06-17
Added invariant I-8 (the `ext` forward-compat slot, the forward-compatible ext-slot contract): the `vectors` table carries one nullable `.json` `ext` column at schema v3, inert in 1.0. Pre-ship pre-provisioning during the 1.0.0 free-migration window.

### 1.3.0 -- 2026-06-17
Added the "Cross-restart persistence (both ports)" conformance requirement
under the crash-safety section: a `VectorStore` over the on-disk SQLite
backend reconstructs resident state (binary Hamming lane + Lane D float lane)
across a process restart, with no table rebuild on the happy sidecar path, so
`findNearest`/`findNearestFloat`/`findFarthestFloat` reproduce their pre-close
results on reopen. Gated in both ports (Swift `findNearestSurvivesReopenSQLite`
/ `floatIndexSurvivesReopenSQLite`; Rust `find_nearest_survives_reopen_sqlite`,
`find_nearest_survives_reopen_sqlite_with_sidecar`,
`float_index_survives_reopen_sqlite`). No public symbol change — the SQLite
backend ships in PersistenceKit and the store is already backend-agnostic;
this records the contract and closes the Rust conformance-coverage gap.
PostgreSQL persistence remains v1.1 (federation). Additive (MINOR).

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
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.- **1.8.0 (2026-08-20)** — Jaccard binary metric unlocked (W2.5 Track M1): BruteForceIndex serves .binary(.jaccard) — set-overlap/union over 256-bit fingerprints, composed from the conformance-gated zip4+popcount primitives (SubstrateTypes.Jaccard; scalar is the oracle). Jaccard always serves from the brute-force engine (MIH is Hamming-specific). DenseHit stores the [0,1] distance as an f32 bit pattern (the float-lane encoding; the original reserved Double-through-Int32 encoding could never round-trip and was corrected before first use). VectorMatch gains an additive `score` field carrying metric-native similarity; `distance` maps Jaccard onto the 0…256 integer scale as the ordering key.


