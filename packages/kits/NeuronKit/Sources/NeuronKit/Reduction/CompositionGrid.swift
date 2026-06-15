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
        public static let all: [NeuronKit.ReductionComposition] = [
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
            // dense closeness + content-word match.
            .init(name: "hamming+text", terms: [.init(.hamming), .init(.text)]),
            // content-word match + co-occurrence.
            .init(name: "text+matrix", terms: [.init(.text), .init(.matrix)]),
            // knowledge-region proximity + dense closeness.
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

            // --- T2 / T5 semantic: the TRUE dense float lane (Lane D) ---
            // dense-fused is the real dense column that replaces the removed
            // "vector" alias (which was byte-identical to "hamming" — a 256-bit
            // SimHash projection that scored 0.00 found@k on answer-vs-question-
            // echo). The `dense` signal carries the cosine over the pooled float
            // embedding, which IS scale-invariant, so an answer statement ranks
            // above a near-duplicate of the question. dense leads; text is the
            // content discriminator that breaks near-ties on the dense signal.
            // This is the recipe the gauntlet runs for the semantic-similarity
            // tiers (T2, T5) the SimHash-Hamming lane lost.
            // dense leads at full weight; text is a light tie-breaker only.
            // A pure-lexical distractor (text=1.0) whose dense cosine is
            // orthogonal floors at dense=0.5 ((cos0+1)/2), so its total is
            // 0.5 + 0.3 = 0.8 — below a semantically-matched answer whose
            // dense≈1.0. Keeping text's weight low is what lets the dense
            // signal, not the shared words, decide the rank.
            .init(name: "dense-fused", terms: [
                .init(.dense, weight: 1.0),
                .init(.text, weight: 0.3),
            ]),

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
        ]

        /// Look up a composition by name. Returns the default (`text`) when the
        /// name is unknown or nil, so a caller passing a bad name degrades to the
        /// current behavior rather than failing.
        public static func named(_ name: String?) -> NeuronKit.ReductionComposition {
            guard let name else { return byName(defaultName) }
            return byName(name)
        }

        /// All composition names in grid order (the gauntlet column ids).
        public static var names: [String] { all.map(\.name) }

        private static func byName(_ name: String) -> NeuronKit.ReductionComposition {
            all.first { $0.name == name } ?? all.first { $0.name == defaultName }!
        }
    }
}
