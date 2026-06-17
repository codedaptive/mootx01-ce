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
// Shared term-document count builder reused by LSA and NMF.
// Owns vocab encounter-order construction, TF counts, and DF counts.
// Swift port: Sources/CorpusKitProviders/TermDocumentCounts.swift.
pub mod term_document_counts;
// ADR-010 Decision B signal #1: LSA/SVD distributional-semantics provider.
// Uses substrate_ml::svd::JacobiSvd (deterministic, bit-identical with Swift).
pub mod lsa;
// ADR-010 Decision B: NMF latent-factor provider.
// Reuses substrate_ml::nmf::NMFAlternatingLeastSquares (Gate-2: no reimplementation).
// tolerance=0 forces fixed iteration count for bit-identical cross-port output.
pub mod nmf_provider;
pub mod ppmi;
pub mod random_indexing;
pub mod text_providers;
// ADR-010 Decision B: FDC lattice co-classification provider.
// Reuses lattice_lib::Fdc::encode (text→FDC code) and
// lattice_lib::Fdc::ancestors (the runtime façade over FdcFrame::ancestors).
// The decimal hierarchy math lives in LatticeLib — not reimplemented here.
// Stateless — no training required.
pub mod fdc_provider;

pub use deterministic_tokenizer::DeterministicTokenizer;
pub use term_document_counts::TermDocumentCounts;
pub use lsa::{LsaProvider, LSA_DEFAULT_RANK, LSA_PROJECTION_SEED};
pub use nmf_provider::{
    NmfProvider, NMF_DEFAULT_ITERATIONS, NMF_DEFAULT_RANK, NMF_FACTORIZATION_SEED,
    NMF_PROJECTION_SEED,
};
pub use ppmi::{
    PpmiProvider, PPMI_DIMENSION, PPMI_NONZEROS, PPMI_PROJECTION_SEED, PPMI_WINDOW,
};
pub use random_indexing::{
    RandomIndexingProvider, RI_DIMENSION, RI_NONZEROS, RI_PROJECTION_SEED, RI_WINDOW,
    ri_index_vector,
};
pub use text_providers::{EmbeddingGemmaProvider, MPNetTextProvider, MiniLMTextProvider};
pub use fdc_provider::{
    FDCProvider, FDC_DIMENSION, FDC_PROJECTION_SEED,
    fdc_node_vector, fdc_embedding_vector,
};
