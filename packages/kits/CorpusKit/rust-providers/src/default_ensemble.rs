//! The ONE definition of the 1.0 default recall ensemble (Rust port).
//!
//! Mission 6a-iii-wire: flip the production default from a single deterministic
//! provider to the canonical five honest signals. `default_ensemble()` is the
//! single source of truth for "the 1.0 default recall ensemble" — every
//! production provision / open site threads THIS list, so the five honest
//! signals (RI / PPMI / LSA / NMF / FDC) are the live default everywhere.
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

use crate::{
    FDCProvider, LsaProvider, NmfProvider, PpmiProvider, RandomIndexingProvider,
};

/// The canonical FIVE-signal default recall ensemble (untrained).
///
/// Returns, in this fixed order:
///   1. `RandomIndexing` — Random Indexing distributional semantics.
///   2. `Ppmi`           — PPMI-weighted distributional semantics.
///   3. `Lsa`            — Latent Semantic Analysis (truncated SVD).
///   4. `Nmf`            — Non-negative matrix factorization latent factors.
///   5. `Fdc`            — Frame Decimal Classification co-classification.
///
/// The four distributional / matrix providers (RI/PPMI/LSA/NMF) are trainable:
/// the Corpus lifecycle trains and persists them on first ingest / reindex under
/// their own model_ids. FDC is stateless — ready immediately, no training. The
/// providers are returned UNTRAINED; the Corpus owns the train+persist lifecycle.
///
/// `models[0]` (`RandomIndexing`) is the DEFAULT signal that the Corpus's
/// single-signal entry points delegate to, so it leads the order.
///
/// LSA/NMF use their canonical default constructors (same rank / sweeps /
/// iterations / seeds as the Swift parameterless inits) so the trained bases —
/// and therefore the per-signal rankings — match Swift bit-for-bit. The order
/// and provider set are byte-identical to `CorpusEnsemble.defaultEnsemble()`.
///
/// Constructed FRESH each call — `EmbeddingModelConfig` is not `Clone`.
pub fn default_ensemble() -> Vec<EmbeddingModelConfig> {
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
