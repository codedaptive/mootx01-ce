//! corpus-kit-providers -- Rust port of Swift's `CorpusKitProviders`
//! target. Hosts concrete `Tokenizer` implementations and concrete
//! `synapsekit::EmbeddingProvider` implementations (the named text
//! providers) over a host-supplied inference seam.
//!
//! The crate ships:
//! - `DeterministicTokenizer` -- the no-host fallback tokenizer,
//!   bit-identical to Swift's same-named type (both fold token
//!   strings through `substrate_types::fnv`).
//! - `MiniLMTextProvider` -- the MiniLM text provider (always compiled).
//! - `MPNetTextProvider`, `EmbeddingGemmaProvider` -- compiled only when
//!   the `dense-families` feature is enabled (off by default; plan 70BC55F3).
//!
//! The real WordPiece / SentencePiece tokenizers are owned by
//! NEITHER port -- Swift's named providers default to
//! `DeterministicTokenizer` too, and the real tokenizers land with
//! the host's model bundle (see `text_providers` for the full
//! parity reasoning).
//!
//! Core `corpus-kit` (the sibling crate) is intentionally
//! provider-free -- only the `Tokenizer` trait lives there. The
//! `EmbeddingProvider` trait lives in `synapsekit` (consolidation
//! 2026-05-27); the concrete text providers in this crate conform
//! to it directly. This layout matches Swift's split between
//! `CorpusKit` and `CorpusKitProviders`.
//!
//! ## Compile-time switches
//!
//! `dense-families` (default: off, plan 70BC55F3 2026-09-05):
//!     Compiles LSA, NMF, PPMI, FDC, MPNet, and EmbeddingGemma providers.
//!     Off by default: measured cost exceeds benefit vs. BM25+RI on two corpora.
//!     RI stays always-on: binary fingerprint feeds dreaming, contradiction,
//!     and consolidation. Enable: `cargo test --features dense-families`.
//!     Mirror of Swift trait DenseFamilies / #define MOOTX01_DENSE_FAMILIES.

pub mod deterministic_tokenizer;
// Shared little-endian binary codec for distributional-provider
// basis serialization. PROVIDER-FORMAT code (not a math primitive) used by
// RandomIndexing, PPMI, LSA, and NMF. Swift port: Sources/CorpusKitProviders/
// BasisCodec.swift. The byte layout is the cross-port contract.
pub mod basis_codec;
// Shared term-document count builder reused by LSA, NMF, RI, and PPMI.
// Owns vocab encounter-order construction, TF counts, DF counts, and the
// one smoothed IDF function.
// Swift port: Sources/CorpusKitProviders/TermDocumentCounts.swift.
pub mod term_document_counts;
// The ONE pooling function for the term-vector distributional providers
// (RI, PPMI): IDF-weighted sum of the distinct terms' vectors, L2-normalised,
// corpus-mean direction removed, L2-normalised. Documents and queries share it.
// Swift port: Sources/CorpusKitProviders/DistributionalPooling.swift.
pub mod distributional_pooling;
pub mod random_indexing;
// MiniLM text provider — always compiled; used by the encoder rerank lane.
// MPNet and EmbeddingGemma are under dense-families; see text_providers.rs.
pub mod text_providers;
// The ONE definition of the default recall ensemble.
// With dense-families OFF: RI only. With ON: RI/PPMI/LSA/NMF/FDC.
// Mirrors Swift's CorpusEnsemble.defaultEnsemble() in CorpusKitProviders.
pub mod default_ensemble;

// Dense-family providers: compiled only when `dense-families` feature is on.
// Off by default (plan 70BC55F3, 2026-09-05): LSA/NMF/PPMI/FDC add cost
// without beating BM25+RI on two corpora. RI stays always-on.
// Enable: cargo test --features dense-families.
#[cfg(feature = "dense-families")]
// shared IDF-reduced vocabulary selection for the dense LSA/NMF
// factorizations (bit-identical with Swift's CorpusKitProviders/ReducedVocab).
pub mod reduced_vocab;
#[cfg(feature = "dense-families")]
// Semantic fusion signal: LSA/SVD distributional-semantics provider.
// Uses substrate_ml::svd::JacobiSvd (deterministic, bit-identical with Swift).
pub mod lsa;
#[cfg(feature = "dense-families")]
// NMF latent-factor provider.
// Reuses substrate_ml::nmf::NMFAlternatingLeastSquares (Gate-2: no reimplementation).
// tolerance=0 forces fixed iteration count for bit-identical cross-port output.
pub mod nmf_provider;
#[cfg(feature = "dense-families")]
pub mod ppmi;
#[cfg(feature = "dense-families")]
// FDC lattice co-classification provider.
// Reuses lattice_lib::Fdc::encode (text→FDC code) and
// lattice_lib::Fdc::ancestors (the runtime façade over FdcFrame::ancestors).
// The decimal hierarchy math lives in LatticeLib — not reimplemented here.
// Stateless — no training required.
pub mod fdc_provider;

// Candle-backed in-process ML inference provider (all-MiniLM-L6-v2).
// Compiled only when the `candle` Cargo feature is enabled.
// See src/candle_provider.rs for the gate-8 throughput disposition and
// the critical tokenizer-padding override note.
pub mod candle_provider;
pub mod span_encoder_factory;
// ModelDirectoryResolver: locates the encoder model directory for a given
// model ID by searching the 1.2 download slot and the installer package slot.
// Verifies vocab.txt sha256 as the integrity sentinel; returns None on any
// mismatch. Called by SpanEncoderFactory::make. Swift port:
// Sources/CorpusKitProviders/ModelDirectoryResolver.swift.
pub mod model_directory_resolver;
// Hardcoded seed constants for the bundled all-MiniLM-L6-v2 encoder model.
// Consumed by `mootx01 upgrade` and estate provisioning to INSERT the initial
// `encoder_models` row. Twin of Swift's `EncoderModelSeed`.
pub mod encoder_model_seed;

pub use basis_codec::{BasisCodecError, BasisReader, BasisWriter, BASIS_FORMAT_VERSION};
pub use deterministic_tokenizer::DeterministicTokenizer;
pub use term_document_counts::{smoothed_inverse_document_frequency, TermDocumentCounts};
pub use distributional_pooling::{mean_direction, pool, remove_mean_direction};
pub use random_indexing::{
    RandomIndexingProvider, RI_DIMENSION, RI_NONZEROS, RI_PROJECTION_SEED, RI_WINDOW,
    ri_index_vector,
};
// MiniLM is always compiled; MPNet and EmbeddingGemma are dense-families only.
pub use text_providers::MiniLMTextProvider;
#[cfg(feature = "dense-families")]
pub use text_providers::{EmbeddingGemmaProvider, MPNetTextProvider};
#[cfg(feature = "dense-families")]
pub use lsa::{LsaProvider, LSA_DEFAULT_RANK, LSA_PROJECTION_SEED};
#[cfg(feature = "dense-families")]
pub use nmf_provider::{
    NmfProvider, NMF_DEFAULT_ITERATIONS, NMF_DEFAULT_RANK, NMF_FACTORIZATION_SEED,
    NMF_PROJECTION_SEED,
};
#[cfg(feature = "dense-families")]
pub use ppmi::{
    PpmiProvider, PPMI_DIMENSION, PPMI_NONZEROS, PPMI_PROJECTION_SEED, PPMI_WINDOW,
};
#[cfg(feature = "dense-families")]
pub use fdc_provider::{
    FDCProvider, FDC_DIMENSION, FDC_PROJECTION_SEED,
    fdc_node_vector, fdc_embedding_vector,
};
pub use default_ensemble::default_ensemble;
pub use span_encoder_factory::{SpanEncoderFactory, VOCABULARY_FILE_NAME};
pub use model_directory_resolver::model_dir_for;
pub use encoder_model_seed::EncoderModelSeed;
#[cfg(feature = "candle")]
pub use candle_provider::{
    CandleNLProvider, CANDLE_NL_DIMENSION, CANDLE_NL_MODEL_ID, CANDLE_NL_MODEL_VERSION,
    CANDLE_NL_PROJECTION_SEED,
};
