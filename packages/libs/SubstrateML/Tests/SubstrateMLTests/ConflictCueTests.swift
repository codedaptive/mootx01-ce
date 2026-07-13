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
        // Both sides negated → same stance, not asymmetry.
        #expect(ConflictCue.evaluate(
            "Bob does not live in Paris",
            "Bob does not live in Paris anymore").kind == .none)
        // Different word (non-value) in the same template must NOT fire
        // valueDivergence — that judgment belongs to the agent.
        #expect(ConflictCue.evaluate(
            "Bob lives in Paris today",
            "Bob lives in Rome today").kind == .none)
        // Empty inputs.
        #expect(ConflictCue.evaluate("", "Bob lives in Paris").kind == .none)
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
    }
}
