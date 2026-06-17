//! VectorKit -- on-device embedding generation and persistence-kit-backed
//! vector storage. Parallel to the Swift `VectorKit` Swift Package.
//!
//! Refactored 2026-05-19 (Rust mission 6) per
//! DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md section 4.6:
//! - Storage moved from direct rusqlite to `persistence-kit`. Backends
//!   (InMemory today; SQLite + PostgreSQL in follow-on R-missions)
//!   slot in additively.
//! - `FloatSimHashEmbeddingProvider` is the only provider shipped
//!   today. It accepts a host-supplied inference closure that
//!   returns a `Vec<f32>`, then projects through
//!   `substrate_ml::float_simhash::project` (the canonical
//!   SimHash projection) with a stable per-provider seed. Mirrors
//!   Swift's MiniLM / mpnet / EmbeddingGemma providers in CorpusKit.
//! - FTS5 removed; `find_by_keyword` is a substring LIKE on
//!   `drawer_id` (full BM25 lives in CorpusKit).
//!
//! The earlier `MockEmbeddingProvider` and `ScalarEmbeddingProvider`
//! were FNV-folded fingerprint generators that bypassed the
//! canonical SimHash projection. They are gone. Tests that need a
//! deterministic provider construct
//! `FloatSimHashEmbeddingProvider::new(model_id, version, seed,
//! closure)` with a closure that returns a hash-derived `Vec<f32>`
//! -- the canonical projection runs against that vector, giving
//! the same determinism but real Hamming geometry.

pub mod embedding_provider;
pub mod engine;
pub mod error;
pub mod simhash_embedding_provider;
pub mod vector_store;

pub use embedding_provider::EmbeddingProvider;
pub use engine::{
    // Lane F shared foundation types.
    BinaryMetric, DenseHit, DenseIndex, DenseMetric, FloatMetric, IndexKind, LaneTag,
    MetadataFilter, ModelPartitionEntry, ResidentVectorArray, SearchDirection, VectorKind,
    VectorPayload, VectorRecordKey,
    // Lane A binary oracle + persistence.
    BruteForceIndex, ResidentArrayStore,
    // Lane C float implementations.
    FloatBruteForceIndex,
    // Lane E1 binary ColBERT MaxSim scorer (Exact-A exhaustive).
    MaxSimHit, MaxSimScorer,
};
pub use error::VectorKitError;
pub use simhash_embedding_provider::FloatSimHashEmbeddingProvider;
pub use vector_store::{StoredVector, VectorMatch, VectorPayloadInput, VectorStore};
