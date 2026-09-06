// DefaultEnsemble.swift — the ONE definition of the default recall ensemble.
//
// Measurement (plan 70BC55F3, 2026-09-05): a retrieval-trained sentence encoder
// reranking BM25's head beat BM25 on two corpora (0.496 vs. 0.470; 0.335 vs.
// 0.310). The four float families (LSA/NMF/PPMI/FDC) did not earn their cost.
// The default ensemble is now RI only; the dense families compile only when the
// DenseFamilies trait is active (MOOTX01_DENSE_FAMILIES). RI stays always-on
// because its binary fingerprint feeds dreaming, contradiction, and consolidation.
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
/// default recall ensemble. The active set depends on the compile-time switch:
///
///   - **`MOOTX01_DENSE_FAMILIES` OFF (default):** one signal — RI only.
///     Measurement showed the dense families add cost without beating BM25+RI.
///     RI stays because its binary fingerprint feeds dreaming, contradiction,
///     and consolidation.
///   - **`MOOTX01_DENSE_FAMILIES` ON (`--traits DenseFamilies`):** five signals
///     — RI / PPMI / LSA / NMF / FDC. Used for measurement and benchmarks.
public enum CorpusEnsemble {

    /// The default recall ensemble (untrained), gated by `MOOTX01_DENSE_FAMILIES`.
    ///
    /// With the switch OFF (default): one provider — `.randomIndexing`.
    /// With the switch ON:  five providers — RI, PPMI, LSA, NMF, FDC — in that
    /// fixed canonical order.
    ///
    /// `models[0]` (`.randomIndexing`) leads in both cases — it is the DEFAULT
    /// signal that the Corpus's single-signal entry points delegate to.
    ///
    /// Constructed FRESH each call — see the file header for why a function and
    /// not a shared constant.
    ///
    /// - Returns: the untrained `EmbeddingModel` cases for the active switch state.
    public static func defaultEnsemble() -> [EmbeddingModel] {
#if MOOTX01_DENSE_FAMILIES
        // Dense families are ON: return all five honest signals.
        // Activated via `swift test --traits DenseFamilies` / `swift build --traits DenseFamilies`.
        [
            .randomIndexing(provider: RandomIndexingProvider()),
            .ppmi(provider: PpmiProvider()),
            .lsa(provider: LsaProvider()),
            .nmf(provider: NmfProvider()),
            .fdc(provider: FDCProvider())
        ]
#else
        // Dense families are OFF (default, plan 70BC55F3, 2026-09-05):
        // LSA/NMF/PPMI/FDC did not beat BM25+RI on two measured corpora.
        // RI only — its binary fingerprint feeds dreaming, contradiction,
        // and consolidation and must not be removed.
        [.randomIndexing(provider: RandomIndexingProvider())]
#endif
    }
}
