# CorpusKit

**Status:** v1.0 complete (2026-05-19, mission 7). Built greenfield against PersistenceKit + ConvergenceKit + VectorKit + SubstrateLib.
**Standalone:** Yes; use independently as a RAG database, or as the RAG tier inside GeniusLocusKit.

A Swift library for privacy-first retrieval-augmented generation on Apple Silicon. CorpusKit keeps content and its embedding together: store a chunk, its vector, and its metadata atomically; retrieve the most relevant chunks by hybrid semantic + keyword search.

## What this kit provides

Two targets:

- **CorpusKit** -- core surface. Chunker (sentence-aware with NaturalLanguage), BM25 inverted index, BundleStore (chunks table on PersistenceKit), Tokenizer protocol, TextEmbeddingProvider protocol, HybridRecall (vector + BM25 + RRF + optional MMR), SyncManifest declaration for content sync. No model weights, no CoreML, no network.
- **CorpusKitProviders** -- three text embedding providers (MiniLM, mpnet, EmbeddingGemma) with stable per-provider FloatSimHash seeds. CoreML inference is closure-injected so providers test without model bundles.

## Mission 7 changes

Per `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md` section 4.7:

1. Tokenization migrated from VectorKit to CorpusKit. Tokenizer protocol defines vocab id, max tokens, pad and unknown ids, model tokenization, and BM25 keyword tokenization with a default implementation.
2. Three text embedding providers ship (MiniLM, mpnet, EmbeddingGemma). Each carries its own DeterministicTokenizer stand-in for v1.0; real WordPiece and SentencePiece tokenizers ship in the v1.1 model-bundle mission (per DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12).
3. Chunker uses NaturalLanguage sentence segmentation with a configurable target (default 800 chars) and overlap (default 100 chars).
4. BundleStore consumes PersistenceKit; one schema declaration (`BundleStore.schemaDeclaration`), one table (`chunks`), idempotent on primary key.
5. BM25Index is an actor; rebuilt on demand from the bundle store. Configurable k1 and b.
6. HybridRecall composes vector kNN (via VectorKit) and BM25 keyword scoring via Reciprocal Rank Fusion. Optional MMR slot reserved for the diversification follow-on.
7. SyncManifest declaration; the application enables ConvergenceKit on the underlying Storage instance. Per-table conflict policy is `appendOnly` since chunks are content-addressed and never edited in place.

## Building and testing

```
cd CorpusKit
swift build
swift test
```

Requires Swift 6.0+ and sibling packages at `../SubstrateLib`, `../EngramLib`, `../PersistenceKit`, `../ConvergenceKit`, `../VectorKit`. 18 tests pass on Apple Silicon (Chunker, BM25, BundleStore, Providers).

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
- `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md` -- architecture record
