//! corpus-kit-providers -- Rust port of Swift's `CorpusKitProviders`
//! target. Hosts concrete `Tokenizer` implementations and concrete
//! `vectorkit::EmbeddingProvider` implementations (the named text
//! providers) over a host-supplied inference seam.
//!
//! The crate ships:
//! - `DeterministicTokenizer` -- the no-host fallback tokenizer,
//!   bit-identical to Swift's same-named type (both fold token
//!   strings through `substrate_types::fnv`).
//! - `MiniLMTextProvider`, `MPNetTextProvider`,
//!   `EmbeddingGemmaProvider` -- the named text providers, mirrors
//!   of the Swift trio. Each conforms to `vectorkit::EmbeddingProvider`,
//!   holds a tokenizer and a model-specific projection seed, and
//!   takes a host-supplied inference seam (token IDs -> pooled
//!   vector). The kit bundles no model weights and links no
//!   ML-runtime crate; the host injects inference on every platform.
//!
//! The real WordPiece / SentencePiece tokenizers are owned by
//! NEITHER port -- Swift's named providers default to
//! `DeterministicTokenizer` too, and the real tokenizers land with
//! the host's model bundle (see `text_providers` for the full
//! parity reasoning).
//!
//! Core `corpus-kit` (the sibling crate) is intentionally
//! provider-free -- only the `Tokenizer` trait lives there. The
//! `EmbeddingProvider` trait lives in `vectorkit` (consolidation
//! 2026-05-27); the concrete text providers in this crate conform
//! to it directly. This layout matches Swift's split between
//! `CorpusKit` and `CorpusKitProviders`.

pub mod deterministic_tokenizer;
pub mod ppmi;
pub mod random_indexing;
pub mod text_providers;

pub use deterministic_tokenizer::DeterministicTokenizer;
pub use ppmi::{
    PpmiProvider, PPMI_DIMENSION, PPMI_NONZEROS, PPMI_PROJECTION_SEED, PPMI_WINDOW,
};
pub use random_indexing::{
    RandomIndexingProvider, RI_DIMENSION, RI_NONZEROS, RI_PROJECTION_SEED, RI_WINDOW,
    ri_index_vector,
};
pub use text_providers::{EmbeddingGemmaProvider, MPNetTextProvider, MiniLMTextProvider};
