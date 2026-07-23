//! VectorKit -- on-device embedding generation and persistence-kit-backed
//! vector storage. Parallel to the Swift `VectorKit` Swift Package.
//!
//! Refactored 2026-05-19 (Rust mission 6) per
//! current kit ownership section 4.6:
//! - Storage flows through `persistence-kit`, not direct rusqlite. The
//!   `VectorStore` is backend-agnostic: it holds an `Arc<dyn Storage>` and
//!   never names a backend. The application selects the backend. The
//!   InMemory and the on-disk SQLite (`persistence_kit::SqliteStorage`)
//!   backends both ship and are both exercised by VectorKit's tests; over
//!   the SQLite backend the resident binary array and float lane survive a
//!   process restart (rebuilt from the durable `vectors` table — or from the
//!   `.vec` sidecar when one is supplied — on the next open). PostgreSQL is
//!   the remote-backed v1.1 path (ships with federation) and is not present
//!   here. See VECTORKIT_SPEC §cross-restart persistence.
//! - `FloatSimHashEmbeddingProvider` is the only provider shipped
//!   today. It accepts a host-supplied inference closure that
//!   returns a `Vec<f32>`, then projects through
//!   `substrate_ml::float_simhash::project` (the canonical
//!   SimHash projection) with a stable per-provider seed. Mirrors
//!   Swift's MiniLM / mpnet / EmbeddingGemma providers in CorpusKit.
//! - FTS5 removed; `find_by_keyword` is a substring LIKE on
//!   `item_id` (full BM25 lives in CorpusKit).
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
// Representation-ownership manifest (GLK shared-content 1.1, P0).
pub mod representation_claims;
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
pub use representation_claims::{VectorRepresentationClaims, VectorRepresentationKey};
pub use vector_store::{StoredVector, VectorExactKey, VectorMatch, VectorPayloadInput, VectorStore};
