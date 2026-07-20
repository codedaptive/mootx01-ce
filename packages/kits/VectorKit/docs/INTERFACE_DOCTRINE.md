# VectorKit Interface Doctrine

For coding agents using VectorKit in product code or downstream kits.

## 1. The kit is PersistenceKit-backed

VectorKit's storage is `any Storage` from PersistenceKit. The application picks the backend (InMemory for tests, SQLite for Apple-platform deployment, PostgreSQL for server-side). VectorKit does not open SQLite directly any more.

```swift
let storage = SQLiteStorage(configuration: EstateConfiguration(
    estateID: estate.id,
    backend: .sqlite(url: dbURL)
))
try await storage.open(schema: VectorStore.schemaDeclaration)
let store = VectorStore(storage: storage)
```

A kit consuming VectorStore receives `any Storage` from its caller. It does not pick a backend.

## 2. Engrams are tagged

Every vector stored carries `(modelID, modelVersion)` per spec I-4. Cross-model comparisons are forbidden. `findNearest(probe:modelID:limit:)` filters to a single model; the caller is responsible for ensuring the probe was produced by that same model.

```swift
let probe = try await provider.embed("query text")
let matches = try await store.findNearest(
    probe: probe,
    modelID: provider.modelID,
    limit: 10
)
```

## 3. Use FloatSimHash for new providers

External embedding providers (MiniLM, BERT, EmbeddingGemma) project dense float vectors through `SubstrateLib.FloatSimHash` to produce 256-bit Engrams. Each provider picks a stable, deterministic seed so its fingerprints are model-tagged independent of vector content.

```swift
private static let providerSeed: UInt64 = 0x...  // unique per model
let engram = FloatSimHash.project(vector: pooledFloats, seed: providerSeed)
```

Do not invent ad-hoc projections. Sign-bit folding, hash-into-bits, etc. are gone from the kit graph; they did not preserve cosine similarity faithfully. FloatSimHash does (cookbook section 3.6).

## 4. Tokenization belongs in CorpusKit (mission 7)

VectorKit currently embeds a deterministic stand-in tokenizer inside `MiniLMProvider` so the provider can ship before CorpusKit lands. After mission 7, tokenization moves to CorpusKit and providers consume it through CorpusKit's tokenizer protocol. Do not extend the MiniLMProvider tokenizer; it is internal and migrating.

If you need text tokenization in a non-MiniLM context today, wait for CorpusKit. If you need it before CorpusKit lands, file a decision record.

## 5. Hybrid retrieval composes elsewhere

VectorKit's `findByKeyword` is a coarse substring filter on drawer IDs, kept for backward compatibility with hybrid-retrieval callers that need a fast pre-filter. Full BM25 keyword search with proper tokenization lives in CorpusKit. Composition of vector + keyword scoring (RRF, MMR) lives in NeuronKit's hybrid recall (paper section 10.2). VectorKit stays focused on vector primitives.

## 6. The schema is owned by VectorStore

`VectorStore.schemaDeclaration` is a public static. Callers pass it to `Storage.open(schema:)` before constructing the store. The schema declares one table (`vectors`) with the columns and constraints documented inline. Do not reach into the table directly from outside the kit; go through VectorStore's API.

If you need a column VectorStore does not expose, file a decision record proposing the schema change. Schema version bumps follow the migration rules in PersistenceKit's INTERFACE_DOCTRINE.

## 7. findNearest is currently a linear scan

The v1 implementation scans every row in the `vectors` table for the given `modelID` and computes Hamming distance in memory. This matches the pre-refactor SQLite behavior. The migration to PersistenceKit's `VectorIndex` protocol with sqlite-vec or pgvector ANN is a follow-on; it does not change the public API.

If your call sites need sub-linear retrieval today, gate them on corpus size or fall through to a higher-tier path. P99 on a 10k-row corpus is roughly 50ms on Apple Silicon.

## 8. Sendable everywhere

VectorStore is an actor. Its public methods are async. EmbeddingProvider is `Sendable`. StoredVector and VectorMatch are `Sendable` value types. If you wrap VectorKit in another kit, that kit's public surface stays `Sendable` too.

## 9. When in doubt, file a decision record

If you find yourself wanting to:

- Bypass the model tag (modelID, modelVersion) on stored vectors
- Add a new projection besides FloatSimHash
- Expose VectorStore internals (the underlying Storage, the schema, the table name)
- Add a kit dependency from VectorKit on something other than SubstrateLib, EngramLib, or PersistenceKit
- Cross the kit boundary into CorpusKit-shaped tokenization concerns

Stop. Update the owning reference specification and engineering master before
changing code. The kit boundaries are deliberate, and the new contract must be
conformance-testable in both versions.
