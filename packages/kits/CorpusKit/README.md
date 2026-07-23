# CorpusKit

**Status:** 1.1 shared-content architecture.
**Standalone:** Yes; use independently as a RAG database, or as the RAG tier inside GeniusLocusKit.

A Swift library for privacy-first retrieval-augmented generation on Apple Silicon. CorpusKit is standalone-capable and can own canonical documents itself. When composed into GeniusLocusKit, it indexes the existing GLK Drawers without copying their text; recall returns the same Drawer identity used by every other GLK lane.

## What this kit provides

Two targets:

- **CorpusKit** -- core surface. Canonical content-source/store contracts, whole-content indexing, BM25, provider-vector fusion, and deterministic lifecycle reconciliation. The optional `StandalonePassages` trait adds range-only passage indexing to direct SDK builds. GLK/MOOTx01 leaves it disabled. The legacy standalone Chunker/BundleStore surface remains compatibility-only.
- **CorpusKitProviders** -- three text embedding providers (MiniLM, mpnet, EmbeddingGemma) with stable per-provider FloatSimHash seeds. CoreML inference is closure-injected so providers test without model bundles.

## Mission 7 changes

Per `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#21-dependency-direction-and-kit-ownership` section 4.7:

1. Tokenization migrated from VectorKit to CorpusKit. Tokenizer protocol defines vocab id, max tokens, pad and unknown ids, model tokenization, and BM25 keyword tokenization with a default implementation.
2. Three text embedding providers ship (MiniLM, mpnet, EmbeddingGemma). Each carries its own DeterministicTokenizer stand-in for v1.0; real WordPiece and SentencePiece tokenizers ship in the v1.1 model-bundle mission (per the embedding-provider contract).
3. New standalone applications may opt into token-window passages with a database-bound window and overlap. Passage rows contain UTF-8 ranges, never copied text. The feature is compile-dark in GeniusLocusKit/MOOTx01.
4. BundleStore remains a standalone compatibility store. The GLK attached schema excludes `chunks`, `corpus_metadata`, standalone documents, and passages.
5. BM25Index is an actor; rebuilt on demand from the bundle store. Configurable k1 and b.
6. HybridRecall composes vector kNN (via VectorKit) and BM25 keyword scoring via Reciprocal Rank Fusion. Optional MMR slot reserved for the diversification follow-on.
7. SyncManifest declaration; the application enables ConvergenceKit on the underlying Storage instance. Per-table conflict policy is `appendOnly` since chunks are content-addressed and never edited in place.

## Building and testing

```
cd CorpusKit
swift build
swift test

# Direct standalone SDK passage build/tests
swift build --traits StandalonePassages
swift test --traits StandalonePassages
```

```swift
let corpus = try await CorpusContentEngine(
    standaloneOn: storage,
    indexUnit: .tokenWindows(windowTokens: 512, overlapTokens: 64))
```

```rust
let corpus = CorpusContentEngine::standalone_on_with_policy(
    storage,
    CorpusIndexUnitPolicy::TokenWindows {
        window_tokens: 512,
        overlap_tokens: 64,
    },
    models,
)?;
```

The Rust twin uses `--features standalone-passages`. Window/overlap policy is
persisted per standalone database; changing it requires an explicit derived
generation rebuild.

## What this kit does NOT provide

- Structured content, KG facts, bitmaps, or audit -> **LocusKit**
- Raw vector storage or kNN -> **VectorKit** (CorpusKit consumes VectorKit; it does not reimplement it)
- Unified nine-verb estate surface -> **GeniusLocusKit**
- AI reasoning algorithms -> **NeuronKit**
- MCP server -> **ARIA_MCP**

## See also

- `docs/INTERFACE_DOCTRINE.md` -- contract for downstream consumers
- `../VectorKit/` -- vector primitives this kit consumes
- `../PersistenceKit/` -- backing storage
- `../ConvergenceKit/` -- sync transport
- `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#21-dependency-direction-and-kit-ownership` -- architecture record
