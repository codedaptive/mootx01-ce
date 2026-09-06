//! The ONE definition of the default recall ensemble (Rust port).
//!
//! Measurement (plan 70BC55F3, 2026-09-05): a retrieval-trained sentence encoder
//! reranking BM25's head beat BM25 on two corpora; the four float families
//! (LSA/NMF/PPMI/FDC) did not earn their cost. The default ensemble is now RI
//! only; the dense families compile only when the `dense-families` Cargo feature
//! is enabled. RI stays always-on: its binary fingerprint feeds dreaming,
//! contradiction, and consolidation.
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

use crate::RandomIndexingProvider;
#[cfg(feature = "dense-families")]
use crate::{FDCProvider, LsaProvider, NmfProvider, PpmiProvider};

/// The default recall ensemble (untrained), gated by the `dense-families` feature.
///
/// With `dense-families` OFF (default): one provider — `RandomIndexing`.
/// With `dense-families` ON (`--features dense-families`): five providers —
/// RI, PPMI, LSA, NMF, FDC — in that fixed canonical order.
///
/// `models[0]` (`RandomIndexing`) leads in both cases: it is the DEFAULT signal
/// that the Corpus's single-signal entry points delegate to.
///
/// The dense families are OFF by default (plan 70BC55F3, 2026-09-05):
/// LSA/NMF/PPMI/FDC did not beat BM25+RI on two measured corpora. RI stays
/// because its binary fingerprint feeds dreaming, contradiction, and consolidation.
///
/// Constructed FRESH each call — `EmbeddingModelConfig` is not `Clone`.
pub fn default_ensemble() -> Vec<EmbeddingModelConfig> {
    #[cfg(not(feature = "dense-families"))]
    {
        // Dense families are OFF (default, plan 70BC55F3, 2026-09-05).
        // RI only: binary fingerprint feeds dreaming and contradiction.
        vec![EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        }]
    }
    #[cfg(feature = "dense-families")]
    {
        // Dense families are ON: return all five signals.
        // Activated via --features dense-families.
        vec![
            EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(RandomIndexingProvider::new()),
            },
            EmbeddingModelConfig::Ppmi {
                provider: Box::new(PpmiProvider::new()),
            },
            EmbeddingModelConfig::Lsa {
                provider: Box::new(LsaProvider::default_new()),
            },
            EmbeddingModelConfig::Nmf {
                provider: Box::new(NmfProvider::default_new()),
            },
            EmbeddingModelConfig::Fdc {
                provider: Box::new(FDCProvider::default_provider()),
            },
        ]
    }
}
