// DefaultEnsemble.swift — the ONE definition of the default recall ensemble.
//
// The default ensemble is two signals: Random Indexing (RI) and LSA. Both are
// always-on; neither requires a trait or feature flag.
//
// RI stays because its binary fingerprint feeds dreaming, contradiction, and
// consolidation. LSA earned its place: paired with RI it improves recall
// fidelity over RI alone, and its cost is acceptable at the signal count we
// ship (two providers).
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
/// `CorpusEnsemble.defaultEnsemble()` is the single definition of the default
/// recall ensemble: two signals, RI and LSA, always on.
///
/// - RI (Random Indexing): binary fingerprint, feeds dreaming/contradiction/
///   consolidation. Required; cannot be removed.
/// - LSA (Latent Semantic Analysis): improves recall fidelity paired with RI.
///   Always active alongside RI in the default ensemble.
public enum CorpusEnsemble {

    /// The default recall ensemble (untrained): RI and LSA, always active.
    ///
    /// `models[0]` (`.randomIndexing`) leads — it is the DEFAULT signal that the
    /// Corpus's single-signal entry points delegate to.
    ///
    /// Constructed FRESH each call — see the file header for why a function and
    /// not a shared constant.
    ///
    /// - Returns: the untrained `EmbeddingModel` cases for the default ensemble.
    public static func defaultEnsemble() -> [EmbeddingModel] {
        [
            .randomIndexing(provider: RandomIndexingProvider()),
            .lsa(provider: LsaProvider()),
        ]
    }
}
