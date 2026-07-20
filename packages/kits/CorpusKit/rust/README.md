# rag-kit (Rust)

Rust port of the Swift `CorpusKit` Swift Package. The RAG layer of the GeniusLocus substrate: chunking, BM25 inverted index, content-plus-vector bundle storage, hybrid retrieval, and the sync manifest for cross-device replication.

**Status:** v1.0 -- Rust mission 7 greenfield. Closes the Rust catch-up phase.

## What ships at v1.0

- `Chunk` and `ScoredChunk` -- content unit and retrieval-scored variant. `Chunk` embeds substrate's `HLC` directly (no flat-field decomposition); `metadata` is the only serde-crossing field.
- `Tokenizer` trait + `default_keyword_tokens` helper. Concrete tokenizer implementations -- including the `DeterministicTokenizer` test stub -- live in the sibling `rag-kit-providers` crate, mirroring Swift's `CorpusKit` / `CorpusKitProviders` target split.
- `Chunker` -- sentence-aware chunking with delimiter fallback (matches Swift's Linux fallback path since there's no `NaturalLanguage` framework on Rust)
- `BM25Index` -- in-memory BM25 inverted index (k1=1.5, b=0.75 defaults, tunable)
- `BundleStore` -- storage-kit-backed CRUD over the `chunks` table; same schema as Swift's `BundleStore`
- `recall` -- hybrid retrieval composition: vector kNN (via vectorkit's `VectorStore`) + BM25 keyword scoring fused via Reciprocal Rank Fusion
- `CorpusKitSync::manifest` -- builds a `sync_kit::SyncManifest` for the chunks table with append-only conflict policy

## Tests

Core `rag-kit` integration tests (in `tests/`):

- `chunk_tests.rs`: Chunk HLC roundtrip, ScoredChunk subscores, CorpusKitError display
- `tokenizer_tests.rs`: default keyword tokenization, empty input, punctuation-only input
- `chunker_tests.rs`: short input one chunk, splits when target exceeded, respect_sentences disabled, HLC advances per chunk, empty input no chunks
- `bm25_tests.rs`: empty index, single doc match, ranking by relevance, limit cap, remove drops doc, custom parameters, no-match returns empty, empty query returns empty
- `bundle_store_tests.rs`: insert + get roundtrip, get returns None for unknown, ordering by start_offset, get_many, delete, idempotent insert, metadata JSON roundtrip, all_chunks
- `hybrid_recall_tests.rs`: manifest shape matches Swift, hybrid recall merges vector + keyword, limit=0 returns empty, empty corpus returns empty

`DeterministicTokenizer` lives in the sibling `rag-kit-providers` crate; its tests ship there.

## What does NOT ship at v1.0

- Real model bundles conforming to `vectorkit::EmbeddingProvider` (ONNX/Candle/Burn). The Swift consolidation (2026-05-27) moved text providers onto VectorKit's `EmbeddingProvider`; the Rust mirror is now the same trait. Closure-injected paths can be wired through `FloatSimHashEmbeddingProvider` from vectorkit today.
- MMR diversification in `recall` (configuration field is reserved; the implementation lands in a follow-on)
- BM25 persistence (rebuilt in-memory from `BundleStore` today; persistent IDF/posting-list backed by storage-kit is deferred to v1.x per the Swift kit's own note)
- Apple `NaturalLanguage`-quality sentence segmentation (the delimiter fallback is identical to Swift's Linux path)

## Building

```
cd CorpusKit/rust
cargo build
cargo test
```

Requires Rust 1.75+ and sibling `substrate-kit`, `engram-kit`, `storage-kit`, `sync-kit`, `vectorkit` crates. Tests additionally pull in `rag-kit-providers` via dev-dependency.

## See also

- Swift counterpart: `CorpusKit/Sources/`
- Sibling providers crate: `CorpusKit/rust-providers/`
- Kit graph rule: `docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#21-dependency-direction-and-kit-ownership`
