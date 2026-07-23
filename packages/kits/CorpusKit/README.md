# CorpusKit

CorpusKit is the standalone RAG database and derived retrieval engine used by
MOOTx01. It builds deterministic BM25 and model-tagged vector indexes, fuses
their rankings, and returns the canonical identity owned by its configured
content source.

This README describes the implementation on `develop/1.1.x`. The complete
behavioral contract is in
[`CORPUSKIT_SPEC.md`](../../../docs/reference/CORPUSKIT_SPEC.md), and the
Swift/Rust API concordance is in
[`CORPUSKIT_INTERFACE.md`](../../../docs/reference/CORPUSKIT_INTERFACE.md).

## Choose the right surface

| Use case | Surface |
|---|---|
| New standalone RAG database | `CorpusContentEngine(standaloneOn:models:)` in Swift or `CorpusContentEngine::standalone_on` in Rust |
| Standalone token-window passages | Enable Swift trait `StandalonePassages` or Rust feature `standalone-passages`, then select a token-window policy |
| MOOTx01 or GeniusLocusKit composition | Let GeniusLocusKit inject its LocusKit-backed `CorpusContentSource`; mutate content through GLK verbs |
| Existing 1.0 standalone integration | `Corpus`, `Chunk`, `Chunker`, `ScoredChunk`, and `BundleStore` remain as the compatibility surface |
| Concrete embedding models | Add `CorpusKitProviders` or `corpus-kit-providers`; the core package contains no model weights |

CorpusKit has no dependency on LocusKit. GeniusLocusKit owns the adapter
between them so both kits remain independently usable.

## The 1.1 architecture

```text
Standalone                            GeniusLocusKit attached
----------                            -----------------------
CorpusDocumentStore                   LocusKit Drawer source
        \                                  /
         \                                /
             CorpusContentSource
                      |
              source change feed
       id + revision + digest + cursor
                 (no text)
                      |
             CorpusContentEngine
          /          |           \
       BM25       provider       index
     postings      vectors       state
          \          |           /
           canonical-ID RRF recall
                      |
             CorpusContentHit.id
```

The two modes use one indexing and recall engine:

- **Standalone mode** owns canonical documents through
  `CorpusDocumentStore`. Direct applications may ingest and remove content
  through CorpusKit.
- **Attached mode** reads canonical content through an injected
  `CorpusContentSource`. In MOOTx01, that source projects active LocusKit
  Drawers. CorpusKit stores only derived state and rejects direct content
  mutation.
- **Whole-content indexing** is the default everywhere and the only policy
  compiled into GeniusLocusKit/MOOTx01.
- **Token-window passages** are an explicit standalone build option. Passage
  rows store UTF-8 ranges, revision, digest, and policy identity. They do not
  copy passage text, and recall still returns the canonical document ID.

## What changed on `develop/1.1.x`

| Area | Development-branch behavior |
|---|---|
| Content ownership | The old assumption that every Corpus owns copied chunk text is gone. Standalone owns documents; attached mode reads the owner's content source. |
| Identity | BM25 rows, CorpusKit provider vectors, checkpoints, deletion, and recall all use `CorpusContentID`. In GLK this is the Drawer ID directly. |
| GLK storage | The attached schema contains no CorpusKit documents, chunks, passage text, or corpus metadata. LocusKit remains the sole canonical content owner. |
| Change application | Upserts carry revision and digest. A stale job is rejected without advancing the checkpoint. Retrying a committed change is idempotent. |
| Queue payloads | The durable QueueKit job contains ID, revision, digest, and cursor. Text is resolved from the source at work time, so the queue is not another content store. |
| Passage indexing | Standalone applications can opt into database-bound token windows. GLK builds keep the passage types, segmenter, and tables compile-dark. |
| Provider ensemble | The default ensemble is Random Indexing, PPMI, LSA, NMF, and FDC. Text-model and Apple NaturalLanguage providers remain opt-in. |
| Maintained counts | Trainable-provider state uses a published base plus reference-only canonical-content deltas. Checkpoints and nondecreasing anchors commit transactionally and reopen deterministically. |
| Reindex performance | Full reindex streams bounded batches and defers resident vector-index publication until the rewrite completes. It no longer republishes the resident index after every record. |
| Lifecycle | `destroyRecallIndex` removes only CorpusKit-owned BM25, checkpoints, basis/count state, coverage, claims, and exact provider vectors. Canonical content and unrelated vector lanes survive. |
| Migration | A pre-1.1 GLK corpus lane stays unavailable while its derived state is rebuilt and verified. LocusKit recall remains available during that work. |

The Git history behind these changes starts with the shared-content boundary
and schema profiles, then proceeds through the common engine, GLK cutover,
lifecycle reclamation, cross-port qualification, and restart-exact provider
publication.

## Public API: standalone example

Swift:

```swift
import CorpusKit
import CorpusKitProviders

let corpus = try await CorpusContentEngine(
    standaloneOn: storage,
    models: CorpusEnsemble.defaultEnsemble()
)

try await corpus.ingest(
    "A local document owned by this Corpus.",
    contentID: "document-001",
    now: now
)

let hits = try await corpus.recall(
    "local document",
    limit: 10,
    now: now
)
```

Rust:

```rust
use corpus_kit::CorpusContentEngine;
use corpus_kit_providers::default_ensemble;

let corpus = CorpusContentEngine::standalone_on(
    storage,
    default_ensemble(),
)?;

corpus.ingest(
    "A local document owned by this Corpus.",
    "document-001",
    now_millis,
)?;

let hits = corpus.recall("local document", 10)?;
```

`storage`, `now`, and `now_millis` are supplied by the host so tests and
replays remain deterministic.

## Optional standalone passages

Passage indexing is opt-in because it changes the database's derived-index
policy.

Swift:

```swift
let corpus = try await CorpusContentEngine(
    standaloneOn: storage,
    indexUnit: .tokenWindows(
        windowTokens: 512,
        overlapTokens: 64
    ),
    models: CorpusEnsemble.defaultEnsemble()
)
```

Rust:

```rust
let corpus = CorpusContentEngine::standalone_on_with_policy(
    storage,
    CorpusIndexUnitPolicy::TokenWindows {
        window_tokens: 512,
        overlap_tokens: 64,
    },
    default_ensemble(),
)?;
```

The policy is persisted with the database. Reopening with the same policy is
idempotent. Changing the window, overlap, tokenizer identity, or policy
version requires an explicit derived-state rebuild. Attached mode rejects the
policy.

## Index and recall behavior

For each current content record, CorpusKit:

1. Validates the canonical ID and current revision/digest.
2. Tokenizes the current text for BM25.
3. Produces provider-specific binary and dense vector representations.
4. Writes coverage and index-state checkpoints only after derived rows are
   durable.
5. Advances the source cursor only after the change is committed.

Recall requests fan out to BM25 and the default provider's vector lane. Each
lane is first aggregated to canonical content identity. Reciprocal Rank Fusion
then combines the rankings with a deterministic ID tie-break.

The result is `CorpusContentHit`:

- `id` is always the canonical content ID.
- `keywordScore` and `vectorScore` identify contributing lanes.
- `evidence` is present only for an opt-in standalone passage and contains a
  UTF-8 range into the canonical document.

Per-signal dense nearest and farthest surfaces are also available to
GeniusLocusKit's shaped recall. Rows from different model IDs are never
compared.

## Providers

`CorpusKitProviders` supplies:

- The five-signal default ensemble: Random Indexing, PPMI, LSA, NMF, and FDC.
- Optional MiniLM, MPNet, and EmbeddingGemma text providers with
  closure-injected inference.
- Swift-only `NLEmbeddingProvider` and
  `NLContextualEmbeddingProvider`. Missing Apple assets produce an unavailable
  lane instead of blocking or crashing.

The core `CorpusKit` target owns provider protocols, persisted basis/count
state, coverage, and model-tagged indexing. It contains no model bundles.

## Queue, restart, and failure behavior

- The engine uses QueueKit's shared per-estate encrypted queue for durable
  SQLite estates and an in-memory queue for ephemeral estates.
- Work is at-least-once and revision-aware. Terminal success is recorded only
  after the index update commits.
- A stale upsert cannot advance the source checkpoint.
- Permanently failing or undecodable jobs are blocked after bounded retries so
  one bad record cannot wedge the queue.
- Provider counts and growth anchors reopen to the same governor decision.
- Removal clears the content ID's derived rows. A later higher revision can
  re-add the same canonical identity without double-counting it.
- Teardown and migration delete by exact CorpusKit ownership scope. They do
  not call a shared-store-wide vector deletion.

## Building and testing

From the repository root:

```sh
swift build --package-path packages/kits/CorpusKit
swift test --package-path packages/kits/CorpusKit

cargo test \
  --manifest-path packages/kits/CorpusKit/rust/Cargo.toml \
  --locked
```

Run the opt-in passage suites:

```sh
swift test \
  --package-path packages/kits/CorpusKit \
  --traits StandalonePassages

cargo test \
  --manifest-path packages/kits/CorpusKit/rust/Cargo.toml \
  --features standalone-passages \
  --locked
```

The shared-content qualification suites cover standalone/attached parity,
canonical identity, no-copy composition, removal and re-add, restart
determinism, provider coverage, legacy migration, and ownership-scoped
teardown.

## Migration guidance

- Existing standalone applications can keep using the 1.0 `Corpus` and
  `BundleStore` compatibility surface.
- New standalone applications should prefer `CorpusContentEngine`.
- GeniusLocusKit integrations must mutate content through the GLK verb
  surface. Attached CorpusKit rejects standalone content writes.
- Do not enable `StandalonePassages` in a MOOTx01 or GLK dependency build.
- Treat BM25, provider vectors, coverage, counts, and index-state rows as
  rebuildable derived state.
- Do not treat a Corpus lane as available until the 1.0-to-1.1 migration has
  completed its identity and no-copy verification.

## Package layout

| Path | Responsibility |
|---|---|
| `Sources/CorpusKit/CorpusContent.swift` | Canonical IDs, records, source/store protocols, changes, modes, and configuration. |
| `Sources/CorpusKit/CorpusContentEngine.swift` | Shared standalone/attached indexing, recall, provider state, reindex, and lifecycle. |
| `Sources/CorpusKit/CorpusContentEngineQueue.swift` | Durable source-change queue and drain. |
| `Sources/CorpusKit/CorpusDocumentStore.swift` | Standalone canonical document store. |
| `Sources/CorpusKit/CorpusIndexStateStore.swift` | Per-content revision, digest, cursor, and index-version checkpoints. |
| `Sources/CorpusKit/CorpusSchemaProfile.swift` | Standalone and attached schema declarations. |
| `Sources/CorpusKitProviders/` | Default ensemble, text-model providers, and Apple-specific optional providers. |
| `rust/src/content*.rs` | Rust parity implementation of the content boundary and engine. |
| `rust/tests/` and `Tests/CorpusKitTests/` | Cross-mode, migration, restart, lifecycle, and conformance gates. |

## Ownership boundaries

CorpusKit does not provide:

- Structured memory, knowledge-graph facts, or audit semantics:
  [`LocusKit`](../LocusKit/)
- Raw vector ownership and nearest-neighbor storage:
  [`VectorKit`](../VectorKit/)
- The composed nine-verb estate:
  [`GeniusLocusKit`](../GeniusLocusKit/)
- Reasoning and dreaming:
  [`NeuronKit`](../NeuronKit/)
- The MCP access surface:
  [`AriaMcpKit`](../AriaMcpKit/)

## Further documentation

- [`CorpusKit behavioral specification`](../../../docs/reference/CORPUSKIT_SPEC.md)
- [`CorpusKit Swift/Rust interface`](../../../docs/reference/CORPUSKIT_INTERFACE.md)
- [`Package interface doctrine`](docs/INTERFACE_DOCTRINE.md)
- [`GeniusLocusKit composition specification`](../../../docs/reference/GENIUSLOCUSKIT_SPEC.md)
- [`System engineering reference`](../../../docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md)
- [Stable public `moot-memory` SDK repository](https://github.com/codedaptive/moot-memory)
