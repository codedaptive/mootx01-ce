// DefaultEnsemble.swift — the ONE definition of the 1.0 default recall ensemble.
//
// Mission 6a-iii-wire: flip the production default from a single deterministic
// provider to the canonical five honest signals. This factory is the single
// source of truth for "the 1.0 default recall ensemble" — every production
// provision/open site threads THIS list, so the five honest signals
// (RI / PPMI / LSA / NMF / FDC) are the live default everywhere.
//
// ## Why this lives in CorpusKitProviders, not CorpusKit core
//
// The factory NEWs the concrete provider types (RandomIndexingProvider, etc.),
// which live in CorpusKitProviders. CorpusKit core owns only the `EmbeddingModel`
// enum and never names a concrete provider (the sealed-vector / layering
// principle: providers depend on core, never the reverse). So the construction
// of the default set belongs here, in the providers layer. Core's
// `EmbeddingModel.default` (the single `.deterministic` case) remains the N=1
// fallback for callers that explicitly want one signal; the ENSEMBLE default is
// this factory.
//
// ## Why a factory function, not a shared constant
//
// Each `EmbeddingModel` distributional/co-classification case carries a freshly
// constructed provider whose trained state is built per-estate by the Corpus
// lifecycle (first-ingest auto-train / reindex). The providers are reference
// types holding mutable trained state, so a single shared array would alias one
// provider instance across every estate. Constructing fresh per call gives each
// estate its own untrained providers, which the Corpus lifecycle then trains and
// persists under their own modelIDs. This also mirrors the Rust
// `default_ensemble()`, where `EmbeddingModelConfig` is not `Clone` and the set
// MUST be constructed fresh per call.

import CorpusKit

/// Factory namespace for CorpusKit's canonical default embedding ensemble.
///
/// `CorpusEnsemble.defaultEnsemble()` is the single definition of the 1.0
/// default recall ensemble — the five honest distributional / co-classification
/// signals every production estate is provisioned with.
public enum CorpusEnsemble {

    /// The canonical FIVE-signal default recall ensemble (untrained).
    ///
    /// Returns, in this fixed order:
    ///   1. `.randomIndexing` — Random Indexing distributional semantics.
    ///   2. `.ppmi`           — PPMI-weighted distributional semantics.
    ///   3. `.lsa`            — Latent Semantic Analysis (truncated SVD).
    ///   4. `.nmf`            — Non-negative matrix factorization latent factors.
    ///   5. `.fdc`            — Frame Decimal Classification co-classification.
    ///
    /// The four distributional / matrix providers (RI/PPMI/LSA/NMF) are
    /// trainable: the Corpus lifecycle trains and persists them on first
    /// ingest / reindex under their own modelIDs. FDC is stateless — ready
    /// immediately, no training required. The providers are returned UNTRAINED;
    /// the Corpus owns the train+persist lifecycle.
    ///
    /// `models[0]` (`.randomIndexing`) is the DEFAULT signal that the Corpus's
    /// single-signal entry points delegate to, so it leads the order.
    ///
    /// Constructed FRESH each call — see the file header for why a function and
    /// not a shared constant.
    ///
    /// - Returns: the five untrained `EmbeddingModel` cases in canonical order.
    public static func defaultEnsemble() -> [EmbeddingModel] {
        [
            .randomIndexing(provider: RandomIndexingProvider()),
            .ppmi(provider: PpmiProvider()),
            .lsa(provider: LsaProvider()),
            .nmf(provider: NmfProvider()),
            .fdc(provider: FDCProvider())
        ]
    }
}
