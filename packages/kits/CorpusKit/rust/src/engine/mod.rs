//! Lane F, Lane D, and Lane E engine types for CorpusKit.
//!
//! Lane F: canonical sparse and fusion types (ImpactPosting, SparseHit,
//!   LaneTag, FusedHit). A downstream lane that needs a new field on any
//!   of these files an FT-1 update to sparse_types rather than adding it
//!   locally.
//!
//! Lane D: weighted impact-ordered inverted index with WAND / Block-Max
//!   WAND exact top-k retrieval. BM25 is one impact weighting scheme.
//!
//! Lane E: generalized Reciprocal Rank Fusion over arbitrary per-lane
//!   ranked inputs. `fusion::fuse` is the primary entry point;
//!   `fusion::fuse_scored` is a convenience wrapper. `hybrid_recall`
//!   routes through this module instead of duplicating the RRF logic inline.

pub mod sparse_types;
pub mod inverted_index;
pub mod bm25_weighting;
pub mod inverted_index_store;
pub mod fusion;

// Re-export Lane F types at the engine surface.
pub use sparse_types::{FusedHit, ImpactPosting, LaneTag, SparseHit};
// Re-export Lane D types.
pub use inverted_index::{Algorithm, InvertedIndex, QUANT_SCALE, BLOCK_SIZE};
pub use bm25_weighting::{BM25Parameters, BM25Weighting, TermFreqTable, quantize_impact};
pub use inverted_index_store::InvertedIndexStore;
// Re-export Lane E fusion entry points.
pub use fusion::{fuse, fuse_scored};
