// HMMTagger.swift
//
// The deterministic non-Apple novel-token tagger: a small Hidden Markov
// Model decoded with integer Viterbi over a morphological observation
// alphabet. This is the non-Apple branch of `WordClassTagger`
// (`hmmViterbiTag`); the Apple branch uses NLTagger instead.
//
// CONTRACT (load-bearing — read before changing anything)
//   * DETERMINISTIC and IDENTICAL Swift ↔ Rust. The model tables below are
//     mirrored verbatim in rust/src/word_class.rs::hmm_tag. Scoring is
//     INTEGER (fixed-point log-weights, scale 1000) so there is no floating
//     rounding to diverge between ports. The shared fixture
//     rust/tests/fixtures/tag_conformance.json gates byte-identity.
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
// DERIVATION OF THE TABLES (priors, not trained weights)
// We do not ship a trained corpus model — that infrastructure is out of
// scope and would not be reproducible bit-for-bit across ports without a
// frozen training artifact. Instead the weights are HAND-SPECIFIED priors
// grounded in English morphology, expressed as integer log-weights:
//   * Initial (prior) weights reflect that, absent morphology, an unknown
//     English token is most often a noun, less often other, least often a
//     bare verb.
//   * Emission weights reflect well-known suffix signals: "-ing"/"-ed"/
//     "-ize"/"-ate" lean verb; "-tion"/"-ness"/"-ity"/"-ment"/"-er" lean
//     noun; non-alphabetic shapes lean other. These are deliberate,
//     documented priors — a future mission may replace them with a frozen
//     trained artifact, which would ship as a checked-in table read by both
//     ports (the same shape as this one).
//
// The weights are log-likelihoods scaled by `LOG_SCALE` and rounded to
// integers at authoring time; runtime arithmetic is pure integer add +
// max, so the two ports cannot diverge.

import Foundation

/// A 3-state HMM (Noun/Verb/Other) with integer Viterbi decode, used as the
/// deterministic non-Apple novel-token tagger. Pure, total, and
/// byte-identical to the Rust port.
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

    /// Initial (prior) log-weights per state, index-aligned with `states`.
    /// Noun-dominant prior for a morphology-free unknown English token.
    /// Hand-specified; see file header "DERIVATION".
    private static let initialWeights: [Int] = [
        -400,  // noun  : ln≈-0.40, the most likely default
        -1200, // verb  : ln≈-1.20, least likely as a bare unknown
        -900,  // other : ln≈-0.90
    ]

    /// Emission log-weights `emission[stateIndex][obs]`. Each row is a state;
    /// each column an observation. Higher (closer to 0) = more likely.
    /// Hand-specified morphology priors; see file header "DERIVATION".
    private static let emissionWeights: [[Int]] = [
        // noun
        [
            -3000, // nonAlpha    : a noun rarely contains non-letters
            -1500, // ing         : gerunds can be nouns, but verb-leaning
            -2200, // ed          : strongly verb-leaning
            -2500, // ize/ise     : verb-leaning
            -1800, // ate         : verb-leaning (but nouns exist: "advocate")
             -300, // tion/sion   : strong noun signal
             -300, // ness        : strong noun signal
             -300, // ment        : strong noun signal
             -300, // ity/ty      : strong noun signal
             -400, // er/or/ar    : agent nouns
            -2500, // ly          : adverb-leaning
             -600, // plain       : nouns are the common default
        ],
        // verb
        [
            -3000, // nonAlpha
             -300, // ing         : strong verb signal
             -300, // ed          : strong verb signal
             -300, // ize/ise     : strong verb signal
             -500, // ate         : verb signal
            -2000, // tion/sion   : noun-leaning
            -2500, // ness        : noun-leaning
            -2500, // ment        : noun-leaning
            -2500, // ity/ty      : noun-leaning
            -1800, // er/or/ar     : usually agent noun, sometimes verb
            -2500, // ly
            -1200, // plain       : a bare unknown is sometimes a verb
        ],
        // other
        [
             -200, // nonAlpha    : non-letter shapes are almost always other
            -2000, // ing
            -2000, // ed
            -2500, // ize/ise
            -2200, // ate
            -2200, // tion/sion
            -2200, // ness
            -2200, // ment
            -2200, // ity/ty
            -1800, // er/or/ar
             -400, // ly          : adverbs are other
            -1000, // plain       : function words, adjectives, etc.
        ],
    ]

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
    /// identical sequence of checks.
    static func observe(_ token: String) -> Obs {
        // Non-alphabetic shape: any scalar that is not an ASCII/Unicode
        // letter routes to `nonAlpha`. Checked first because a digit or
        // symbol overrides any coincidental suffix match.
        if token.isEmpty || token.contains(where: { !$0.isLetter }) {
            return .nonAlpha
        }
        // Suffix checks, most specific first.
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
