// ConflictCueTests.swift
//
// Pinned cross-leg vectors for the ConflictCue pairwise conflict screen.
// The SAME (a, b, kind, scoreBits) cases are mirrored verbatim in
// rust/src/conflict_cue.rs tests — a change to either leg's lexicons,
// tokenizer, or scoring must update BOTH mirrors or the legs have
// diverged. Scores are asserted by f32 bit pattern (they derive from
// the conformance-gated ShingleSimilarity plus integer ratios, so
// bit-identity holds across ports).

import Testing
import Foundation
@testable import SubstrateML

@Suite("ConflictCue")
struct ConflictCueTests {

    // MARK: - Tokenizer contract

    @Test func tokenizerContract() {
        #expect(ConflictCue.tokenize("Bob lives in Paris.") == ["bob", "lives", "in", "paris"])
        #expect(ConflictCue.tokenize("shipped in v1.0.30!") == ["shipped", "in", "v1.0.30"])
        #expect(ConflictCue.tokenize("...") == [])
        #expect(ConflictCue.tokenize("Isn't  DONE") == ["isn", "t", "done"])

        // U+0130 İ (LATIN CAPITAL LETTER I WITH DOT ABOVE) lowercases to
        // "i" + U+0307 (COMBINING DOT ABOVE). The combining scalar must act
        // as a token separator — NOT be swallowed into an ASCII token.
        // Expected: identical to "i1 x2 y3 z4" (plain i), mirrored in Rust.
        #expect(ConflictCue.tokenize("İ1 x2 y3 z4") == ["i", "1", "x2", "y3", "z4"])
        #expect(ConflictCue.tokenize("i1 x2 y3 z4") == ["i1", "x2", "y3", "z4"])
    }

    // MARK: - Unicode scalar conformance (İ cross-leg)

    @Test("İ (U+0130) tokenizer divergence regression — must match Rust output")
    func unicodeCombiningMarkTokenizer() {
        // İ lowercases to i + U+0307 (combining dot). The combining mark
        // is NOT ascii_lowercase, so Rust treats it as a separator: "İ1 ..."
        // tokenizes to ["i", "1", ...] not ["i\u{0307}1", ...].
        // Swift must agree (scalar-level iteration, not grapheme-cluster).
        let withDotAbove = ConflictCue.tokenize("İ1 x2 y3 z4")
        let plainI       = ConflictCue.tokenize("i1 x2 y3 z4")
        // Not the same token stream — İ1 splits, i1 does not.
        #expect(withDotAbove != plainI)
        #expect(withDotAbove == ["i", "1", "x2", "y3", "z4"])

        // evaluate() must also agree across legs for this input.
        // "İ1 x2 y3 z4" vs "i1 x2 y3 z4" — different token streams, but
        // neither carries negation/marker/digit-only diffs, so no cue fires.
        let r = ConflictCue.evaluate("İ1 x2 y3 z4", "i1 x2 y3 z4")
        #expect(r.kind == .none)
    }

    // MARK: - Cue detection (mirrored vectors)

    @Test("negation asymmetry fires on the same claim negated on one side")
    func negationAsymmetry() {
        let r = ConflictCue.evaluate(
            "Bob lives in Paris",
            "Bob does not live in Paris"
        )
        #expect(r.kind == .negationAsymmetry)
        #expect(r.score >= ConflictCue.borderlineThreshold)

        let contraction = ConflictCue.evaluate(
            "the feature flag is enabled in production",
            "the feature flag isn't enabled in production"
        )
        #expect(contraction.kind == .negationAsymmetry)
        #expect(contraction.score >= ConflictCue.strongThreshold)

        let noLonger = ConflictCue.evaluate(
            "the staging server is reachable from the office network",
            "the staging server is no longer reachable from the office network"
        )
        #expect(noLonger.kind == .negationAsymmetry)
        #expect(noLonger.score >= ConflictCue.strongThreshold)
    }

    @Test("value divergence fires on same-template different values")
    func valueDivergence() {
        let r = ConflictCue.evaluate(
            "the API timeout is 30 seconds",
            "the API timeout is 90 seconds"
        )
        #expect(r.kind == .valueDivergence)
        // 6 tokens, 1 diff → 5/6.
        #expect(r.score == Float(5) / Float(6))

        let version = ConflictCue.evaluate(
            "the fix shipped in release 1.0.29",
            "the fix shipped in release 1.0.30"
        )
        #expect(version.kind == .valueDivergence)
        #expect(version.score >= ConflictCue.strongThreshold)
    }

    @Test("revision marker fires over substantially similar content")
    func markerRevision() {
        let r = ConflictCue.evaluate(
            "use the staging endpoint for uploads",
            "the staging endpoint for uploads is deprecated"
        )
        #expect(r.kind == .markerRevision)
        #expect(r.score >= ConflictCue.borderlineThreshold)
    }

    // MARK: - Non-firing (precision) cases

    @Test("agreement, unrelated content, and double negation do not fire")
    func precisionGuards() {
        // Identical → agreement.
        #expect(ConflictCue.evaluate("Bob lives in Paris", "Bob lives in Paris").kind == .none)
        // Unrelated claims — negation present but no shared claim.
        #expect(ConflictCue.evaluate(
            "Bob lives in Paris",
            "the deploy pipeline is not green").kind == .none)
        // Both sides negated → same stance, not asymmetry; and the tail
        // is a pure extension (one side has no divergent value phrase),
        // so wordExclusion must not claim it either.
        #expect(ConflictCue.evaluate(
            "Bob does not live in Paris",
            "Bob does not live in Paris anymore").kind == .none)
        // Different word (non-value) in the same template must NOT fire
        // valueDivergence — but it IS the word-valued exclusion class,
        // so cue 4 surfaces it as a borderline candidate for the agent.
        #expect(ConflictCue.evaluate(
            "Bob lives in Paris today",
            "Bob lives in Rome today").kind == .wordExclusion)
        // Empty inputs.
        #expect(ConflictCue.evaluate("", "Bob lives in Paris").kind == .none)
    }

    // MARK: - Word exclusion (mirrored vectors)

    @Test("word exclusion fires on the four corpus attribute classes in the borderline band")
    func wordExclusionCorpusClasses() {
        // Full corpus-template sentences, same entity on both sides.
        // Every score must sit in [borderline, ceiling] and strictly
        // below strongThreshold — the cue can never auto-propose.
        let pairs: [(String, String)] = [
            // employer — 6 tokens each, 4-token anchor
            ("Riley Nakamura works at Acme Robotics.",
             "Riley Nakamura works at Northwind Analytics."),
            // city — 5 tokens each, 4-token anchor
            ("Riley Nakamura lives in Lisbon.",
             "Riley Nakamura lives in Toronto."),
            // role — 6 tokens each, 3-token anchor ("a" vs "an" diverges)
            ("Riley Nakamura is a staff engineer.",
             "Riley Nakamura is an engineering manager."),
            // language — 5 tokens each, 4-token anchor
            ("Riley Nakamura primarily writes Swift.",
             "Riley Nakamura primarily writes Rust."),
        ]
        for (a, b) in pairs {
            let r = ConflictCue.evaluate(a, b)
            #expect(r.kind == .wordExclusion)
            #expect(r.score >= ConflictCue.borderlineThreshold)
            #expect(r.score <= ConflictCue.wordExclusionCeiling)
            #expect(r.score < ConflictCue.strongThreshold)
        }
    }

    @Test("word exclusion guards: digit tails, cross-entity digits, unrelated sentences stay none")
    func wordExclusionGuards() {
        // Digit-valued diff over a same-length template is
        // valueDivergence's lane — unchanged by cue 4.
        let timeout = ConflictCue.evaluate(
            "the API timeout is 30 seconds",
            "the API timeout is 90 seconds"
        )
        #expect(timeout.kind == .valueDivergence)

        // Cross-entity pure-digit tails ("sarah chen 3" vs "sarah chen
        // 7") — the RCA's false-positive class — must stay none.
        #expect(ConflictCue.evaluate("Sarah Chen 3", "Sarah Chen 7").kind == .none)

        // Single shared leading token is not a substantial anchor.
        #expect(ConflictCue.evaluate(
            "the deploy pipeline is green",
            "the build server is fast").kind == .none)

        // Shared two-token opening but anchor fraction below half of
        // the longer stream — unrelated continuation, stays none.
        #expect(ConflictCue.evaluate(
            "the team met",
            "the team shipped four features early today").kind == .none)

        // Negation asymmetry present but claim similarity too low for
        // cue 2 — the pair stays none, never downgrades to cue 4.
        #expect(ConflictCue.evaluate(
            "Bob lives in Paris",
            "the deploy pipeline is not green").kind == .none)
    }

    @Test("negation and marker pairs are unchanged by cue 4 (regression)")
    func wordExclusionDoesNotStealStrongerCues() {
        // A word-exclusion-shaped pair with a negation on one side is
        // still negation asymmetry, not word exclusion.
        let negated = ConflictCue.evaluate(
            "Riley Nakamura lives in Lisbon",
            "Riley Nakamura does not live in Lisbon"
        )
        #expect(negated.kind == .negationAsymmetry)

        // Marker pairs unchanged.
        let marker = ConflictCue.evaluate(
            "use the staging endpoint for uploads",
            "the staging endpoint for uploads is deprecated"
        )
        #expect(marker.kind == .markerRevision)
    }

    // MARK: - Tier classifier

    @Test("contradiction tier classifier maps cue kinds to tiers")
    func contradictionTierClassifier() {
        // Tier 1 is the typed-KGFact lane, produced elsewhere — this
        // screen never emits it, so no kind maps to 1.
        #expect(ConflictCueKind.valueDivergence.contradictionTier == 3)
        #expect(ConflictCueKind.negationAsymmetry.contradictionTier == 2)
        #expect(ConflictCueKind.markerRevision.contradictionTier == 2)
        #expect(ConflictCueKind.wordExclusion.contradictionTier == 2)
        #expect(ConflictCueKind.none.contradictionTier == nil)
        // Wire-stable raw value, mirrored in Rust as_str.
        #expect(ConflictCueKind.wordExclusion.rawValue == "word_exclusion")
    }

    // MARK: - Bit-pinned score vectors (cross-leg conformance)

    @Test("pinned score bit patterns match the Rust mirror")
    func pinnedScoreBits() {
        // These bit patterns are asserted VERBATIM in the Rust mirror
        // (conflict_cue.rs::pinned_score_bits). Regenerate both together.
        let v1 = ConflictCue.evaluate(
            "the API timeout is 30 seconds",
            "the API timeout is 90 seconds"
        )
        #expect(v1.score.bitPattern == (Float(5) / Float(6)).bitPattern)

        let v2 = ConflictCue.evaluate(
            "Bob lives in Paris",
            "Bob does not live in Paris"
        )
        #expect(v2.kind == .negationAsymmetry)
        // Claim similarity of "bob lives in paris" vs "bob does live in
        // paris" via ShingleSimilarity — pin the exact bits.
        let expected = ShingleSimilarity.similarity(
            "bob lives in paris", "bob does live in paris")
        #expect(v2.score.bitPattern == expected.bitPattern)

        // wordExclusion scores are borderline + bandWidth * anchorFraction
        // (anchor tokens / longer stream length), computed in f32 in this
        // exact op order in both legs. Pin the bits per corpus class.
        func wordExclusionScore(anchor: Int, total: Int) -> Float {
            min(
                ConflictCue.borderlineThreshold
                    + ConflictCue.wordExclusionBandWidth * (Float(anchor) / Float(total)),
                ConflictCue.wordExclusionCeiling)
        }
        // employer: anchor 4 of 6 tokens.
        let employer = ConflictCue.evaluate(
            "Riley Nakamura works at Acme Robotics.",
            "Riley Nakamura works at Northwind Analytics.")
        #expect(employer.kind == .wordExclusion)
        #expect(employer.score.bitPattern == wordExclusionScore(anchor: 4, total: 6).bitPattern)
        // city: anchor 4 of 5 tokens.
        let city = ConflictCue.evaluate(
            "Riley Nakamura lives in Lisbon.",
            "Riley Nakamura lives in Toronto.")
        #expect(city.kind == .wordExclusion)
        #expect(city.score.bitPattern == wordExclusionScore(anchor: 4, total: 5).bitPattern)
        // role: anchor 3 of 6 tokens ("a" vs "an" diverges at index 3).
        let role = ConflictCue.evaluate(
            "Riley Nakamura is a staff engineer.",
            "Riley Nakamura is an engineering manager.")
        #expect(role.kind == .wordExclusion)
        #expect(role.score.bitPattern == wordExclusionScore(anchor: 3, total: 6).bitPattern)
        // language: anchor 4 of 5 tokens.
        let language = ConflictCue.evaluate(
            "Riley Nakamura primarily writes Swift.",
            "Riley Nakamura primarily writes Rust.")
        #expect(language.kind == .wordExclusion)
        #expect(language.score.bitPattern == wordExclusionScore(anchor: 4, total: 5).bitPattern)
    }
}
