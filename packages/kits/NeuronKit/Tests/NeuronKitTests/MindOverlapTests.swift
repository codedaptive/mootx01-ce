import Testing
import SubstrateTypes
@testable import NeuronKit

// Mind-overlap lens (SPEC § 7.7). Tests assert the behavioral claims
// the spec makes — not the implementation. Each estate reduces its
// fingerprints to ONE differentially-private aggregate; only the
// aggregates are compared. Deterministic for a fixed seed (B-5) — two
// estates seeded alike produce comparable noise. Block 2
// (lineage-temporal) is excluded from the overlap: it encodes per-row
// identity, meaningless across estates.

@Suite("Mind-overlap lens (SPEC § 7.7)")
struct MindOverlapTests {

    /// A fingerprint where each 64-bit block is all-ones or all-zeros.
    private func fingerprint(_ blocks: [Bool]) -> Fingerprint256 {
        var bits = [Bool](repeating: false, count: 256)
        for (block, on) in blocks.enumerated() where on {
            for i in (block * 64)..<((block + 1) * 64) { bits[i] = true }
        }
        return .fromBits(bits)
    }

    // MO-1: the same fingerprint set, reduced under the same seed,
    // yields the same DP aggregate — overlap with itself is total
    // (deterministic DP).
    @Test("same set and seed give the same aggregate and total overlap")
    func sameSetSameSeedFullOverlap() {
        let set = [
            fingerprint([true, false, false, false]),
            fingerprint([true, true, false, false]),
        ]
        let a = NeuronKit.dpSummary(
            fingerprints: set, epsilon: 5.0, delta: 1e-6, kAnonymity: 1, seed: 0xABCD)
        let b = NeuronKit.dpSummary(
            fingerprints: set, epsilon: 5.0, delta: 1e-6, kAnonymity: 1, seed: 0xABCD)

        #expect(a == b, "same set + seed ⇒ same DP aggregate")
        #expect(abs(NeuronKit.summaryOverlap(a, b) - 1.0) < 1e-9, "self-overlap is total")
    }

    // MO-2: disjoint fingerprint spaces reduce to different aggregates
    // and overlap less than two convergent ones do.
    @Test("convergent minds overlap more than divergent ones")
    func disjointOverlapsLessThanConvergent() {
        let summaryA = NeuronKit.dpSummary(
            fingerprints: [fingerprint([true, true, false, false])],
            epsilon: 8.0, delta: 1e-6, kAnonymity: 1, seed: 0x11)
        let convergent = NeuronKit.dpSummary(
            fingerprints: [fingerprint([true, true, false, false])],
            epsilon: 8.0, delta: 1e-6, kAnonymity: 1, seed: 0x11)
        let divergent = NeuronKit.dpSummary(
            fingerprints: [fingerprint([false, false, true, true])],
            epsilon: 8.0, delta: 1e-6, kAnonymity: 1, seed: 0x11)

        let overlapConvergent = NeuronKit.summaryOverlap(summaryA, convergent)
        let overlapDivergent = NeuronKit.summaryOverlap(summaryA, divergent)
        #expect(overlapConvergent > overlapDivergent,
                "convergent minds overlap more than divergent")
    }
}
