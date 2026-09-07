// DefaultEnsemble.swift — the ONE definition of the default recall ensemble.
//
// Measurement (plan 70BC55F3, 2026-09-05): a retrieval-trained sentence encoder
// reranking BM25's head beat BM25 on two corpora (0.496 vs. 0.470; 0.335 vs.
// 0.310). The four float families (NMF/PPMI/FDC and the dark LSA) did not earn
// their cost. The default ensemble is now RI only; the dense families compile
// only when the DenseFamilies trait is active (MOOTX01_DENSE_FAMILIES). RI
// stays always-on because its binary fingerprint feeds dreaming, contradiction,
// and consolidation. LSA is on its own separate switch (MOOTX01_LSA); it is
// dark and unproven — DenseFamilies does NOT enable it (ruling 2026-09-07).
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
/// `CorpusEnsemble.defaultEnsemble()` is the single definition of the
/// default recall ensemble. The active set depends on the compile-time switches:
///
///   - **`MOOTX01_DENSE_FAMILIES` OFF (default):** one signal — RI only.
///     Measurement showed the dense families add cost without beating BM25+RI.
///     RI stays because its binary fingerprint feeds dreaming, contradiction,
///     and consolidation.
///   - **`MOOTX01_DENSE_FAMILIES` ON (`--traits DenseFamilies`):** four signals
///     — RI / PPMI / NMF / FDC. LSA is dark on its own switch (MOOTX01_LSA);
///     DenseFamilies does NOT enable it (ruling 2026-09-07).
///   - **`MOOTX01_LSA` ON (`--traits LSA`):** five signals — RI / PPMI / LSA /
///     NMF / FDC. Used for LSA measurement only; the LSA provider is unproven.
public enum CorpusEnsemble {

    /// The default recall ensemble (untrained), gated by `MOOTX01_DENSE_FAMILIES`.
    ///
    /// With the switch OFF (default): one provider — `.randomIndexing`.
    /// With `MOOTX01_DENSE_FAMILIES` ON: four providers — RI, PPMI, NMF, FDC —
    /// in that fixed canonical order. LSA is excluded; it is on its own switch
    /// (`MOOTX01_LSA`) and is dark and unproven (ruling 2026-09-07).
    /// With `MOOTX01_LSA` ON: five providers — RI, PPMI, LSA, NMF, FDC.
    ///
    /// `models[0]` (`.randomIndexing`) leads in all cases — it is the DEFAULT
    /// signal that the Corpus's single-signal entry points delegate to.
    ///
    /// Constructed FRESH each call — see the file header for why a function and
    /// not a shared constant.
    ///
    /// - Returns: the untrained `EmbeddingModel` cases for the active switch state.
    public static func defaultEnsemble() -> [EmbeddingModel] {
#if MOOTX01_DENSE_FAMILIES
        // Dense families are ON: four signals — RI, PPMI, NMF, FDC.
        // LSA is on its own separate switch (MOOTX01_LSA); DenseFamilies does
        // NOT enable it. Enable `--traits LSA` to get the fifth signal.
        var models: [EmbeddingModel] = [
            .randomIndexing(provider: RandomIndexingProvider()),
            .ppmi(provider: PpmiProvider()),
        ]
#if MOOTX01_LSA
        // LSA is on: insert it in the canonical slot (after PPMI, before NMF).
        models.append(.lsa(provider: LsaProvider()))
#endif
        models.append(.nmf(provider: NmfProvider()))
        models.append(.fdc(provider: FDCProvider()))
        return models
#else
        // Dense families are OFF (default, plan 70BC55F3, 2026-09-05):
        // NMF/PPMI/FDC (and the dark LSA) did not beat BM25+RI on two corpora.
        // RI only — its binary fingerprint feeds dreaming, contradiction,
        // and consolidation and must not be removed.
        return [.randomIndexing(provider: RandomIndexingProvider())]
#endif
    }
}
