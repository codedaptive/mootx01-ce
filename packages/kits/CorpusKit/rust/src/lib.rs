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
//! - bm25_index: in-memory BM25 inverted index (now delegates to engine layer)
//! - bundle_store: persistence-kit-backed chunks table
//! - corpus: Corpus struct + EmbeddingModelConfig (public RAG entry point)
//! - hybrid_recall: vector kNN + BM25 fused via RRF (routes through engine::fusion)
//! - sync_manifest: CorpusKitSync::manifest helper
//! - engine: Lane F, Lane D, and Lane E engine types
//!   (inverted index, WAND/BMW, BM25 weighting, generalized RRF fusion)

pub mod basis_store;
pub mod bm25_index;
pub mod bundle_store;
pub mod chunk;
pub mod chunker;
// Canonical content boundary + operating profiles (GLK shared-content 1.1, P1).
pub mod content;
pub mod content_engine;
pub mod content_engine_queue;
pub mod corpus;
pub mod corpus_ingest_queue;
pub mod corpus_provider_counts_store;
pub mod document_store;
pub mod engine;
pub mod error;
pub mod hybrid_recall;
pub mod index_state_operational;
pub mod index_state_store;
#[cfg(feature = "standalone-passages")]
pub mod index_configuration_store;
pub mod provider_configuration_store;
pub mod provider_coverage_store;
pub mod removed_source_store;
pub mod schema_profile;
pub mod sub_span_scoring;
pub mod sync_manifest;
pub mod tokenizer;
// Mission 6a-ii-α: the trainable-basis type-erasure seam. Declared here in
// core so the providers crate (corpus-kit-providers) can implement it without
// core depending on it (layering: providers → core). Swift port:
// Sources/CorpusKit/TrainableEmbeddingBasis.swift.
pub mod trainable_embedding_basis;

pub use basis_store::{BasisStore, PersistedBasis};
pub use bm25_index::*;
pub use bundle_store::*;
pub use chunk::*;
pub use chunker::*;
pub use content::{
    content_digest, CorpusContentChange, CorpusContentChangeBatch, CorpusContentId,
    CorpusContentRecord, CorpusContentSource, CorpusContentStore,
};
pub use content_engine::{
    content_id_from_item_key, ContentIndexJob, ContentIndexJobKind, CorpusContentEngine,
    CorpusContentHit, CorpusEvidence, CLAIMS_CONSUMER, CONTENT_ENGINE_INDEX_VERSION,
};
#[cfg(feature = "standalone-passages")]
pub use content_engine::passage_ranges;
#[cfg(feature = "standalone-passages")]
pub use index_configuration_store::CorpusIndexConfigurationStore;
pub use corpus::Corpus;
pub use corpus::EmbeddingModelConfig;
pub use corpus::FloatDiscriminationSignal;
pub use corpus::FloatLaneOutcome;
pub use corpus::NamedInferenceFn;
pub use document_store::CorpusDocumentStore;
pub use index_state_store::{CorpusIndexState, CorpusIndexStateStore};
pub use schema_profile::{
    attached_declaration, attached_excluded_tables, standalone_declaration,
    CorpusContentConfiguration, CorpusIndexUnitPolicy, CorpusOperatingMode,
};
// Lane F types (sparse + fusion).
pub use engine::{FusedHit, ImpactPosting, LaneTag, SparseHit};
// Lane D types (inverted index + BM25 weighting + persistence store).
pub use engine::{
    quantize_impact, Algorithm, BM25Parameters, BM25Weighting, InvertedIndex, InvertedIndexStore,
    TermFreqTable, BLOCK_SIZE, QUANT_SCALE,
};
// Lane E types (generalized RRF fusion entry points).
pub use engine::{fuse, fuse_scored};
pub use error::*;
pub use hybrid_recall::*;
// Sub-span max-cosine scoring (MISSION_11X_RECALL_GAP_01 Item 1).
// Re-export the scoring primitives so SDK consumers can call them directly
// without reaching into the module path.
pub use sub_span_scoring::{
    cosine_similarity, score as score_sub_spans_raw, sub_span_ranges, DEFAULT_OVERLAP_TOKENS,
    DEFAULT_WINDOW_TOKENS,
};
pub use sync_manifest::*;
pub use tokenizer::*;
pub use trainable_embedding_basis::TrainableEmbeddingBasis;
