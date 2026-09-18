---
title: CorpusKit Specification
version: 2.8.0
status: accepted-1.1-target
date: 2026-09-14
description: "Behavior and invariants for CORPUSKIT. 2.8.0: LSA retraining is document- and sweep-bounded, cooperatively cancellable, and publishes only completed replacement bases."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/CORPUSKIT_INTERFACE.md
  - docs/reference/SYNAPSEKIT_SPEC.md
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

The default distributional provider is random indexing. References below
to other record-vector families describe optional provider contracts.
They do not define the current recall ensemble. See
[the retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md).


## § 1 — What this package is

CorpusKit is a standalone-capable retrieval-augmented-generation database and
the RAG indexing engine used by GeniusLocusKit. It builds BM25 and model-tagged
vector retrieval state over a `CorpusContentSource`, fuses the available lanes,
and returns the canonical identity supplied by that source. It also defines the
`Tokenizer` protocol used by its concrete embedding providers (MiniLM, mpnet,
EmbeddingGemma), which conform to SynapseKit's `EmbeddingProvider`; the providers
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
both kits' standalone use and the bottom-up dependency graph. SynapseKit remains
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
- Optional standalone passage indexing with a developer-selected token window
  and overlap and revision-bound offsets; passage text is never copied into
  passage rows. Swift selects it with the `StandalonePassages` package trait;
  Rust selects it with the `standalone-passages` crate feature.
- The BM25 inverted index and its scoring contract.
- Hybrid recall: candidate-window fan-out, Reciprocal Rank Fusion of
  vector and keyword hits, deterministic ranking, and aggregation to canonical
  content identity.
- The `Tokenizer` protocol, the concrete embedding providers (which
  conform to SynapseKit's `EmbeddingProvider`), and the
  model-tagging discipline that forbids cross-model comparison.
- Standalone content synchronization and composed-mode derived-index
  invalidation.
- The 1.0-to-1.1 migration contract for chunk-backed GLK databases.

This specification does NOT define:

- API signatures — those live in `CORPUSKIT_INTERFACE.md`.
- Embedding storage, the ANN/HNSW index, or `VectorStore.findNearest`
  ordering — those are SynapseKit's (`SYNAPSEKIT_SPEC.md`).
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
PersistenceKit ── CorpusKit ── SynapseKit ── ConvergenceKit
   (Storage)        │  ▲          (VectorStore)   (SyncManifest)
                    │  └── CorpusKitProviders (MiniLM, mpnet, Gemma)
                    ▼
              GeniusLocusKit / NeuronKit (composition)
```

**Depends on:** SubstrateLib (HLC, `FloatSimHash` projection),
EngramLib (the `Engram` type), EideticLib (sentence segmentation via
`EideticLib.sentences`), PersistenceKit (the `Storage`
backend and schema declaration; the in-memory backend backs the ingest
queue), ConvergenceKit (the `SyncManifest` type), SynapseKit
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
SynapseKit's, consumed directly by `CorpusKitProviders`' concrete
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

**I-14 (deferred provider contract):** the earlier platform embedding
providers are outside the default build. Their disposition is recorded in
[the retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md).
Current span-encoder activation follows the encoder registry contract.

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
whole-content indexing. GLK/MOOTx01 enables neither the Swift
`StandalonePassages` trait nor the Rust `standalone-passages` feature, so the
passage-policy enum case, segmenter, policy authority, passage identities,
passage table, overlap logic, and passage-text storage are absent from that
build. One active GLK Drawer produces one BM25 document identity and one logical
provider result identity per model.

**I-19 (standalone passage containment):** standalone CorpusKit may enable
passage indexing only as an explicit `IndexUnitPolicy`. The developer selects a
positive token window and an overlap in `[0, window)`. Boundaries use the
versioned `corpus-alphanumeric-v1` tokenizer so Swift and Rust produce identical
UTF-8 ranges. Persisted passage state contains the canonical content ID, content
revision/digest, policy fingerprint, and range only; the text remains owned by
the standalone document store. Public recall aggregates passage scores to
`CorpusContentID` and may attach the best range as evidence.

**I-19a (per-database passage authority):** each standalone database persists
exactly one policy fingerprint containing policy version, tokenizer identity,
window, and overlap. Reopening with the same policy is idempotent. Reopening
with a different policy is rejected until the caller explicitly rebuilds the
derived generation. An older unbound database with existing derived rows cannot
silently enable passages; it must first bind whole-content or be rebuilt.

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
crash before the final write safely replays reconciliation. The lanes the
engine claims per slot are `claimedLanes` / `CLAIMED_LANES`: lane 0 (the
engram row) in the default build, lanes 0 and 1 (the whole-record float row)
under `WholeRecordDense` / `whole-record-dense`; the GeniusLocusKit 1.6→1.7
capsule releases a populated estate's lane-1 claim with its float rows
(GENIUSLOCUSKIT_SPEC I-26), and the default build's reconcile never
re-creates it.

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

**B-1a (1.1 standalone passage policy):** new passage indexing uses
`tokenWindows(windowTokens:overlapTokens:)` in Swift and the byte-equivalent
`TokenWindows` policy in Rust. Consecutive windows advance by
`windowTokens - overlapTokens`; the final window ends at the final token and is
not followed by a redundant overlap-only tail. It persists only canonical
content id, revision/digest, policy fingerprint, and UTF-8 range. The source
document remains the sole text owner. The policy is rejected in attached mode
and is not compiled into the GLK/MOOTx01 dependency build.

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

**B-22 (retrain counts path):** when a force retrain fires on an attached
`CorpusContentEngine` slot whose provider has a persisted basis, the engine
attempts the **counts path** before falling back to full corpus re-tokenization.
The guard chain runs in order; the first failing guard records its reason and
routes to the corpus path:

1. *firstTrain* — no persisted basis row exists; the counts path does not apply.
   This includes the first training of any slot, forced or not.
2. *noCountsRow* — no persisted counts row found for the provider key; counts
   cannot be restored.
3. *notCountsCapable* — `finalizeFromCounts()` returned `false`; LSA and NMF
   always fall back here because their per-document TF rows are not persisted in
   the counts blob.
4. *deltaNotFoldSafe* (attached mode) / *foldOrderProvenanceUnknown* (standalone
   mode) — RandomIndexing's float context-vector accumulation is order-sensitive;
   the counts path cannot safely reconstruct an RI basis without knowing that the
   accumulated fold order matches the canonical training order (reviewer finding
   F-3, see INTERFACE § 2 `TrainableEmbeddingBasis`). In **attached** mode the
   pending-reference delta is non-empty and `countsDeltaFoldSafe` is `false`; the
   real pending delta IS the operative reason the counts path cannot proceed, so
   the decision is `corpus(.deltaNotFoldSafe)`. In **standalone** mode there is no
   pending-reference tracking; the maintained accumulator folds in ingest-arrival
   order while a from-scratch train uses active-chunk order, and the two cannot
   be proven equal, so the decision is `corpus(.foldOrderProvenanceUnknown)`
   (reviewer finding F-11).
5. *populationMismatch* — `PersistedBasis.trainedChunkCount` (frozen base document
   count written at the last corpus-path publication) plus the non-subsumed pending
   reference count does not equal the current active-content-ID count from the
   source. A revision or removal drives a mismatch and forces a full retrain.
   `PersistedCounts.documentCount` is the live monotonic anchor and is NEVER used
   for this comparison.
6. *pendingUnresolvable* — a non-subsumed pending reference's `contentID` resolved
   to `nil` from the source; the corpus path heals by deleting all references and
   republishing from surviving active IDs.

When all guards pass, the provider is reconstructed from the empty-basis blob and
counts are restored. Per-provider behavior is fixed:

- *PPMI:* the non-subsumed pending references are delta-folded into the restored
  counts in `contentID` ascending order (one body paged per reference). The
  integer count maps are commutative so fold order is irrelevant to the derived
  basis. `finalizeFromCounts()` then derives the serving basis without touching
  corpus text. The decision is `.countsDeltaFold(folded: N)` where N is the
  pending count; `.countsRestore` when the pending set is empty.
- *RandomIndexing:* restore-only — `countsDeltaFoldSafe` is `false` so any
  non-empty pending delta (attached mode) forces the corpus path with
  `corpus(.deltaNotFoldSafe)`. Standalone RI always takes the corpus path with
  `corpus(.foldOrderProvenanceUnknown)` because fold-order provenance cannot be
  proven (guard 4; reviewer finding F-11). When the pending set IS empty in
  attached mode (counts reflect the full corpus), the guard-4 check passes and the
  decision is `.countsRestore`. Zero bodies are paged in either case.
- *LSA / NMF:* always take the corpus path because `finalizeFromCounts()` returns
  `false` (guard 3).

**Publication** for the counts path occurs in a single serializable transaction:
basis row upsert (`PersistedBasis` with `trainedChunkCount` = frozen base document count +
pending count), counts row persist via `persistCounts`, and per-reference delete
for every folded pending row. *Per-reference delete* — not `deleteReferences` —
is required to preserve subsumed markers written by earlier corpus-path
publications. Those markers are consumed by delayed-admission logic that may still
hold a training-snapshot reference; `deleteReferences` would erase them. The
serving provider and counts accumulator are installed into the slot immediately
after the transaction commits, without corpus re-embedding — the finalized basis
already reflects the full corpus population.

Skipped IDs during a corpus-path publication (content IDs that resolved to `nil`
from the source) become non-subsumed sentinel reference rows. On the next
force-retrain pass they appear in the pending delta; if they still resolve to
`nil`, guard 6 (*pendingUnresolvable*) routes to the corpus path, which deletes
all references and republishes from surviving active IDs.

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

**C-12 (passage darkness):** GLK builds CorpusKit without the standalone
passage trait/feature. The resulting `CorpusIndexUnitPolicy` contains only
whole-content, the attached schema contains no passage-policy columns or tables,
one logical index identity is produced per Drawer, and no segmenter can execute
during capture, drain, reindex, or recall. Swift and Rust GLK suites carry
negative compile-selection and schema gates.

**C-12a (standalone policy binding):** opt-in standalone suites prove non-zero
windows, bounded overlap, byte-identical overlapping UTF-8 ranges, idempotent
same-policy reopen, independent policies in separate databases, rejection of a
changed policy, and rejection of passage enablement over existing unbound
derived state.

**C-13 (migration preservation):** fixtures containing 1.0 chunk rows,
chunk-keyed CorpusKit vectors, and unrelated Drawer-keyed vectors migrate to
1.1 with identical canonical Drawer/audit data, rebuilt CorpusKit rows keyed by
Drawer ID, no surviving chunk-keyed artifacts, and byte-identical unrelated
Drawer-keyed vectors.

**C-14 (maintained-count restart determinism):** both ports exercise the queue
and direct-feed paths with a new canonical identity, multiple revisions,
remove/re-add, same-digest replay, and reopen between revisions. The document
anchor increments once per canonical identity, the vocabulary anchor never
decreases, the frozen base blob is unchanged until provider publication, and a
fixed governor threshold produces the same decision immediately before and
after reopen.

**C-15 (training-path decision seam):** the `TrainingPathDecision` /
`CorpusPathReason` enums (both ports, INTERFACE § 2) and the
`_trainingPathDecision(for:)` / `_training_path_decision` accessor on
`CorpusContentEngine` are a **test seam** that exposes which path
`trainTrainableSlots` took for each modelID in the most recent call. Both types
conform to `Equatable` so suites can assert on structure directly. Conformance
suites MUST assert the expected decision for each guard-chain scenario: counts
restore (all guards pass, empty pending), counts delta-fold (all guards pass,
non-empty PPMI pending), and each of the seven corpus-path reasons (B-22):
firstTrain, noCountsRow, notCountsCapable, deltaNotFoldSafe (attached RI with
non-empty pending delta), foldOrderProvenanceUnknown (standalone RI),
populationMismatch, and pendingUnresolvable.
Non-forced calls that skip already-trained slots return `nil` for those slots —
the accessor is not populated for skipped slots.

**C-15 (dense pooling):** over the shared fixture corpus
(`Tests/SharedVectors/dense_pooling_vectors.json`, 12 documents), for each of
random-indexing-v1, ppmi-v1, and nmf-v1: (a) the mean pairwise cosine between
the document vectors is below 0.5 and reproduces the recorded float bits
(measured: −0.088 / −0.089 / −0.091); (b) every document's opening sentence,
embedded through the query path, ranks that document first; (c) the document
path (`embedPair`) and the query path (`embedFloat`) return bit-identical
vectors for the same text; and every document and query vector is bit-identical
across ports (B-23, I-7). The basis/counts format-version gate is covered by a
both-port test that rewrites a trained estate's rows under the previous
version, reopens (untrained, opt-out), and reindexes (current rows republished,
float lane serving) (B-24).

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
No SynapseKit type, Engram, model ID, or internal passage identity crosses the
public result boundary. This is the sealed-vector principle applied at the Kit
level: callers know canonical content and queries, not retrieval storage units.

### 9.2 EmbeddingModel enum

`EmbeddingModel` is a CorpusKit-owned enum. It lets the host select
an embedding model without importing SynapseKit or naming an
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

**B-8 (sealed-vector and sealed-index-unit principle):** No SynapseKit type or
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
standalone document schema plus CorpusKit/SynapseKit derived schemas. Attached
GLK construction applies only derived CorpusKit/SynapseKit schemas; the GLK
composite supplies LocusKit's Drawer schema and excludes CorpusKit document and
passage tables. Callers do not need to pre-open the selected schema set.
Before each SynapseKit declaration is migrated, the constructor calls that
store's ledger preparation (`VectorStore.prepareSchemaLedger(storage:)` before
the vector store's declaration; `VectorRepresentationClaims.prepareSchemaLedger`
before the claims ledger's, in `CorpusContentEngine`; Rust
`prepare_schema_ledger`), so a populated estate a pre-rename runtime left
behind (ledger rows under `VectorKit` / `VectorKitClaims`) opens without
replaying the vector ladder (SYNAPSEKIT_SPEC I-10). A conflicted ledger (rows
under both a former and the current id) does not fail construction: both rows
are left in place, SynapseKit logs one warning, and the constructor migrates
under the current id, whose row already records the ladder position, so no
step replays (the GeniusLocusKit 1.4 → 1.5 capsule applies the same policy).
Only a failed rename call fails construction, with
`CorpusKitError.storeUnavailable` wrapping the SynapseKit error.
Applies to `Corpus.init` / `Corpus::open` (and the provider test seam)
and to `CorpusContentEngine` in both modes. Pinned regression, both ports:
ledger row `VectorKit` v6 plus one `vectors` row at generation 3 → after a
standalone open the row is at generation 3 and the ledger carries one row for
the store, under `SynapseKit`. Conflict pin, both ports: the same estate plus
`SynapseKit` v6 and `SynapseKitClaims` v1 rows → both constructors open, every
ledger row keeps its version, and the row is still at generation 3.

**B-13 (basis training lifecycle):** for a trainable distributional
provider (RI/PPMI/LSA/NMF):
- *Load-on-open:* `Corpus.init`/`open` reconstructs the trained provider
  from the persisted basis (when present for the provider key AND current
  under B-24), so the dense lane is trained-ready immediately after restart
  with no retrain.
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
  The full re-embedding loop MUST hold SynapseKit's deferred-index bracket and
  publish the resident index once after the durable rewrite; rebuilding the
  resident index per content item is forbidden.
- *Lifecycle:* `destroyRecallIndex` additionally deletes all basis rows
  AND all counts rows (no orphans). All paths are deterministic — `now` is
  the only clock source; the engine never reads the wall clock. Swift and
  Rust produce the byte-identical basis blob and embedding for a shared
  corpus (I-7): the ingest → reindex → reopen → embed path reproduces the
  canonical RI basis blob and embedding bit patterns byte-for-byte on both ports.

**B-23 (bounded LSA retraining):** the public bounded reindex path admits an
LSA attempt only when its active-document snapshot fits `maxDocuments`, caps
Jacobi work at `maxSweeps`, and observes task cancellation or the supplied
deadline before allocation and between tournament rounds. These values come
from `MootProductIdentity.Settings` (`corpus.lsa_retraining`), with identical
defaults in both ports: 2,048 documents, 30 sweeps, and 30,000 milliseconds.
Training always targets a fresh provider. A limit, deadline, or cancellation
outcome leaves the serving provider and persisted basis untouched; only a
completed attempt may be installed and persisted.
The production `CorpusContentEngine` obtains at most `maxDocuments + 1`
identities through the source's storage-limited enumeration before it opens a
shadow generation or reads any record body. A cap refusal therefore performs
no training, re-embedding, basis publication, or vector-generation publish.
All provider preparations finish before any provider is committed; one skipped
provider aborts the whole attempt so a deadline cannot publish mixed bases.
The deadline is a training-admission and provider-preparation budget. Once all
providers are complete and the provider commit phase begins, re-embedding must finish the
shadow swap; it does not convert a committed provider set into a skipped result.

**B-23 (distributional pooling):** the embedding a Random Indexing, PPMI,
or NMF provider produces for a text is ONE function applied to documents at
index time and to queries at recall time:
- RI and PPMI: the DISTINCT terms of the text (UTF-8 order), each weighted by
  its smoothed IDF `max(0, ln((N+1)/(df(t)+1)))` fitted over the training
  documents, summed over the term's context vectors, L2-normalised, the
  component along the unit corpus-mean direction removed (`u − (u·m̂) m̂`),
  L2-normalised. The corpus-mean direction is
  `l2Normalize(Σ_t df(t)·idf(t)·vector(t))` — the direction of the mean raw
  document vector under the same binary term weighting — a closed form over
  the maintained counts, so the counts path (B-22) fits the identical bytes.
- NMF: the term-document matrix and the text vector both carry
  `ln(1+tf)·idf`; the fold-in through the pseudo-inverse of W is
  L2-normalised, the unit mean of the training documents' fold-in vectors is
  removed, and the result L2-normalised.
- The IDF table and mean direction are FITTED STATE: they are produced by
  `finalize()`, serialized in the basis blob, and reconstructed with it. A
  reconstructed provider pools exactly as the trainer did (round-trip law).
- A text whose matched terms all carry IDF 0 (every term appears in every
  document — a one-document corpus is the degenerate case, matching LSA's
  all-zero SVD) pools to NO SIGNAL: `embedFloat` returns `[]` and `embed`
  returns the zero engram, an opt-out distinct from the all-OOV vocabulary
  miss. A trained but unfinalized RI or PPMI provider reports no basis.
- Why: the plain token sum every family used before pointed every document
  at the corpus mean (mean pairwise cosine 0.999 RI / 0.955 PPMI / 0.990 NMF
  on a 13,817 drawer estate; dense-only nDCG@10 at chance). IDF weighting
  removes the shared terms' contribution; mean-direction removal removes the
  shared component that survives it; doing both to documents and queries
  alike is what lets a document's own opening sentence find the document.

**B-24 (basis format-version gate and migration):** the shared basis format
version (`basisFormatVersion` / `BASIS_FORMAT_VERSION`, currently 2) is the
version byte of every basis and counts blob frame. Every reader refuses a
blob of any other version with a structured decoding error — a v1 blob is
never decoded as if it were v2. At open, the corpus compares each persisted
basis frame with the frame the fresh provider writes (`BasisBlobFrame` /
`basis_blob_frame`): a stale-version basis opens the slot UNTRAINED (its
basis digest is the untrained sentinel; an error-level log names both
versions) and a stale-version counts row restores as `false` (the sentinel
contract of B-14). The estate stays openable; the stale vectors are never
matched against queries pooled the current way, because the slot embeds
nothing until it is retrained. The retrain is the ordinary provider
reconcile at open (train the untrained slots from the estate's content, then
re-cover every row under the new basis digest) and, explicitly and reported,
the `mootx01 upgrade` dense-pooling convergence step — the only migration
vehicle — which runs that open under the daemon quiesce for any estate whose
`corpus_provider_basis` rows carry another version and verifies that none
remain afterwards. Idempotent: once every row is current the step is a no-op.

**B-14 (incremental maintained counts):** each trainable provider has a
published raw-statistics base in `corpus_provider_counts`. Standalone `Corpus`
may replace that base at bounded ingest/reindex publication points. Attached
`CorpusContentEngine` MUST NOT serialize the full base for each canonical
content change. It writes an idempotent row to
`corpus_provider_count_references`, keyed by provider generation and canonical
content identity. In the same transaction it publishes that reference, the
corresponding content checkpoint, and the `doc_count` / `vocab_size` anchor
columns. The row stores identity/revision/digest metadata only—never canonical
text, tokens, or passages. A new identity increments the document anchor once;
a changed digest refreshes the existing identity reference, folds its text for
novel vocabulary, and MUST NOT increment the document anchor; an identical
digest is an idempotent no-op. Both anchors are nondecreasing. Open reconstructs
the working accumulator from the frozen base counts blob plus canonical-source hydration of
pending references, then restores the stored anchor columns as the governor's
durable authority. A provider retrain/publication atomically replaces its base,
publishes matching anchors, and deletes only that provider generation's
subsumed references.

The accumulator remains separate from the serving provider, so vocabulary
growth cannot desynchronize a frozen LSA/NMF basis. LSA/NMF bases still derive
TF from the canonical corpus during refactor; RI/PPMI retain their full additive
base state. `Corpus.maintainedVocabAnchor()` exposes the
maximum maintained vocabulary across trainable slots. The autonomic governor's
auto-reindex trigger (NeuronKit) fires on VOCABULARY growth —
`max(floor, ceil(fraction × lastReindexVocab))`, defaults floor 25 / fraction
0.10 — reading that anchor, replacing the prior +25-index-unit gate. The counts codec
is byte-identical across ports (the provider owns it via the
`TrainableEmbeddingBasis` counts seam).

The base and reference tables are intentionally retained in attached GLK
estates. Neither is a second content store: the base is provider-specific
derived statistics and the reference table is identity metadata. Reopen
conformance proves that the maintained vocabulary anchor and threshold decision
are restored before serving, that same-digest replay is idempotent, that
revision/remove/re-add paths do not double-count a canonical identity, and that
queued and direct-feed revisions use the same admission authority.

**Counts invalidation on migration.** `INVALIDATED_COUNTS_SENTINEL` / `invalidatedCountsSentinel` is a defined empty byte slice (Rust) / empty `Data` (Swift) on `CorpusProviderCountsStore` in both ports. It means "counts invalidated, rebuild from zero." The upgrade migration writes this sentinel into `corpus_provider_counts.counts` for every row. Writing the sentinel preserves the `doc_count` and `vocab_size` monotone anchors, which the migration is required to retain. `restore_counts_into` / `restoreCounts(into:)` checks for the sentinel before any provider decode, before the v4 term-row branch, so that surviving term rows from a prior schema generation cannot cause the provider decoder to receive an empty header. An empty blob causes the method to return `Ok(false)` / `false`. A non-empty but undecodable blob propagates `DecodingFailure` / throws — real corruption must fail loudly and is not silenced by this path. Both ports share the predicate through `is_invalidated_counts` / `isInvalidatedCounts(_:)` so the writer and reader cannot drift independently.

**Sentinel-preserving flush.** `persist_counts_into` / `persistCounts(provider:into:)` skips writing when the provider's maintained vocabulary is empty AND the stored row for that key carries the sentinel. Without this guard, a flush on a just-migrated estate — whose live accumulator is empty — would serialise a valid empty-state blob over the sentinel, erasing the "rebuild from zero" signal. The restore path would then return `true`, the caller guard would not fire, and a zero-vocabulary basis would be published over the trained basis the migration preserved. The guard tests `counts_vocabulary_size` / `countsVocabularySize` first (in-memory, no I/O); the storage read occurs only when that size is zero.

**Reindex latch.** The upgrade migration calls `CorpusReindexLatch.reindexRequired` / the Rust equivalent. That call writes the key `corpus_reindex_required` into the estate manifest and enqueues a `{"kind":"full_reindex"}` marker job on the `"reindex"` stream (`CorpusReindexLatch.swift:103`, `reindex_latch.rs:REINDEX_MANIFEST_KEY`). Neither `Corpus` nor `CorpusContentEngine` reads that manifest key directly. The rebuild occurs when `restoreCounts` / `restore_counts_into` returns false and the caller's counts-path guard routes to the full corpus retrain — the outcome the sentinel and the sentinel-preserving flush together guarantee on the first retrain cycle after migration.

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
- All persisted counts rows in `corpus_provider_counts` and all pending rows
  in `corpus_provider_count_references` (via
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

## § 12 — Encoder contract (span rerank)

CorpusKit owns the contract a retrieval-trained sentence encoder is served
through. The encoder reranks the lexical head; it is never an ensemble member
and never writes the BM25 document.

### 12.1 Registry row value type

`EncoderModelSpec` mirrors one `encoder_models` row (LocusKit schema 19):
`modelID` (`<model>-w<windowWords>`; the span unit is part of the identity and
two window sizes are two indexes, never compared), `modelVersion` (weights
revision), `dim`, `queryPrefix`, `docPrefix`, `pooling` (`mean` | `cls`),
`tokenizerHash` (SHA-256 hex of the vendored `vocab.txt`), `windowWords`,
`overlapDivisor`, `maxSpans`, `maxSequence`. Serialised field names are the
column names. `EncoderModelSpec.floor` / `EncoderModelSpec::floor()` is
`minilm-l6-v2-w60` (all-MiniLM-L6-v2 @ HF `1110a243`, dim 384, mean, no
prefixes, 256 tokens, window 60, divisor 2, 32 spans) and is byte-identical
across ports.

### 12.2 `SpanEncoder`

`encodeQuery(text)` applies `queryPrefix`; `encodeSpans(spans)` applies
`docPrefix` to every span and preserves count and order. Both return
L2-normalised vectors of `dim` floats through `FloatVecOps.l2Normalize` /
`float_vec_ops::l2_normalize`. An empty input string yields the all-zero
vector (no direction), never an error. The float VALUES of a real model may
differ by port (CoreML vs candle, ruled); the shape and the normalisation are
conformance-gated. `ProviderSpanEncoder` is the shipped conformer: a spec, a
`SpanInference` seam (pooled vectors in input order) and a batch size
(`encoder_batch`); a seam vector of the wrong dimension or a batch of the
wrong count is `EncoderError.inferenceFailed`.

### 12.3 Spanner rule (shared fixture)

`Spanner.spans(wordCount:windowWords:overlapDivisor:maxSpans:)` /
`spanner::spans` returns half-open word ranges in ascending start order:

1. `wordCount <= windowWords` → one span `(0, wordCount)` (a zero-word record
   yields `(0, 0)`; callers skip empty records before encoding).
2. Otherwise `step = max(1, windowWords / overlapDivisor)`, starts
   `0, step, 2·step, …` while `start <= wordCount - windowWords`, each span
   `(start, start + windowWords)`. The remainder past the last full window is
   left uncovered, exactly as the measured offline reference.
3. If rule 2 exceeds `maxSpans`, `step' = ceil((wordCount - windowWords) /
   (maxSpans - 1))`, starts `0, step', …` while `start < wordCount - windowWords`,
   and the final start is pinned to `wordCount - windowWords` so the last span
   ends at `wordCount`; the count is then `<= maxSpans`.

Never longest-first. `Spanner.words` / `spanner::words` is
`defaultKeywordTokens` / `default_keyword_tokens` (the BM25 split), so span
bounds address the words the lexical lane matched. The fixture
`SynapseKit/Tests/Fixtures/encoder/spanner_vectors.json` (word counts
{0, 1, 59, 60, 61, 90, 120, 121, 900, 5000} × windows {60, 150}, divisor 2,
32 spans) is read by both ports' tests.

### 12.4 Factory and failure contract

`SpanEncoderFactory.make(spec:modelDirectory:)` / `SpanEncoderFactory::make`
(CorpusKitProviders / corpus-kit-providers) checks in order: directory and
`vocab.txt` present (else `modelUnavailable`); `sha256(vocab.txt) ==
spec.tokenizerHash` (else `tokenizerMismatch(expected:actual:)`); vocabulary
parses (else `loadFailed`); runtime loads (Swift: CoreML `.mlmodelc` /
`.mlpackage` via `CoreMLSpanInference`, WordPiece over `vocab.txt`; Rust:
`CandleNLProvider::load_with_max_tokens` under the `candle` feature, mean
pooling only). A build without a runtime reports `modelUnavailable` AFTER the
hash check, so a wrong vocabulary is always named first. Both ports hash the
same `vocab.txt`; the Rust model directory carries it beside `tokenizer.json`.
Callers (GeniusLocusKit activation) turn any of these into: no encoder for the
session, one log line, lexical-only recall, no error to the caller.

### 12.5 Cross-encoder contract (retrieval-time pair scoring)

CorpusKit also owns the contract a retrieval-time cross encoder is served
through; the stage that consumes it lives in GeniusLocusKit and the whole
contract is written up in `CROSSENCODER_SPEC.md`. `CrossEncoderProfile`
names the one packaged pair classifier (`ms-marco-minilm-l6-cross-v1`,
ms-marco-MiniLM-L-6-v2 @ HF `233902d2`, the same `vocab.txt` hash as the
floor sentence encoder, pair limit 512, pool 50, head 30, spans 3, RRF k 60)
and is byte-identical across ports; `artifactName` is the Pascal-cased id.
`PairScorer.score(query, spans)` returns one finite logit per span in span
order, empty for an empty list; `ProviderPairScorer` drives a `PairInference`
seam (text pairs in, raw logits out) in `batchSize` chunks (default 8) and
reports a wrong count or a non-finite logit as `inferenceFailed`. Every
scorer names its `backend`. `RerankDirective` (`bypass` | `apply`,
`profileID`, optional `reason`) is the request-borne decision the stage
consumes; it lives here so GeniusLocusKit and the ARIA surfaces share one
type. Pair tokenization is `[CLS] q [SEP] s [SEP]` with segment ids 0 / 1
and longest-first truncation (ties trim the query): Swift
`WordPieceTokenizer.tokenizePair`, Rust the `tokenizers` pair encode.
`PairScorerFactory` applies the § 12.4 check order over the same model
directory layout (Swift: `CoreMLPairInference`, the compiled classifier's
`logits` output; Rust: `CandlePairScorer` under the `candle` feature,
`bert.pooler.dense` + tanh + `classifier` over `[CLS]`).

## Changelog

### 2.6.0 -- 2026-09-08

Cross-encoder contract (§ 12.5), both ports: `CrossEncoderProfile`,
`PairScorer` / `PairInference` / `ProviderPairScorer`, `RerankDirective`,
pair tokenization (`tokenizePair`, the `tokenizers` pair encode) and
`PairScorerFactory` over `CoreMLPairInference` / `CandlePairScorer`; the
model directory resolver knows the packaged profile. Contract written up in
`CROSSENCODER_SPEC.md`.

### 2.5.0 -- 2026-09-07

Transient sub-span scoring runs under a work bound, both ports. `SubSpanBudget`
holds a per-record byte cap (16,384 bytes, cut on a scalar boundary) and an
aggregate budget of sub-span embedding calls per scoring call (1,024; the
query embedding is not counted). `SubSpanScoring.score` /
`sub_span_scoring::score`, `CorpusContentEngine.scoreSubSpans` /
`score_sub_spans` and `Corpus.scoreSubSpans(query:sourceIDs:)` /
`Corpus::score_sub_spans` visit the candidates in the caller's order, stop
when the aggregate budget is spent, and return a `SubSpanScoringOutcome`:
the scores, whether the budget truncated, the candidates it left without a
window (they keep their stored signals), and the windows embedded. A
candidate the budget reached only partway is scored over the windows it got.
The per-record cap alone never sets the truncation flag. Without the bound a
call's cost was the sum of every candidate's window count, which a client
able to file large records and issue ordinary searches could raise to
hundreds of thousands of synchronous embedding calls per query. Pinned by
the §7 tests of `SubSpanScoringTests.swift` and `sub_span_scoring_tests.rs`.

### 2.4.0 -- 2026-09-07
The representation claims follow the build (I-21): `claimedLanes` /
`CLAIMED_LANES` is `[0]` in the default build and `[0, 1]` under
`WholeRecordDense` / `whole-record-dense`; `registerClaims`,
`reconcileConfiguredProviders`, the shared-family check and the remove and
destroy paths iterate it. Populated estates lose their lane-1 claim and their
float rows through the GeniusLocusKit 1.6→1.7 capsule run by `mootx01
upgrade` (GENIUSLOCUSKIT_SPEC I-26), which supersedes the 2.3.0 note about a
later reclaim. LSA on a switch of its own: the `LsaProvider`, its basis
training and its tests compile only under trait `LSA` (`MOOTX01_LSA`) / cargo
feature `lsa` (both enable `DenseFamilies` / `dense-families`); `DenseFamilies`
no longer compiles it, so `CorpusEnsemble.defaultEnsemble()` /
`default_ensemble()` under DenseFamilies is RI, PPMI, NMF, FDC and under LSA
is RI, PPMI, LSA, NMF, FDC. `EmbeddingModel.lsa` / `EmbeddingModelConfig::Lsa`
stays in every build as vocabulary, like the other family cases. The family
is dark and unproven since 2026-09-07 (DECISION_RETIRED_TECHNIQUES_LEDGER);
no dark-variant gate row builds it.

### 2.3.0 -- 2026-09-07
The whole-record dense float engine becomes an opt-in sidecar, both ports.
Under the `WholeRecordDense` trait (`MOOTX01_WHOLE_RECORD_DENSE`) / the
`whole-record-dense` cargo feature, which `DenseFamilies` / `dense-families`
enables, ingest writes the float row (`vectorIndex` 1, kind float32) beside
the engram row and the per-signal float query surface (`floatNearest`,
`floatNearestPerSignal`, `floatFarthestPerSignal`,
`floatNearestPerSignalWithDiscrimination`, `recomposeDenseVector`,
`FloatLaneOutcome`, `FloatDiscriminationSignal`) exists in the Swift library
target `CorpusKitWholeRecordDense` / the Rust `float_lane` modules. The default
build writes the engram row only, holds no float query surface and answers
the span stage alone (ruling 2026-09-07: one active dense provider per
machine, the Arctic span shape). The representation claims still cover
`vectorIndex` 1 so float rows already in a populated estate stay in place;
a later `mootx01 upgrade --reclaim` may vacuum them. `embedFloat`, the
provider protocol and transient sub-span scoring (`scoreSubSpans`) are
unchanged. The engine members the sidecar reads are `package` visible.

### 2.2.0 -- 2026-09-07
B-12 extended: the standalone constructors (`Corpus`, `CorpusContentEngine`;
both ports) call the SynapseKit ledger preparation for each SynapseKit
declaration before migrating it, so a populated pre-rename estate (ledger rows
under `VectorKit` / `VectorKitClaims`) opens without replaying the vector
ladder; a conflicted ledger (rows under both ids) is left in place with one
warning and construction continues under the current id, so the estate still
opens; only a failed rename call fails construction with `storeUnavailable`
(SYNAPSEKIT_SPEC I-10). Additive (MINOR).

### 2.1.0 -- 2026-09-06

Checkpoint schema v4 drops `corpus_index_state.composition_policy`, both
ports (Bob's ruling: the dead column goes). The v2→v3 `addColumn` step stays
so a v2 estate walks the same ladder; the v3→v4 step is a `dropColumn`,
which PersistenceKit treats idempotently (PERSISTENCEKIT_SPEC I-7b), so a
fresh estate (created at v4 and replayed from version 0) and a re-run both
pass through it. A populated estate opens CorpusKit only through the
composite estate declarations, which carry no migrations, so the column
reaches populated estates through the GeniusLocusKit 1.5→1.6 capsule
(GENIUSLOCUSKIT_SPEC I-25), which `mootx01 upgrade` runs. Nothing in
CorpusKit reads or writes the column at any version.

### 2.0.0 -- 2026-09-06

Separated deferred provider contracts from the current default ensemble.
Removed the live platform-encoder contract.

### 1.28.0 -- 2026-09-05

One index composition. Since schema 19 the adornment store and the stored
distilled rendering are gone, so every `IndexCompositionPolicy` id composed
the same document: the content plus its `ssc_facts` supplement. The knob
retires in both ports. Removed: `IndexCompositionPolicy`, `LexicalIndexSource`,
`DenseIndexSource` (Swift and Rust); `CorpusContentConfiguration.compositionPolicy`
/ `composition_policy` and `with_composition_policy`; `CorpusContentEngine
.compositionPolicy` / `composition_policy()`; `CorpusIndexState.compositionPolicyID`
/ `composition_policy_id`; `CorpusIndexStateStore.mismatchedCompositionPolicy`
/ `mismatched_composition_policy`; `CorpusKitError.compositionPolicyMismatch`
/ `CompositionPolicyMismatch`; and the `reindexPending` / `reindex_pending`
open parameter, which existed only to skip the policy check. The open-time
check itself is gone: an estate opens under the one composition whatever its
rows once recorded. The `corpus_index_state.composition_policy` column stays
declared at checkpoint schema v3 (populated estates carry it and dropping a
column is a schema reduction) and is neither written nor read; new rows take
its `''` default. No migration rewrites the column or the retired estate
setting `index_composition_policy`: an estate that stored either still opens,
and the values are ignored.

### 1.27.0 -- 2026-09-05
Encoder Rerank Program: § 12 added — `EncoderModelSpec` (registry-row value
type, floor `minilm-l6-v2-w60`), `SpanEncoder` / `SpanInference` /
`ProviderSpanEncoder` (prefixes, batched seam, L2-normalised output, empty
input → zero vector), the Spanner rule with its shared fixture, and the
`SpanEncoderFactory` check order and failure classes. Both ports.

### 1.26.0 -- 2026-09-05
Added **B-23 (distributional pooling)**: random-indexing, PPMI, and NMF embed
documents and queries through one function — IDF-weighted sum of the distinct
terms' vectors (NMF: TF-IDF fold-in), L2-normalise, unit corpus-mean direction
removed, L2-normalise — with the IDF table and mean direction fitted at
`finalize()` and carried in the basis blob. Records the measured collapse the
contract corrects (mean pairwise cosine 0.999 / 0.955 / 0.990 on a 13,817
drawer estate) and the no-signal rule for IDF-0 texts. Added **B-24 (basis
format-version gate and migration)**: format version 1 → 2, readers refuse any
other version, the open path serves a stale-version basis untrained and
restores a stale-version counts row as `false`, and the retrain is the
open-time provider reconcile plus the reported `mootx01 upgrade` dense-pooling
convergence step. Added **C-15 (dense pooling)** conformance over the shared
`dense_pooling_vectors.json` fixture, both ports. B-13's load-on-open now reads
"from the persisted basis when present AND current (B-24)".

### 1.25.0 -- 2026-09-04
Cross-reference updated: VECTORKIT_SPEC.md and VECTORKIT_INTERFACE.md renamed to SYNAPSEKIT_SPEC.md and SYNAPSEKIT_INTERFACE.md; VectorKit renamed to SynapseKit throughout. No behavioral changes.

### 1.24.0 -- 2026-09-03

The open-time composition-policy mismatch check is a both-port contract.
At every open, unless the caller has committed to a full rebuild before
serving, the engine scans `corpus_index_state` once (O(rows)) and refuses
the estate when any active row (lexically indexed, not removed; the
feed-cursor sentinel row skipped; an empty recorded id read as `current`)
was built under a policy other than the configured one. The error is
`CorpusKitError.compositionPolicyMismatch` (Swift) /
`CorpusKitError::CompositionPolicyMismatch` (Rust) with the byte-identical
detail `recorded=<id>;configured=<id>`, where `<id>` is the first
disagreeing effective id in the port's row order. The rebuild-committed
skip is `reindexPending` (Swift) / `reindex_pending` (Rust); every serving
open leaves it false, and `mootx01 db composition --set` sets it in both
ports. Rust `CorpusIndexStateStore::mismatched_composition_policy` is the
twin of the Swift helper. The 1.23.0 note that the Rust engine performed no
open-time check is closed.

### 1.23.0 -- 2026-09-03

The policy an estate indexes under is a stored estate setting (LocusKit
manifest key `index_composition_policy`, GeniusLocusKit spec I-23) that
GeniusLocusKit supplies through `CorpusContentConfiguration` at every open;
`MOOT_INDEX_COMPOSITION` is a creation-time seed, not an open-time selector,
and `IndexCompositionPolicy.fromEnvironmentValue` / `from_environment_value`
is the id parser every reader of that id uses. Swift `CorpusContentEngine
.init` gains `reindexPending: Bool = false`: when true the open-time
`compositionPolicyMismatch` check is skipped, because the caller has
committed to `reindex(now:)` before the engine serves a query (the `mootx01
db composition --set` path; every serving open leaves it false). Rust
`CorpusContentConfiguration` carries `composition_policy`
(`with_composition_policy`, `composition_policy()`), the Rust engine records
the configured id on every `corpus_index_state` row it writes and exposes
`composition_policy()`, and `IndexCompositionPolicy`, `LexicalIndexSource`,
`DenseIndexSource` derive `Copy`. The Rust engine performs no open-time
mismatch check; on that port the stored setting and the rows are kept in
agreement by the rebuild `db composition --set` runs.

### 1.20.0 -- 2026-08-15

Extended the B-14 counts-invalidation sentinel contract to both ports (TASK-MXE-2026-0358). `invalidatedCountsSentinel` / `isInvalidatedCounts` are now public statics on `CorpusProviderCountsStore` in Swift, matching the Rust module-level `INVALIDATED_COUNTS_SENTINEL` / `is_invalidated_counts`. `restoreCounts(into:)` intercepts the sentinel before the v4 term-row branch and before any provider decode, returning `false` for a sentinel blob. A non-empty but undecodable blob still throws. `persistCounts` / `persist_counts_into` gain a sentinel-preserving flush guard: if the provider's maintained vocabulary is empty and the stored row carries the sentinel, the flush is skipped so the sentinel stays on disk and the caller's reindex-path guard can fire. Corrected the reindex-latch description: the latch writes `corpus_reindex_required` into the manifest and enqueues a marker job; the rebuild itself occurs when the counts path declines and the corpus path retrains.

### 1.19.0 -- 2026-08-15

Added the counts-invalidation sentinel contract to B-14 (MG-01). `INVALIDATED_COUNTS_SENTINEL` is a defined empty byte slice the upgrade migration writes to `corpus_provider_counts.counts` to invalidate stale provider counts. The migration preserves the `doc_count` and `vocab_size` monotone anchors. `restore_counts_into` intercepts the sentinel before any provider decode and returns `Ok(false)` ("nothing stored, start from zero"), letting the reindex latch rebuild counts. A non-empty but undecodable blob still propagates `DecodingFailure`. This contract is implemented in the Rust port only. The Swift port carries the identical gap and a follow-up mission must close it.

### 1.18.2 -- 2026-08-15

Vocabulary disambiguation (Nagatha step-18 finding): "frozen base" was
naming both the persisted counts blob (pre-existing usage, §7/§B-13 area)
and the scalar `PersistedBasis.trainedChunkCount` (new B-22 usage). Each
site now carries its qualifier — "frozen base counts blob" vs "frozen base
document count" — so the two persisted quantities cannot be conflated by
name (the F-5 defect class, applied to prose).

### 1.18.1 -- 2026-08-15

CORPUS-INCREMENTAL-01 F-11 (corrective amendment): added `foldOrderProvenanceUnknown`
to the `CorpusPathReason` set in **B-22** to precisely describe the standalone RI
rejection (the maintained accumulator folds in ingest-arrival order; a from-scratch
train uses active-chunk order; the two cannot be proven equal for a
float-order-sensitive provider). Guard 4 and the RI per-provider behavior paragraph
are updated to distinguish attached mode (`deltaNotFoldSafe` — a real pending delta
is the operative reason) from standalone mode (`foldOrderProvenanceUnknown`). **C-15**
updated from six to seven corpus-path reasons with the full list. No behavioral
contract changed; this is a precision correction to reason naming only.

### 1.18.0 -- 2026-08-15

CORPUS-INCREMENTAL-01 (retrain counts path): added **B-22** specifying the
guard chain that governs when a force retrain uses restored counts instead of
full corpus re-tokenization. The six fallback reasons (firstTrain, noCountsRow,
notCountsCapable, deltaNotFoldSafe, populationMismatch, pendingUnresolvable) and
their semantics are now normative. Per-provider behavior is locked: PPMI
delta-folds non-subsumed pending references (pages only that delta), RI is
restore-only (pages zero when pending is empty; corpus path otherwise), LSA/NMF
always take the corpus path. Publication side-effects (basis + counts in one
serializable transaction, per-reference delete preserving subsumed markers,
generation bump without corpus re-embedding) are normative. The population guard
uses `PersistedBasis.trainedChunkCount` (the frozen base document count) + pending-reference count
vs active-content-ID count. Added **C-15** documenting the
`TrainingPathDecision` / `CorpusPathReason` test seam and its conformance
obligations.

### 1.17.0 -- 2026-08-13

- Drain-unit identity (A2): a drain unit's queue session id is now part
  of the post-encode coordination contract — the engine hands
  `(encodedIDs, unitSessionID)` to the orchestrator, one callback per
  drain unit. The session id is claim-scoped (single-pass batch claim),
  so it brackets the unit end-to-end for audit-marker derivation.

### 1.16.0 -- 2026-07-30

MXE-BB (ee#49 — basis blob limit): `BasisStore` now persists trained
embedding-provider bases using chunked multi-row storage. Blobs are split
into 256 MiB parts and written in one atomic transaction; reads reassemble
parts in `part_index ASC` order. The single-blob schema used before this
version cannot be written for any basis that exceeds `sqlite3_limit`'s
compile-time `SQLITE_MAX_LENGTH` (1 GB). Both Swift and Rust ports ship
the same chunked layout. Existing single-row bases are transparent at read
time via a fallback path that loads a legacy row if the `part_index`
column is absent or if no chunked rows are found. `BasisStore.deleteAll`
and `BasisStore.delete(provider:)` delete across both old and new layouts.

This is an additive behavioral change. The invariant that `BasisStore`
blobs survive unbounded vocabulary growth (ee#49 root cause: a 122 k-term
RI/PPMI basis compresses to ≈ 950 MiB single-blob → `sqlite3_bind_blob`
error) is now met.

### 1.15.0 -- 2026-07-22

Changed B-14 attached-count persistence from complete blob replacement per
queue burst to a published base plus reference-only canonical-content deltas.
Added atomic checkpoint/reference/anchor publication, revision-aware admission,
restart-stable governor decisions, and provider-compaction requirements. Added
the B-13 deferred resident-index requirement for full reindex. Historical 1.0
basis fixtures remain immutable while production trainable providers use the
1.1 tokenizer generation. Made standalone passage indexing an explicit Swift
trait/Rust feature that GLK/MOOTx01 does not enable; added token window and
overlap configuration, per-database policy authority, range policy
fingerprints, mismatch/rebuild gating, and negative GLK compile-selection
tests.

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
this") via SynapseKit `findFarthestFloat`. The per-source aggregation inverts
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
reproducible-within-config, not four-way bit-identical — arch spec §6). SynapseKit
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
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.- **v1.21.0 (2026-08-20)** — Trailer lexical supplement (DECISION_DENSE_LANE_ENRICHMENT Wave-2 delivery ruling): whole-content index units tokenize the verbatim canonical text PLUS the grammar-v1 enrichment-trailer tokens scanned (never regex) from the dense-composition text — the LAST well-formed `(*[ … ]*)` block. The canonical text itself is never modified and remains the payload; the supplement participates in BM25 keyword scoring only (measured basis: the anarrow oracle arm — temporal MRR 0.4154→0.4487, 3/11 never-rescued misses recovered; storage cost <1%). Supersedes the "text is always the lexical text" note. Passage-mode sub-spans remain verbatim-only.

### 1.22.0 -- 2026-09-02
CDL-03 — Index Composition Policy: added `IndexCompositionPolicy`, `LexicalIndexSource`,
and `DenseIndexSource` types that record as a named, versioned policy what text each index
lane consumes. The policy id (e.g. `"lex=original;dense=distilled"`) is stored in
`corpus_index_state.composition_policy` (schema v2→v3) and validated at engine open time
against the configured policy — a mismatch raises `CorpusKitError.compositionPolicyMismatch`.
Named policies: `.current` (cell A, production default), `.lexicalAdornments` (B),
`.denseAdornments` (C), `.bothAdornments` (D), `.lexicalBaseline` (E). Policy selected
at estate open via `MOOT_INDEX_COMPOSITION` env var; absent/unrecognised → `.current`.
`CorpusContentConfiguration` gains a `compositionPolicy` field (default `.current`).
`CorpusContentEngine` exposes `compositionPolicy: IndexCompositionPolicy`. Swift and Rust
twins are conformant.
