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
//! - `RandomIndexingProvider` -- the always-on distributional provider;
//!   feeds dreaming, contradiction, and consolidation.
//! - `LsaProvider` -- compiled when the `lsa` feature is on.
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
//! ## Default ensemble
//!
//! RI and LSA are both always-on. No Cargo feature gates are required.
//! RandomIndexingProvider and LsaProvider compile unconditionally.

pub mod deterministic_tokenizer;
// Shared little-endian binary codec for distributional-provider
// basis serialization. PROVIDER-FORMAT code (not a math primitive) used by
// RandomIndexing and LSA. Swift port: Sources/CorpusKitProviders/
// BasisCodec.swift. The byte layout is the cross-port contract.
pub mod basis_codec;
// Shared term-document count builder reused by LSA and RI.
// Owns vocab encounter-order construction, TF counts, DF counts, and the
// one smoothed IDF function.
// Swift port: Sources/CorpusKitProviders/TermDocumentCounts.swift.
pub mod term_document_counts;
// The ONE pooling function for the term-vector distributional provider
// (RI): IDF-weighted sum of the distinct terms' vectors, L2-normalised,
// corpus-mean direction removed, L2-normalised. Documents and queries share it.
// Swift port: Sources/CorpusKitProviders/DistributionalPooling.swift.
pub mod distributional_pooling;
pub mod random_indexing;
// MiniLM text provider — always compiled; used by the encoder rerank lane.
pub mod text_providers;
// The ONE definition of the default recall ensemble.
// Default ensemble: RI and LSA, both always on.
// Mirrors Swift's CorpusEnsemble.defaultEnsemble() in CorpusKitProviders.
pub mod default_ensemble;

// feature is on. Bit-identical with Swift's CorpusKitProviders/ReducedVocab.
pub mod reduced_vocab;
// Semantic fusion signal: LSA/SVD distributional-semantics provider.
// Compiled only when the `lsa` feature is on (ruling 2026-09-07):
// Uses substrate_ml::svd::JacobiSvd (deterministic, bit-identical with Swift).
pub mod lsa;

// Candle-backed in-process ML inference provider (all-MiniLM-L6-v2).
// Compiled only when the `candle` Cargo feature is enabled.
// See src/candle_provider.rs for the gate-8 throughput disposition and
// the critical tokenizer-padding override note.
pub mod candle_provider;
pub mod span_encoder_factory;
// Cross encoder: the candle sequence classifier and the factory that builds a
// `PairScorer` from a model directory. Twin of Swift `CoreMLPairInference` +
// `PairScorerFactory`.
pub mod candle_pair_scorer;
pub mod pair_scorer_factory;
// ModelDirectoryResolver: locates the encoder model directory for a given
// model ID by searching the 1.2 download slot and the installer package slot.
// Verifies vocab.txt sha256 as the integrity sentinel; returns None on any
// mismatch. Called by SpanEncoderFactory::make. Swift port:
// Sources/CorpusKitProviders/ModelDirectoryResolver.swift.
pub mod model_directory_resolver;
// Hardcoded seed constants for the bundled arctic-embed-s encoder model.
// Consumed by the GLK activation path (`EstateCoordinator::seed_default_encoder_model_in`,
// called at open when the manifest names `embedding_provider = "encoder"`) and
// by `mootx01 upgrade` to INSERT the initial `encoder_models` row. Twin of Swift's
// `EncoderModelSeed`.
pub mod encoder_model_seed;

pub use basis_codec::{BasisCodecError, BasisReader, BasisWriter, BASIS_FORMAT_VERSION};
pub use deterministic_tokenizer::DeterministicTokenizer;
pub use term_document_counts::{smoothed_inverse_document_frequency, TermDocumentCounts};
pub use distributional_pooling::{mean_direction, pool, remove_mean_direction};
pub use random_indexing::{
    RandomIndexingProvider, RI_DIMENSION, RI_NONZEROS, RI_PROJECTION_SEED, RI_WINDOW,
    ri_index_vector,
};
// MiniLM is always compiled; LSA is gated behind the `lsa` feature.
pub use text_providers::MiniLMTextProvider;
pub use lsa::{LsaProvider, LSA_DEFAULT_RANK, LSA_PROJECTION_SEED};
pub use default_ensemble::default_ensemble;
pub use span_encoder_factory::{SpanEncoderFactory, VOCABULARY_FILE_NAME};
pub use pair_scorer_factory::PairScorerFactory;
pub use model_directory_resolver::model_dir_for;
pub use encoder_model_seed::EncoderModelSeed;
#[cfg(feature = "candle")]
pub use candle_provider::{
    CandleNLProvider, CANDLE_NL_DIMENSION, CANDLE_NL_MODEL_ID, CANDLE_NL_MODEL_VERSION,
    CANDLE_NL_PROJECTION_SEED,
};
