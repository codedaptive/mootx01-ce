// TokenCompactionConformanceTests.swift
//
// Cross-language conformance gate for the §7.6 token-compaction transform
// and the §6 token-count estimator (SPEC_DISTILLATION_STORAGE §13.9).
// These are the GOLDEN VECTORS: fixed inputs → fixed byte-exact outputs,
// produced at build time from the canonical v1 ("p1") implementation and
// pinned here AND in Rust token_compaction_conformance.rs. Any divergence
// between the two suites is a parity failure.
//
// Inputs and expected values MUST NOT be changed to make tests pass.
// If a value doesn't match, fix the algorithm, not the vector. Changing
// the transform tables legitimately (a pipeline-version bump beyond "p1")
// regenerates BOTH suites together.

import Testing
@testable import SubstrateML

// Vector sources: the SPEC §5.4 example inputs (illustrative sources; the
// pinned outputs are the v1 transform's canonical renderings, which the
// spec explicitly distinguishes from its illustrative renderings).

private let v1Source = "The quarterly planning meeting has been moved from Tuesday, "
    + "March 3rd to Thursday, March 5th because the conference room on the 4th floor is "
    + "being renovated. Sarah will send out the updated calendar invites by end of day on "
    + "Monday. Please make sure to update your travel plans if you were planning to fly in "
    + "for this meeting."

private let v1Distilled = "Quarterly planning meeting moved from Tuesday, March 3rd "
    + "to Thursday, March 5th because conference room on 4th floor being renovated. Sarah "
    + "will send out updated calendar invites by end of day on Monday. Update your travel "
    + "plans if you were planning to fly in for this meeting."

private let v2Source = "I have thought about it some more, and I really don\u{2019}t "
    + "want the deluxe package after all \u{2014} the standard one is fine for what I need."

private let v2Distilled = "I have thought about it some more, and I don't want "
    + "deluxe package after all - standard one fine for what I need."

private let v3Source = "My favorite color is blue."
private let v3Distilled = "My favorite color blue."

@Suite("TokenCompaction conformance (§13.9 golden vectors)")
struct TokenCompactionConformanceTests {

    @Test("golden V1: meeting-moved renders byte-exact")
    func goldenV1() {
        #expect(TokenCompaction.compact(v1Source) == v1Distilled)
        #expect(TokenCompaction.estimateTokenCount(v1Distilled) == 66)
        // The rendering is strictly denser than the source (§13.4 payload
        // contract feeds off this property).
        #expect(TokenCompaction.estimateTokenCount(v1Distilled)
            < TokenCompaction.estimateTokenCount(v1Source))
    }

    @Test("golden V2: negation survives byte-exact")
    func goldenV2() {
        // Rule 1 over rule 2: the filler drops, the negation NEVER does,
        // and the typographic apostrophe/em-dash normalize to ASCII (rule 4).
        #expect(TokenCompaction.compact(v2Source) == v2Distilled)
        #expect(TokenCompaction.estimateTokenCount(v2Distilled) == 29)
        #expect(v2Distilled.contains("don't want"))
    }

    @Test("golden V3: short item byte-exact")
    func goldenV3() {
        #expect(TokenCompaction.compact(v3Source) == v3Distilled)
        #expect(TokenCompaction.estimateTokenCount(v3Distilled) == 6)
    }

    @Test("transform is idempotent on its own output")
    func idempotent() {
        // Re-compacting a rendering is a no-op modulo already-applied
        // rules — the hydration variants (§10.1) may compact distilled
        // text at read.
        #expect(TokenCompaction.compact(v1Distilled) == v1Distilled)
        #expect(TokenCompaction.compact(v2Distilled) == v2Distilled)
        #expect(TokenCompaction.compact(v3Distilled) == v3Distilled)
    }
}
