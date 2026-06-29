// HMMTagger.swift
//
// The deterministic non-Apple novel-token tagger: a small Hidden Markov
// Model decoded with integer Viterbi over a morphological observation
// alphabet. This is the non-Apple branch of `WordClassTagger`
// (`hmmViterbiTag`); the Apple branch uses NLTagger instead.
//
// CONTRACT (load-bearing — read before changing anything)
//   * DETERMINISTIC and IDENTICAL Swift ↔ Rust. The model tables are loaded
//     from the frozen checked-in artifact `Resources/HMMTaggerModel.json`,
//     which is byte-identical on both ports. Scoring is INTEGER (fixed-point
//     log-weights, scale 1000) so there is no floating rounding to diverge
//     between ports. The shared fixture rust/tests/fixtures/tag_conformance.json
//     gates byte-identity.
//   * It does NOT, and is NOT required to, match Apple's NLTagger output.
//     Apple and this HMM are different engines. The guarantee is
//     cross-platform SELF-CONSISTENCY of the non-Apple path, exactly as the
//     fast-path table is the cross-platform-guaranteed surface for table
//     tokens (cookbook §2.2). On Apple, novel tokens still go to NLTagger;
//     this tagger is the deterministic fallback everywhere NLTagger is
//     absent.
//
// WHY AN HMM (not a flat lookup)
// A single token carries only morphology, so the emission distribution is
// keyed on a small alphabet of suffix/shape OBSERVATIONS (see `observe`).
// The Viterbi machinery is written for a general state sequence; for a
// one-token input it reduces to argmax over (initial + emission), but the
// structure is the real thing and extends to multi-token tagging without a
// rewrite. Keeping it a true Viterbi (rather than inlining the argmax)
// documents intent and keeps the Swift/Rust ports structurally identical.
//
// TRAINED WEIGHTS — MASC 3.0.0 Penn Treebank constituency (ANC)
// The model tables (initial_weights + emission_weights) are TRAINED on the
// MASC 3.0.0 Penn Treebank constituency annotation (CC BY 3.0 US), read from
// the frozen checked-in artifact `Resources/HMMTaggerModel.json`. Attribution:
// see `Resources/HMMTaggerModel.NOTICE.md`.
//
// UNKNOWN-WORD ESTIMATION (load-bearing). This HMM only ever runs on NOVEL
// (out-of-vocabulary) tokens — known/closed-class words are served by the
// fast-path WordClassTable and never reach it. So the model is estimated from
// the words that behave like novel ones: the corpus's RARE words (hapax
// legomena, frequency 1), ~5,230 tokens. Frequent function words (all "other")
// are never rare and so drop out by frequency — giving the correct, content-
// noun-dominant unknown-word prior (a no-suffix unknown token defaults to
// noun, e.g. "religion"). Estimating from the full corpus instead would let
// function words dominate the no-suffix bucket and wrongly default unknowns to
// "other"; the rare-word filter is what prevents that.
//
// Estimation formulas (over rare tokens; Laplace add-1, integer log-weight,
// scale 1000):
//   initial:  p(state)  = (count[state]+1) / (rare_tokens+3)
//   emission: p(o|state) = (count[state][o]+1) / (count[state]+12)
//   weight:   w = int(floor(ln(p)*1000 + 0.5))
//
// The Rust port (`rust/src/word_class.rs`) reads the SAME JSON artifact via
// `include_bytes!`, so the two ports cannot diverge as long as the artifact
// is the single source of truth. See the artifact's `hmm_viterbi_version`
// field; bump it (and `currentTaggerVersion` in WordClassTagger.swift) when
// the artifact is regenerated.
//
// The weights are log-likelihoods scaled by `LOG_SCALE` and rounded to
// integers at ETL time; runtime arithmetic is pure integer add + max,
// so the two ports cannot diverge.

import Foundation

/// A 3-state HMM (Noun/Verb/Other) with integer Viterbi decode, used as the
/// deterministic non-Apple novel-token tagger. Pure, total, and
/// byte-identical to the Rust port. Weights loaded from the frozen checked-in
/// artifact `Resources/HMMTaggerModel.json` (MASC 3.0.0, CC BY 3.0 US).
enum HMMTagger {

    /// Fixed-point scale for the integer log-weights. A weight of
    /// `-700` represents ln(p) ≈ -0.7 (p ≈ 0.5). Scoring never divides, so
    /// the scale only needs to be consistent between the two ports.
    static let logScale = 1000

    /// The hidden states, in a fixed index order shared with Rust:
    /// 0 = noun, 1 = verb, 2 = other. The order is part of the contract
    /// because the Viterbi tie-break favours the lowest state index.
    private static let states: [WordClass] = [.noun, .verb, .other]

    /// The morphological observation alphabet. Each token maps to exactly
    /// one observation via `observe`. The alphabet is small and closed so
    /// the emission table is a fixed matrix.
    enum Obs: Int, CaseIterable {
        case nonAlpha      = 0  // contains a non-letter (digit, symbol)
        case suffixIng     = 1  // ...ing
        case suffixEd      = 2  // ...ed
        case suffixIzeIse  = 3  // ...ize / ...ise
        case suffixAte     = 4  // ...ate
        case suffixTion    = 5  // ...tion / ...sion
        case suffixNess    = 6  // ...ness
        case suffixMent    = 7  // ...ment
        case suffixItyTy   = 8  // ...ity / ...ty
        case suffixErOrAr  = 9  // ...er / ...or / ...ar
        case suffixLy      = 10 // ...ly  (adverb-ish → other)
        case plain         = 11 // none of the above
    }

    // MARK: - Frozen artifact loading (once per process)

    /// The on-disk schema of `HMMTaggerModel.json`. Both ports decode the
    /// same JSON; field order in the file is alphabetical (sort_keys=True).
    private struct ModelArtifact: Decodable {
        // swiftlint:disable identifier_name
        let emission_weights: [[Int]]
        let initial_weights: [Int]
        let token_count: Int
        // swiftlint:enable identifier_name
    }

    /// The loaded model artifact, parsed once per process from
    /// `Bundle.module`'s `HMMTaggerModel.json`. Mirrors the `QIDClosure`
    /// and `FDCRuntime` resource-load pattern.
    ///
    /// Written once at first access under `static let`, never mutated.
    /// Thread-safe after initialization because `static let` uses Swift's
    /// native atomic once-initializer (the same guarantee as `DispatchOnce`).
    private static let model: ModelArtifact? = {
        guard
            let url = Bundle.module.url(
                forResource: "HMMTaggerModel",
                withExtension: "json"
            ),
            let data = try? Data(contentsOf: url)
        else {
            // The artifact is checked in and bundled at build time; this
            // path should never be reached in a correctly built binary.
            // If it is, `initialWeights` and `emissionWeights` fall back
            // to compiled-in trained values rather than emitting all nouns.
            return nil
        }
        return try? JSONDecoder().decode(ModelArtifact.self, from: data)
    }()

    /// Initial (prior) log-weights per state, index-aligned with `states`.
    /// Loaded from the frozen artifact. Trained on MASC 3.0.0 PTB corpus.
    ///
    /// Falls back to `[-643, -1562, -1329]` if the artifact is unavailable
    /// (build-time invariant — the artifact is always present). These are
    /// exactly the trained values so the fallback preserves correctness even
    /// if Bundle.module resolution fails in an unusual host environment.
    private static let initialWeights: [Int] = {
        model?.initial_weights ?? [-643, -1562, -1329]
    }()

    /// Emission log-weights `emission[stateIndex][obs]`. Each row is a state;
    /// each column an observation. Higher (closer to 0) = more likely.
    /// Loaded from the frozen artifact. Trained on MASC 3.0.0 PTB corpus.
    ///
    /// Falls back to the trained values if the artifact is unavailable
    /// (build-time invariant — the artifact is always present).
    private static let emissionWeights: [[Int]] = {
        model?.emission_weights ?? [
            // noun
            [-2954, -3606, -5526, -6132, -5978, -3103, -4746, -4260, -3898, -2867, -5621, -270],
            // verb
            [-4525, -1473, -1011, -4445, -3609, -6317, -7010, -6317, -7010, -4708, -6317, -1075],
            // other
            [-1125, -3874, -2898, -7241, -4843, -6548, -7241, -7241, -5162, -3528, -2160, -826],
        ]
    }()

    // MARK: - Viterbi decode

    /// Tags a single lowercased token via integer Viterbi decode.
    ///
    /// For a one-token observation sequence Viterbi reduces to
    /// `argmax_state (initial[state] + emission[state][obs])`. Ties resolve
    /// to the lowest state index (noun < verb < other), which the loop
    /// enforces by using strict `>` on the running best. Deterministic and
    /// byte-identical to the Rust port.
    static func tag(_ lowered: String) -> WordClass {
        let obs = observe(lowered)
        var bestState = 0
        var bestScore = initialWeights[0] + emissionWeights[0][obs.rawValue]
        for i in 1..<states.count {
            let score = initialWeights[i] + emissionWeights[i][obs.rawValue]
            if score > bestScore {
                bestScore = score
                bestState = i
            }
        }
        return states[bestState]
    }

    /// Maps a token to its single morphological observation. Checked in a
    /// fixed priority order: a non-alphabetic shape first (it dominates),
    /// then the longest/most-specific suffixes before shorter ones so that,
    /// e.g., "-tion" wins over "-on" and "-ization" routes via "-tion".
    ///
    /// The order here is part of the cross-port contract: Rust applies the
    /// identical sequence of checks. The ETL script also replicates this
    /// order exactly when computing emission counts from the training corpus.
    static func observe(_ token: String) -> Obs {
        // Non-alphabetic shape: any scalar that is not an ASCII/Unicode
        // letter routes to `nonAlpha`. Checked first because a digit or
        // symbol overrides any coincidental suffix match.
        if token.isEmpty || token.contains(where: { !$0.isLetter }) {
            return .nonAlpha
        }
        // Suffix checks, most specific first (matching ETL script and Rust).
        if token.hasSuffix("ing") { return .suffixIng }
        if token.hasSuffix("tion") || token.hasSuffix("sion") { return .suffixTion }
        if token.hasSuffix("ness") { return .suffixNess }
        if token.hasSuffix("ment") { return .suffixMent }
        if token.hasSuffix("ize") || token.hasSuffix("ise") { return .suffixIzeIse }
        if token.hasSuffix("ate") { return .suffixAte }
        if token.hasSuffix("ity") || token.hasSuffix("ty") { return .suffixItyTy }
        if token.hasSuffix("ed") { return .suffixEd }
        if token.hasSuffix("ly") { return .suffixLy }
        if token.hasSuffix("er") || token.hasSuffix("or") || token.hasSuffix("ar") {
            return .suffixErOrAr
        }
        return .plain
    }
}
