//! The ONE definition of the default recall ensemble (Rust port).
//!
//! The default ensemble is two signals: Random Indexing (RI) and LSA. Both are
//! always-on; neither requires a feature flag.
//!
//! RI stays because its binary fingerprint feeds dreaming, contradiction, and
//! consolidation. LSA earned its place: paired with RI it improves recall
//! fidelity over RI alone, and its cost is acceptable at the signal count we
//! ship (two providers).
//!
//! ## Why this lives in corpus-kit-providers, not corpus-kit core
//!
//! The factory constructs the concrete provider types (`RandomIndexingProvider`,
//! etc.), which live in this crate. `corpus-kit` core owns only the
//! `EmbeddingModelConfig` enum and never names a concrete provider (layering:
//! providers depend on core, never the reverse). So the construction of the
//! default set belongs here, in the providers layer. Mirrors the Swift
//! `CorpusEnsemble.defaultEnsemble()` in `CorpusKitProviders`.
//!
//! ## Why a function, not a constant
//!
//! `EmbeddingModelConfig` is NOT `Clone` — it carries `Box<dyn …>` provider
//! trait objects. The set therefore MUST be constructed fresh per call; a shared
//! `static` is impossible. Each estate gets its own untrained providers, which
//! the Corpus lifecycle trains and persists under their own model_ids. This is
//! the exact parity contract with the Swift factory, which constructs fresh per
//! call for the same per-estate-trained-state reason.

use corpus_kit::EmbeddingModelConfig;

use crate::LsaProvider;
use crate::RandomIndexingProvider;

/// The default recall ensemble (untrained): RI and LSA, always active.
///
/// - `RandomIndexing` leads at `models[0]`: it is the DEFAULT signal that the
///   Corpus's single-signal entry points delegate to.
/// - `Lsa` follows: improves recall fidelity paired with RI.
///
/// Constructed FRESH each call — `EmbeddingModelConfig` is not `Clone`.
pub fn default_ensemble() -> Vec<EmbeddingModelConfig> {
    vec![
        EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        },
        EmbeddingModelConfig::Lsa {
            provider: Box::new(LsaProvider::default_new()),
        },
    ]
}
