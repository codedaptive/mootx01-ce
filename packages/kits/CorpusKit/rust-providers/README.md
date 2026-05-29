# rag-kit-providers (Rust)

Rust port of Swift's `CorpusKitProviders` target. Hosts the concrete `Tokenizer` and `TextEmbeddingProvider` implementations whose presence implies a model bundle or a deliberately documented test stub.

Sibling of `rag-kit` (the core crate). Core `rag-kit` ships traits, primitives, and engines (BM25Index, BundleStore, chunker, hybrid recall); this providers crate ships the implementations that satisfy those traits.

**Status:** v1.0. `DeterministicTokenizer` is the only implementation today. Real WordPiece and SentencePiece tokenizers plus ONNX-backed embedding providers land in a follow-on R-mission once model bundles are wired in.

## What ships at v1.0

- `DeterministicTokenizer` -- documented test stub mirroring Swift's same-named type. Stable per-token integer IDs derived from FNV-1a 32-bit fold; reserves 0 and 1 for pad/unk sentinels. Same byte-level construction as the Swift implementation, so a Swift/Rust conformance test produces identical IDs for identical inputs.

The stub's purpose is twofold: exercising the `Tokenizer::keyword_tokens` path (which uses the trait's default Unicode-word-boundary split, not the stub's hash IDs) for BM25 indexing and hybrid recall fixtures, and giving cross-language conformance harnesses a tokenizer whose output is stable across language boundaries.

It is NOT a model vocabulary. Feeding `tokenize()` output into a real embedding model produces garbage embeddings. Tests that need a real vocab wait for the model-bundle R-mission.

## What does NOT ship at v1.0

- BERT WordPiece tokenizer (MiniLM, mpnet)
- SentencePiece tokenizer (EmbeddingGemma, gemma family)
- ONNX-backed `TextEmbeddingProvider` for any of the above

## Tests

`deterministic_tokenizer_tests.rs` (7 tests): identity, determinism per input, distinct ids per input, sentinel-avoidance for produced ids, max-tokens truncation, empty-input pad-token fallback, keyword_tokens uses the trait default.

## Building

```
cd CorpusKit/rust-providers
cargo build
cargo test
```

Requires Rust 1.75+ and the sibling `rag-kit` crate at `../rust`.

## Layout rationale

Swift's `CorpusKit` Swift Package splits into two targets:

- `CorpusKit` -- traits and engines
- `CorpusKitProviders` -- concrete tokenizer and provider implementations

The Rust port preserves this split as two sibling crates. The boundary keeps core kit consumers from accidentally depending on a test stub, and gives model-bundle providers a natural home that doesn't pollute the core crate's dependency surface.
