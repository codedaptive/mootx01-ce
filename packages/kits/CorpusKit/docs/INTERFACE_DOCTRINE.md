# CorpusKit Interface Doctrine

For coding agents using CorpusKit in product code or downstream kits.

## 1. The kit is PersistenceKit-backed

BundleStore wraps `any Storage` from PersistenceKit. The application picks the backend; the kit does not.

```swift
let storage = SQLiteStorage(configuration: EstateConfiguration(
    estateID: estate.id,
    backend: .sqlite(url: dbURL)
))
try await storage.open(schema: BundleStore.schemaDeclaration)
let bundles = BundleStore(storage: storage)
```

If your kit composes CorpusKit, you pass `any Storage` down. You do not pick a backend.

## 2. Chunks are immutable

Chunks have a content-addressed identity (UUID). The kit does not edit a chunk in place. If you need to change a chunk, delete the old one and insert a new one with a new id. This is why the sync policy is `appendOnly` (idempotent upsert on duplicate id), not `lastWriterWinsByHLC`.

The `metadata` field is the only legal place for per-chunk side data. If your code wants to record something about a chunk, encode it in metadata; do not invent shadow tables.

## 3. Tokenization belongs in CorpusKit, not in providers

`Tokenizer` is CorpusKit's protocol. Each `TextEmbeddingProvider` carries a tokenizer; providers do not reach for their own tokenization library. If you need a new tokenizer (model-specific WordPiece, SentencePiece variant), conform to `Tokenizer` in CorpusKitProviders, not in product code.

VectorKit's `MiniLMProvider` still carries an inline FNV stand-in for backward compatibility. New providers consume `CorpusKitProviders.MiniLMTextProvider` and pass a `Tokenizer` explicitly. The VectorKit-side stand-in is documented as migrating to CorpusKit's MiniLM tokenizer when the WordPiece vocab metadata lands in the CoreML bundle.

## 4. FloatSimHash for the projection

External providers (MiniLM, mpnet, EmbeddingGemma) project pooled float vectors to 256-bit engrams via `SubstrateLib.FloatSimHash`. Each provider picks a stable, deterministic seed so its fingerprints are model-tagged independent of vector content. The seeds shipped:

| Provider           | Seed (hex)              | Mnemonic    |
|--------------------|-------------------------|-------------|
| MiniLM-L6 v2       | 0x4D49_4E4C_4D_5F76_31  | "MINLM_v1"  |
| mpnet-base-v2      | 0x4D50_4E45_54_5F76_31  | "MPNET_v1"  |
| EmbeddingGemma 300M| 0x454D_4247_4D_5F76_31  | "EMBGM_v1"  |

Do not invent ad-hoc projections. Sign-bit folding, hash-into-bits, etc. are gone from the kit graph; they did not preserve cosine similarity faithfully.

## 5. CoreML inference is closure-injected

`TextEmbeddingProvider` implementations take an `inference: ([Int32]) -> [Float]` closure rather than holding a CoreML model directly. This keeps the providers testable without a model bundle and decouples the kit from the model loading path (host apps load CoreML models differently across iOS, macOS, and CI).

The host app composes the closure once at startup and reuses it across embed calls.

## 6. Hybrid recall composes vector + BM25 via RRF

`HybridRecall.recall(...)` is the canonical hybrid retrieval path. It pulls a generous candidate window from each side (vector kNN, BM25), fuses via Reciprocal Rank Fusion with per-side weights, optionally diversifies via MMR. Returns `[ScoredChunk]` hydrated from the bundle store.

Per-side weights are tunable. The substrate's parameter sensitivity work documents the default 0.6 / 0.4 split.

## 7. Sync is enabled at the application layer

`CorpusKitSync.manifest(zoneIdentifier:)` returns a `SyncManifest`. The application picks a `SyncEngine` (CloudKit, Federation, or None) and calls `enable(manifest:storage:)`. CorpusKit does not import ConvergenceKit at runtime; the manifest declaration is the only contract with ConvergenceKit.

If the application also enables VectorKit sync, both kits should sync into the same CloudKit zone so chunks and their vectors stay join-compatible across devices. This is a deployment choice, not a kit choice.

## 8. BM25 is in-memory at v1.0

`BM25Index` holds postings in memory. For estates with hundreds of thousands of chunks this fits comfortably; for larger estates the persistent IDF / posting list lives in PersistenceKit (v1.x deferral). If you observe BM25 memory pressure, file a decision record proposing the persistent index.

## 9. When in doubt, file a decision record

If you find yourself wanting to:

- Edit a chunk in place (don't; delete + reinsert)
- Add a fourth embedding provider (do it in CorpusKitProviders, follow the seed convention)
- Add a different fusion strategy (decision record; RRF is the v1.0 baseline)
- Reach into the chunks table directly
- Skip schema versioning on a migration

Stop. Write a decision record in `docs/decisions/` proposing the change. The kit boundaries are deliberate.
