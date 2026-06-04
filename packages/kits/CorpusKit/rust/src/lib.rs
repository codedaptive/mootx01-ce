//! corpus-kit -- the RAG layer of the GeniusLocus substrate.
//!
//! Rust version of the Swift `CorpusKit` Swift Package. Depends on
//! vectorkit (vector primitives), persistence-kit (content and bundle
//! persistence), convergence-kit (replication), engram-lib (the Engram
//! type), and substrate-lib (HLC, fingerprints).
//!
//! Concrete tokenizer implementations -- including the
//! `DeterministicTokenizer` test stub -- live in the sibling
//! `corpus-kit-providers` crate. Concrete embedding providers
//! conform to `vectorkit::EmbeddingProvider` directly (Swift/Rust
//! consolidation 2026-05-27). This split mirrors
//! Swift's `CorpusKit` / `CorpusKitProviders` target layout: core kit
//! ships the traits, primitives, and persistence-kit-backed engines;
//! the providers crate ships the implementations that imply a
//! model bundle or a documented test stub.
//!
//! Modules:
//! - chunk: Chunk + ScoredChunk
//! - tokenizer: Tokenizer trait + default keyword_tokens helper
//! - error: CorpusKitError
//! - chunker: sentence-aware chunker (delimiter fallback, since
//!   no NaturalLanguage on Linux)
//! - bm25_index: in-memory BM25 inverted index
//! - bundle_store: persistence-kit-backed chunks table
//! - corpus: Corpus struct + EmbeddingModelConfig (public RAG entry point)
//! - hybrid_recall: vector kNN + BM25 fused via RRF
//! - sync_manifest: CorpusKitSync::manifest helper

pub mod bm25_index;
pub mod bundle_store;
pub mod chunk;
pub mod chunker;
pub mod corpus;
pub mod error;
pub mod hybrid_recall;
pub mod sync_manifest;
pub mod tokenizer;

pub use bm25_index::*;
pub use bundle_store::*;
pub use chunk::*;
pub use chunker::*;
pub use corpus::Corpus;
pub use corpus::EmbeddingModelConfig;
pub use error::*;
pub use hybrid_recall::*;
pub use sync_manifest::*;
pub use tokenizer::*;
