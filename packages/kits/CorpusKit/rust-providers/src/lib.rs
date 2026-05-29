//! corpus-kit-providers -- Rust port of Swift's `CorpusKitProviders`
//! target. Hosts concrete `Tokenizer` implementations and (in a
//! follow-on R-mission) concrete `vectorkit::EmbeddingProvider`
//! implementations whose presence implies a model bundle or a
//! deliberately documented test stub.
//!
//! `DeterministicTokenizer` ships at v1.0 as the test fixture
//! mirror of Swift's same-named type. Real WordPiece /
//! SentencePiece tokenizers and ONNX-backed providers land in a
//! follow-on R-mission once model bundles are wired in.
//!
//! Core `corpus-kit` (the sibling crate) is intentionally
//! provider-free -- only the `Tokenizer` trait lives there. The
//! `EmbeddingProvider` trait lives in `vectorkit` (consolidation
//! 2026-05-27); concrete text providers in this crate will conform
//! to it directly. This layout matches Swift's split between
//! `CorpusKit` and `CorpusKitProviders`.

pub mod deterministic_tokenizer;

pub use deterministic_tokenizer::DeterministicTokenizer;
