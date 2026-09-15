// CompositionGrid.swift
//
// THE ABLATION GRID — the named set of reduction compositions the gauntlet
// ranks. This is an ABLATION, not a tournament: every composition is kept (a
// non-winner serves other recall needs — a hamming-only reduce is the right
// tool for a semantic-paraphrase query even if tokenExact wins on numeric
// needles). None is pre-judged; reality (the gauntlet) ranks them.
//
// The grid is data: each entry is a `ReductionComposition` value. Adding a
// composition is one line here, runnable and measurable immediately — no new
// type, no new code path. The optimizer enumerates this list against the
// gauntlet and reads the per-tier leaderboard.

import Foundation
import GeniusLocusKit
import SubstrateML

extension NeuronKit {

    /// The named ablation grid: every reduction composition the harness exposes.
    /// The first entry is the default (`text`) — the current PreciseRecall
    /// behavior — so an unspecified `composition` arg reproduces today's recipe.
    public enum CompositionGrid {

        /// The default composition name (the current text-only precise reduce).
        public static let defaultName = "text"

        /// Every composition in the grid, in a stable enumeration order. Single-
        /// signal compositions isolate one signal's contribution; the combined
        /// and weighted-all compositions test interactions.
        public static let all: [NeuronKit.ReductionComposition] = {
            var grid: [NeuronKit.ReductionComposition] = [
            // --- single-signal isolations (one signal's contribution, ablated) ---
            .init(name: "text", terms: [.init(.text)]),
            .init(name: "hamming", terms: [.init(.hamming)]),
            .init(name: "matrix", terms: [.init(.matrix)]),
            .init(name: "lattice", terms: [.init(.lattice)]),
            .init(name: "tokenExact", terms: [.init(.tokenExact)]),
            .init(name: "bm25", terms: [.init(.bm25)]),
            .init(name: "vector", terms: [.init(.vector)]),

            // --- pairwise / combination compositions ---
            // hamming + the fine numeric discriminator.
            .init(name: "hamming+tokenExact", terms: [.init(.hamming), .init(.tokenExact)]),
            // SimHash-Hamming similarity + content-word match.
            .init(name: "hamming+text", terms: [.init(.hamming), .init(.text)]),
            // content-word match + co-occurrence.
            .init(name: "text+matrix", terms: [.init(.text), .init(.matrix)]),
            // knowledge-region proximity + SimHash-Hamming similarity.
            .init(name: "lattice+hamming", terms: [.init(.lattice), .init(.hamming)]),
            // the precise discriminator pair: content match + exact token match.
            .init(name: "text+tokenExact", terms: [.init(.text), .init(.tokenExact)]),

            // --- diversity-aware composition ---
            // content match, then an MMR diversity re-rank to cut near-duplicate
            // contamination without dropping the target out of the bounded set.
            .init(name: "text+mmr", terms: [.init(.text), .init(.mmr)], mmrLambda: 0.7),

            // --- T3 temporal: current-over-superseded ---
            // temporalState (dense, body-free): structural currency from the
            // drawer state cluster. temporalText (content): the currency-marker
            // discriminator the gauntlet's T3 tier plants. temporal: the two
            // halves together. text+temporal: content-word match plus currency,
            // the practical recipe — find the right fact, then prefer its
            // current version.
            .init(name: "temporalState", terms: [.init(.temporalState)]),
            .init(name: "temporalText", terms: [.init(.temporalText)]),
            .init(name: "temporal", terms: [.init(.temporalState), .init(.temporalText)]),
            .init(name: "text+temporal", terms: [
                .init(.text, weight: 1.0),
                .init(.temporalText, weight: 0.8),
                .init(.temporalState, weight: 0.4),
            ]),

            // --- T4 split-fact assembly ---
            // assembly is a set-level EXPANSION: it pulls a record's REF-code
            // partner into the bounded set so both halves of a split fact are
            // co-surfaced. Paired with text so the needle half ranks first, then
            // assembly completes the answer by pulling its partner.
            .init(name: "text+assembly", terms: [.init(.text), .init(.assembly)]),
            .init(name: "tokenExact+assembly", terms: [.init(.tokenExact), .init(.assembly)]),

            // --- T5 association: matrix co-occurrence (needs a DREAMED estate) ---
            // text+matrix already exists above. These weight the matrix
            // association lane more heavily so a needle filed far from its
            // topical home is surfaced through what it co-occurs with rather than
            // where it sits. matrix-weighted: content match led by the
            // association signal; matrix+hamming: pure-dense association + dense
            // closeness (no body).
            .init(name: "matrix-weighted", terms: [
                .init(.text, weight: 1.0),
                .init(.matrix, weight: 0.8),
            ]),
            .init(name: "matrix+hamming", terms: [.init(.matrix), .init(.hamming)]),

            // --- weighted-all: every PER-CANDIDATE signal, weighted ---
            // Weights lead with the content/token discriminators (the found@1
            // levers) and add the dense lanes as support. Now includes the
            // per-candidate temporal terms (currency text + structural state) so
            // the everything-weighted seed prefers the current version too. The
            // set-level expansions (mmr, assembly) are NOT here — they re-order
            // the set rather than score a candidate, so they have their own
            // columns. Not tuned by the optimizer yet — the seed the ablation
            // measures.
            .init(name: "weighted-all", terms: [
                .init(.text, weight: 1.0),
                .init(.tokenExact, weight: 0.8),
                .init(.hamming, weight: 0.5),
                .init(.dense, weight: 0.5),
                .init(.matrix, weight: 0.3),
                .init(.vector, weight: 0.3),
                .init(.temporalText, weight: 0.3),
                .init(.temporalState, weight: 0.2),
                .init(.lattice, weight: 0.2),
                .init(.bm25, weight: 0.2),
            ]),

            // --- composite: cookbook §8.4, THE designed primary retrieval
            // distance, activated by W2.5 Track M3. d = αL·lattice_distance
            // + αF·hamming/256 with αL = αF = 0.5 at estate creation. The
            // grid scores SIMILARITIES (1 − each normalized distance), so
            // this weighted-similarity entry is the same ordering as the
            // §8.4 distance (affine flip; weights ARE the §8.4 alphas, read
            // from the designed constants so Track R's Bradley-Terry-learned
            // alphas later flow through one source of truth).
            .init(name: "composite", terms: [
                .init(.lattice, weight: CompositeDistance.defaultAlphaLattice),
                .init(.hamming, weight: CompositeDistance.defaultAlphaFingerprint),
            ]),
            ]
            // --- T2 / T5 semantic: the whole-record float lane (
            // build only). The `dense` signal carries the cosine over the pooled
            // float embedding, which is scale-invariant, so an answer statement
            // ranks above a near-duplicate of the question. dense leads; text is
            // the content discriminator that breaks near-ties on the dense
            // signal. A pure-lexical distractor (text=1.0) whose dense cosine is
            // orthogonal floors at dense=0.5 ((cos0+1)/2), so its total is
            // 0.5 + 0.3 = 0.8, below a semantically matched answer whose
            // dense is about 1.0. In the default build PreciseRecall recalls
            // with `.raw` scoring, where the dense column is never filled, so
            // the composition is compiled out with the lane. It keeps its
            // declaration slot (before weighted-all) so the benchmarker
            // fixture order and the grid order agree in that build.
            let slot = grid.firstIndex { $0.name == "weighted-all" } ?? grid.endIndex
            grid.insert(.init(name: "dense-fused", terms: [
                .init(.dense, weight: 1.0),
                .init(.text, weight: 0.3),
            ]), at: slot)
            return grid
        }()

        /// Look up a composition by name. Returns the default (`text`) when the
        /// name is unknown or nil, so a caller passing a bad name degrades to the
        /// current behavior rather than failing.
        public static func named(_ name: String?) -> NeuronKit.ReductionComposition {
            guard let name else { return byName(defaultName) }
            return byName(name)
        }

        /// Look up a composition by name and apply the optimizer-owned recall
        /// tuning to override the `mmrLambda` for compositions that include an
        /// `mmr` term. Non-MMR compositions are returned unchanged.
        ///
        /// Precedence: the `tuning.mmrLambda` always applies when the composition
        /// has an MMR term — the optimizer chose it; the spec constant is the
        /// factory fallback when no manifest key is present.
        ///
        /// - Parameters:
        ///   - name: composition name (falls back to `text` if unknown or nil).
        ///   - tuning: optimizer-owned recall-tuning envelope from the estate
        ///     manifest (e.g. from `GeniusLocusKit.provisionedRecallTuning(for:)`).
        ///     Pass `.default` to preserve the spec constant behavior.
        /// - Returns: the named composition with `mmrLambda` overridden when the
        ///   tuning is non-default and the composition uses the `mmr` signal.
        public static func named(
            _ name: String?,
            applyingTuning tuning: RecallTuningManifest
        ) -> NeuronKit.ReductionComposition {
            let base = named(name)
            // Only override mmrLambda when the composition has an MMR term and
            // the manifest carries a non-spec-default value. Pure-spec-default
            // tuning returns the same composition as `named(_:)` exactly.
            guard base.hasMMR, tuning != .default else { return base }
            return NeuronKit.ReductionComposition(
                name: base.name,
                terms: base.terms,
                mmrLambda: Double(tuning.mmrLambda))
        }

        /// All composition names in grid order (the gauntlet column ids).
        public static var names: [String] { all.map(\.name) }

        private static func byName(_ name: String) -> NeuronKit.ReductionComposition {
            all.first { $0.name == name } ?? all.first { $0.name == defaultName }!
        }
    }
}
